// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

interface IPosmLite {
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256);
}

/// @title  MillLens
/// @notice Read-only. Holds nothing, owns nothing, can change nothing.
///
/// @dev    Exists so the front end does not have to do keccak and storage-slot
///         arithmetic in JavaScript to read a v4 pool, and does not have to make
///         hundreds of RPC calls to find a user's positions. Every function here
///         is a view; the worst a bug can do is display a wrong number.
///
///         Liquidity provision in the app is full-range only. At full range the
///         pool's current price fixes the ratio between the two sides, so a user
///         picks one amount and the other follows — which is what `quoteAdd`
///         answers.
contract MillLens {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    IPosmLite public immutable positionManager;

    /// @dev The full range, snapped to a spacing. Both ticks must be multiples of
    ///      it or the mint reverts.
    function fullRange(int24 spacing) public pure returns (int24 lower, int24 upper) {
        lower = (TickMath.MIN_TICK / spacing) * spacing;
        upper = (TickMath.MAX_TICK / spacing) * spacing;
    }

    constructor(IPoolManager pm, IPosmLite posm) {
        poolManager = pm;
        positionManager = posm;
    }

    // ---------------------------------------------------------------- pool

    struct PoolState {
        bool initialized;
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 lpFee;
        uint128 liquidity;
    }

    function poolState(PoolKey calldata key) public view returns (PoolState memory s) {
        PoolId id = key.toId();
        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = poolManager.getSlot0(id);
        s.initialized = sqrtPriceX96 != 0;
        s.sqrtPriceX96 = sqrtPriceX96;
        s.tick = tick;
        s.lpFee = lpFee;
        s.liquidity = poolManager.getLiquidity(id);
    }

    /// @notice The pool's id, which is also the indexed topic on every
    ///         `ModifyLiquidity` log for it. Exposed so a front end can filter
    ///         logs without implementing keccak and abi-encoding itself.
    function poolIdFor(PoolKey calldata key) external pure returns (bytes32) {
        return PoolId.unwrap(key.toId());
    }

    // ---------------------------------------------------------------- quote

    /// @notice Given one side of a full-range deposit, returns the other side.
    /// @param  amount    how much the user typed
    /// @param  isAmount0 true if they typed the currency0 amount
    /// @return liquidity the position that amount buys
    /// @return amount0   currency0 actually required
    /// @return amount1   currency1 actually required
    /// @dev    Amounts round UP, matching what PositionManager will pull. Quoting
    ///         a rounded-down number is how a UI ends up showing one figure and
    ///         charging another.
    function quoteAdd(PoolKey calldata key, uint256 amount, bool isAmount0)
        external
        view
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        PoolState memory s = poolState(key);
        if (!s.initialized || amount == 0) return (0, 0, 0);

        (int24 lower, int24 upper) = fullRange(key.tickSpacing);
        uint160 sA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sB = TickMath.getSqrtPriceAtTick(upper);

        liquidity = isAmount0
            ? LiquidityAmounts.getLiquidityForAmount0(s.sqrtPriceX96, sB, amount)
            : LiquidityAmounts.getLiquidityForAmount1(sA, s.sqrtPriceX96, amount);
        if (liquidity == 0) return (0, 0, 0);

        amount0 = SqrtPriceMath.getAmount0Delta(s.sqrtPriceX96, sB, liquidity, true);
        amount1 = SqrtPriceMath.getAmount1Delta(sA, s.sqrtPriceX96, liquidity, true);
    }

    // ------------------------------------------------------------ positions

    struct Position {
        uint256 tokenId;
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        bool fullRange;
        uint256 amount0;
        uint256 amount1;
    }

    /// @notice Details for a specific set of token ids, filtered to those `user`
    ///         actually owns in this pool.
    /// @dev    The front end finds candidate ids from `ModifyLiquidity` logs on
    ///         the pool — which are scoped to one pool and therefore few — and
    ///         passes them here. That works no matter how large the position
    ///         manager's id space grows, unlike scanning backwards from the newest
    ///         id, which stops finding anything on a busy chain.
    function positionsByIds(address user, PoolKey calldata key, uint256[] calldata ids)
        external
        view
        returns (Position[] memory out)
    {
        PoolState memory s = poolState(key);
        (int24 fLower, int24 fUpper) = fullRange(key.tickSpacing);
        bytes25 wantPool = bytes25(PoolId.unwrap(key.toId()));

        Position[] memory buf = new Position[](ids.length);
        uint256 n;
        for (uint256 i; i < ids.length; i++) {
            Position memory p;
            if (!_read(ids[i], user, wantPool, fLower, fUpper, s.sqrtPriceX96, p)) continue;
            buf[n++] = p;
        }
        out = new Position[](n);
        for (uint256 i; i < n; i++) out[i] = buf[i];
    }

    /// @dev Shared by both lookups. Returns false when the id is not a position
    ///      this user holds in this pool.
    function _read(
        uint256 id,
        address user,
        bytes25 wantPool,
        int24 fLower,
        int24 fUpper,
        uint160 sqrtPriceX96,
        Position memory p
    ) internal view returns (bool) {
        address owner;
        try positionManager.ownerOf(id) returns (address o) { owner = o; } catch { return false; }
        if (owner != user) return false;

        (, uint256 info) = positionManager.getPoolAndPositionInfo(id);
        if (bytes25(bytes32(info)) != wantPool) return false;

        int24 tl = int24(int256(info >> 8));
        int24 tu = int24(int256(info >> 32));
        uint128 liq = positionManager.getPositionLiquidity(id);

        uint160 sA = TickMath.getSqrtPriceAtTick(tl);
        uint160 sB = TickMath.getSqrtPriceAtTick(tu);
        uint160 sP = sqrtPriceX96 < sA ? sA : (sqrtPriceX96 > sB ? sB : sqrtPriceX96);

        p.tokenId = id;
        p.liquidity = liq;
        p.tickLower = tl;
        p.tickUpper = tu;
        p.fullRange = tl == fLower && tu == fUpper;
        p.amount0 = liq == 0 ? 0 : SqrtPriceMath.getAmount0Delta(sP, sB, liq, false);
        p.amount1 = liq == 0 ? 0 : SqrtPriceMath.getAmount1Delta(sA, sP, liq, false);
        return true;
    }

    /// @notice Every position `user` holds in `key`'s pool.
    /// @param  maxScan how many of the most recent token ids to look back over.
    /// @dev    PositionManager is not enumerable, so this walks token ids backwards
    ///         from the newest. That is exact for a young protocol and stops being
    ///         practical once the id space is large — at which point this wants an
    ///         indexer, not a bigger number. The scan is bounded so the call can
    ///         never run away.
    function userPositions(address user, PoolKey calldata key, uint256 maxScan)
        external
        view
        returns (Position[] memory out)
    {
        uint256 next = positionManager.nextTokenId();
        uint256 from = next > maxScan + 1 ? next - maxScan : 1;

        PoolState memory s = poolState(key);
        (int24 fLower, int24 fUpper) = fullRange(key.tickSpacing);
        bytes25 wantPool = bytes25(PoolId.unwrap(key.toId()));

        Position[] memory buf = new Position[](next - from);
        uint256 n;

        for (uint256 id = from; id < next; id++) {
            address owner;
            try positionManager.ownerOf(id) returns (address o) { owner = o; } catch { continue; }
            if (owner != user) continue;

            (, uint256 info) = positionManager.getPoolAndPositionInfo(id);
            if (bytes25(bytes32(info)) != wantPool) continue;

            int24 tl = int24(int256(info >> 8));
            int24 tu = int24(int256(info >> 32));
            uint128 liq = positionManager.getPositionLiquidity(id);

            uint160 sA = TickMath.getSqrtPriceAtTick(tl);
            uint160 sB = TickMath.getSqrtPriceAtTick(tu);
            uint160 sP = s.sqrtPriceX96 < sA ? sA : (s.sqrtPriceX96 > sB ? sB : s.sqrtPriceX96);

            buf[n++] = Position({
                tokenId: id,
                liquidity: liq,
                tickLower: tl,
                tickUpper: tu,
                fullRange: tl == fLower && tu == fUpper,
                amount0: liq == 0 ? 0 : SqrtPriceMath.getAmount0Delta(sP, sB, liq, false),
                amount1: liq == 0 ? 0 : SqrtPriceMath.getAmount1Delta(sA, sP, liq, false)
            });
        }

        out = new Position[](n);
        for (uint256 i; i < n; i++) out[i] = buf[i];
    }
}
