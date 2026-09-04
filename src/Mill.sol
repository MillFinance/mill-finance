// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title  Mill
/// @notice Wraps an underlying TKN into mTKN. Wrap and unwrap fees are taken in
///         *shares*, accumulate at the contract, and are later split between a
///         burn (which raises the redemption ratio for every holder) and a fee
///         recipient. The burn share is the dial between "holders earn" and
///         "everyone else gets paid".
///
/// @dev    THE INVARIANT THAT MATTERS
///         --------------------------
///         There is no code path that moves the underlying out of this contract
///         except `unwrap`. No pause, no upgrade, no rescue, no owner function.
///         `rescue` explicitly refuses the underlying and refuses mTKN itself.
///
///         The redemption ratio is therefore monotonically non-decreasing under
///         every operation, and redemption is unconditional forever: `wrap` can
///         be disabled once and permanently, `unwrap` can never be.
///
/// @dev    WHY FEES ARE DENOMINATED IN SHARES
///         ---------------------------------
///         Retaining the underlying instead would move 100% of every fee to
///         holders with no way to route any of it elsewhere. Taking the fee as
///         shares leaves the ratio untouched at the moment of the trade and
///         makes the split a parameter, settled later in `processFees`.
contract Mill is ERC20 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ---------------------------------------------------------------------
    // constants
    // ---------------------------------------------------------------------

    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_WRAP_FEE_BPS = 100; // 1%
    uint16 public constant MAX_UNWRAP_FEE_BPS = 300; // 3%

    /// @dev Virtual shares. Makes the first-depositor inflation attack
    ///      uneconomic: an attacker must donate ~10**OFFSET times the victim's
    ///      deposit to round it to zero.
    uint8 public constant DECIMALS_OFFSET = 3;

    // ---------------------------------------------------------------------
    // immutables
    // ---------------------------------------------------------------------

    IERC20 public immutable asset;
    uint8 private immutable _assetDecimals;

    uint16 public immutable wrapFeeBps;
    uint16 public immutable unwrapFeeBps;

    /// @notice Floor on the burn share, fixed at deployment. Governance can
    ///         raise the burn but can never take holders below this.
    uint16 public immutable minBurnBps;

    /// @notice For launchpad hooks that gate pool registration on the token
    ///         naming its registrant as creator.
    address public immutable creator;

    // ---------------------------------------------------------------------
    // storage
    // ---------------------------------------------------------------------

    /// @notice The three-way split of accumulated fee shares, in bps. Always
    ///         sums to BPS.
    ///
    ///         `burnBps`     burned, which raises the ratio for every holder
    ///         `lpBps`       to `lpRecipient` — LP incentives or a staking contract
    ///         the remainder to `feeRecipient` — protocol revenue
    ///
    ///         Bounded below by `minBurnBps`, so governance can move revenue
    ///         between the protocol and LPs freely but can never take holders
    ///         below the floor fixed at deployment.
    uint16 public burnBps;
    uint16 public lpBps;

    address public feeRecipient;
    address public lpRecipient;
    address public owner;

    /// @notice One-way. For a delisted or deprecated underlying.
    bool public wrapDisabled;

    /// @notice Cumulative shares burned. The number you publish.
    uint256 public totalBurned;

    // ---------------------------------------------------------------------
    // events / errors
    // ---------------------------------------------------------------------

    event Wrapped(address indexed caller, address indexed receiver, uint256 assetsIn, uint256 sharesOut, uint256 feeShares);
    event Unwrapped(address indexed caller, address indexed receiver, uint256 sharesIn, uint256 assetsOut, uint256 feeShares);
    event FeesProcessed(uint256 burned, uint256 toProtocol, uint256 toLp, uint256 newTotalBurned);
    event SplitUpdated(uint16 burnBps, uint16 lpBps);
    event FeeRecipientUpdated(address indexed previous, address indexed current);
    event LpRecipientUpdated(address indexed previous, address indexed current);
    event WrapDisabledForever();
    event OwnershipTransferred(address indexed previous, address indexed current);

    error ZeroAmount();
    error ZeroAddress();
    error FeeTooHigh();
    error BurnBelowFloor();
    error SplitOverflow();
    error WrapDisabled();
    error Unauthorized();
    error NotRescuable();
    error Reentrancy();
    error BelowMinimum();

    /// @dev `wrap` credits the BALANCE DELTA across `safeTransferFrom`. If the
    ///      underlying hands control back to the sender during that transfer —
    ///      ERC777 `tokensReceived`, ERC1363, any token with a post-transfer
    ///      notifier — a re-entrant `wrap` would be counted twice: once by the
    ///      inner call that minted for it correctly, and again by the outer
    ///      call's delta. That mints shares with no backing behind them.
    ///
    ///      A guard rather than a rewrite, because the balance-delta read is
    ///      also what makes fee-on-transfer underlyings safe; the two
    ///      requirements pull in opposite directions and the lock resolves both.
    ///      `processFees` is deliberately NOT guarded — wrap and unwrap call it
    ///      while holding the lock.
    uint256 private _entered = 1;

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        uint16 wrapFeeBps_,
        uint16 unwrapFeeBps_,
        uint16 minBurnBps_,
        uint16 burnBps_,
        uint16 lpBps_,
        address feeRecipient_,
        address lpRecipient_,
        address owner_
    ) ERC20(name_, symbol_) {
        if (
            address(asset_) == address(0) || feeRecipient_ == address(0) || lpRecipient_ == address(0)
                || owner_ == address(0)
        ) revert ZeroAddress();
        if (wrapFeeBps_ > MAX_WRAP_FEE_BPS || unwrapFeeBps_ > MAX_UNWRAP_FEE_BPS) revert FeeTooHigh();
        if (minBurnBps_ > BPS || burnBps_ > BPS || burnBps_ < minBurnBps_) revert BurnBelowFloor();
        if (uint256(burnBps_) + lpBps_ > BPS) revert SplitOverflow();

        if (feeRecipient_ == address(this) || lpRecipient_ == address(this)) revert ZeroAddress();

        asset = asset_;
        _assetDecimals = _tryDecimals(address(asset_));
        wrapFeeBps = wrapFeeBps_;
        unwrapFeeBps = unwrapFeeBps_;
        minBurnBps = minBurnBps_;
        burnBps = burnBps_;
        lpBps = lpBps_;
        feeRecipient = feeRecipient_;
        lpRecipient = lpRecipient_;
        owner = owner_;
        creator = owner_;
    }

    function _tryDecimals(address token) private view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }

    function decimals() public view override returns (uint8) {
        return _assetDecimals + DECIMALS_OFFSET;
    }

    // ---------------------------------------------------------------------
    // accounting
    // ---------------------------------------------------------------------

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Underlying per whole share, scaled to 1e18. The number to publish.
    function ratio() external view returns (uint256) {
        return _convertToAssets(10 ** decimals(), totalAssets(), Math.Rounding.Floor) * 1e18 / (10 ** _assetDecimals);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, totalAssets(), Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, totalAssets(), Math.Rounding.Floor);
    }

    function _convertToShares(uint256 assets, uint256 ta, Math.Rounding r) internal view returns (uint256) {
        return assets.mulDiv(totalSupply() + 10 ** DECIMALS_OFFSET, ta + 1, r);
    }

    function _convertToAssets(uint256 shares, uint256 ta, Math.Rounding r) internal view returns (uint256) {
        return shares.mulDiv(ta + 1, totalSupply() + 10 ** DECIMALS_OFFSET, r);
    }

    /// @dev Shares that `processFees` is about to destroy. They are still counted
    ///      in `totalSupply`, so any quote that ignores them prices against a
    ///      supply that will not exist by the time the call executes.
    function pendingBurn() public view returns (uint256) {
        return (balanceOf(address(this)) * burnBps) / BPS;
    }

    function _convertToSharesAt(uint256 assets, uint256 ta, uint256 supply, Math.Rounding r)
        internal
        pure
        returns (uint256)
    {
        return assets.mulDiv(supply + 10 ** DECIMALS_OFFSET, ta + 1, r);
    }

    function _convertToAssetsAt(uint256 shares, uint256 ta, uint256 supply, Math.Rounding r)
        internal
        pure
        returns (uint256)
    {
        return shares.mulDiv(ta + 1, supply + 10 ** DECIMALS_OFFSET, r);
    }

    /// @notice What `wrap` will actually mint, settling first the way `wrap` does.
    /// @dev The naive version reads the pre-settlement supply and therefore
    ///      OVERSTATES — the caller receives fewer shares than quoted whenever
    ///      fees are parked, which is most of the time.
    function previewWrap(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply() - pendingBurn();
        uint256 shares = _convertToSharesAt(assets, totalAssets(), supply, Math.Rounding.Floor);
        return shares - (shares * wrapFeeBps) / BPS;
    }

    /// @notice What `unwrap` will actually pay, settling first the way `unwrap` does.
    function previewUnwrap(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply() - pendingBurn();
        uint256 redeemShares = shares - (shares * unwrapFeeBps) / BPS;
        return _convertToAssetsAt(redeemShares, totalAssets(), supply, Math.Rounding.Floor);
    }

    // ---------------------------------------------------------------------
    // wrap / unwrap
    // ---------------------------------------------------------------------

    /// @dev Shares are priced against the pre-deposit state, and the amount
    ///      credited is the balance delta rather than `assets` — so a
    ///      fee-on-transfer underlying cannot mint unbacked supply.
    ///
    ///      Fees from PRIOR operations are settled first, before this deposit is
    ///      priced. Two reasons, in order of importance. Unprocessed fee shares
    ///      are still in `totalSupply`, so leaving them there under-credits every
    ///      holder — deferring the burn is not neutral, it is a real loss that
    ///      persists until someone calls. And settling first rather than last
    ///      means this caller's own toll never lifts the ratio they are about to
    ///      hold, so the fee cannot partially refund itself.
    /// @notice `wrap` with a floor on what you receive.
    /// @dev The ratio can only rise, and it rises between quote and execution
    ///      whenever anyone else transacts first — so a caller who priced off
    ///      `previewWrap` gets slightly less than quoted. Bounded, but an
    ///      integrator should be able to say how much less it will accept.
    function wrap(uint256 assets, address receiver, uint256 minSharesOut) external returns (uint256 sharesOut) {
        sharesOut = wrap(assets, receiver);
        if (sharesOut < minSharesOut) revert BelowMinimum();
    }

    function unwrap(uint256 shares, address receiver, uint256 minAssetsOut) external returns (uint256 assetsOut) {
        assetsOut = unwrap(shares, receiver);
        if (assetsOut < minAssetsOut) revert BelowMinimum();
    }

    function wrap(uint256 assets, address receiver) public nonReentrant returns (uint256 sharesOut) {
        if (wrapDisabled) revert WrapDisabled();
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        processFees();

        uint256 taBefore = totalAssets();
        asset.safeTransferFrom(msg.sender, address(this), assets);
        uint256 received = totalAssets() - taBefore;
        if (received == 0) revert ZeroAmount();

        uint256 shares = _convertToShares(received, taBefore, Math.Rounding.Floor);
        if (shares == 0) revert ZeroAmount();

        uint256 feeShares = (shares * wrapFeeBps) / BPS;
        sharesOut = shares - feeShares;

        _mint(receiver, sharesOut);
        if (feeShares > 0) _mint(address(this), feeShares);

        emit Wrapped(msg.sender, receiver, received, sharesOut, feeShares);
    }

    /// @dev Prior fees are settled first, so the redeemer is paid at a current
    ///      ratio rather than a stale one. Their own toll is moved to this
    ///      contract rather than burned, and becomes holder value on the next
    ///      call — never on this one.
    ///
    ///      `processFees` cannot revert: it burns from this contract's own
    ///      balance and `_transfer`s to a `feeRecipient` that can never be the
    ///      zero address and is never called back. So putting it here does not
    ///      give the fee recipient a way to block redemptions.
    function unwrap(uint256 shares, address receiver) public nonReentrant returns (uint256 assetsOut) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        processFees();

        uint256 feeShares = (shares * unwrapFeeBps) / BPS;
        uint256 redeemShares = shares - feeShares;

        assetsOut = _convertToAssets(redeemShares, totalAssets(), Math.Rounding.Floor);

        _burn(msg.sender, redeemShares);
        if (feeShares > 0) _transfer(msg.sender, address(this), feeShares);

        asset.safeTransfer(receiver, assetsOut);

        emit Unwrapped(msg.sender, receiver, shares, assetsOut, feeShares);
    }

    // ---------------------------------------------------------------------
    // fees
    // ---------------------------------------------------------------------

    /// @notice Splits accumulated fee shares three ways: burn, LPs, protocol.
    /// @dev Permissionless, and called automatically at the top of every wrap
    ///      and unwrap, so the ratio is never stale. Frequent small settlements
    ///      keep any single ratio step well below the cost of trading against it.
    ///
    ///      The protocol leg takes the remainder rather than its own `mulDiv`,
    ///      so integer division can never strand dust at this contract — and
    ///      dust here is not inert, it is unburned supply diluting holders.
    function processFees() public returns (uint256 burned, uint256 toProtocol, uint256 toLp) {
        uint256 bal = balanceOf(address(this));
        if (bal == 0) return (0, 0, 0);

        burned = (bal * burnBps) / BPS;
        toLp = (bal * lpBps) / BPS;
        toProtocol = bal - burned - toLp;

        if (burned > 0) {
            _burn(address(this), burned);
            totalBurned += burned;
        }
        if (toLp > 0) _transfer(address(this), lpRecipient, toLp);
        if (toProtocol > 0) _transfer(address(this), feeRecipient, toProtocol);

        emit FeesProcessed(burned, toProtocol, toLp, totalBurned);
    }

    // ---------------------------------------------------------------------
    // admin — none of this can touch the underlying
    // ---------------------------------------------------------------------

    /// @notice Moves the split. Both legs at once, so the vault can never sit in
    ///         a half-updated state where the shares do not add up.
    /// @dev Settles at the OLD split first — otherwise a change would retroactively
    ///      redirect fees that were earned under the previous one.
    function setSplit(uint16 newBurnBps, uint16 newLpBps) external onlyOwner {
        if (newBurnBps > BPS || newBurnBps < minBurnBps) revert BurnBelowFloor();
        if (uint256(newBurnBps) + newLpBps > BPS) revert SplitOverflow();
        processFees();
        burnBps = newBurnBps;
        lpBps = newLpBps;
        emit SplitUpdated(newBurnBps, newLpBps);
    }

    /// @dev Refuses this contract. `_transfer(address(this), address(this), x)` is
    ///      a no-op, so pointing a leg here would leave fee shares in the balance
    ///      permanently — unburned supply diluting every holder, recycled on
    ///      every call, and the one thing `processFees` promises never happens.
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0) || newRecipient == address(this)) revert ZeroAddress();
        processFees();
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    /// @notice Where the LP share goes. Point it at your treasury while liquidity
    ///         is protocol-owned, then at a staking contract when there are
    ///         third-party LPs to pay.
    function setLpRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0) || newRecipient == address(this)) revert ZeroAddress();
        processFees();
        emit LpRecipientUpdated(lpRecipient, newRecipient);
        lpRecipient = newRecipient;
    }

    /// @notice One-way and permanent. `unwrap` is unaffected and can never be disabled.
    function disableWrapForever() external onlyOwner {
        wrapDisabled = true;
        emit WrapDisabledForever();
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Recovers unrelated tokens. Refuses the underlying and refuses
    ///         mTKN, which would otherwise be a path to the fee balance.
    function rescue(IERC20 token, address to) external onlyOwner returns (uint256 amount) {
        if (address(token) == address(asset) || address(token) == address(this)) revert NotRescuable();
        if (to == address(0)) revert ZeroAddress();
        amount = token.balanceOf(address(this));
        token.safeTransfer(to, amount);
    }
}
