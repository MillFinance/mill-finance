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
import {MockERC20} from "./Mocks.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {MillLens, IPosmLite} from "../src/MillLens.sol";

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function allowance(address user, address token, address spender)
        external view returns (uint160 amount, uint48 expiration, uint48 nonce);
}
interface IPosm {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title  The add-liquidity path the browser has to reproduce
///
/// @notice The front end cannot import v4-periphery — it hand-encodes this call in
///         JavaScript. So this test does the same thing in Solidity, asserts it
///         actually mints, and prints the exact bytes for the JS to be compared
///         against. If the two disagree by one byte, the JS is wrong.
contract PosmTest is Test {
    uint8 constant MINT_POSITION = 0x02;
    uint8 constant SETTLE_PAIR   = 0x0d;
    int24 constant SPACING = 60;
    uint24 constant LP_FEE = 3000;

    IPoolManager pm;
    IPermit2 permit2;
    IPosm posm;
    MillLens lens;
    MockERC20 tkn;
    Mill mill;
    PoolKey key;
    bool millIsCurrency0;

    function setUp() public {
        pm      = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        permit2 = IPermit2(deployCode("out/Permit2.sol/Permit2.json"));
        posm    = IPosm(deployCode("out/PositionManager.sol/PositionManager.json",
                    abi.encode(address(pm), address(permit2), uint256(300_000), address(0), address(0))));

        lens = new MillLens(pm, IPosmLite(address(posm)));
        tkn = new MockERC20("Token", "TKN", 18);
        tkn.mint(address(this), 1_000_000e18);
        mill = new Mill(IERC20(address(tkn)), "Mill TKN", "mTKN", 25, 50, 5_000, 7_000, 1_000,
                        address(0xFEE), address(0x11B), address(this));
        tkn.approve(address(mill), type(uint256).max);
        mill.wrap(100_000e18, address(this));

        (address c0, address c1, bool m0) = MillPoolMath.order(address(mill), address(tkn));
        millIsCurrency0 = m0;
        key = PoolKey({currency0:Currency.wrap(c0), currency1:Currency.wrap(c1),
                       fee:LP_FEE, tickSpacing:SPACING, hooks:IHooks(address(0))});
        pm.initialize(key, MillPoolMath.sqrtPriceAtRatio(mill.ratio(), mill.DECIMALS_OFFSET(), m0));

        // the two-step approval every wallet has to make: token -> Permit2 -> posm
        tkn.approve(address(permit2), type(uint256).max);
        mill.approve(address(permit2), type(uint256).max);
        permit2.approve(address(tkn),  address(posm), type(uint160).max, type(uint48).max);
        permit2.approve(address(mill), address(posm), type(uint160).max, type(uint48).max);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function _fullRange() internal pure returns (int24 lower, int24 upper) {
        lower = (TickMath.MIN_TICK / SPACING) * SPACING;
        upper = (TickMath.MAX_TICK / SPACING) * SPACING;
    }

    /// @notice Mints a full-range position and prints the calldata the JS must match.
    function test_MintFullRangePosition() public {
        (int24 lower, int24 upper) = _fullRange();
        uint256 liquidity = 3_000e18;
        uint128 max0 = type(uint128).max;
        uint128 max1 = type(uint128).max;

        bytes memory actions = abi.encodePacked(MINT_POSITION, SETTLE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, lower, upper, liquidity, max0, max1, address(this), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        bytes memory unlockData = abi.encode(actions, params);

        uint256 id = posm.nextTokenId();
        uint256 t0 = tkn.balanceOf(address(this));
        uint256 m0 = mill.balanceOf(address(this));

        posm.modifyLiquidities(unlockData, block.timestamp + 60);

        assertEq(posm.ownerOf(id), address(this), "position not minted to us");
        assertEq(posm.getPositionLiquidity(id), uint128(liquidity), "wrong liquidity");
        assertGt(t0 - tkn.balanceOf(address(this)), 0, "no TKN was taken");
        assertGt(m0 - mill.balanceOf(address(this)), 0, "no mTKN was taken");

        console2.log("tokenId       ", id);
        console2.log("TKN  spent    ", t0 - tkn.balanceOf(address(this)));
        console2.log("mTKN spent    ", m0 - mill.balanceOf(address(this)));
        console2.log("mill addr     ", address(mill));
        console2.log("tkn  addr     ", address(tkn));
        console2.log("currency0     ", Currency.unwrap(key.currency0));
        console2.log("currency1     ", Currency.unwrap(key.currency1));
        console2.log("millIsCurrency0", millIsCurrency0);
        assertEq(Currency.unwrap(key.currency0), millIsCurrency0 ? address(mill) : address(tkn), "ordering disagrees");
        console2.log("tickLower", int256(lower)); console2.log("tickUpper", int256(upper));
        console2.log("CALLDATA modifyLiquidities(unlockData, deadline) with deadline=1234567890:");
        console2.logBytes(abi.encodeWithSignature("modifyLiquidities(bytes,uint256)", unlockData, uint256(1234567890)));
        console2.log("ACTIONS:");
        console2.logBytes(actions);
        console2.log("PARAMS0:");
        console2.logBytes(params[0]);
        console2.log("PARAMS1:");
        console2.logBytes(params[1]);
        console2.log("PERMIT2 approve calldata (token->posm, max, max):");
        console2.logBytes(abi.encodeWithSignature("approve(address,address,uint160,uint48)",
            address(tkn), address(posm), type(uint160).max, type(uint48).max));
    }

    /// @notice The amount -> liquidity conversion, which the JS also has to redo.
    ///         Printed here so the JS can be checked against v4's own arithmetic.
    function test_LiquidityForAmounts() public view {
        (int24 lower, int24 upper) = _fullRange();
        uint160 sqrtP = MillPoolMath.sqrtPriceAtRatio(mill.ratio(), mill.DECIMALS_OFFSET(), millIsCurrency0);
        console2.log("sqrtPriceX96  ", sqrtP);
        console2.log("sqrtLowerX96  ", TickMath.getSqrtPriceAtTick(lower));
        console2.log("sqrtUpperX96  ", TickMath.getSqrtPriceAtTick(upper));
        console2.log("MIN_TICK used ", int256(lower));
        console2.log("MAX_TICK used ", int256(upper));
    }

    /// @notice v4's own amount<->liquidity arithmetic, printed for a spread of inputs
    ///         so the JavaScript port can be checked against it rather than trusted.
    function test_LiquidityMathVectors() public view {
        (int24 lower, int24 upper) = _fullRange();
        uint160 sA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sB = TickMath.getSqrtPriceAtTick(upper);
        uint160[3] memory prices = [
            uint160(2505414483750479311864138015696),   // ratio 1.0, mill = currency1
            uint160(79228162514264337593543950336),     // 1:1
            uint160(4339505179874779672736284672)       // ~0.003
        ];
        uint256[3] memory a0 = [uint256(1e18), 25e18, 1234567890123456789];
        uint256[3] memory a1 = [uint256(1e21), 7e18, 999999999999999999];

        for (uint256 i; i < 3; i++) {
            uint128 L = LiquidityAmounts.getLiquidityForAmounts(prices[i], sA, sB, a0[i], a1[i]);
            // amounts a position of L would need at this price, the way v4 itself
            // computes them: token0 above the current price, token1 below it.
            uint256 x = SqrtPriceMath.getAmount0Delta(prices[i], sB, L, true);
            uint256 y = SqrtPriceMath.getAmount1Delta(sA, prices[i], L, true);
            console2.log("--- vector", i);
            console2.log("sqrtP ", prices[i]);
            console2.log("amt0in", a0[i]);
            console2.log("amt1in", a1[i]);
            console2.log("L     ", L);
            console2.log("amt0  ", x);
            console2.log("amt1  ", y);
        }
    }

    // ------------------------------------------------------------------
    // the lens the front end reads through
    // ------------------------------------------------------------------

    function _mintFullRange(uint256 liquidity) internal returns (uint256 id) {
        (int24 lower, int24 upper) = _fullRange();
        bytes memory actions = abi.encodePacked(MINT_POSITION, SETTLE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, lower, upper, liquidity, type(uint128).max, type(uint128).max, address(this), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        id = posm.nextTokenId();
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
    }

    function test_LensReadsPoolState() public view {
        MillLens.PoolState memory s = lens.poolState(key);
        assertTrue(s.initialized, "pool not seen as initialised");
        assertEq(s.lpFee, LP_FEE, "wrong lp fee");
        console2.log("sqrtPriceX96 ", s.sqrtPriceX96);
        console2.log("tick         ", int256(s.tick));
        console2.log("liquidity    ", s.liquidity);
    }

    /// @dev The quote is what the UI shows; the mint is what actually gets pulled.
    ///      If those two disagree the interface is lying, so this asserts they are
    ///      the same to the wei.
    function test_QuoteMatchesWhatTheMintActuallyPulls() public {
        uint256 typed = 50e18; // the user types a currency1 amount
        (uint128 liq, uint256 q0, uint256 q1) = lens.quoteAdd(key, typed, false);
        assertGt(liq, 0, "no liquidity quoted");

        uint256 b0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 b1 = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        _mintFullRange(liq);
        uint256 spent0 = b0 - IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 spent1 = b1 - IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));

        console2.log("typed        ", typed);
        console2.log("quoted amt0  ", q0);
        console2.log("spent  amt0  ", spent0);
        console2.log("quoted amt1  ", q1);
        console2.log("spent  amt1  ", spent1);
        assertEq(spent0, q0, "quote for currency0 did not match the mint");
        assertEq(spent1, q1, "quote for currency1 did not match the mint");
    }

    /// @dev Typing either side must land on the same position.
    function test_QuoteIsSymmetric() public view {
        (uint128 lA, uint256 a0, uint256 a1) = lens.quoteAdd(key, 50e18, false);
        (uint128 lB,,)                        = lens.quoteAdd(key, a0, true);
        console2.log("liquidity from side1", lA);
        console2.log("liquidity from side0", lB);
        assertApproxEqRel(lB, lA, 1e12, "quoting from the other side gave a different position");
        assertGt(a1, 0);
    }

    function test_LensFindsUserPositions() public {
        uint256 id1 = _mintFullRange(1_000e18);
        uint256 id2 = _mintFullRange(2_500e18);

        MillLens.Position[] memory ps = lens.userPositions(address(this), key, 50);
        assertEq(ps.length, 2, "wrong number of positions found");
        assertEq(ps[0].tokenId, id1);
        assertEq(ps[1].tokenId, id2);
        assertEq(ps[1].liquidity, 2_500e18);
        assertTrue(ps[0].fullRange, "not recognised as full range");
        assertGt(ps[1].amount0, 0); assertGt(ps[1].amount1, 0);

        console2.log("position 2 tokenId", ps[1].tokenId);
        console2.log("  liquidity       ", ps[1].liquidity);
        console2.log("  amount0         ", ps[1].amount0);
        console2.log("  amount1         ", ps[1].amount1);

        // somebody else holds nothing here
        assertEq(lens.userPositions(address(0xBEEF), key, 50).length, 0, "found phantom positions");
    }

    /// @dev An uninitialised pool must quote zero rather than revert, so the UI can
    ///      say "no pool yet" instead of showing an error.
    function test_QuoteOnUninitialisedPoolIsZero() public view {
        PoolKey memory ghost = PoolKey({currency0:key.currency0, currency1:key.currency1,
                                        fee:500, tickSpacing:10, hooks:IHooks(address(0))});
        (uint128 l, uint256 a, uint256 b) = lens.quoteAdd(ghost, 1e18, true);
        assertEq(l, 0); assertEq(a, 0); assertEq(b, 0);
        assertFalse(lens.poolState(ghost).initialized);
    }

    /// @dev Finding positions by id is what the front end actually uses, so it
    ///      must agree with the scan and reject ids that are not ours.
    function test_PositionsByIdsMatchesTheScan() public {
        uint256 id1 = _mintFullRange(1_000e18);
        uint256 id2 = _mintFullRange(2_500e18);

        uint256[] memory ids = new uint256[](4);
        ids[0] = id1; ids[1] = id2; ids[2] = 999999; ids[3] = id1;   // junk and a duplicate

        MillLens.Position[] memory byId = lens.positionsByIds(address(this), key, ids);
        MillLens.Position[] memory scan = lens.userPositions(address(this), key, 50);

        assertEq(scan.length, 2, "scan found the wrong number");
        assertEq(byId.length, 3, "duplicates and junk not handled as expected");
        assertEq(byId[0].tokenId, id1);
        assertEq(byId[1].tokenId, id2);
        assertEq(byId[0].amount0, scan[0].amount0, "amounts disagree between the two lookups");
        assertEq(byId[1].liquidity, scan[1].liquidity, "liquidity disagrees");

        // somebody else's ids come back empty rather than reverting
        assertEq(lens.positionsByIds(address(0xBEEF), key, ids).length, 0);
    }

    /// @dev Taking a position apart. The front end encodes this by hand, so the
    ///      bytes are printed for the JavaScript to be compared against.
    function test_BurnPositionReturnsTheMoney() public {
        uint256 id = _mintFullRange(2_000e18);
        uint256 t0 = tkn.balanceOf(address(this));
        uint256 m0 = mill.balanceOf(address(this));

        uint8 BURN_POSITION = 0x03;
        uint8 TAKE_PAIR = 0x11;
        bytes memory actions = abi.encodePacked(BURN_POSITION, TAKE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(id, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        bytes memory unlockData = abi.encode(actions, params);

        posm.modifyLiquidities(unlockData, block.timestamp + 60);

        assertGt(tkn.balanceOf(address(this)), t0, "no TKN came back");
        assertGt(mill.balanceOf(address(this)), m0, "no mTKN came back");
        assertEq(lens.positionsByIds(address(this), key, _one(id)).length, 0, "position still listed");

        console2.log("BURN CALLDATA with deadline=1234567890:");
        console2.logBytes(abi.encodeWithSignature("modifyLiquidities(bytes,uint256)", unlockData, uint256(1234567890)));
        console2.log("BURN PARAMS0:"); console2.logBytes(params[0]);
        console2.log("BURN PARAMS1:"); console2.logBytes(params[1]);
        console2.log("burn tokenId ", id);
    }

    function _one(uint256 a) internal pure returns (uint256[] memory r){ r = new uint256[](1); r[0] = a; }
}
