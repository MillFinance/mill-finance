// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Mill} from "../src/Mill.sol";
import {MockERC20} from "../test/Mocks.sol";

/// @notice Stands up a playground on a local anvil: a mock TKN, a Mill over it,
///         and a pre-minted balance for anvil's first account.
///
///   anvil
///   forge script script/LocalDev.s.sol:LocalDev --rpc-url http://127.0.0.1:8545 --broadcast
///
/// Then paste the two printed addresses into dev-ui.html.
contract LocalDev is Script {
    // anvil's deterministic account #0
    uint256 constant PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        // PK is anvil's published account 0. Without this guard, a shell-history
        // recall that keeps --broadcast but swaps the RPC deploys real contracts
        // owned by a key every developer on earth has.
        require(block.chainid == 31337, "local script: anvil only");
        address me = vm.addr(PK);
        vm.startBroadcast(PK);

        MockERC20 tkn = new MockERC20("Test Token", "TKN", 18);
        tkn.mint(me, 1_000_000e18);

        Mill mill = new Mill(
            IERC20(address(tkn)),
            "Mill TKN",
            "mTKN",
            25, // 0.25% wrap
            50, // 0.50% unwrap
            5_000, // immutable burn floor, 50%
            7_000, // starting burn share, 70%
            1_000, // LP share, 10%
            me, // feeRecipient
            me, // lpRecipient
            me // owner
        );

        // Seed as first depositor — closes the inflation-attack window by size.
        tkn.approve(address(mill), type(uint256).max);
        mill.wrap(10_000e18, me);
        mill.processFees();

        vm.stopBroadcast();

        console2.log("");
        console2.log("  paste these into dev-ui.html");
        console2.log("  ----------------------------");
        console2.log("  TKN  ", address(tkn));
        console2.log("  MILL ", address(mill));
        console2.log("  you  ", me);
        console2.log("");
        console2.log("  ratio (1e18) ", mill.ratio());
        console2.log("  totalAssets  ", mill.totalAssets());
        console2.log("  totalSupply  ", mill.totalSupply());
    }
}
