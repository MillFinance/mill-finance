// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MillLPStaking, IPosm721} from "../src/MillLPStaking.sol";
import {MillPoolMath} from "../src/MillPoolMath.sol";
import {MillLens} from "../src/MillLens.sol";

/// @notice Deploys the LP staking vault for one Mill's pool.
///
///   MILL=0x… QUOTE=0x… HOOK=0x… LP_FEE=3000 TICK_SPACING=60 \
///     forge script script/DeployLPStaking.s.sol:DeployLPStaking \
///       --rpc-url $RH_RPC --account deployer --sender 0x… --broadcast -vvvv
///
/// @dev AFTER deploying, the Mill's owner must point the LP leg at it:
///        mill.setLpRecipient(<this address>)
///      Until that call the vault receives nothing. It is a separate transaction
///      on purpose — the vault should exist and be inspectable before any revenue
///      is routed into it.
contract DeployLPStaking is Script {
    address constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;

    function run() external returns (MillLPStaking vault) {
        address mill  = vm.envAddress("MILL");
        address quote = vm.envAddress("QUOTE");
        address hook  = vm.envAddress("HOOK");
        uint24 lpFee  = uint24(vm.envOr("LP_FEE", uint256(3000)));
        int24 spacing = int24(uint24(vm.envOr("TICK_SPACING", uint256(60))));

        // Required, not defaulted to msg.sender. In a forge script msg.sender is
        // the --sender flag, or forge's own default caller if it is omitted — an
        // address with no known key. `rescuer` is immutable, so defaulting to it
        // would silently deploy a vault whose rescue path can never be used.
        address rescuer = vm.envAddress("RESCUER");
        require(rescuer != address(0), "RESCUER is required");

        (address c0, address c1,) = MillPoolMath.order(mill, quote);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0), currency1: Currency.wrap(c1),
            fee: lpFee, tickSpacing: spacing, hooks: IHooks(hook)
        });

        // The vault's pool identity is immutable. A wrong LP_FEE, TICK_SPACING or
        // HOOK produces a plausible-looking poolId for a pool that does not
        // exist: every stake would revert WrongPool while the LP fee leg piled up
        // unreachable. Check against a live pool before committing.
        address lens = vm.envOr("LENS", address(0));
        if (lens != address(0)) {
            require(MillLens(lens).poolState(key).initialized, "no initialised pool at this key");
        } else {
            require(vm.envOr("SKIP_POOL_CHECK", false), "set LENS to verify the pool, or SKIP_POOL_CHECK=true");
        }

        console2.log("reward (pod token)", mill);
        console2.log("currency0         ", c0);
        console2.log("currency1         ", c1);

        vm.startBroadcast();
        vault = new MillLPStaking(IERC20(mill), IPosm721(POSITION_MANAGER), key, rescuer);
        vm.stopBroadcast();

        console2.log("");
        console2.log("  LP_STAKING      ", address(vault));
        console2.log("  poolId          ");
        console2.logBytes25(vault.poolId());
        console2.log("  tickLower/Upper ");
        console2.log(int256(vault.tickLower()));
        console2.log(int256(vault.tickUpper()));
        console2.log("");
        console2.log("NOW route the LP leg to it, from the Mill's owner:");
        console2.log("  mill.setLpRecipient(<LP_STAKING>)");
    }
}
