// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MillLens, IPosmLite} from "../src/MillLens.sol";

/// @notice Deploys the read-only lens the front end reads pool state through.
///         It holds nothing and can change nothing, so this is the one deploy in
///         the stack with no security consequences at all.
///
///   forge script script/DeployLens.s.sol:DeployLens \
///     --rpc-url $RH_RPC --account deployer --sender 0x458e… --broadcast -vvvv
contract DeployLens is Script {
    address constant POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;

    function run() external returns (MillLens lens) {
        vm.startBroadcast();
        lens = new MillLens(IPoolManager(POOL_MANAGER), IPosmLite(POSITION_MANAGER));
        vm.stopBroadcast();

        console2.log("LENS            ", address(lens));
        console2.log("poolManager     ", address(lens.poolManager()));
        console2.log("positionManager ", address(lens.positionManager()));
        console2.log("");
        console2.log("Put this in the front end as CFG.lens.");
    }
}
