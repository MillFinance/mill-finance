// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {Mill} from "../src/Mill.sol";
import {MillLens, IPosmLite} from "../src/MillLens.sol";
import {MillLPStaking, IPosm721} from "../src/MillLPStaking.sol";
import {MillPoolMath} from "../src/MillPoolMath.sol";
import {MockERC20} from "../test/Mocks.sol";

/// @notice The whole v4 stack on a local anvil — PoolManager, Permit2,
///         PositionManager, a Mill, an initialised pool and the lens — so the
///         front end's liquidity flow can be exercised against real contracts
///         rather than a mock.
///
///   forge script script/LocalStack.s.sol:LocalStack --rpc-url http://127.0.0.1:8545 --broadcast
contract LocalStack is Script {
    uint256 constant PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        // PK is anvil's published account 0. Without this guard, a shell-history
        // recall that keeps --broadcast but swaps the RPC deploys real contracts
        // owned by a key every developer on earth has.
        require(block.chainid == 31337, "local script: anvil only");
        address me = vm.addr(PK);
        vm.startBroadcast(PK);

        address pm      = deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(me));
        address permit2 = deployCode("out/Permit2.sol/Permit2.json");
        address posm    = deployCode("out/PositionManager.sol/PositionManager.json",
                            abi.encode(pm, permit2, uint256(300_000), address(0), address(0)));
        MillLens lens = new MillLens(IPoolManager(pm), IPosmLite(posm));

        MockERC20 tkn = new MockERC20("Thinking Cat", "HMM", 18);
        tkn.mint(me, 2_000_000e18);
        Mill mill = new Mill(IERC20(address(tkn)), "Milled Thinking Cat", "mHMM",
                             25, 50, 5_000, 7_000, 1_000, me, me, me);
        tkn.approve(address(mill), type(uint256).max);
        mill.wrap(200_000e18, me);
        mill.unwrap(5_000e21, me);   // some churn so the ratio is off 1.0
        mill.wrap(1_000e18, me);

        (address c0, address c1, bool m0) = MillPoolMath.order(address(mill), address(tkn));
        PoolKey memory key = PoolKey({currency0:Currency.wrap(c0), currency1:Currency.wrap(c1),
                                      fee:3000, tickSpacing:60, hooks:IHooks(address(0))});
        IPoolManager(pm).initialize(key, MillPoolMath.sqrtPriceAtRatio(mill.ratio(), mill.DECIMALS_OFFSET(), m0));

        MillLPStaking staking = new MillLPStaking(IERC20(address(mill)), IPosm721(posm), key, me);
        mill.setLpRecipient(address(staking));
        // a little churn so the vault already has something waiting
        mill.wrap(500e18, me);
        mill.unwrap(100e21, me);

        vm.stopBroadcast();

        console2.log("");
        console2.log("  POOL_MANAGER    ", pm);
        console2.log("  PERMIT2         ", permit2);
        console2.log("  POSITION_MANAGER", posm);
        console2.log("  LENS            ", address(lens));
        console2.log("  STAKING         ", address(staking));
        console2.log("  TKN             ", address(tkn));
        console2.log("  MILL            ", address(mill));
        console2.log("  currency0       ", c0);
        console2.log("  currency1       ", c1);
        console2.log("  ratio           ", mill.ratio());
    }
}
