// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Mill} from "../src/Mill.sol";
import {MockERC20} from "./Mocks.sol";

/// @notice Not a correctness test. This answers the only question that decides
///         whether the protocol is worth launching: given a level of churn,
///         what yield does a passive holder actually see?
contract EconomicsTest is Test {
    MockERC20 tkn;
    Mill mill;

    address lp = address(0x11);
    address arber = address(0x22);
    address holder = address(0x33);

    uint256 constant TVL = 1_000_000e18;

    function setUp() public {
        tkn = new MockERC20("Token", "TKN", 18);
        // 0.25% wrap, 0.50% unwrap, 70% of fees burned to holders.
        mill = new Mill(IERC20(address(tkn)), "Mill TKN", "mTKN", 25, 50, 5_000, 7_000, 0, address(0xFEE), address(0x11B), address(this));

        tkn.mint(holder, TVL);
        tkn.mint(arber, 100_000_000e18);
        vm.prank(holder);
        tkn.approve(address(mill), type(uint256).max);
        vm.prank(arber);
        tkn.approve(address(mill), type(uint256).max);

        vm.prank(holder);
        mill.wrap(TVL, holder);
        mill.processFees();
    }

    function _aps() internal view returns (uint256) {
        return (mill.totalAssets() + 1) * 1e27 / (mill.totalSupply() + 10 ** mill.DECIMALS_OFFSET());
    }

    /// @dev One "arb round trip" = wrap X, unwrap X. That is what an arbitrageur
    ///      does to close a premium and then a discount. `dailyTurnover` is that
    ///      volume as a fraction of TVL.
    function _simulate(uint256 dailyTurnoverBps, uint256 days_) internal returns (uint256 apr) {
        uint256 start = _aps();
        uint256 perDay = (TVL * dailyTurnoverBps) / 10_000;

        for (uint256 d; d < days_; d++) {
            vm.prank(arber);
            uint256 s = mill.wrap(perDay, arber);
            vm.prank(arber);
            mill.unwrap(s, arber);
            mill.processFees();
        }

        uint256 end = _aps();
        uint256 growth = (end - start) * 1e18 / start; // fractional growth over the window
        apr = growth * 365 / days_; // 1e18 == 100%
    }

    function test_YieldAtVaryingChurn() public {
        uint256[4] memory turnovers = [uint256(100), 500, 2_000, 10_000]; // 1%, 5%, 20%, 100% of TVL per day

        console2.log("");
        console2.log("  holder APR vs daily churn  (0.25%/0.50% fees, 70%% burned)");
        console2.log("  ---------------------------------------------------------");

        for (uint256 i; i < turnovers.length; i++) {
            uint256 snap = vm.snapshotState();
            uint256 apr = _simulate(turnovers[i], 90);
            console2.log(
                string.concat(
                    "  daily churn ",
                    vm.toString(turnovers[i] / 100),
                    "% of TVL  ->  holder APR ",
                    vm.toString(apr / 1e14),
                    " bps"
                )
            );
            vm.revertToState(snap);
        }
        console2.log("");
    }

    function test_RatioClimbsOverASimulatedQuarter() public {
        uint256 start = _aps();
        uint256 apr = _simulate(500, 90); // 5% of TVL churned daily
        uint256 end = _aps();

        assertGt(end, start, "ratio climbed");
        console2.log("  90 days at 5% daily churn:");
        console2.log("    ratio start (1e27)", start);
        console2.log("    ratio end   (1e27)", end);
        console2.log("    implied APR (bps) ", apr / 1e14);
    }
}
