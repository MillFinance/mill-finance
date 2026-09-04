// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {ForkTier2Test} from "./ForkTier2.t.sol";
import {MockERC20} from "./Mocks.sol";

/// @title  Tier 2, offline
/// @notice The same sequence and the same assertions as `ForkTier2Test`, run
///         against a PoolManager deployed right here. No RPC, no fork, no
///         network — so it runs in CI and in a locked-down shell, and it is
///         where the sequence gets debugged before any gas is spent.
///
///         The fork variant then answers the only question this one cannot:
///         whether the *live* PoolManager on Robinhood Chain behaves the same.
///
///   forge test --match-contract LocalTier2Test -vv
///
/// @dev    Requires solc 0.8.26 alongside 0.8.28 (v4-core's PoolManager pins it)
///         and v4-core's solmate submodule. See README.
contract LocalTier2Test is ForkTier2Test {
    function _bootstrap() internal override {
        pm = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        MockERC20 t = new MockERC20("Test Token", "TKN", 18);
        token = IERC20(address(t));
    }

    function _fund(address to, uint256 amount) internal override {
        MockERC20(address(token)).mint(to, amount);
    }
}
