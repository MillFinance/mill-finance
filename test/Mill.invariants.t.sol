// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Mill} from "../src/Mill.sol";
import {MockERC20} from "./Mocks.sol";

/// @dev Drives the Mill through random sequences. Every action re-checks the
///      ratio itself, so a regression is attributed to the exact call that
///      caused it rather than surfacing at the end of a long run.
contract Handler is Test {
    Mill public mill;
    MockERC20 public tkn;

    address[] public actors;
    uint256 public lastAps;
    uint256 public ratioDrops;

    uint256 public wraps;
    uint256 public unwraps;
    uint256 public processes;
    uint256 public donations;

    constructor(Mill mill_, MockERC20 tkn_, address[] memory actors_) {
        mill = mill_;
        tkn = tkn_;
        actors = actors_;
        lastAps = _aps();
    }

    function _aps() internal view returns (uint256) {
        return (mill.totalAssets() + 1) * 1e27 / (mill.totalSupply() + 10 ** mill.DECIMALS_OFFSET());
    }

    function _check() internal {
        uint256 now_ = _aps();
        if (now_ < lastAps) ratioDrops++;
        lastAps = now_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function wrap(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 1, 100_000e18);
        if (tkn.balanceOf(a) < amount) return;
        vm.prank(a);
        try mill.wrap(amount, a) {
            wraps++;
        } catch {}
        _check();
    }

    function unwrap(uint256 actorSeed, uint256 pct) external {
        address a = _actor(actorSeed);
        uint256 bal = mill.balanceOf(a);
        if (bal == 0) return;
        uint256 amount = (bal * bound(pct, 1, 10_000)) / 10_000;
        if (amount == 0) return;
        vm.prank(a);
        try mill.unwrap(amount, a) {
            unwraps++;
        } catch {}
        _check();
    }

    function processFees() external {
        try mill.processFees() {
            processes++;
        } catch {}
        _check();
    }

    function donate(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 1, 1_000e18);
        if (tkn.balanceOf(a) < amount) return;
        vm.prank(a);
        tkn.transfer(address(mill), amount);
        _check();
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 pct) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = mill.balanceOf(from);
        if (bal == 0 || from == to) return;
        uint256 amount = (bal * bound(pct, 1, 10_000)) / 10_000;
        if (amount == 0) return;
        vm.prank(from);
        mill.transfer(to, amount);
        _check();
    }
}

contract MillInvariantTest is Test {
    MockERC20 tkn;
    Mill mill;
    Handler handler;

    function setUp() public {
        tkn = new MockERC20("Token", "TKN", 18);
        mill = new Mill(IERC20(address(tkn)), "Mill TKN", "mTKN", 25, 50, 5_000, 7_000, 1_000, address(0xFEE), address(0x11B), address(this));

        address[] memory actors = new address[](4);
        for (uint256 i; i < 4; i++) {
            actors[i] = address(uint160(0x1000 + i));
            tkn.mint(actors[i], 10_000_000e18);
        }

        handler = new Handler(mill, tkn, actors);
        for (uint256 i; i < 4; i++) {
            vm.prank(actors[i]);
            tkn.approve(address(mill), type(uint256).max);
        }

        targetContract(address(handler));
    }

    /// @notice I2 — the redemption ratio never falls, under any sequence.
    function invariant_RatioIsMonotone() public view {
        assertEq(handler.ratioDrops(), 0, "ratio fell");
    }

    /// @notice I1 — the vault always covers every outstanding share.
    function invariant_Solvent() public view {
        assertLe(mill.convertToAssets(mill.totalSupply()), mill.totalAssets(), "undercollateralised");
    }

    /// @notice The vault only ever holds the underlying it was given.
    function invariant_NoPhantomAssets() public view {
        assertEq(mill.totalAssets(), tkn.balanceOf(address(mill)), "accounting drift");
    }
}
