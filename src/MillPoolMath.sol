// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title  MillPoolMath
/// @notice The one piece of arithmetic that must be identical in the test and
///         in the deploy script: the sqrt price to initialise a pool at so it
///         opens exactly at backing.
///
/// @dev    Initialising at 1:1 when `ratio()` is already above 1 hands the first
///         arber free money out of protocol-owned liquidity, and initialising at
///         the human ratio when the Mill carries `DECIMALS_OFFSET` extra decimals
///         puts the pool three orders of magnitude away from backing. Both are
///         one-line mistakes with no undo, which is why this lives in `src/` and
///         is exercised by `ForkTier2Test` rather than being retyped per script.
library MillPoolMath {
    /// @notice Opening price for a pool whose QUOTE IS THE UNDERLYING ITSELF.
    ///
    /// @dev    ONLY correct for an mTKN/TKN pool. It knows what a share is worth
    ///         in underlying and nothing else, so pointing it at mMILL/wETH would
    ///         open the pool at "1 mMILL = `ratio` wETH" — wrong by whatever MILL
    ///         is worth, with no undo. For any other quote use
    ///         `sqrtPriceAtRatioWithQuote`, which makes the market price an
    ///         argument rather than an assumption.
    ///
    /// @param ratio1e18       `Mill.ratio()` — underlying per whole share, 1e18-scaled
    /// @param decimalsOffset  `Mill.DECIMALS_OFFSET()`
    /// @param millIsCurrency0 whether the Mill sorts below the underlying
    /// @return sqrtPriceX96   raw currency1 per raw currency0, in Q64.96
    function sqrtPriceAtRatio(uint256 ratio1e18, uint8 decimalsOffset, bool millIsCurrency0)
        internal
        pure
        returns (uint160 sqrtPriceX96)
    {
        // Identical to the general form with a quote that IS the underlying:
        // price 1e18, and decimals that cancel. Expressed as a call rather than
        // a second copy of the arithmetic so the two can never drift.
        return sqrtPriceAtRatioWithQuote(ratio1e18, decimalsOffset, 1e18, 0, 0, millIsCurrency0);
    }

    /// @notice Opening price for a pool against ANY quote token.
    ///
    /// @dev    One whole share is worth `ratio` underlying, and one whole
    ///         underlying is worth `quotePerAsset` quote, so one whole share is
    ///         worth `ratio * quotePerAsset` quote. The pool wants that as a raw
    ///         ratio, which is where the decimals come in: the milled token
    ///         carries `assetDecimals + decimalsOffset`.
    ///
    ///         The market price is a required argument, not a default. There is
    ///         no sensible fallback — a pool initialised at the wrong price is a
    ///         gift to the first arbitrageur and it cannot be reopened.
    ///
    /// @param ratio1e18         `Mill.ratio()` — underlying per whole share, 1e18-scaled
    /// @param decimalsOffset    `Mill.DECIMALS_OFFSET()`
    /// @param quotePerAsset1e18 whole quote per whole underlying, 1e18-scaled.
    ///                          For mMILL/wETH this is the MILL price in wETH.
    /// @param assetDecimals     decimals of the underlying
    /// @param quoteDecimals     decimals of the quote token
    /// @param millIsCurrency0   whether the Mill sorts below the quote
    function sqrtPriceAtRatioWithQuote(
        uint256 ratio1e18,
        uint8 decimalsOffset,
        uint256 quotePerAsset1e18,
        uint8 assetDecimals,
        uint8 quoteDecimals,
        bool millIsCurrency0
    ) internal pure returns (uint160 sqrtPriceX96) {
        require(ratio1e18 > 0, "ratio is zero");
        require(quotePerAsset1e18 > 0, "quote price is zero");

        // whole quote per whole milled token, 1e18-scaled
        uint256 wholePer1e18 = Math.mulDiv(ratio1e18, quotePerAsset1e18, 1e18);

        uint8 podDecimals = assetDecimals + decimalsOffset;
        uint256 num;
        uint256 den;
        if (quoteDecimals >= podDecimals) {
            num = wholePer1e18 * (10 ** uint256(quoteDecimals - podDecimals));
            den = 1e18;
        } else {
            num = wholePer1e18;
            den = 1e18 * (10 ** uint256(podDecimals - quoteDecimals));
        }

        // num/den is now raw quote per raw milled token. The pool wants raw
        // currency1 per raw currency0, so flip when the Mill sorts second.
        (uint256 n, uint256 d) = millIsCurrency0 ? (num, den) : (den, num);
        sqrtPriceX96 = uint160(Math.sqrt(Math.mulDiv(n, 1 << 192, d)));
    }

    /// @notice Sorts a Mill and its quote into V4 currency order.
    function order(address mill, address quote)
        internal
        pure
        returns (address currency0, address currency1, bool millIsCurrency0)
    {
        millIsCurrency0 = mill < quote;
        (currency0, currency1) = millIsCurrency0 ? (mill, quote) : (quote, mill);
    }
}
