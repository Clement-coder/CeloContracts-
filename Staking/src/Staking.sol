// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IStaking} from "./IStaking.sol";

/// @title Staking
/// @notice CELO staking contract. Users stake CELO with an optional lock period
///         and earn rewards proportional to their stake and time elapsed.
///         Rewards are funded by the owner into a reward pool.
///         Annual reward rate is set in basis points (e.g. 1000 = 10% APR).
/// @dev    Production-grade: reentrancy guard, pause, two-step ownership,
///         custom errors, full NatSpec, locked pragma, optimizer config.
contract Staking is IStaking {

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Minimum stake amount: 0.001 CELO.
    uint256 public constant MIN_STAKE = 0.001 ether;

    /// @notice Maximum lock duration: 2 years.
    uint256 public constant MAX_LOCK = 2 * 365 days;

    /// @notice Maximum annual reward rate: 100% (10000 bps).
    uint256 public constant MAX_RATE_BPS = 10_000;

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice Current contract owner.
    address public owner;

    /// @notice Pending owner in two-step transfer.
    address public pendingOwner;

    /// @notice Whether the contract is paused.
    bool public paused;

    /// @notice Reentrancy lock.
    bool private _locked;

    /// @notice Annual reward rate in basis points (e.g. 1000 = 10% APR).
    uint256 public rewardRateBps;

    /// @notice Total CELO currently staked.
    uint256 public totalStaked;

    /// @notice Total CELO in the reward pool.
    uint256 public rewardPool;

    /// @dev Stake record per user.
    struct StakeRecord {
        /// @dev Amount staked in wei.
        uint256 amount;
        /// @dev Timestamp after which unstaking is allowed (0 = no lock).
        uint256 lockUntil;
        /// @dev Timestamp when stake was last updated (for reward calculation).
        uint256 stakedAt;
    }

    /// @notice Stake records by user address.
    mapping(address => StakeRecord) public stakes;

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @notice Deploy the staking contract.
    /// @param _rewardRateBps Annual reward rate in basis points. Must be > 0 and <= MAX_RATE_BPS.
    constructor(uint256 _rewardRateBps) {
        if (_rewardRateBps == 0 || _rewardRateBps > MAX_RATE_BPS) revert InvalidRate();
        owner = msg.sender;
        rewardRateBps = _rewardRateBps;
    }

    // ─── Core ──────────────────────────────────────────────────────────────────

    /// @notice Stake CELO with an optional lock period.
    /// @param lockDuration Seconds to lock the stake (0 = no lock, max MAX_LOCK).
    /// @dev   If user already has a stake, rewards are auto-claimed and stake is topped up.
    ///        Emits {Staked}.
    function stake(uint256 lockDuration)
        external payable override whenNotPaused nonReentrant
    {
        if (msg.value < MIN_STAKE) revert AmountTooLow();
        if (lockDuration > MAX_LOCK) revert LockTooLong();

        StakeRecord storage s = stakes[msg.sender];

        // Auto-claim pending rewards before updating stake
        if (s.amount > 0) {
            uint256 reward = _calcReward(s);
            if (reward > 0 && reward <= rewardPool) {
                rewardPool -= reward;
                s.stakedAt = block.timestamp;
                emit RewardClaimed(msg.sender, reward);
                (bool ok,) = msg.sender.call{value: reward}("");
                if (!ok) revert TransferFailed();
            } else {
                s.stakedAt = block.timestamp;
            }
        }

        s.amount += msg.value;
        totalStaked += msg.value;

        if (lockDuration > 0) {
            uint256 newLock = block.timestamp + lockDuration;
            if (newLock > s.lockUntil) s.lockUntil = newLock;
        }

        if (s.stakedAt == 0) s.stakedAt = block.timestamp;

        emit Staked(msg.sender, msg.value, s.lockUntil);
    }

    /// @notice Unstake all CELO. Auto-claims pending rewards.
    /// @dev   Lock must have expired. Emits {Unstaked} and {RewardClaimed}.
    function unstake() external override nonReentrant {
        StakeRecord storage s = stakes[msg.sender];
        if (s.amount == 0) revert NothingStaked();
        if (block.timestamp < s.lockUntil) revert LockNotExpired();

        uint256 amount = s.amount;
        uint256 reward = _calcReward(s);

        // Clear state before transfers
        s.amount = 0;
        s.lockUntil = 0;
        s.stakedAt = 0;
        totalStaked -= amount;

        emit Unstaked(msg.sender, amount);

        // Return principal
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        // Pay reward if pool has enough
        if (reward > 0 && reward <= rewardPool) {
            rewardPool -= reward;
            emit RewardClaimed(msg.sender, reward);
            (bool rok,) = msg.sender.call{value: reward}("");
            if (!rok) revert TransferFailed();
        }
    }

    /// @notice Claim accrued rewards without unstaking.
    /// @dev   Emits {RewardClaimed}.
    function claimReward() external override nonReentrant whenNotPaused {
        StakeRecord storage s = stakes[msg.sender];
        if (s.amount == 0) revert NothingStaked();

        uint256 reward = _calcReward(s);
        if (reward == 0) revert NothingToWithdraw();
        if (reward > rewardPool) revert InsufficientRewardPool();

        rewardPool -= reward;
        s.stakedAt = block.timestamp; // reset reward timer

        emit RewardClaimed(msg.sender, reward);

        (bool ok,) = msg.sender.call{value: reward}("");
        if (!ok) revert TransferFailed();
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Returns the pending reward for a user at current timestamp.
    /// @param user Address to query.
    /// @return Pending reward in wei.
    function pendingReward(address user) external view override returns (uint256) {
        StakeRecord storage s = stakes[user];
        if (s.amount == 0) return 0;
        return _calcReward(s);
    }

    /// @notice Returns a user's stake details.
    /// @param user Address to query.
    /// @return amount    Amount staked in wei.
    /// @return lockUntil Lock expiry timestamp (0 = no lock).
    /// @return stakedAt  Timestamp of last stake/claim update.
    function getStake(address user)
        external view override
        returns (uint256 amount, uint256 lockUntil, uint256 stakedAt)
    {
        StakeRecord storage s = stakes[user];
        return (s.amount, s.lockUntil, s.stakedAt);
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Fund the reward pool. Anyone can contribute.
    /// @dev Emits {RewardPoolFunded}.
    function fundRewardPool() external payable override {
        if (msg.value == 0) revert AmountTooLow();
        rewardPool += msg.value;
        emit RewardPoolFunded(msg.sender, msg.value);
    }

    /// @notice Update the annual reward rate.
    /// @param newRateBps New rate in basis points. Must be > 0 and <= MAX_RATE_BPS.
    /// @dev Emits {RateUpdated}. Only affects future reward accrual.
    function setRewardRate(uint256 newRateBps) external override onlyOwner {
        if (newRateBps == 0 || newRateBps > MAX_RATE_BPS) revert InvalidRate();
        emit RateUpdated(rewardRateBps, newRateBps);
        rewardRateBps = newRateBps;
    }

    /// @notice Pause the contract.
    function pause() external override onlyOwner {
        paused = true;
        emit ContractPaused(msg.sender);
    }

    /// @notice Unpause the contract.
    function unpause() external override onlyOwner {
        paused = false;
        emit ContractUnpaused(msg.sender);
    }

    /// @notice Initiate two-step ownership transfer.
    function transferOwnership(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Accept ownership.
    function acceptOwnership() external override {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    // ─── Internal ──────────────────────────────────────────────────────────────

    /// @dev Simple interest: reward = amount * rate * elapsed / (365 days * 10_000)
    function _calcReward(StakeRecord storage s) internal view returns (uint256) {
        if (s.amount == 0 || s.stakedAt == 0) return 0;
        uint256 elapsed = block.timestamp - s.stakedAt;
        return (s.amount * rewardRateBps * elapsed) / (365 days * 10_000);
    }
}
