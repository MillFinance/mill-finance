// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MillPoolMath} from "../src/MillPoolMath.sol";

/// @dev MillPoolMath is an internal library, so a direct call is inlined into
///      the test contract and reverts at the same depth as the cheatcode —
///      which `vm.expectRevert` cannot see. This gives it a real external call
///      to watch.
contract PoolPriceHarness {
    function withQuote(uint256 ratio, uint8 offset, uint256 price, uint8 aDec, uint8 qDec, bool m0)
        external
        pure
        returns (uint160)
    {
        return MillPoolMath.sqrtPriceAtRatioWithQuote(ratio, offset, price, aDec, qDec, m0);
    }
}

/// @title  Opening a pool at backing, against any quote
///
/// @notice `ratio()` says what a share is worth in the UNDERLYING. For an
///         mTKN/TKN pool that is also the pool price; for mMILL/wETH it is not,
///         and the gap is however much MILL is worth. Initialising a pool is
///         one-way, so this is the arithmetic that has to be right the first
///         time.
contract PoolPriceTest is Test {
    uint8 constant OFFSET = 3;

    PoolPriceHarness harness = new PoolPriceHarness();

    /// @dev Raw currency1 per raw currency0, recovered from a sqrt price.
    ///      Scaled by 1e36, not 1e18: a six-decimal quote puts the raw price
    ///      around 2.6e-15, which at 1e18 has three significant digits left and
    ///      fails a comparison on rounding alone.
    function _priceFromSqrt(uint160 sp) internal pure returns (uint256) {
        uint256 x = Math.mulDiv(uint256(sp), uint256(sp), 1 << 96);
        return Math.mulDiv(x, 1e36, 1 << 96);
    }

    /// @dev What one raw milled token should be worth in raw quote, 1e36-scaled,
    ///      derived independently of the library.
    function _expected(uint256 ratio, uint256 quotePer, uint8 aDec, uint8 qDec)
        internal
        pure
        returns (uint256)
    {
        uint256 whole = Math.mulDiv(ratio, quotePer, 1e18); // whole quote per whole mTKN, 1e18
        uint8 podDec = aDec + OFFSET;
        return qDec >= podDec
            ? whole * 1e18 * (10 ** uint256(qDec - podDec))
            : Math.mulDiv(whole, 1e18, 10 ** uint256(podDec - qDec));
    }

    // =================================================================
    // the general form must contain the old one
    // =================================================================

    /// @dev When the quote IS the underlying the price is 1 and the decimals
    ///      cancel, so the two functions must agree exactly — not approximately.
    function test_CollapsesToTheUnderlyingFormWhenTheQuoteIsTheUnderlying() public pure {
        uint256[5] memory ratios = [uint256(1e18), 1.0028e18, 1.5e18, 3.3333e18, 1_000e18];
        for (uint256 i; i < ratios.length; i++) {
            for (uint256 d = 6; d <= 18; d += 6) {
                assertEq(
                    MillPoolMath.sqrtPriceAtRatioWithQuote(ratios[i], OFFSET, 1e18, uint8(d), uint8(d), true),
                    MillPoolMath.sqrtPriceAtRatio(ratios[i], OFFSET, true),
                    "currency0 form drifted"
                );
                assertEq(
                    MillPoolMath.sqrtPriceAtRatioWithQuote(ratios[i], OFFSET, 1e18, uint8(d), uint8(d), false),
                    MillPoolMath.sqrtPriceAtRatio(ratios[i], OFFSET, false),
                    "currency1 form drifted"
                );
            }
        }
    }

    // =================================================================
    // the case this exists for
    // =================================================================

    /// @dev mMILL/wETH. MILL at 0.0005 wETH, ratio a shade over 1.
    function test_MilledMillAgainstWeth() public pure {
        uint256 ratio = 1.002792965994736174e18;
        uint256 millInWeth = 0.0005e18;

        uint160 sp = MillPoolMath.sqrtPriceAtRatioWithQuote(ratio, OFFSET, millInWeth, 18, 18, true);
        assertApproxEqRel(_priceFromSqrt(sp), _expected(ratio, millInWeth, 18, 18), 1e12, "price off");

        // and the naive form is wrong by roughly the price of MILL, which is the
        // whole reason this function exists
        uint160 naive = MillPoolMath.sqrtPriceAtRatio(ratio, OFFSET, true);
        assertGt(_priceFromSqrt(naive), _priceFromSqrt(sp) * 1000, "the naive form was not catastrophically wrong");
    }

    /// @dev A six-decimal quote is where the offset arithmetic goes wrong if the
    ///      decimals are assumed to cancel.
    function test_SixDecimalQuote() public pure {
        uint256 ratio = 1.05e18;
        uint256 price = 2.5e18; // one underlying is worth 2.5 quote

        uint160 sp0 = MillPoolMath.sqrtPriceAtRatioWithQuote(ratio, OFFSET, price, 18, 6, true);
        assertApproxEqRel(_priceFromSqrt(sp0), _expected(ratio, price, 18, 6), 1e12, "6-dec quote off");

        uint160 sp1 = MillPoolMath.sqrtPriceAtRatioWithQuote(ratio, OFFSET, price, 6, 18, true);
        assertApproxEqRel(_priceFromSqrt(sp1), _expected(ratio, price, 6, 18), 1e12, "6-dec asset off");
    }

    /// @dev Sorting the pair the other way must invert the price exactly, or one
    ///      of the two orderings opens the pool upside down.
    function test_OrderingIsAnInverse() public pure {
        uint256 ratio = 1.0028e18;
        uint256 price = 0.0005e18;

        uint256 a = _priceFromSqrt(MillPoolMath.sqrtPriceAtRatioWithQuote(ratio, OFFSET, price, 18, 18, true));
        uint256 b = _priceFromSqrt(MillPoolMath.sqrtPriceAtRatioWithQuote(ratio, OFFSET, price, 18, 18, false));

        assertApproxEqRel(Math.mulDiv(a, b, 1e36), 1e36, 1e10, "the two orderings are not inverses");
    }

    function test_RefusesAPriceOfZero() public {
        vm.expectRevert(bytes("quote price is zero"));
        harness.withQuote(1e18, OFFSET, 0, 18, 18, true);
    }

    function test_RefusesARatioOfZero() public {
        vm.expectRevert(bytes("ratio is zero"));
        harness.withQuote(0, OFFSET, 1e18, 18, 18, true);
    }

    /// @dev Across the range of ratios and prices a real deployment could see,
    ///      the sqrt price must round-trip to the price that was asked for.
    function testFuzz_RoundTripsToTheRequestedPrice(uint96 ratioSeed, uint96 priceSeed) public pure {
        uint256 ratio = bound(uint256(ratioSeed), 1e18, 100e18);
        uint256 price = bound(uint256(priceSeed), 1e12, 1e24);

        uint160 sp = MillPoolMath.sqrtPriceAtRatioWithQuote(ratio, OFFSET, price, 18, 18, true);
        assertApproxEqRel(_priceFromSqrt(sp), _expected(ratio, price, 18, 18), 1e12, "round trip drifted");
    }
}
