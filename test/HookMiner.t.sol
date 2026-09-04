// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {HookMiner} from "../src/HookMiner.sol";

/// @dev Stands in for the real hook while proving the miner works. Same shape:
///      constructor takes (poolManager, owner) and self-checks its own address,
///      which is what `validateHookPermissions` does in DirectionalFeeHook.
contract FakeHook {
    address public immutable poolManager;
    address public owner;

    error InvalidHookAddress(address actual, uint160 flags);

    constructor(address poolManager_, address owner_) {
        poolManager = poolManager_;
        owner = owner_;
        if (uint160(address(this)) & 0x3FFF != 0x0044) {
            revert InvalidHookAddress(address(this), uint160(address(this)) & 0x3FFF);
        }
    }
}

contract HookMinerTest is Test {
    // afterSwap (1<<6) | afterSwapReturnDelta (1<<2)
    uint160 constant FLAGS = 0x0044;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant OWNER = 0x525B02d556ad9A87ea491E9ee9BCD775cC20D96f;

    function _initCode() internal pure returns (bytes memory) {
        return abi.encodePacked(type(FakeHook).creationCode, abi.encode(POOL_MANAGER, OWNER));
    }

    /// @dev `new C{salt:}` deploys from the *calling contract*, so to check the
    ///      address math end to end we mine against `address(this)` and deploy
    ///      here. `forge script --broadcast` routes through the CREATE2 factory
    ///      instead, which is what the second test covers.
    function test_PredictedAddressMatchesActualDeploy() public {
        (address predicted, bytes32 salt) = HookMiner.find(address(this), FLAGS, _initCode());

        console2.log("salt       ", uint256(salt));
        console2.log("predicted  ", predicted);

        FakeHook deployed = new FakeHook{salt: salt}(POOL_MANAGER, OWNER);

        console2.log("deployed   ", address(deployed));
        console2.log("flags      ", uint160(address(deployed)) & 0x3FFF);

        assertEq(address(deployed), predicted, "CREATE2 address math is wrong");
        assertTrue(HookMiner.hasFlags(address(deployed), FLAGS), "deployed hook lacks the flags");
        assertEq(deployed.poolManager(), POOL_MANAGER);
    }

    /// @dev The salt you would actually broadcast with.
    function test_MinesForTheCanonicalCreate2Factory() public pure {
        (address predicted, bytes32 salt) = HookMiner.find(HookMiner.CREATE2_DEPLOYER, FLAGS, _initCode());

        console2.log("factory salt", uint256(salt));
        console2.log("hook address", predicted);
        assertTrue(HookMiner.hasFlags(predicted, FLAGS), "mined address lacks the flags");
    }

    function test_ArbitrarySaltIsAlmostCertainlyInvalid() public pure {
        address bad = HookMiner.computeAddress(HookMiner.CREATE2_DEPLOYER, bytes32(0), keccak256(_initCode()));
        assertFalse(HookMiner.hasFlags(bad, FLAGS), "salt 0 happened to match; not a real failure");
    }
}
