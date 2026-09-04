// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

interface IPosm721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256);
}

/// @title  MillLPStaking
/// @notice Stake a full-range Uniswap v4 position in one Mill's pool, earn that
///         Mill's LP share of the toll.
///
/// @dev    The Mill splits every fee three ways and sends the LP leg to whatever
///         address is set as `lpRecipient`. Point that at this contract and the
///         leg arrives here as pod tokens; this contract divides it between
///         stakers in proportion to liquidity staked, over time.
///
///         Rewards arrive as plain transfers with no callback, so there is no
///         "notifyReward" to hook. Instead `sync` measures the balance that has
///         appeared since it last looked. That makes the contract indifferent to
///         how it is funded — the Mill, a top-up, anything.
///
///         WEIGHT IS RAW LIQUIDITY, WHICH IS ONLY FAIR AT A FIXED RANGE. A narrow
///         position holds far more liquidity per pound deposited than a wide one,
///         so mixing ranges would let a one-tick position farm the pool. This
///         contract therefore accepts full-range positions ONLY, which is also
///         the only kind the app mints.
interface IMillFees {
    function processFees() external returns (uint256, uint256, uint256);
}

contract MillLPStaking {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    /// @dev Rewards per unit of weight are tiny, so they are tracked scaled up.
    uint256 private constant ACC = 1e30;

    /// @notice How long a newly staked position waits before it can be activated
    ///         and start earning.
    /// @dev Fees do not stream in — they land as a lump whenever `processFees`
    ///      runs. Without a delay a bot mints full-range liquidity in front of a
    ///      large wrap, stakes, claims and burns the position in the next block,
    ///      at no cost, because full-range liquidity is minted and burned at the
    ///      current price with no impact. Five minutes forces it to hold real
    ///      liquidity across a window it cannot predict, which is just being an
    ///      LP.
    ///
    ///      A warming position carries NO weight, rather than carrying weight it
    ///      is later denied. Denying it after the fact would not work: `debt` is
    ///      fixed at stake time, so the bot could simply wait out the delay and
    ///      claim the event anyway. Excluding the weight is what actually closes
    ///      it, and it also means the honest stakers who were already here take
    ///      the whole of that period rather than sharing it with a tourist.
    uint256 public constant WARMUP = 5 minutes;

    IERC20 public immutable reward;      // the pod token the Mill pays in
    IPosm721 public immutable posm;
    address public immutable rescuer;
    bytes25 public immutable poolId;     // the one pool this vault accepts
    int24 public immutable tickLower;    // full range, snapped to the spacing
    int24 public immutable tickUpper;

    /// @notice Weight that is live and earning. Warming positions are not in it.
    uint256 public totalWeight;
    /// @notice How many staked positions are still warming. `sweepUnallocated`
    ///         refuses to run while any of them could still be activated.
    uint256 public warming;
    uint256 public accPerWeight;
    /// @notice Reward already counted — distributed or waiting for a first staker.
    uint256 public accounted;
    /// @notice Arrived while nothing was staked. Paid to whoever stakes next
    ///         rather than stranded.
    uint256 public unallocated;
    uint256 public totalClaimed;

    /// @dev `owner` fills one slot; `weight`, `activeAt` and `active` pack into
    ///      the next, so the warm-up costs no extra storage.
    struct Stake {
        address owner;
        uint128 weight;
        uint64 activeAt;  // cannot be activated before this
        bool active;      // counted in totalWeight and earning
        uint256 debt;     // accPerWeight at the moment this position last settled
    }

    mapping(uint256 tokenId => Stake) public stakes;
    mapping(address user => uint256[] tokenIds) private _staked;

    error NotOwner();
    error WrongPool();
    error NotFullRange();
    error NoLiquidity();
    error AlreadyStaked();
    error NotStaked();
    error ZeroAddress();
    error NotWarm();
    error StillStaked();

    event Staked(address indexed user, uint256 indexed tokenId, uint128 weight, uint64 activeAt);
    event Activated(uint256 indexed tokenId, uint128 weight);
    event UnallocatedSwept(address indexed to, uint256 amount);
    event Unstaked(address indexed user, uint256 indexed tokenId, uint128 weight);
    event Claimed(address indexed user, uint256 indexed tokenId, uint256 amount);
    event Synced(uint256 added, uint256 accPerWeight, uint256 totalWeight);

    constructor(IERC20 reward_, IPosm721 posm_, PoolKey memory key, address rescuer_) {
        if (rescuer_ == address(0)) revert ZeroAddress();
        rescuer = rescuer_;
        if (address(reward_) == address(0) || address(posm_) == address(0)) revert ZeroAddress();
        reward = reward_;
        posm = posm_;
        poolId = bytes25(PoolId.unwrap(key.toId()));
        tickLower = (TickMath.MIN_TICK / key.tickSpacing) * key.tickSpacing;
        tickUpper = (TickMath.MAX_TICK / key.tickSpacing) * key.tickSpacing;
    }

    // =====================================================================
    // rewards
    // =====================================================================

    /// @notice Books any reward that has arrived since the last look.
    /// @dev Permissionless and called at the start of every state change, so a
    ///      staker can never be paid at a stale rate. Reward that lands while
    ///      nothing is staked is held, not lost.
    function sync() public {
        // Settle the Mill first. processFees() is permissionless, so a staker
        // clicking claim sweeps the latest fees through on the way in and nobody
        // runs a keeper. try/catch so a reward token that is not a Mill just skips.
        try IMillFees(address(reward)).processFees() {} catch {}

        uint256 bal = reward.balanceOf(address(this));
        uint256 fresh = bal > accounted ? bal - accounted : 0;
        uint256 added = fresh + unallocated;
        if (added == 0) return;

        accounted = bal;
        if (totalWeight == 0) {
            // nothing to divide it between yet; hold it for the first staker
            unallocated = added;
        } else {
            accPerWeight += (added * ACC) / totalWeight;
            unallocated = 0;
        }
        emit Synced(added, accPerWeight, totalWeight);
    }

    /// @notice Reward owed to a position, including anything not yet synced.
    function pending(uint256 tokenId) public view returns (uint256) {
        Stake memory s = stakes[tokenId];
        if (s.owner == address(0) || !s.active) return 0;

        uint256 acc = accPerWeight;
        uint256 bal = reward.balanceOf(address(this));
        if (bal > accounted && totalWeight > 0) {
            acc += ((bal - accounted + unallocated) * ACC) / totalWeight;
        }
        return (uint256(s.weight) * (acc - s.debt)) / ACC;
    }

    function pendingFor(address user) external view returns (uint256 total) {
        uint256[] memory ids = _staked[user];
        for (uint256 i; i < ids.length; i++) total += pending(ids[i]);
    }

    // =====================================================================
    // staking
    // =====================================================================

    /// @notice Stake a position you have already approved to this contract.
    function stake(uint256 tokenId) external {
        if (posm.ownerOf(tokenId) != msg.sender) revert NotOwner();
        posm.transferFrom(msg.sender, address(this), tokenId);
        _stake(msg.sender, tokenId);
    }

    /// @dev Lets `safeTransferFrom` stake in a single transaction, with no prior
    ///      approval. Only positions sent by the position manager count.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        returns (bytes4)
    {
        if (msg.sender != address(posm)) revert NotOwner();
        _stake(from, tokenId);
        return this.onERC721Received.selector;
    }

    function _stake(address user, uint256 tokenId) internal {
        if (stakes[tokenId].owner != address(0)) revert AlreadyStaked();

        (PoolKey memory key, uint256 info) = posm.getPoolAndPositionInfo(tokenId);
        if (bytes25(bytes32(info)) != poolId) revert WrongPool();

        int24 tl = int24(int256(info >> 8));
        int24 tu = int24(int256(info >> 32));
        if (tl != tickLower || tu != tickUpper) revert NotFullRange();
        key; // silence unused; the poolId check above is the authoritative one

        uint128 weight = posm.getPositionLiquidity(tokenId);
        if (weight == 0) revert NoLiquidity();

        sync();

        // No weight and no debt yet. Both are set by `activate`, which is what
        // makes the warm-up real rather than cosmetic.
        uint64 activeAt = uint64(block.timestamp + WARMUP);
        stakes[tokenId] = Stake({owner: user, weight: weight, activeAt: activeAt, active: false, debt: 0});
        _staked[user].push(tokenId);
        warming += 1;

        emit Staked(user, tokenId, weight, activeAt);
    }

    /// @notice Brings warmed-up positions into the reward pool.
    /// @dev Permissionless and takes a list, so a staker, the app, or anyone at
    ///      all can activate any position that has served its delay — nobody is
    ///      left out because they did not come back. A position earns from the
    ///      moment it is activated, never before.
    function activate(uint256[] calldata tokenIds) external {
        sync();

        uint256 added;
        for (uint256 i; i < tokenIds.length; i++) {
            Stake storage s = stakes[tokenIds[i]];
            if (s.owner == address(0)) revert NotStaked();
            if (s.active) continue;
            if (block.timestamp < s.activeAt) revert NotWarm();

            s.debt = accPerWeight;   // taken before the flush below
            s.active = true;
            added += s.weight;
            warming -= 1;

            emit Activated(tokenIds[i], s.weight);
        }
        if (added == 0) return;
        totalWeight += added;

        // `sync` above ran while totalWeight may still have been zero, so what it
        // found went to `unallocated`. Now there is weight to divide it by.
        if (unallocated > 0) {
            accPerWeight += (unallocated * ACC) / totalWeight;
            unallocated = 0;
        }
    }

    /// @notice Claim without unstaking.
    function claim(uint256 tokenId) public returns (uint256 amount) {
        Stake storage s = stakes[tokenId];
        if (s.owner != msg.sender) revert NotStaked();
        if (!s.active) return 0;   // still warming; nothing has accrued to it

        sync();
        amount = (uint256(s.weight) * (accPerWeight - s.debt)) / ACC;
        s.debt = accPerWeight;

        if (amount > 0) {
            accounted -= amount;
            totalClaimed += amount;
            reward.safeTransfer(msg.sender, amount);
            emit Claimed(msg.sender, tokenId, amount);
        }
    }

    function claimAll() external returns (uint256 total) {
        uint256[] memory ids = _staked[msg.sender];
        for (uint256 i; i < ids.length; i++) total += claim(ids[i]);
    }

    /// @notice Take the position back. Pays out everything owed on the way.
    /// @dev There is no lock and no exit penalty. The position is returned with
    ///      `transferFrom` rather than `safeTransferFrom` so a receiver that
    ///      reverts cannot trap the NFT in this contract.
    function unstake(uint256 tokenId) external {
        Stake memory s = stakes[tokenId];
        if (s.owner != msg.sender) revert NotStaked();

        claim(tokenId);

        if (s.active) totalWeight -= s.weight;
        else warming -= 1;
        delete stakes[tokenId];
        _remove(msg.sender, tokenId);

        posm.transferFrom(address(this), msg.sender, tokenId);
        emit Unstaked(msg.sender, tokenId, s.weight);
    }

    function _remove(address user, uint256 tokenId) internal {
        uint256[] storage ids = _staked[user];
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == tokenId) {
                ids[i] = ids[ids.length - 1];
                ids.pop();
                return;
            }
        }
    }

    // =====================================================================
    // views
    // =====================================================================

    function stakedTokens(address user) external view returns (uint256[] memory) {
        return _staked[user];
    }

    function stakedCount(address user) external view returns (uint256) {
        return _staked[user].length;
    }
    error Unauthorized();
    event Rescued(uint256 indexed tokenId, address indexed to);

    /// @notice Move reward that accrued while nothing was earning.
    /// @dev Reward that arrives at an empty vault is held for the next staker,
    ///      which means one dust position could otherwise collect months of fees
    ///      by being first through the door. This is the way out. It refuses to
    ///      run while anything is staked or warming, so it can never reach what a
    ///      staker is owed.
    ///
    ///      The natural destination is the Mill itself: shares sitting in the
    ///      Mill's own balance are re-split by the next `processFees`, so the
    ///      bulk is burned back to holders rather than taken by anyone. It is
    ///      also the only escape if a vault is ever built against the wrong pool,
    ///      where `stake` reverts forever and the LP leg would otherwise pile up
    ///      unreachable.
    function sweepUnallocated(address to) external returns (uint256 amount) {
        if (msg.sender != rescuer) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();

        sync();
        if (totalWeight != 0 || warming != 0) revert StillStaked();

        amount = unallocated;
        if (amount == 0) return 0;

        unallocated = 0;
        accounted -= amount;
        reward.safeTransfer(to, amount);
        emit UnallocatedSwept(to, amount);
    }

    /// @notice Return a position that arrived via a plain `transferFrom`, so it never
    ///         hit `onERC721Received` and has no stake recorded against it. Cannot
    ///         touch anything that is actually staked.
    function rescue(uint256 tokenId, address to) external {
        if (msg.sender != rescuer) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();
        if (stakes[tokenId].owner != address(0)) revert AlreadyStaked();
        posm.transferFrom(address(this), to, tokenId);
        emit Rescued(tokenId, to);
    }
}
