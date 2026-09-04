// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  HookMiner
/// @notice Finds a CREATE2 salt whose resulting address encodes the hook
///         permission bits Uniswap v4 requires.
///
/// @dev    V4 reads a hook's permissions from the low 14 bits of its own
///         address, so a hook cannot simply be deployed — the address has to be
///         mined. `DirectionalFeeHook` needs
///
///             afterSwap (1 << 6) | afterSwapReturnDelta (1 << 2) == 0x0044
///
///         and its constructor asserts this, so a wrong salt fails at deploy
///         rather than silently later.
///
///         One in 16,384 salts matches, so expect ~16k iterations. Each one is
///         a single keccak over 85 bytes because the init-code hash is computed
///         once up front — pure Solidity is fast enough that this runs in
///         under a second.
library HookMiner {
    /// @dev Deterministic CREATE2 factory, at the same address on every EVM
    ///      chain. Foundry routes `new C{salt: s}()` through it when
    ///      broadcasting, so mining must assume the same deployer.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant FLAG_MASK = 0x3FFF;

    error NoSaltFound(uint256 tried);

    /// @param deployer  the CREATE2 factory (use `CREATE2_DEPLOYER`)
    /// @param flags     required low-14-bit pattern, e.g. 0x0044
    /// @param initCode  creation code *including* abi-encoded constructor args
    function find(address deployer, uint160 flags, bytes memory initCode)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 i; i < 500_000; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);
            if (uint160(hookAddress) & FLAG_MASK == flags) return (hookAddress, salt);
        }
        revert NoSaltFound(500_000);
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash))))
        );
    }

    /// @notice True if `hook` carries exactly `flags` in its permission bits.
    function hasFlags(address hook, uint160 flags) internal pure returns (bool) {
        return uint160(hook) & FLAG_MASK == flags;
    }
}
