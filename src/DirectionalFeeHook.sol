// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @title  DirectionalFeeHook
/// @notice A Uniswap V4 hook that collects a per-pool, per-direction fee on each swap
///         and forwards it to that pool's vault. Not tied to any particular token: any
///         pool can be configured, and the two swap directions carry independent rates.
///
/// @dev    FEE MECHANICS
///         -------------
///         The fee is taken from the swap's unspecified currency:
///
///           exact-input  (amountSpecified < 0): specified = input,  unspecified = output
///           exact-output (amountSpecified > 0): specified = output, unspecified = input
///
///         `afterSwap` may only adjust the unspecified currency, so one callback covers
///         all four (direction x exactness) cases without `beforeSwap` and without the
///         `beforeSwapReturnDelta` permission.
///
///         Invariant: the specified side is exactly what the trader asked for — exact-input
///         spends exactly `amountSpecified`, exact-output delivers exactly
///         `amountSpecified` — except on a partial fill against a binding price limit,
///         where the pool fills less than requested on both sides. The fee is applied to
///         the unspecified side and accrues to the vault, not to the pool. Exact-input
///         reduces the output; exact-output increases the input. The on-chain quoter
///         simulates the hook, so quotes include the fee.
///
///         `afterSwap` runs post-settlement, so the fee is computed on the filled amount.
///         A partial fill against a binding price limit is charged on the fill rather than
///         on the requested amount.
///
///         Both swap types are charged the same bps of the unspecified magnitude, but the
///         fee sits on opposite sides of the trader's headline number: exact-input takes it
///         out of the output, exact-output adds it on top of the input. Measured against
///         what the trader nets or pays, the two therefore differ slightly. At 500 bps an
///         exact-input fee is 5.263% of the amount received, an exact-output fee is 4.762%
///         of the amount paid. The gap narrows with the rate (~0.02pp at 100 bps) and is
///         inherent to charging on the unspecified side, not a rounding defect.
///
/// @dev    DIRECTIONS
///         ----------
///         `zeroForOne == true` means currency0 in, currency1 out. PoolKey currencies are
///         sorted ascending and native ETH is address(0), so in a native-ETH pool ETH is
///         currency0: `zeroForOne == true` buys the other token, `false` sells it. For
///         WETH pools the ordering depends on address comparison; use `buyDirection()`.
///
/// @dev    DEPLOYMENT
///         ----------
///         Permission flags are afterSwap (1 << 6) | afterSwapReturnDelta (1 << 2) = 0x44.
///         Deploy via CREATE2 with a mined salt such that:
///             uint160(hookAddress) & 0x3FFF == 0x0044
contract DirectionalFeeHook is IHooks {
    using Hooks for IHooks;

    // =========================================================================
    // CONSTANTS
    // =========================================================================

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard ceiling on any fee, in basis points. Not raisable by anyone, ever.
    uint16 public constant MAX_FEE_BPS = 500; // 5%

    /// @notice Every change to a pool's configured rate takes effect only after this delay,
    ///         in either direction. Bounds how fast a privileged key can move the fee
    ///         against a live quote.
    ///
    ///         `setPaused` is the one exception. It suspends collection immediately and
    ///         resumes it immediately, but resuming can only restore collection up to the
    ///         pool's already-published configured rate — it cannot reach a rate that did
    ///         not itself serve this delay. Pausing is owner-only; the operator has no path
    ///         to an undelayed increase.
    uint256 public constant RATE_CHANGE_DELAY = 5 minutes;

    // =========================================================================
    // STORAGE
    // =========================================================================

    IPoolManager public immutable poolManager;

    address public owner;
    address public pendingOwner;

    /// @notice Optional second key, restricted to `setRates` and `cancelQueuedRates`, and
    ///         bound by the same MAX_FEE_BPS ceiling and RATE_CHANGE_DELAY as the owner.
    ///         It cannot configure pools, move vaults, pause, or touch ownership. Unset by
    ///         default; `setOperator(address(0))` revokes it.
    address public operator;

    /// @notice Global switch for fee collection. While set, `afterSwap` returns a zero delta
    ///         and no fee is charged on any pool. It cannot block or revert a swap, and
    ///         clearing it restores collection only up to each pool's configured rate.
    ///         Both directions take effect immediately — see RATE_CHANGE_DELAY.
    bool public paused;

    /// @dev Packs into exactly one storage slot (160 + 16 + 16 + 16 + 16 + 32 = 256 bits),
    ///      so the swap path costs a single SLOAD.
    ///      A pool is configured iff `vault != address(0)`. That is never cleared once set,
    ///      which prevents `configurePool` from being used to bypass the rate delay.
    ///      `pendingEffectiveAt == 0` means nothing is queued. uint32 seconds is valid to 2106.
    struct PoolConfig {
        address vault;
        uint16 zeroForOneBps;
        uint16 oneForZeroBps;
        uint16 pendingZeroForOneBps;
        uint16 pendingOneForZeroBps;
        uint32 pendingEffectiveAt;
    }

    /// @dev Internal rather than public deliberately. An auto-generated getter would expose
    ///      `zeroForOneBps` as though it were the live rate, but a matured queue entry is
    ///      applied on read by `_effectiveBps` and is not written back to the struct until
    ///      the next `setRates`. Callers go through `getEffectiveRates` for the rate a swap
    ///      is charged, or `getRawConfig` for the unresolved storage contents.
    mapping(PoolId => PoolConfig) internal _poolConfig;

    /// @dev Who queued the current pending change. Read only on the admin path,
    ///      never on the swap path, so it costs the hot slot nothing.
    ///      The operator is meant to be a lesser key. Without this it could hold
    ///      a rate in place indefinitely by re-queueing every four minutes, so a
    ///      fee cut the owner published would never mature.
    mapping(PoolId => address) internal _queuedBy;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event PoolConfigured(PoolId indexed poolId, address indexed vault, uint16 zeroForOneBps, uint16 oneForZeroBps);
    event VaultUpdated(PoolId indexed poolId, address indexed previousVault, address indexed newVault);
    event RatesQueued(PoolId indexed poolId, uint16 zeroForOneBps, uint16 oneForZeroBps, uint32 effectiveAt);
    event QueuedRatesCancelled(PoolId indexed poolId);
    /// @dev `sender` is the caller of `PoolManager.swap` — a router in production, not the
    ///      end trader. v4 does not surface the originating EOA to hooks.
    event FeeCollected(
        PoolId indexed poolId, address indexed sender, Currency indexed currency, uint256 amount, bool zeroForOne
    );
    event PauseStateChanged(bool isPaused);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);

    // =========================================================================
    // ERRORS
    // =========================================================================

    error NotPoolManager();
    error HookNotImplemented();
    error Unauthorized();
    error ZeroAddress();
    error ExceedsMaxFee();
    error PoolNotConfigured();
    error PoolAlreadyConfigured();
    error WrongHookForPool();
    error TokenNotInPool();
    error FeeOverflow();

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyOwnerOrOperator() {
        if (msg.sender != owner && msg.sender != operator) revert Unauthorized();
        _;
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    constructor(IPoolManager _poolManager, address _owner) {
        if (_owner == address(0)) revert ZeroAddress();

        poolManager = _poolManager;
        owner = _owner;

        IHooks(address(this)).validateHookPermissions(getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // =========================================================================
    // SWAP HOOK
    // =========================================================================

    /// @notice Collects the configured fee from the unspecified side of the swap.
    /// @dev Every early return yields a zero delta, leaving the swap as the pool priced it.
    ///      The only revert path is the vault rejecting a native-currency transfer inside
    ///      `take`.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        if (paused) return (IHooks.afterSwap.selector, 0);

        PoolId poolId = key.toId();
        PoolConfig memory config = _poolConfig[poolId];
        if (config.vault == address(0)) return (IHooks.afterSwap.selector, 0);

        uint16 bps = _effectiveBps(config, params.zeroForOne);
        if (bps == 0) return (IHooks.afterSwap.selector, 0);

        // The unspecified currency is currency1 exactly when zeroForOne == exactInput.
        // Mirrors the branch v4-core itself uses to place the hook delta (Hooks.afterSwap).
        bool exactInput = params.amountSpecified < 0;
        bool unspecifiedIsCurrency1 = (params.zeroForOne == exactInput);

        Currency feeCurrency = unspecifiedIsCurrency1 ? key.currency1 : key.currency0;
        int256 unspecifiedDelta = unspecifiedIsCurrency1 ? int256(delta.amount1()) : int256(delta.amount0());

        // Positive on exact-input (trader is owed the output), negative on exact-output
        // (trader owes the input). The fee is a share of the magnitude in both cases.
        uint256 amount = uint256(unspecifiedDelta < 0 ? -unspecifiedDelta : unspecifiedDelta);
        uint256 fee = (amount * bps) / BPS_DENOMINATOR;
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        // Unreachable while MAX_FEE_BPS <= 10_000, since `amount` fits in int128. Retained
        // as a guard on the cast below.
        if (fee > uint256(uint256(int256(type(int128).max)))) revert FeeOverflow();

        // Debits the hook by `fee`; the returned delta credits the same amount back, so the
        // hook's net delta is zero and the cost falls on the trader.
        poolManager.take(feeCurrency, config.vault, fee);

        emit FeeCollected(poolId, sender, feeCurrency, fee, params.zeroForOne);

        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    /// @dev The operator may queue and cancel freely, but it may not replace or
    ///      cancel a change somebody else queued that has not matured yet. The
    ///      owner is unrestricted. Without this the operator could restart the
    ///      delay indefinitely and stall a rate the owner had already published.
    function _assertMayDisturbQueue(PoolConfig memory config, PoolId poolId) internal view {
        if (msg.sender == owner) return;
        if (
            config.pendingEffectiveAt != 0 && block.timestamp < config.pendingEffectiveAt
                && _queuedBy[poolId] != msg.sender
        ) revert Unauthorized();
    }

    /// @notice Who queued the pending change, if there is one.
    function queuedBy(PoolKey calldata key) external view returns (address) {
        return _queuedBy[key.toId()];
    }

    /// @dev Matured queued rates take effect on read; no commit transaction is required.
    function _effectiveBps(PoolConfig memory config, bool zeroForOne) internal view returns (uint16) {
        if (config.pendingEffectiveAt != 0 && block.timestamp >= config.pendingEffectiveAt) {
            return zeroForOne ? config.pendingZeroForOneBps : config.pendingOneForZeroBps;
        }
        return zeroForOne ? config.zeroForOneBps : config.oneForZeroBps;
    }

    // =========================================================================
    // POOL CONFIGURATION
    // =========================================================================

    /// @notice Enables fee collection on a pool. A pool can only be configured once, so this
    ///         cannot be used to reset rates and skip the change delay. To stop collecting,
    ///         call `setRates(key, 0, 0)`, which takes effect after RATE_CHANGE_DELAY, or
    ///         `setPaused(true)` for an immediate global stop.
    /// @dev Rejects a key whose `hooks` field is not this contract. Such a pool would never
    ///      call this hook, so the stored config would be inert while still reading as
    ///      configured — a silent misconfiguration rather than an exploit.
    function configurePool(PoolKey calldata key, address vault, uint16 zeroForOneBps, uint16 oneForZeroBps)
        external
        onlyOwner
    {
        if (address(key.hooks) != address(this)) revert WrongHookForPool();
        if (vault == address(0)) revert ZeroAddress();
        if (zeroForOneBps > MAX_FEE_BPS || oneForZeroBps > MAX_FEE_BPS) revert ExceedsMaxFee();

        PoolId poolId = key.toId();
        if (_poolConfig[poolId].vault != address(0)) revert PoolAlreadyConfigured();

        _poolConfig[poolId] = PoolConfig({
            vault: vault,
            zeroForOneBps: zeroForOneBps,
            oneForZeroBps: oneForZeroBps,
            pendingZeroForOneBps: 0,
            pendingOneForZeroBps: 0,
            pendingEffectiveAt: 0
        });

        emit PoolConfigured(poolId, vault, zeroForOneBps, oneForZeroBps);
    }

    /// @notice Queues both direction rates for a pool.
    /// @dev Every change is queued for RATE_CHANGE_DELAY, in both directions. The rate
    ///      readable on-chain is therefore exactly what a swap will be charged until
    ///      `pendingEffectiveAt`, which is itself readable via `getQueuedRates`.
    ///      A later call replaces any unmatured queue entry and restarts the delay, so no
    ///      rate change can take effect sooner than RATE_CHANGE_DELAY from now.
    ///      For an immediate stop, use `setPaused(true)` — see RATE_CHANGE_DELAY for the
    ///      one exception the pause represents.
    function setRates(PoolKey calldata key, uint16 zeroForOneBps, uint16 oneForZeroBps)
        external
        onlyOwnerOrOperator
    {
        if (zeroForOneBps > MAX_FEE_BPS || oneForZeroBps > MAX_FEE_BPS) revert ExceedsMaxFee();

        PoolId poolId = key.toId();
        PoolConfig memory config = _poolConfig[poolId];
        if (config.vault == address(0)) revert PoolNotConfigured();
        _assertMayDisturbQueue(config, poolId);

        PoolConfig storage stored = _poolConfig[poolId];
        _queuedBy[poolId] = msg.sender;

        // Materialise any matured queue entry so this write does not discard it.
        stored.zeroForOneBps = _effectiveBps(config, true);
        stored.oneForZeroBps = _effectiveBps(config, false);

        uint32 effectiveAt = uint32(block.timestamp + RATE_CHANGE_DELAY);
        stored.pendingZeroForOneBps = zeroForOneBps;
        stored.pendingOneForZeroBps = oneForZeroBps;
        stored.pendingEffectiveAt = effectiveAt;

        emit RatesQueued(poolId, zeroForOneBps, oneForZeroBps, effectiveAt);
    }

    /// @notice Drops a queued rate change.
    /// @dev The effective rate is invariant across this call. Whatever is currently in force
    ///      is committed to the base fields before the queue is cleared: for an unmatured
    ///      entry `_effectiveBps` returns the base values, so those writes are no-ops and
    ///      this is a plain cancel; for a matured entry it promotes the pending values that
    ///      are already live. Clearing the queue without committing would let a matured
    ///      change be reverted instantly, bypassing RATE_CHANGE_DELAY.
    function cancelQueuedRates(PoolKey calldata key) external onlyOwnerOrOperator {
        PoolId poolId = key.toId();
        PoolConfig memory config = _poolConfig[poolId];
        if (config.vault == address(0)) revert PoolNotConfigured();
        _assertMayDisturbQueue(config, poolId);

        PoolConfig storage stored = _poolConfig[poolId];
        _queuedBy[poolId] = address(0);
        stored.zeroForOneBps = _effectiveBps(config, true);
        stored.oneForZeroBps = _effectiveBps(config, false);
        stored.pendingZeroForOneBps = 0;
        stored.pendingOneForZeroBps = 0;
        stored.pendingEffectiveAt = 0;

        emit QueuedRatesCancelled(poolId);
    }

    /// @notice Repoints a pool's fees at a new vault.
    /// @dev Immediate, and the correct response to a compromised vault. Zeroing rates via
    ///      `setRates` would take RATE_CHANGE_DELAY; repointing takes effect on the next
    ///      swap.
    /// @dev The vault must be able to receive the pool's currencies. For native currency
    ///      that requires an EOA, or a contract with a payable receive/fallback. v4
    ///      forwards all gas, so receiver gas cost is not a constraint, but a missing or
    ///      reverting receiver reverts swaps on this pool until the vault is changed.
    function setVault(PoolKey calldata key, address vault) external onlyOwner {
        if (vault == address(0)) revert ZeroAddress();

        PoolId poolId = key.toId();
        PoolConfig storage stored = _poolConfig[poolId];
        if (stored.vault == address(0)) revert PoolNotConfigured();

        emit VaultUpdated(poolId, stored.vault, vault);
        stored.vault = vault;
    }

    // =========================================================================
    // ADMIN
    // =========================================================================

    function setOperator(address _operator) external onlyOwner {
        emit OperatorUpdated(operator, _operator);
        operator = _operator;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PauseStateChanged(_paused);
    }

    /// @notice Two-step ownership transfer; the proposed owner must call acceptOwnership().
    ///         Pass address(0) to cancel a pending transfer.
    function transferOwnership(address _newOwner) external onlyOwner {
        pendingOwner = _newOwner;
        emit OwnershipTransferStarted(owner, _newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    // =========================================================================
    // VIEWS
    // =========================================================================

    /// @notice The rates a swap would be charged right now, resolving a matured queue entry
    ///         and the global pause. Returns (0, 0) while paused, matching what `afterSwap`
    ///         actually does. Use `getRawConfig` for the configured rate irrespective of
    ///         pause state.
    function getEffectiveRates(PoolKey calldata key)
        external
        view
        returns (uint16 zeroForOneBps, uint16 oneForZeroBps)
    {
        if (paused) return (0, 0);
        PoolConfig memory config = _poolConfig[key.toId()];
        return (_effectiveBps(config, true), _effectiveBps(config, false));
    }

    /// @notice A queued change and when it matures. `effectiveAt == 0` means nothing queued.
    function getQueuedRates(PoolKey calldata key)
        external
        view
        returns (uint16 zeroForOneBps, uint16 oneForZeroBps, uint32 effectiveAt)
    {
        PoolConfig memory config = _poolConfig[key.toId()];
        return (config.pendingZeroForOneBps, config.pendingOneForZeroBps, config.pendingEffectiveAt);
    }

    /// @notice Raw stored configuration, without resolving a matured queue entry.
    /// @dev For ops and debugging. `zeroForOneBps` and `oneForZeroBps` are the pre-queue
    ///      values and are stale once `pendingEffectiveAt` has passed. Use
    ///      `getEffectiveRates` for the rate a swap is actually charged.
    function getRawConfig(PoolKey calldata key) external view returns (PoolConfig memory) {
        return _poolConfig[key.toId()];
    }

    function isConfigured(PoolKey calldata key) external view returns (bool) {
        return _poolConfig[key.toId()].vault != address(0);
    }

    function getVault(PoolKey calldata key) external view returns (address) {
        return _poolConfig[key.toId()].vault;
    }

    /// @notice Resolves which swap direction buys `token` in this pool.
    /// @dev Configuration helper for mapping rates onto the correct direction. In a
    ///      native-ETH pool ETH is currency0, so buying the other token is `true`.
    function buyDirection(PoolKey calldata key, Currency token) external pure returns (bool zeroForOne) {
        if (key.currency1 == token) return true;
        if (key.currency0 == token) return false;
        revert TokenNotInPool();
    }

    /// @notice Fee that would be charged on `amount` of the unspecified currency.
    /// @dev Pause-aware for the same reason as `getEffectiveRates`: it must agree with what
    ///      a swap would actually be charged.
    function previewFee(PoolKey calldata key, uint256 amount, bool zeroForOne) external view returns (uint256) {
        if (paused) return 0;
        PoolConfig memory config = _poolConfig[key.toId()];
        return (amount * _effectiveBps(config, zeroForOne)) / BPS_DENOMINATOR;
    }

    // =========================================================================
    // UNUSED HOOK CALLBACKS (disabled by permission flags; never called by PoolManager)
    // =========================================================================

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
