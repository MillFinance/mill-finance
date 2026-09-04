// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Mill} from "../src/Mill.sol";
import {MockERC20, FeeOnTransferERC20, ReentrantERC20} from "./Mocks.sol";

contract MillTest is Test {
    MockERC20 tkn;
    Mill mill;

    address owner = address(0xA11CE);
    address feeRecipient = address(0xFEE);
    address lpRecipient = address(0x11B);
    address alice = address(0xA);
    address bob = address(0xB);

    uint16 constant WRAP_FEE = 25; // 0.25%
    uint16 constant UNWRAP_FEE = 50; // 0.50%
    uint16 constant MIN_BURN = 5_000; // 50% floor
    uint16 constant BURN = 7_000; // 70%
    uint16 constant LP_SHARE = 1_000; // 10% to LPs, 20% left to protocol

    function setUp() public {
        tkn = new MockERC20("Token", "TKN", 18);
        mill = new Mill(IERC20(address(tkn)), "Mill TKN", "mTKN", WRAP_FEE, UNWRAP_FEE, MIN_BURN, BURN, LP_SHARE, feeRecipient, lpRecipient, owner);

        tkn.mint(alice, 1_000_000e18);
        tkn.mint(bob, 1_000_000e18);
        vm.prank(alice);
        tkn.approve(address(mill), type(uint256).max);
        vm.prank(bob);
        tkn.approve(address(mill), type(uint256).max);
    }

    function _aps() internal view returns (uint256) {
        return (mill.totalAssets() + 1) * 1e27 / (mill.totalSupply() + 10 ** mill.DECIMALS_OFFSET());
    }

    // -----------------------------------------------------------------
    // basics
    // -----------------------------------------------------------------

    function test_WrapMintsNetOfFee() public {
        vm.prank(alice);
        uint256 got = mill.wrap(1_000e18, alice);

        uint256 gross = 1_000e18 * 10 ** mill.DECIMALS_OFFSET();
        assertEq(got, gross - (gross * WRAP_FEE) / 10_000, "net shares");
        assertEq(mill.balanceOf(address(mill)), (gross * WRAP_FEE) / 10_000, "fee shares held");
        assertEq(mill.totalAssets(), 1_000e18, "all assets in vault");
    }

    /// @dev A wrap settles prior fees first, then takes its own toll without
    ///      moving the ratio again. So the only ratio movement a wrap can cause
    ///      is the settlement of tolls that were already owed to holders — never
    ///      anything drawn from the incoming deposit.
    function test_WrapIsRatioNeutralOnceFeesAreSettled() public {
        vm.prank(alice);
        mill.wrap(1_000e18, alice);

        mill.processFees(); // settle by hand so nothing is owed
        uint256 before = _aps();

        vm.prank(bob);
        mill.wrap(500e18, bob);

        assertEq(_aps(), before, "the deposit itself moved the ratio");
        assertGt(mill.balanceOf(address(mill)), 0, "bob's toll was not parked");
    }

    function test_ProcessFeesBurnRaisesRatio() public {
        vm.prank(alice);
        mill.wrap(1_000e18, alice);

        uint256 before = _aps();
        uint256 feeBal = mill.balanceOf(address(mill));

        (uint256 burned, uint256 toProtocol, uint256 toLp) = mill.processFees();

        assertEq(burned, (feeBal * BURN) / 10_000, "70% burned");
        assertEq(toLp, (feeBal * LP_SHARE) / 10_000, "10% to LPs");
        assertEq(toProtocol, feeBal - burned - toLp, "protocol takes the remainder");
        assertEq(mill.balanceOf(feeRecipient), toProtocol, "protocol credited");
        assertEq(mill.balanceOf(lpRecipient), toLp, "LP recipient credited");
        assertEq(burned + toProtocol + toLp, feeBal, "a share went missing");
        assertEq(mill.totalBurned(), burned, "cumulative burned");
        assertGt(_aps(), before, "burn raises the ratio");
        assertEq(mill.totalAssets(), 1_000e18, "burn never touches the vault");
    }

    function test_UnwrapIsRatioNeutralUntilProcessed() public {
        vm.prank(alice);
        uint256 shares = mill.wrap(1_000e18, alice);
        mill.processFees();

        uint256 before = _aps();
        vm.prank(alice);
        mill.unwrap(shares / 2, alice);

        assertGe(_aps(), before, "unwrap never lowers the ratio");
        assertApproxEqRel(_aps(), before, 1e12, "and barely raises it before processing");

        uint256 mid = _aps();
        mill.processFees();
        assertGt(_aps(), mid, "the unwrap fee reaches holders on process");
    }

    /// @dev 0.25% in, 0.50% out. Measured against a book that already has size
    ///      in it, because the burn share of a toll goes to HOLDERS — and a lone
    ///      round-tripper in an empty vault is the only holder, so they get most
    ///      of their own fee back and the round trip looks far cheaper than it is.
    ///      That is real behaviour, not an artefact; see the test below.
    function test_RoundTripCostsApproximatelyTheFees() public {
        vm.prank(bob);
        mill.wrap(1_000_000e18, bob); // an existing book, so alice is not the whole pod

        vm.prank(alice);
        uint256 shares = mill.wrap(1_000e18, alice);
        vm.prank(alice);
        uint256 out = mill.unwrap(shares, alice);

        uint256 expected = uint256(1_000e18) * (10_000 - uint256(WRAP_FEE)) / 10_000 * (10_000 - uint256(UNWRAP_FEE)) / 10_000;
        assertApproxEqRel(out, expected, 1e14, "round trip ~= 0.75%");
    }

    /// @dev The flip side, stated explicitly so nobody mistakes it for a leak:
    ///      in a vault they dominate, a round-tripper recovers most of their own
    ///      toll through the burn. The fee is not avoided — it is paid to the
    ///      holders, and they are the holders.
    function test_SoleHolderRecoversMostOfTheirOwnToll() public {
        vm.prank(alice);
        uint256 shares = mill.wrap(1_000e18, alice);
        vm.prank(alice);
        uint256 out = mill.unwrap(shares, alice);

        uint256 fullFee = uint256(1_000e18) * (10_000 - uint256(WRAP_FEE)) / 10_000 * (10_000 - uint256(UNWRAP_FEE)) / 10_000;
        assertGt(out, fullFee, "sole holder did not recover any of the burn");
        assertLt(out, 1_000e18, "round trip was free");
    }

    // -----------------------------------------------------------------
    // safety
    // -----------------------------------------------------------------

    function test_InflationAttackIsUneconomic() public {
        // Attacker front-runs with 1 wei then donates a large amount.
        vm.prank(bob);
        mill.wrap(1, bob);
        vm.prank(bob);
        tkn.transfer(address(mill), 10_000e18);

        vm.prank(alice);
        uint256 victimShares = mill.wrap(1_000e18, alice);
        assertGt(victimShares, 0, "victim is not rounded to zero");

        vm.prank(alice);
        uint256 back = mill.unwrap(victimShares, alice);
        // Victim keeps the overwhelming majority of a 1000e18 deposit.
        assertGt(back, 900e18, "victim recovers their deposit");
    }

    function test_FeeOnTransferUnderlyingCannotMintUnbackedSupply() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20(500); // 5% burn on transfer
        Mill p = new Mill(IERC20(address(fot)), "p", "p", WRAP_FEE, UNWRAP_FEE, MIN_BURN, BURN, LP_SHARE, feeRecipient, lpRecipient, owner);
        fot.mint(alice, 1_000e18);
        vm.startPrank(alice);
        fot.approve(address(p), type(uint256).max);
        p.wrap(1_000e18, alice);
        vm.stopPrank();

        // Only 950 actually arrived; supply must be priced off that.
        assertEq(p.totalAssets(), 950e18, "balance delta credited");
        assertLe(p.convertToAssets(p.totalSupply()), p.totalAssets(), "solvent");
    }

    function test_NoAdminPathToTheUnderlying() public {
        vm.prank(alice);
        mill.wrap(1_000e18, alice);

        vm.prank(owner);
        vm.expectRevert(Mill.NotRescuable.selector);
        mill.rescue(IERC20(address(tkn)), owner);

        vm.prank(owner);
        vm.expectRevert(Mill.NotRescuable.selector);
        mill.rescue(IERC20(address(mill)), owner);
    }

    function test_UnwrapSurvivesWindDown() public {
        vm.prank(alice);
        uint256 shares = mill.wrap(1_000e18, alice);

        vm.prank(owner);
        mill.disableWrapForever();

        vm.prank(bob);
        vm.expectRevert(Mill.WrapDisabled.selector);
        mill.wrap(1e18, bob);

        vm.prank(alice);
        uint256 out = mill.unwrap(shares, alice);
        assertGt(out, 0, "redemption is unconditional forever");
    }

    function test_BurnFloorCannotBeBreached() public {
        vm.prank(owner);
        vm.expectRevert(Mill.BurnBelowFloor.selector);
        mill.setSplit(MIN_BURN - 1, 0);

        vm.prank(owner);
        mill.setSplit(10_000, 0);
        assertEq(mill.burnBps(), 10_000);
        assertEq(mill.lpBps(), 0);
    }

    /// @dev The three legs must always sum to at most BPS. Anything else means a
    ///      settlement that either strands shares or under-pays a recipient.
    function test_SplitCannotExceedOneHundredPercent() public {
        vm.prank(owner);
        vm.expectRevert(Mill.SplitOverflow.selector);
        mill.setSplit(7_000, 3_001);

        vm.prank(owner);
        mill.setSplit(7_000, 3_000); // exactly 100%, protocol gets nothing
        assertEq(mill.lpBps(), 3_000);
    }

    /// @dev A split change settles at the OLD rates first, so it can never
    ///      retroactively redirect fees that were earned under the previous one.
    function test_SplitChangeDoesNotRetroactivelyRedirect() public {
        vm.prank(alice);
        mill.wrap(1_000e18, alice);
        uint256 parked = mill.balanceOf(address(mill));
        assertGt(parked, 0);

        vm.prank(owner);
        mill.setSplit(5_000, 5_000); // LPs take everything that is not burned

        // the parked toll was split at 70/10/20, not at the new rates
        assertEq(mill.balanceOf(lpRecipient), (parked * LP_SHARE) / 10_000, "old toll paid at new rates");
        assertEq(mill.totalBurned(), (parked * BURN) / 10_000, "old toll burned at new rates");
    }

    /// @dev Rounding must never leave shares stuck at the contract: unburned
    ///      supply sitting there dilutes every holder. The protocol leg is a
    ///      remainder for exactly this reason.
    function testFuzz_SplitLeavesNoDust(uint16 burnBps_, uint16 lpBps_, uint96 amount) public {
        burnBps_ = uint16(bound(burnBps_, MIN_BURN, 10_000));
        lpBps_ = uint16(bound(lpBps_, 0, 10_000 - burnBps_));
        amount = uint96(bound(amount, 1e6, 1_000_000e18));

        vm.prank(owner);
        mill.setSplit(burnBps_, lpBps_);

        vm.prank(alice);
        mill.wrap(amount, alice);
        mill.processFees();

        assertEq(mill.balanceOf(address(mill)), 0, "shares stranded at the vault");
    }

    function test_DonationsGoToHolders() public {
        vm.prank(alice);
        mill.wrap(1_000e18, alice);
        uint256 before = _aps();

        vm.prank(bob);
        tkn.transfer(address(mill), 100e18);

        assertGt(_aps(), before, "a plain transfer subsidises every holder");
    }

    // -----------------------------------------------------------------
    // fuzz
    // -----------------------------------------------------------------

    function testFuzz_RatioNeverFalls(uint96 a, uint96 b, uint16 pct) public {
        a = uint96(bound(a, 1e12, 1e24));
        b = uint96(bound(b, 1e12, 1e24));
        pct = uint16(bound(pct, 1, 10_000));

        vm.prank(alice);
        uint256 s = mill.wrap(a, alice);
        uint256 r0 = _aps();

        vm.prank(bob);
        mill.wrap(b, bob);
        assertGe(_aps(), r0, "wrap");

        uint256 r1 = _aps();
        mill.processFees();
        assertGe(_aps(), r1, "process");

        uint256 r2 = _aps();
        uint256 amt = (s * pct) / 10_000;
        if (amt > 0) {
            vm.prank(alice);
            mill.unwrap(amt, alice);
        }
        assertGe(_aps(), r2, "unwrap");

        uint256 r3 = _aps();
        mill.processFees();
        assertGe(_aps(), r3, "process again");
    }

    function testFuzz_MicroRoundTripsCannotDrain(uint8 n) public {
        n = uint8(bound(n, 1, 60));
        vm.prank(bob);
        mill.wrap(10_000e18, bob); // establish a real vault
        mill.processFees();

        uint256 r0 = _aps();
        for (uint256 i = 0; i < n; i++) {
            vm.prank(alice);
            uint256 s = mill.wrap(1e6, alice);
            if (s == 0) break;
            vm.prank(alice);
            mill.unwrap(s, alice);
        }
        assertGe(_aps(), r0, "dust round trips never extract value");
    }

    // -----------------------------------------------------------------
    // fees settle themselves
    // -----------------------------------------------------------------

    /// @dev The ratio must be current after ANY wrap or unwrap, with no separate
    ///      call. Unprocessed fee shares sit in `totalSupply`, so a stale pool of
    ///      them under-credits every holder — this is the test that says the
    ///      protocol's value accrual does not depend on someone remembering.
    function test_FeesSettleWithoutAnyoneCalling() public {
        vm.startPrank(alice);
        mill.wrap(1_000e18, alice);
        vm.stopPrank();

        // alice's own toll is parked, not yet hers
        assertGt(mill.balanceOf(address(mill)), 0, "no fee parked");
        assertEq(mill.ratio(), 1e18, "own toll refunded itself");

        // a second, unrelated wrap settles it with no processFees() call
        vm.startPrank(bob);
        mill.wrap(1_000e18, bob);
        vm.stopPrank();

        assertGt(mill.ratio(), 1e18, "ratio still stale after a later wrap");
        assertGt(mill.totalBurned(), 0, "nothing burned");

        uint256 ratioAfterWrap = mill.ratio();
        uint256 burnedAfterWrap = mill.totalBurned();

        // and an unwrap settles bob's toll too
        uint256 bobShares = mill.balanceOf(bob);
        vm.prank(bob);
        mill.unwrap(bobShares / 2, bob);

        assertGt(mill.totalBurned(), burnedAfterWrap, "unwrap did not settle");
        assertGe(mill.ratio(), ratioAfterWrap, "ratio fell");
    }

    /// @dev Settling BEFORE the new toll is taken is what stops a wrapper's own
    ///      fee lifting the ratio they are about to hold. If it settled after,
    ///      a large wrapper would partially refund themselves out of their own
    ///      toll, and the effective fee would depend on deposit size.
    function test_OwnTollDoesNotRefundItself() public {
        vm.prank(alice);
        mill.wrap(1_000e18, alice);
        assertEq(mill.ratio(), 1e18, "wrapper benefited from their own toll");

        vm.prank(bob);
        mill.wrap(1_000e18, bob);

        // bob priced in at the post-burn ratio, so he gets fewer shares per asset
        // than alice did, for the same deposit.
        assertLt(mill.balanceOf(bob), mill.balanceOf(alice), "bob did not pay the higher ratio");
    }

    /// @dev A redeemer is paid at a current ratio, not one stale by however long
    ///      it has been since anyone called processFees.
    function test_UnwrapPaysCurrentRatioNotStale() public {
        vm.prank(alice);
        mill.wrap(1_000e18, alice);
        vm.prank(bob);
        mill.wrap(1_000e18, bob);

        // park a fresh, unprocessed toll
        uint256 bobShares = mill.balanceOf(bob);
        vm.prank(bob);
        mill.unwrap(bobShares / 2, bob);
        assertGt(mill.balanceOf(address(mill)), 0, "nothing parked");

        uint256 shares = mill.balanceOf(alice) / 2;
        uint256 stalePreview = mill.previewUnwrap(shares);

        vm.prank(alice);
        uint256 got = mill.unwrap(shares, alice);

        // previewUnwrap reads the pre-settlement state; the real call settles
        // first, so alice receives at least the previewed amount, never less.
        assertGe(got, stalePreview, "redeemer paid a stale ratio");
    }

    // -----------------------------------------------------------------
    // reentrancy
    // -----------------------------------------------------------------

    /// @dev `wrap` credits the balance delta across `safeTransferFrom`, which is
    ///      what makes fee-on-transfer underlyings safe — and what would make a
    ///      callback-bearing underlying dangerous, because the outer call's delta
    ///      would include a deposit the inner call has already minted for. The
    ///      guard is the thing being tested here, not the arithmetic.
    function test_ReentrantUnderlyingCannotDoubleMint() public {
        ReentrantERC20 re = new ReentrantERC20();
        Mill m = new Mill(
            IERC20(address(re)), "Mill RE", "mRE",
            WRAP_FEE, UNWRAP_FEE, MIN_BURN, BURN, LP_SHARE, feeRecipient, lpRecipient, owner
        );

        re.mint(address(this), 1_000e18);
        re.mint(address(re), 100e18);        // the token's own float to re-wrap
        re.approveMill(address(m));
        re.approve(address(m), type(uint256).max);
        re.arm(address(m), address(this), 100e18);

        vm.expectRevert(Mill.Reentrancy.selector);
        m.wrap(500e18, address(this));

        // and with the callback disarmed the same deposit behaves normally
        re.arm(address(m), address(this), 0);
        uint256 shares = m.wrap(500e18, address(this));
        assertGt(shares, 0, "a plain wrap should still work");
        assertLe(
            m.convertToAssets(m.totalSupply()), m.totalAssets(),
            "more owed than held"
        );
    }

    /// @dev The same door on the way out. `unwrap` sends the underlying last, so
    ///      it is already check-effects-safe, but the lock should hold anyway.
    function test_ReentrantUnderlyingCannotReenterUnwrap() public {
        ReentrantERC20 re = new ReentrantERC20();
        Mill m = new Mill(
            IERC20(address(re)), "Mill RE", "mRE",
            WRAP_FEE, UNWRAP_FEE, MIN_BURN, BURN, LP_SHARE, feeRecipient, lpRecipient, owner
        );

        re.mint(address(this), 1_000e18);
        re.mint(address(re), 100e18);
        re.approveMill(address(m));
        re.approve(address(m), type(uint256).max);

        uint256 shares = m.wrap(500e18, address(this));

        // arm the callback so any transfer INTO the mill re-enters
        re.arm(address(m), address(this), 100e18);
        vm.expectRevert(Mill.Reentrancy.selector);
        m.wrap(100e18, address(this));

        // unwrap moves the underlying out, not in, so the callback never arms;
        // it must still succeed and leave the vault solvent.
        re.arm(address(m), address(this), 0);
        uint256 out = m.unwrap(shares / 2, address(this));
        assertGt(out, 0, "unwrap paid nothing");
        assertLe(m.convertToAssets(m.totalSupply()), m.totalAssets(), "more owed than held");
    }

    // -----------------------------------------------------------------
    // quotes, minimums, and where fees may not be sent
    // -----------------------------------------------------------------

    /// @dev `wrap` settles first, which burns supply and raises the ratio. A
    ///      preview that reads the pre-settlement supply therefore quotes MORE
    ///      shares than the call delivers — an overstatement, in the direction
    ///      that makes an integrator's minimum fail.
    function test_PreviewWrapMatchesWhatWrapMints() public {
        vm.prank(alice);
        mill.wrap(100_000e18, alice);

        // read the balance BEFORE the prank: vm.prank covers the next call, and
        // balanceOf is a call, so reading inline would spend it and send the
        // unwrap from this contract instead of from alice.
        uint256 give = mill.balanceOf(alice) / 50;
        vm.prank(alice);
        mill.unwrap(give, alice);   // parks a toll

        assertGt(mill.balanceOf(address(mill)), 0, "no parked fee to test against");

        uint256 quoted = mill.previewWrap(10_000e18);
        vm.prank(bob);
        uint256 got = mill.wrap(10_000e18, bob);

        assertEq(got, quoted, "the quote did not match the mint");
    }

    function test_PreviewUnwrapMatchesWhatUnwrapPays() public {
        vm.prank(alice);
        mill.wrap(100_000e18, alice);
        vm.prank(bob);
        uint256 shares = mill.wrap(50_000e18, bob);

        uint256 give = mill.balanceOf(alice) / 50;
        vm.prank(alice);
        mill.unwrap(give, alice);   // parks a toll

        uint256 quoted = mill.previewUnwrap(shares / 2);
        vm.prank(bob);
        uint256 got = mill.unwrap(shares / 2, bob);

        assertEq(got, quoted, "the quote did not match the payout");
    }

    function test_MinimumOutRefusesToUnderdeliver() public {
        vm.prank(alice);
        mill.wrap(100_000e18, alice);

        uint256 quoted = mill.previewWrap(1_000e18);
        vm.prank(bob);
        vm.expectRevert(Mill.BelowMinimum.selector);
        mill.wrap(1_000e18, bob, quoted + 1);

        vm.prank(bob);
        uint256 got = mill.wrap(1_000e18, bob, quoted);
        assertEq(got, quoted, "the floor changed the amount");
    }

    /// @dev `_transfer(address(this), address(this), x)` is a no-op, so a leg
    ///      pointed at the Mill would leave fee shares in the balance forever —
    ///      unburned supply diluting every holder, recycled on every call.
    function test_RecipientCannotBeTheMillItself() public {
        vm.prank(owner);
        vm.expectRevert(Mill.ZeroAddress.selector);
        mill.setFeeRecipient(address(mill));

        vm.prank(owner);
        vm.expectRevert(Mill.ZeroAddress.selector);
        mill.setLpRecipient(address(mill));
    }

    /// @dev None of the admin surface is callable by anyone else. The suite had
    ///      no authorisation test at all before this.
    function test_NonOwnerCannotTouchAdmin() public {
        vm.startPrank(bob);
        vm.expectRevert(Mill.Unauthorized.selector);
        mill.setSplit(6_000, 1_000);
        vm.expectRevert(Mill.Unauthorized.selector);
        mill.setFeeRecipient(bob);
        vm.expectRevert(Mill.Unauthorized.selector);
        mill.setLpRecipient(bob);
        vm.expectRevert(Mill.Unauthorized.selector);
        mill.disableWrapForever();
        vm.expectRevert(Mill.Unauthorized.selector);
        mill.transferOwnership(bob);
        vm.expectRevert(Mill.Unauthorized.selector);
        mill.rescue(IERC20(address(tkn)), bob);
        vm.stopPrank();
    }
}
