// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IStaking
/// @notice Interface for the CELO staking contract with time-weighted rewards.
interface IStaking {
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error Paused();
    error Reentrancy();
    error AmountTooLow();
    error NothingStaked();
    error NothingToWithdraw();
    error LockNotExpired();
    error LockTooLong();
    error InvalidRate();
    error TransferFailed();
    error InsufficientRewardPool();

    event Staked(address indexed user, uint256 amount, uint256 lockUntil);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 reward);
    event RewardPoolFunded(address indexed funder, uint256 amount);
    event RateUpdated(uint256 oldRate, uint256 newRate);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function stake(uint256 lockDuration) external payable;
    function unstake() external;
    function claimReward() external;
    function pendingReward(address user) external view returns (uint256);
    function getStake(address user) external view returns (uint256 amount, uint256 lockUntil, uint256 stakedAt);
    function fundRewardPool() external payable;
    function setRewardRate(uint256 newRateBps) external;
    function pause() external;
    function unpause() external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
