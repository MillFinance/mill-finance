// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ---------------------------------------------------------------------------
// PREREQUISITES — this file will not compile until both are done, so add it to
// script/ LAST or your whole build breaks.
//
//   1. Save the verified DirectionalFeeHook source to src/DirectionalFeeHook.sol
//        https://robinhoodchain.blockscout.com/address/0x62F788a21a26eE3fE5D70ef6Ef9942D8B2cb8044?tab=contract
//      Use the explorer's source rather than retyping it — you are deploying
//      this with real money behind it and transcription errors are silent.
//
//      Note its licence: GPL-2.0-or-later. Deploying it unmodified is fine.
//      If you *modify* it, your modified source must also be GPL — which is a
//      real consideration if the rest of your stack is meant to be BUSL or MIT.
//
//   2. forge install Uniswap/v4-core
//      then in foundry.toml:
//        remappings = [..., "v4-core/=lib/v4-core/"]
//        evm_version = "cancun"          # v4 uses transient storage
// ---------------------------------------------------------------------------

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {DirectionalFeeHook} from "../src/DirectionalFeeHook.sol";

/// @notice Mines a CREATE2 salt and deploys your own DirectionalFeeHook, so the
///         owner key is yours rather than 0x525B02d5…
///
///   PRIVATE_KEY=0x... HOOK_OWNER=0x<your multisig> \
///     forge script script/DeployHook.s.sol:DeployHook \
///       --rpc-url $RH_RPC --broadcast --verify -vvvv
///
/// Run without --broadcast first: it prints the address it will land on, and
/// the flags, without spending anything.
contract DeployHook is Script {
    // afterSwap (1<<6) | afterSwapReturnDelta (1<<2)
    uint160 constant FLAGS = 0x0044;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function run() external returns (DirectionalFeeHook hook) {
        address owner = vm.envAddress("HOOK_OWNER");

        bytes memory initCode =
            abi.encodePacked(type(DirectionalFeeHook).creationCode, abi.encode(IPoolManager(POOL_MANAGER), owner));

        (address predicted, bytes32 salt) = HookMiner.find(HookMiner.CREATE2_DEPLOYER, FLAGS, initCode);

        console2.log("salt         ", uint256(salt));
        console2.log("will land at ", predicted);
        console2.log("flags        ", uint160(predicted) & 0x3FFF);
        require(HookMiner.hasFlags(predicted, FLAGS), "mined address lacks flags");

        vm.startBroadcast();
        hook = new DirectionalFeeHook{salt: salt}(IPoolManager(POOL_MANAGER), owner);
        vm.stopBroadcast();

        // The hook's own constructor calls validateHookPermissions, so a bad
        // salt would already have reverted. This is belt and braces.
        require(address(hook) == predicted, "address mismatch");

        console2.log("");
        console2.log("  deployed  ", address(hook));
        console2.log("  owner     ", hook.owner());
        console2.log("  maxFeeBps ", hook.MAX_FEE_BPS());
    }
}

/// @notice Configures ONE pool on your hook.
///
/// @dev    READ THIS. `configurePool` is once-only per pool. Its initial rates
///         apply instantly; every later change serves the 5-minute delay. There
///         is no way to reconfigure a pool to skip that delay — deliberately.
///
///         Two things to get right before broadcasting:
///
///         - The VAULT must accept both currencies. The hook `take`s straight
///           to it, and a vault that reverts on receive REVERTS EVERY SWAP on
///           the pool until the owner repoints it. Never point it at the Mill,
///           or at anything with conditional logic in its receive path.
///
///         - The direction that BUYS mTKN gets rate 0. A discount is repaired
///           by someone buying mTKN and unwrapping it; taxing that trade taxes
///           your own repair crew, and a discount is the state that makes a
///           backed wrapper look broken.
///
///   HOOK=0x... MILL=0x... QUOTE=0x... VAULT=0x... SELL_BPS=100 \
///     forge script script/DeployHook.s.sol:ConfigurePool --rpc-url $RH_RPC -vvvv
///
/// Omit --broadcast to dry-run. Do that first. Always.
contract ConfigurePool is Script {
    struct Key {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    function run() external {
        address hook = vm.envAddress("HOOK");
        address mill = vm.envAddress("MILL");
        address quote = vm.envAddress("QUOTE");
        address vault = vm.envAddress("VAULT");
        uint16 sellBps = uint16(vm.envOr("SELL_BPS", uint256(100)));
        uint24 lpFee = uint24(vm.envOr("LP_FEE", uint256(3000)));
        int24 spacing = int24(uint24(vm.envOr("TICK_SPACING", uint256(60))));

        (address c0, address c1) = mill < quote ? (mill, quote) : (quote, mill);
        Key memory key =
            Key({currency0: c0, currency1: c1, fee: lpFee, tickSpacing: spacing, hooks: hook});

        // zeroForOne buys currency1. So it buys the Mill iff the Mill is c1.
        bool zeroForOneBuysMill = (c1 == mill);
        uint16 z = zeroForOneBuysMill ? 0 : sellBps;
        uint16 o = zeroForOneBuysMill ? sellBps : 0;

        console2.log("currency0    ", c0);
        console2.log("currency1    ", c1);
        console2.log("lpFee        ", lpFee);
        console2.log("vault        ", vault);
        console2.log("zeroForOneBps", z);
        console2.log("oneForZeroBps", o);
        console2.log(zeroForOneBuysMill ? "  (zeroForOne buys mTKN -> zeroed)" : "  (oneForZero buys mTKN -> zeroed)");

        // A low-level call to an address with no code returns success with empty
        // returndata, so without this the script would print ">>> configured"
        // against a typo'd or wrong-chain HOOK and the operator would go on to
        // the irreversible InitPool believing the fee was live.
        require(hook.code.length > 0, "HOOK has no code on this chain");

        vm.startBroadcast();
        (bool ok, bytes memory err) = hook.call(
            abi.encodeWithSignature(
                "configurePool((address,address,uint24,int24,address),address,uint16,uint16)", key, vault, z, o
            )
        );
        vm.stopBroadcast();

        // configurePool is onlyOwner on the hook. If HOOK_OWNER was set to a
        // multisig at deployment — as it should be — this call has to come from
        // there, not from the deployer key, and it will revert here.
        if (!ok) {
            console2.log(">>> configurePool REVERTED");
            console2.logBytes(err);
            revert("configurePool failed");
        }
        console2.log(">>> configured");
    }
}
