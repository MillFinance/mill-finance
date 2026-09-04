// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {Mill} from "../src/Mill.sol";
import {MillPoolMath} from "../src/MillPoolMath.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {DirectionalFeeHook} from "../src/DirectionalFeeHook.sol";

/// @title  Tier 2 — pool, liquidity, real swaps, and the measured arb band
///
/// @notice Everything tier 1 could not answer, against live Robinhood Chain
///         state. This is the full step-7 sequence executed in simulation:
///         deploy a Mill, deploy your own hook, configure the pool, initialise
///         it at `ratio()`, mint a position, and swap it in every direction.
///
///         Run:
///           RH_RPC=https://rpc.mainnet.chain.robinhood.com \
///             forge test --match-contract ForkTier2Test -vv
///
///         Point it at the token you actually intend to use:
///           TOKEN=0x<pons token> RH_RPC=... forge test --match-contract ForkTier2Test -vv
///
///         If `deal` cannot mint that token (non-standard balance storage), set
///         TOKEN_WHALE to any address holding a large balance and it will prank
///         a transfer instead.
///
/// @dev    The pool here is mTKN/TKN — the Mill paired against its own
///         underlying. That is deliberate for measurement: pool price should
///         sit exactly at `ratio()`, so any deviation is cost rather than
///         market. A real mTKN/QUOTE pool adds the QUOTE pool's own tax to
///         every arb round trip, twice. That number is not measured here.
contract ForkTier2Test is Test {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    uint160 constant HOOK_FLAGS = 0x0044;
    uint24 constant LP_FEE = 3000; // 0.30%
    int24 constant TICK_SPACING = 60;
    /// @dev Full-range liquidity L. At a raw price of 1e-3 this puts roughly
    ///      `LIQUIDITY_MULT * sqrt(1e-3)` whole units of the underlying in the
    ///      pool — deep enough that a small probe measures fees, not impact.
    uint256 constant LIQUIDITY_MULT = 30_000;

    // The Mill's own parameters, as the README's launch order sets them.
    uint16 constant WRAP_BPS = 25; // 0.25%
    uint16 constant UNWRAP_BPS = 50; // 0.50%
    uint16 constant MIN_BURN_BPS = 5_000;
    uint16 constant BURN_BPS = 7_000;

    IPoolManager pm;
    IERC20 token;
    uint8 tokenDec;
    Mill mill;
    DirectionalFeeHook hook;

    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;

    PoolKey key;
    bool millIsCurrency0;
    /// @dev zeroForOne is the direction that BUYS the Mill iff the Mill is currency1.
    bool buyMillIsZeroForOne;

    address vault = address(0x7A017);
    address treasury = address(0x7EEA);
    uint16 sellBps;

    uint256 unit; // one whole unit of the underlying

    // =====================================================================
    // setup — this IS the step-7 sequence
    // =====================================================================

    function setUp() public {
        _bootstrap();

        sellBps = uint16(vm.envOr("SELL_BPS", uint256(100)));
        tokenDec = IERC20Metadata(address(token)).decimals();
        unit = 10 ** tokenDec;

        _fund(address(this), 20_000 * unit);

        // 1. deploy our own hook, mined for the permission bits
        bytes memory initCode =
            abi.encodePacked(type(DirectionalFeeHook).creationCode, abi.encode(pm, address(this)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, initCode);
        hook = new DirectionalFeeHook{salt: salt}(pm, address(this));
        require(address(hook) == predicted, "hook address mismatch");

        // 2. deploy the Mill and seed it in the same breath
        mill = new Mill(
            token, "Mill Token", "mTKN", WRAP_BPS, UNWRAP_BPS, MIN_BURN_BPS, BURN_BPS, 0, treasury, treasury, address(this)
        );
        token.approve(address(mill), type(uint256).max);
        mill.wrap(5_000 * unit, address(this));

        // 3. build the key. Currencies sort by address; the Mill's is CREATE-derived
        //    so which side it lands on is not something you get to choose.
        (address c0, address c1, bool m0) = MillPoolMath.order(address(mill), address(token));
        millIsCurrency0 = m0;
        buyMillIsZeroForOne = !millIsCurrency0; // zeroForOne buys currency1

        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // 4. configure — zero on the buy-the-Mill direction, sellBps on the other
        hook.configurePool(
            key,
            vault,
            buyMillIsZeroForOne ? 0 : sellBps, // zeroForOneBps
            buyMillIsZeroForOne ? sellBps : 0 // oneForZeroBps
        );

        // 5. initialise AT THE RATIO, not at 1:1
        pm.initialize(key, _sqrtPriceAtRatio());

        // 6. mint a full-range position
        swapRouter = new PoolSwapTest(pm);
        lpRouter = new PoolModifyLiquidityTest(pm);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        mill.approve(address(swapRouter), type(uint256).max);
        mill.approve(address(lpRouter), type(uint256).max);

        int24 lower = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
        int24 upper = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(LIQUIDITY_MULT * unit)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    // =====================================================================
    // environment — overridden by the local variant
    // =====================================================================

    /// @dev Sets `pm` and `token`. The fork variant points at live Robinhood
    ///      Chain; the local variant deploys a PoolManager and a mock token so
    ///      the whole sequence can be exercised with no network at all.
    function _bootstrap() internal virtual {
        vm.createSelectFork(vm.envString("RH_RPC"));
        pm = IPoolManager(POOL_MANAGER);
        token = IERC20(vm.envOr("TOKEN", WETH));
    }

    // =====================================================================
    // helpers
    // =====================================================================

    function _fund(address to, uint256 amount) internal virtual {
        address whale = vm.envOr("TOKEN_WHALE", address(0));
        if (whale == address(0)) {
            deal(address(token), to, amount);
        } else {
            vm.prank(whale);
            token.transfer(to, amount);
        }
    }

    /// @dev sqrtPriceX96 encodes RAW currency1 per RAW currency0. The Mill carries
    ///      `DECIMALS_OFFSET` more decimals than its underlying, so the raw price is
    ///      the human ratio shifted by 10**OFFSET — get this wrong and you initialise
    ///      the pool three orders of magnitude away from backing.
    function _sqrtPriceAtRatio() internal view returns (uint160) {
        return MillPoolMath.sqrtPriceAtRatio(mill.ratio(), mill.DECIMALS_OFFSET(), millIsCurrency0);
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _vaultBalances() internal view returns (uint256 inToken, uint256 inMill) {
        inToken = token.balanceOf(vault);
        inMill = mill.balanceOf(vault);
    }

    // =====================================================================
    // 5. the pool exists and is priced at backing
    // =====================================================================

    function test_05_PoolInitialisedAtRatio() public view {
        console2.log("chainId          ", block.chainid);
        console2.log("underlying       ", address(token));
        console2.log("underlying dec   ", tokenDec);
        console2.log("mill             ", address(mill));
        console2.log("mill decimals    ", mill.decimals());
        console2.log("hook             ", address(hook));
        console2.log("mill is currency0", millIsCurrency0);
        console2.log("buy-mill is z4o  ", buyMillIsZeroForOne);
        console2.log("ratio            ", mill.ratio());
        console2.log("totalAssets      ", mill.totalAssets());
        console2.log("totalSupply      ", mill.totalSupply());

        (uint16 z, uint16 o) = hook.getEffectiveRates(key);
        console2.log("rate zeroForOne  ", z);
        console2.log("rate oneForZero  ", o);
        assertEq(hook.getVault(key), vault, "vault not stored");
        assertTrue(hook.isConfigured(key), "pool not configured");

        // exactly one direction is free, and it is the one that buys the Mill
        assertTrue((z == 0) != (o == 0), "both or neither direction is free");
        assertEq(buyMillIsZeroForOne ? z : o, 0, "the buy-mill direction is not free");
    }

    // =====================================================================
    // 6. the hook charges on the sell side only, in all four cases
    // =====================================================================

    function test_06_FeeLandsOnlyOnTheSellSide() public {
        uint256 tradeIn = unit / 10;

        // --- buying the Mill, exact input: must be free
        (uint256 t0, uint256 m0) = _vaultBalances();
        _swap(buyMillIsZeroForOne, -int256(tradeIn));
        (uint256 t1, uint256 m1) = _vaultBalances();
        console2.log("buy  exactIn  -> vault dToken/dMill", t1 - t0, m1 - m0);
        assertEq(t1 - t0, 0, "buy direction charged in token");
        assertEq(m1 - m0, 0, "buy direction charged in mill");

        // --- buying the Mill, exact output: must also be free
        _swap(buyMillIsZeroForOne, int256(tradeIn));
        (uint256 t2, uint256 m2) = _vaultBalances();
        console2.log("buy  exactOut -> vault dToken/dMill", t2 - t1, m2 - m1);
        assertEq(t2 - t1, 0, "buy direction charged in token");
        assertEq(m2 - m1, 0, "buy direction charged in mill");

        // --- selling the Mill, exact input: charged
        _swap(!buyMillIsZeroForOne, -int256(mill.balanceOf(address(this)) / 1000));
        (uint256 t3, uint256 m3) = _vaultBalances();
        console2.log("sell exactIn  -> vault dToken/dMill", t3 - t2, m3 - m2);
        assertGt((t3 - t2) + (m3 - m2), 0, "sell direction collected nothing");

        // --- selling the Mill, exact output: charged
        _swap(!buyMillIsZeroForOne, int256(tradeIn));
        (uint256 t4, uint256 m4) = _vaultBalances();
        console2.log("sell exactOut -> vault dToken/dMill", t4 - t3, m4 - m3);
        assertGt((t4 - t3) + (m4 - m3), 0, "sell direction collected nothing");

        console2.log("vault total token", t4);
        console2.log("vault total mill ", m4);
    }

    /// @dev The fee is taken from the UNSPECIFIED side, so which currency it arrives
    ///      in flips with exactness. Both must be a currency the vault can hold —
    ///      which is why the vault is a plain EOA and never the Mill.
    function test_07_FeeCurrencyFlipsWithExactness() public {
        uint256 tradeIn = unit / 10;

        (uint256 t0, uint256 m0) = _vaultBalances();
        _swap(!buyMillIsZeroForOne, -int256(mill.balanceOf(address(this)) / 1000));
        (uint256 t1, uint256 m1) = _vaultBalances();

        _swap(!buyMillIsZeroForOne, int256(tradeIn));
        (uint256 t2,) = _vaultBalances();

        bool exactInPaidToken = (t1 - t0) > 0;
        bool exactOutPaidToken = (t2 - t1) > 0;
        console2.log("sell exactIn  fee in underlying:", exactInPaidToken);
        console2.log("sell exactOut fee in underlying:", exactOutPaidToken);
        assertTrue(exactInPaidToken != exactOutPaidToken, "fee currency did not flip with exactness");
    }

    // =====================================================================
    // 8. THE NUMBER — the measured arb band
    // =====================================================================

    /// @notice Round-trips both directions with the pool priced exactly at backing,
    ///         so the entire loss is cost. That loss IS the half-band: the pool has
    ///         to drift at least this far from `ratio()` before anyone repairs it.
    function test_08_ArbBand() public {
        uint256 probe = vm.envOr("PROBE", unit / 1000);

        // ---- discount side: buy mTKN in the pool, unwrap it for TKN
        uint256 snap = vm.snapshotState();
        uint256 before_ = token.balanceOf(address(this));
        uint256 millBefore = mill.balanceOf(address(this));
        _swap(buyMillIsZeroForOne, -int256(probe));
        uint256 got = mill.balanceOf(address(this)) - millBefore;
        mill.unwrap(got, address(this));
        uint256 back = token.balanceOf(address(this)) - (before_ - probe);
        uint256 discountBps = probe > back ? ((probe - back) * 10_000) / probe : 0;
        vm.revertToState(snap);

        // ---- premium side: wrap TKN into mTKN, sell it in the pool
        snap = vm.snapshotState();
        before_ = token.balanceOf(address(this));
        uint256 shares = mill.wrap(probe, address(this));
        _swap(!buyMillIsZeroForOne, -int256(shares));
        uint256 back2 = token.balanceOf(address(this)) - (before_ - probe);
        uint256 premiumBps = probe > back2 ? ((probe - back2) * 10_000) / probe : 0;
        vm.revertToState(snap);

        console2.log("");
        console2.log("=========== ARB BAND, measured ===========");
        console2.log("probe size (raw)        ", probe);
        console2.log("LP fee bps              ", LP_FEE / 100);
        console2.log("hook sell bps           ", sellBps);
        console2.log("mill wrap/unwrap bps    ", WRAP_BPS, UNWRAP_BPS);
        console2.log("------------------------------------------");
        console2.log("discount repair cost bps", discountBps);
        console2.log("  (buy mTKN in pool, then unwrap)");
        console2.log("premium repair cost bps ", premiumBps);
        console2.log("  (wrap TKN, then sell mTKN in pool)");
        console2.log("full band width bps     ", discountBps + premiumBps);
        console2.log("------------------------------------------");
        console2.log("theoretical discount bps", uint256(LP_FEE / 100 + UNWRAP_BPS));
        console2.log("  = LP fee + buy-side hook (0) + unwrap");
        console2.log("theoretical premium bps ", uint256(WRAP_BPS + LP_FEE / 100 + sellBps));
        console2.log("  = wrap + LP fee + sell-side hook");
        console2.log("excess over theory is price impact + rounding.");
        console2.log("==========================================");
        console2.log("A real mTKN/QUOTE pool adds the QUOTE pool's tax");
        console2.log("to each leg, twice per round trip. Not in this number.");

        // Sanity: the discount side must be the cheaper one. That is the entire
        // point of zeroing the buy direction — repair of a discount, the state
        // that makes a backed wrapper look broken, is the leg we subsidise.
        assertLt(discountBps, premiumBps, "the discount repair is not the cheaper leg");
    }

    // =====================================================================
    // 9. pausing and re-pointing still work on a live, traded pool
    // =====================================================================

    function test_09_PauseStopsCollection() public {
        uint256 sellAmt = mill.balanceOf(address(this)) / 1000;

        hook.setPaused(true);
        (uint256 t0, uint256 m0) = _vaultBalances();
        _swap(!buyMillIsZeroForOne, -int256(sellAmt));
        (uint256 t1, uint256 m1) = _vaultBalances();
        assertEq((t1 - t0) + (m1 - m0), 0, "collected while paused");

        hook.setPaused(false);
        _swap(!buyMillIsZeroForOne, -int256(sellAmt));
        (uint256 t2, uint256 m2) = _vaultBalances();
        assertGt((t2 - t1) + (m2 - m1), 0, "did not resume after unpause");
        console2.log("paused collected 0, unpaused collected", (t2 - t1) + (m2 - m1));
    }

    /// @dev `configurePool` is once-only. Proving that here is cheaper than
    ///      discovering it on mainnet.
    function test_10_ConfigureIsOnceOnly() public {
        vm.expectRevert();
        hook.configurePool(key, address(0xDEAD), 0, 0);
    }

    /// @dev Rate changes serve the delay; the pause does not. Both matter for
    ///      what you can promise about the rates on launch day.
    function test_11_RateChangeServesTheDelay() public {
        (uint16 z0, uint16 o0) = hook.getEffectiveRates(key);
        hook.setRates(key, 200, 200);
        (uint16 z1, uint16 o1) = hook.getEffectiveRates(key);
        assertEq(z1, z0, "zeroForOne changed immediately");
        assertEq(o1, o0, "oneForZero changed immediately");

        vm.warp(block.timestamp + hook.RATE_CHANGE_DELAY());
        (uint16 z2, uint16 o2) = hook.getEffectiveRates(key);
        assertEq(z2, 200);
        assertEq(o2, 200);
        console2.log("rates before/after delay", z0, z2);
    }

    // =====================================================================
    // 12. how much depth the band actually needs
    // =====================================================================

    /// @notice The same discount round trip at growing trade sizes. Fees are flat;
    ///         everything above the flat line is price impact, which is bought
    ///         with protocol-owned liquidity. This is the table that sizes POL:
    ///         pick the trade size you want to stay arbitrageable, and read off
    ///         what the band costs at that size.
    function test_12_BandVsTradeSize() public {
        uint256[6] memory sizes = [unit / 1000, unit / 100, unit / 10, unit, 10 * unit, 100 * unit];

        console2.log("");
        console2.log("=== discount repair cost vs trade size ===");
        console2.log("full-range L        ", LIQUIDITY_MULT * unit);
        console2.log("trade (raw) | cost bps");

        for (uint256 i; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();
            uint256 probe = sizes[i];
            uint256 before_ = token.balanceOf(address(this));
            uint256 millBefore = mill.balanceOf(address(this));
            _swap(buyMillIsZeroForOne, -int256(probe));
            uint256 got = mill.balanceOf(address(this)) - millBefore;
            mill.unwrap(got, address(this));
            uint256 back = token.balanceOf(address(this)) - (before_ - probe);
            uint256 bps = probe > back ? ((probe - back) * 10_000) / probe : 0;
            console2.log(probe, bps);
            vm.revertToState(snap);
        }
        console2.log("==========================================");
    }
}
