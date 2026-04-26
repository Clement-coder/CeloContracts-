// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title ICrowdfunding
/// @notice Interface for the CELO crowdfunding platform.
interface ICrowdfunding {
    // ─── Errors ────────────────────────────────────────────────────────────────
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error Paused();
    error Reentrancy();
    error InvalidCampaign();
    error CampaignNotActive();
    error CampaignAlreadyEnded();
    error CampaignNotEnded();
    error GoalAlreadyMet();
    error GoalNotMet();
    error DeadlineTooShort();
    error DeadlineTooLong();
    error GoalTooLow();
    error ContributionTooLow();
    error AlreadyClaimed();
    error NothingToRefund();
    error TransferFailed();
    error TitleTooLong();
    error NotCreator();

    // ─── Events ────────────────────────────────────────────────────────────────
    event CampaignCreated(uint256 indexed id, address indexed creator, uint256 goal, uint256 deadline, string title);
    event Contributed(uint256 indexed id, address indexed contributor, uint256 amount, uint256 totalRaised);
    event GoalReached(uint256 indexed id, uint256 totalRaised);
    event FundsClaimed(uint256 indexed id, address indexed creator, uint256 amount);
    event Refunded(uint256 indexed id, address indexed contributor, uint256 amount);
    event CampaignCancelled(uint256 indexed id, address indexed creator);
    event CampaignExtended(uint256 indexed id, uint256 oldDeadline, uint256 newDeadline);
    event ReferralReward(address indexed referrer, address indexed contributor, uint256 reward);
    event ReferralRewardsWithdrawn(address indexed referrer, uint256 amount);
    event ReferralRateUpdated(uint256 oldRate, uint256 newRate);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ─── Functions ─────────────────────────────────────────────────────────────
    function createCampaign(string calldata title, string calldata description, uint256 goal, uint256 duration) external returns (uint256);
    function contribute(uint256 id) external payable;
    function claimFunds(uint256 id) external;
    function refund(uint256 id) external;
    function cancelCampaign(uint256 id) external;
    function getCampaign(uint256 id) external view returns (address creator, string memory title, uint256 goal, uint256 deadline, uint256 raised, bool claimed, bool cancelled);
    function getContribution(uint256 id, address contributor) external view returns (uint256);
    function pause() external;
    function unpause() external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
