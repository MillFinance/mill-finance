// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {Mill} from "../src/Mill.sol";
import {MillPoolMath} from "../src/MillPoolMath.sol";
import {MillLPStaking, IPosm721} from "../src/MillLPStaking.sol";
import {MockERC20} from "./Mocks.sol";

interface IPermit2 { function approve(address, address, uint160, uint48) external; }
interface IPosm {
    function modifyLiquidities(bytes calldata, uint256) external payable;
    function nextTokenId() external view returns (uint256);
    function approve(address, uint256) external;
    function safeTransferFrom(address, address, uint256) external;
    function ownerOf(uint256) external view returns (address);
    function transferFrom(address, address, uint256) external;
}

/// @title  Does an LP actually get paid?
/// @notice The vault is the piece where someone else's money sits, so this is
///         the suite that matters most. It builds the whole thing — Mill, pool,
///         real positions — and then checks the arithmetic of who is owed what.
contract LPStakingTest is Test {
    uint8 constant MINT_POSITION = 0x02;
    uint8 constant SETTLE_PAIR   = 0x0d;
    int24 constant SPACING = 60;

    IPoolManager pm;
    IPermit2 permit2;
    IPosm posm;
    MockERC20 tkn;
    Mill mill;
    MillLPStaking vault;
    PoolKey key;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);
    address treasury = address(0x7EEA);

    function setUp() public {
        pm      = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        permit2 = IPermit2(deployCode("out/Permit2.sol/Permit2.json"));
        posm    = IPosm(deployCode("out/PositionManager.sol/PositionManager.json",
                    abi.encode(address(pm), address(permit2), uint256(300_000), address(0), address(0))));

        tkn = new MockERC20("Token", "TKN", 18);
        // burn 60%, LPs 20%, protocol 20% — the LP leg is what this vault receives
        mill = new Mill(IERC20(address(tkn)), "Mill TKN", "mTKN", 25, 50, 5_000, 6_000, 2_000,
                        treasury, address(this), address(this));

        tkn.mint(address(this), 10_000_000e18);
        tkn.approve(address(mill), type(uint256).max);
        mill.wrap(1_000_000e18, address(this));

        (address c0, address c1, bool m0) = MillPoolMath.order(address(mill), address(tkn));
        key = PoolKey({currency0:Currency.wrap(c0), currency1:Currency.wrap(c1),
                       fee:3000, tickSpacing:SPACING, hooks:IHooks(address(0))});
        pm.initialize(key, MillPoolMath.sqrtPriceAtRatio(mill.ratio(), mill.DECIMALS_OFFSET(), m0));

        tkn.approve(address(permit2), type(uint256).max);
        mill.approve(address(permit2), type(uint256).max);
        permit2.approve(address(tkn),  address(posm), type(uint160).max, type(uint48).max);
        permit2.approve(address(mill), address(posm), type(uint160).max, type(uint48).max);

        vault = new MillLPStaking(IERC20(address(mill)), IPosm721(address(posm)), key, address(this));
        // the Mill now pays its LP leg into the vault
        mill.setLpRecipient(address(vault));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function _ticks() internal pure returns (int24 l, int24 u) {
        l = (TickMath.MIN_TICK / SPACING) * SPACING;
        u = (TickMath.MAX_TICK / SPACING) * SPACING;
    }

    function _mint(uint256 liquidity, address owner, int24 tl, int24 tu) internal returns (uint256 id) {
        bytes memory actions = abi.encodePacked(MINT_POSITION, SETTLE_PAIR);
        bytes[] memory p = new bytes[](2);
        p[0] = abi.encode(key, tl, tu, liquidity, type(uint128).max, type(uint128).max, owner, bytes(""));
        p[1] = abi.encode(key.currency0, key.currency1);
        id = posm.nextTokenId();
        posm.modifyLiquidities(abi.encode(actions, p), block.timestamp + 60);
    }

    function _mintFull(uint256 liquidity, address owner) internal returns (uint256) {
        (int24 l, int24 u) = _ticks();
        return _mint(liquidity, owner, l, u);
    }

    /// @dev Churn the vault so the Mill actually earns something to share out.
    function _generateFees(uint256 amount) internal {
        mill.wrap(amount, address(this));
        mill.unwrap(mill.balanceOf(address(this)) / 50, address(this));
        // The unwrap's own toll is still parked in the Mill — settle it here so
        // the balances these tests snapshot are final. The auto-pull path is
        // exercised deliberately in test_ClaimPullsFeesFromTheMillWithoutAKeeper.
        mill.processFees();
    }

    /// @dev Stake, serve the warm-up, activate. A position carries no weight and
    ///      earns nothing until it is activated, so every test that expects a
    ///      staker to earn has to go through all three steps.
    function _stake(address user, uint256 id) internal {
        vm.prank(user);
        posm.safeTransferFrom(user, address(vault), id);
        vm.warp(block.timestamp + vault.WARMUP());
        _activate(id);
    }

    function _activate(uint256 id) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vault.activate(ids);
    }

    // =================================================================
    // the basics
    // =================================================================

    function test_StakeAndEarn() public {
        uint256 id = _mintFull(1_000e18, alice);
        _stake(alice, id);

        assertEq(posm.ownerOf(id), address(vault), "vault does not hold the position");
        assertEq(vault.totalWeight(), 1_000e18, "weight not recorded");
        assertEq(vault.pending(id), 0, "paid before any fees");

        _generateFees(100_000e18);
        uint256 arrived = mill.balanceOf(address(vault));
        assertGt(arrived, 0, "the Mill sent the LP leg nothing");

        assertApproxEqAbs(vault.pending(id), arrived, 1, "sole staker is not owed everything");

        vm.prank(alice);
        uint256 got = vault.claim(id);
        assertApproxEqAbs(got, arrived, 1, "claimed the wrong amount");
        assertEq(mill.balanceOf(alice), got, "alice was not paid");
        assertEq(vault.pending(id), 0, "still owed after claiming");

        console2.log("LP leg received", arrived);
        console2.log("alice claimed  ", got);
    }

    /// @dev The whole point: two LPs, different sizes, proportional split.
    function test_TwoStakersSplitProRata() public {
        uint256 a = _mintFull(1_000e18, alice);
        uint256 b = _mintFull(3_000e18, bob);
        _stake(alice, a);
        _stake(bob, b);

        _generateFees(200_000e18);
        uint256 pot = mill.balanceOf(address(vault));

        uint256 pa = vault.pending(a);
        uint256 pb = vault.pending(b);
        console2.log("pot   ", pot);
        console2.log("alice ", pa);
        console2.log("bob   ", pb);

        assertApproxEqRel(pb, pa * 3, 1e12, "not a 1:3 split");
        assertApproxEqAbs(pa + pb, pot, 2, "the split does not add up to the pot");
    }

    /// @dev Someone who joins after fees were earned must not be paid for the
    ///      period before they arrived.
    function test_LateStakerEarnsNothingRetroactively() public {
        uint256 a = _mintFull(1_000e18, alice);
        _stake(alice, a);
        _generateFees(100_000e18);
        uint256 earnedBefore = vault.pending(a);
        assertGt(earnedBefore, 0);

        uint256 b = _mintFull(1_000e18, bob);
        _stake(bob, b);

        assertEq(vault.pending(b), 0, "late staker was paid for history");
        assertApproxEqAbs(vault.pending(a), earnedBefore, 1, "early staker was diluted retroactively");

        // from here they share equally
        _generateFees(100_000e18);
        uint256 dA = vault.pending(a) - earnedBefore;
        uint256 dB = vault.pending(b);
        assertApproxEqRel(dA, dB, 1e12, "second period not split evenly");
    }

    /// @dev Fees that arrive with nothing staked must not be stranded.
    function test_RewardsArrivingWithNoStakersAreHeldNotLost() public {
        _generateFees(100_000e18);
        uint256 pot = mill.balanceOf(address(vault));
        assertGt(pot, 0);
        vault.sync();
        assertEq(vault.unallocated(), pot, "not held for the first staker");

        uint256 a = _mintFull(1_000e18, alice);
        _stake(alice, a);
        assertApproxEqAbs(vault.pending(a), pot, 1, "first staker did not receive the held rewards");
    }

    function test_UnstakeReturnsThePositionAndPays() public {
        uint256 a = _mintFull(1_000e18, alice);
        _stake(alice, a);
        _generateFees(100_000e18);

        uint256 owed = vault.pending(a);
        vm.prank(alice);
        vault.unstake(a);

        assertEq(posm.ownerOf(a), alice, "position not returned");
        assertApproxEqAbs(mill.balanceOf(alice), owed, 1, "not paid on exit");
        assertEq(vault.totalWeight(), 0, "weight not released");
        assertEq(vault.stakedCount(alice), 0, "still listed as staked");
    }

    function test_UnstakedPositionStopsEarning() public {
        uint256 a = _mintFull(1_000e18, alice);
        uint256 b = _mintFull(1_000e18, bob);
        _stake(alice, a); _stake(bob, b);

        _generateFees(100_000e18);
        vm.prank(alice); vault.unstake(a);
        uint256 bobBefore = vault.pending(b);

        _generateFees(100_000e18);
        uint256 pot2 = mill.balanceOf(address(vault));
        // bob is now the only staker, so the second lot is all his
        assertApproxEqAbs(vault.pending(b), pot2, 2, "bob did not take the whole second period");
        assertGt(vault.pending(b), bobBefore);
    }

    // =================================================================
    // what must not be allowed
    // =================================================================

    /// @dev Raw liquidity is only a fair weight at a fixed range. A narrow
    ///      position carries far more liquidity per pound, so allowing one would
    ///      let it farm the whole pot.
    function test_RejectsNarrowRangePositions() public {
        uint256 id = _mint(1_000e18, alice, -60, 60);
        vm.prank(alice);
        vm.expectRevert(MillLPStaking.NotFullRange.selector);
        posm.safeTransferFrom(alice, address(vault), id);
    }

    function test_RejectsAnotherPoolsPosition() public {
        PoolKey memory other = PoolKey({currency0:key.currency0, currency1:key.currency1,
                                        fee:500, tickSpacing:10, hooks:IHooks(address(0))});
        pm.initialize(other, MillPoolMath.sqrtPriceAtRatio(mill.ratio(), mill.DECIMALS_OFFSET(),
                      Currency.unwrap(key.currency0) == address(mill)));

        (int24 l, int24 u) = (int24(-887270), int24(887270));
        bytes memory actions = abi.encodePacked(MINT_POSITION, SETTLE_PAIR);
        bytes[] memory p = new bytes[](2);
        p[0] = abi.encode(other, l, u, uint256(1_000e18), type(uint128).max, type(uint128).max, alice, bytes(""));
        p[1] = abi.encode(other.currency0, other.currency1);
        uint256 id = posm.nextTokenId();
        posm.modifyLiquidities(abi.encode(actions, p), block.timestamp + 60);

        vm.prank(alice);
        vm.expectRevert(MillLPStaking.WrongPool.selector);
        posm.safeTransferFrom(alice, address(vault), id);
    }

    function test_OnlyOwnerCanUnstakeOrClaim() public {
        uint256 a = _mintFull(1_000e18, alice);
        _stake(alice, a);
        _generateFees(100_000e18);

        vm.prank(bob);
        vm.expectRevert(MillLPStaking.NotStaked.selector);
        vault.unstake(a);

        vm.prank(bob);
        vm.expectRevert(MillLPStaking.NotStaked.selector);
        vault.claim(a);
    }

    /// @dev A direct transfer that did not come from the position manager must
    ///      not be able to register a stake.
    function test_OnERC721ReceivedRejectsImposters() public {
        vm.prank(bob);
        vm.expectRevert(MillLPStaking.NotOwner.selector);
        vault.onERC721Received(bob, bob, 1, "");
    }

    /// @dev The contract must never owe more than it holds.
    function testFuzz_NeverOwesMoreThanItHolds(uint96 la, uint96 lb, uint96 churn) public {
        la = uint96(bound(la, 1e15, 1e24));
        lb = uint96(bound(lb, 1e15, 1e24));
        churn = uint96(bound(churn, 1e18, 500_000e18));

        uint256 a = _mintFull(la, alice);
        uint256 b = _mintFull(lb, bob);
        _stake(alice, a); _stake(bob, b);

        _generateFees(churn);
        vault.sync();

        uint256 owed = vault.pending(a) + vault.pending(b) + vault.unallocated();
        assertLe(owed, mill.balanceOf(address(vault)), "vault owes more than it holds");

        vm.prank(alice); vault.claim(a);
        vm.prank(bob);   vault.claim(b);
        assertLe(vault.pending(a) + vault.pending(b), 1, "still owed after both claimed");
    }

    // =================================================================
    // stranded positions, and fees without a keeper
    // =================================================================

    /// @dev `transferFrom` skips `onERC721Received`, so a position sent that way
    ///      registers no stake and would otherwise sit here forever.
    function test_RescueReturnsAStrandedPosition() public {
        uint256 id = _mintFull(1_000e18, alice);
        vm.prank(alice);
        posm.transferFrom(alice, address(vault), id);

        assertEq(posm.ownerOf(id), address(vault), "vault does not hold it");
        (address owner_,,,,) = vault.stakes(id);
        assertEq(owner_, address(0), "a plain transfer should not register a stake");
        assertEq(vault.totalWeight(), 0, "it must not earn");

        vault.rescue(id, alice);
        assertEq(posm.ownerOf(id), alice, "not returned");
    }

    /// @dev Rescue must never be a back door out of a real stake.
    function test_RescueCannotTouchAStakedPosition() public {
        uint256 id = _mintFull(1_000e18, alice);
        _stake(alice, id);
        vm.expectRevert(MillLPStaking.AlreadyStaked.selector);
        vault.rescue(id, address(this));
    }

    function test_OnlyRescuerCanRescue() public {
        uint256 id = _mintFull(1_000e18, alice);
        vm.prank(alice);
        posm.transferFrom(alice, address(vault), id);

        vm.prank(bob);
        vm.expectRevert(MillLPStaking.Unauthorized.selector);
        vault.rescue(id, bob);
    }

    /// @dev Nobody runs `processFees` on a timer. A staker clicking claim settles
    ///      the Mill on the way in, so their payout includes the toll earned right
    ///      up to that block.
    function test_ClaimPullsFeesFromTheMillWithoutAKeeper() public {
        uint256 a = _mintFull(1_000e18, alice);
        _stake(alice, a);

        // churn WITHOUT settling afterwards
        mill.wrap(100_000e18, address(this));
        mill.unwrap(mill.balanceOf(address(this)) / 50, address(this));

        uint256 parked = mill.balanceOf(address(mill));
        assertGt(parked, 0, "nothing left parked to test with");
        uint256 inVaultBefore = mill.balanceOf(address(vault));

        vm.prank(alice);
        uint256 got = vault.claim(a);

        assertEq(mill.balanceOf(address(mill)), 0, "the claim did not settle the Mill");
        assertGt(got, inVaultBefore, "the claim did not include the freshly pulled fees");
        assertEq(mill.balanceOf(alice), got, "alice was not paid what she claimed");
        assertEq(vault.pending(a), 0, "still owed after claiming");
        console2.log("already in vault", inVaultBefore);
        console2.log("pulled in by claim", got - inVaultBefore);
    }

    // =================================================================
    // the warm-up, and the empty-vault pot
    // =================================================================

    /// @dev The attack the warm-up exists for: mint full-range liquidity in front
    ///      of a large wrap, stake, take the fee, burn the position. Full-range
    ///      liquidity costs nothing to mint and burn at the current price, so
    ///      without a delay this is free money taken from real LPs.
    function test_FlashLiquidityCannotTakeAFeeEvent() public {
        uint256 honest = _mintFull(1_000e18, alice);
        _stake(alice, honest);

        // the bot stakes and does NOT serve the delay
        uint256 flash = _mintFull(100_000e18, bob);
        vm.prank(bob);
        posm.safeTransferFrom(bob, address(vault), flash);

        assertEq(vault.totalWeight(), 1_000e18, "warming weight must not count");
        assertEq(vault.warming(), 1, "not recorded as warming");

        _generateFees(200_000e18);
        uint256 pot = mill.balanceOf(address(vault));

        assertEq(vault.pending(flash), 0, "a warming position earned");
        assertApproxEqAbs(vault.pending(honest), pot, 2, "the honest staker did not take the whole period");

        vm.prank(bob);
        assertEq(vault.claim(flash), 0, "a warming position was paid");
    }

    /// @dev And waiting out the delay must not retroactively unlock the period —
    ///      the reason weight is excluded rather than merely denied.
    function test_WaitingOutTheDelayDoesNotUnlockThePastPeriod() public {
        uint256 honest = _mintFull(1_000e18, alice);
        _stake(alice, honest);

        uint256 late = _mintFull(1_000e18, bob);
        vm.prank(bob);
        posm.safeTransferFrom(bob, address(vault), late);

        _generateFees(100_000e18);
        uint256 owedToAlice = vault.pending(honest);

        vm.warp(block.timestamp + vault.WARMUP());
        _activate(late);

        assertEq(vault.pending(late), 0, "the warm-up period was unlocked by waiting");
        assertApproxEqAbs(vault.pending(honest), owedToAlice, 2, "the honest staker was diluted after the fact");
    }

    function test_ActivationIsPermissionlessButNotEarly() public {
        uint256 id = _mintFull(1_000e18, alice);
        vm.prank(alice);
        posm.safeTransferFrom(alice, address(vault), id);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.expectRevert(MillLPStaking.NotWarm.selector);
        vault.activate(ids);

        vm.warp(block.timestamp + vault.WARMUP());
        vm.prank(bob);            // anyone at all
        vault.activate(ids);
        assertEq(vault.totalWeight(), 1_000e18, "not activated");
        assertEq(vault.warming(), 0, "warming counter not cleared");
    }

    function test_UnstakingWhileWarmingLeavesNoResidue() public {
        uint256 id = _mintFull(1_000e18, alice);
        vm.prank(alice);
        posm.safeTransferFrom(alice, address(vault), id);
        vm.prank(alice);
        vault.unstake(id);

        assertEq(vault.warming(), 0, "warming counter not released");
        assertEq(vault.totalWeight(), 0, "weight leaked");
        assertEq(posm.ownerOf(id), alice, "position not returned");
    }

    /// @dev Reward that lands with nothing staked is held for the next arrival,
    ///      which means one dust position could otherwise take months of fees.
    ///      The rescuer can move it out — but only while nothing is at stake.
    function test_SweepOnlyRunsWhenTheVaultIsTrulyEmpty() public {
        _generateFees(100_000e18);
        vault.sync();
        uint256 held = vault.unallocated();
        assertGt(held, 0);

        // a warming position blocks the sweep
        uint256 id = _mintFull(1_000e18, alice);
        vm.prank(alice);
        posm.safeTransferFrom(alice, address(vault), id);
        vm.expectRevert(MillLPStaking.StillStaked.selector);
        vault.sweepUnallocated(treasury);

        // and so does an active one
        vm.warp(block.timestamp + vault.WARMUP());
        _activate(id);
        vm.expectRevert(MillLPStaking.StillStaked.selector);
        vault.sweepUnallocated(treasury);
    }

    function test_SweepReturnsTheHeldPotAndOnlyToTheRescuer() public {
        _generateFees(100_000e18);
        vault.sync();
        uint256 held = vault.unallocated();
        assertGt(held, 0);

        vm.prank(bob);
        vm.expectRevert(MillLPStaking.Unauthorized.selector);
        vault.sweepUnallocated(bob);

        // the natural destination is the Mill: what lands there is re-split by
        // the next processFees, so most of it is burned back to holders
        uint256 before = mill.balanceOf(address(mill));
        uint256 swept = vault.sweepUnallocated(address(mill));

        assertEq(swept, held, "swept the wrong amount");
        assertEq(mill.balanceOf(address(mill)) - before, held, "the Mill did not receive it");
        assertEq(vault.unallocated(), 0, "still held");
        assertEq(vault.accounted(), mill.balanceOf(address(vault)), "accounting drifted from the balance");
    }
}
