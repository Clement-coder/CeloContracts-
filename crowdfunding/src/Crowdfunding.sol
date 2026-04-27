// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ICrowdfunding} from "./ICrowdfunding.sol";

/// @title Crowdfunding
/// @notice A CELO crowdfunding platform. Creators launch campaigns with a goal and deadline.
///         Contributors send CELO. If goal is met by deadline, creator claims funds.
///         If goal is not met, contributors get full refunds.
/// @dev    Production-grade: reentrancy guard, pause, two-step ownership, pull refunds,
///         custom errors, full NatSpec, locked pragma, optimizer config.
contract Crowdfunding is ICrowdfunding {

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Minimum campaign goal: 0.01 CELO.
    uint256 public constant MIN_GOAL = 0.01 ether;

    /// @notice Minimum contribution: 0.001 CELO.
    uint256 public constant MIN_CONTRIBUTION = 0.001 ether;

    /// @notice Minimum campaign duration: 1 day.
    uint256 public constant MIN_DURATION = 1 days;

    /// @notice Maximum campaign duration: 90 days.
    uint256 public constant MAX_DURATION = 90 days;

    /// @notice Maximum title length in bytes.
    uint256 public constant MAX_TITLE_LENGTH = 100;

    /// @notice Maximum referral rate: 5% (500 bps).
    uint256 public constant MAX_REFERRAL_RATE = 500;

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice Current contract owner.
    address public owner;

    /// @notice Pending owner in two-step transfer.
    address public pendingOwner;

    /// @notice Whether the contract is paused.
    bool public paused;

    /// @notice Reentrancy lock.
    bool private _locked;

    /// @notice Total number of campaigns created.
    uint256 public campaignCount;

    /// @notice Referral rate in basis points (e.g., 100 = 1%).
    uint256 public referralRate;

    /// @dev Campaign record.
    struct Campaign {
        /// @dev Address that created the campaign.
        address creator;
        /// @dev Short campaign title.
        string title;
        /// @dev Full campaign description.
        string description;
        /// @dev Funding goal in wei.
        uint256 goal;
        /// @dev Unix timestamp when the campaign was created (used for MAX_DURATION cap).
        uint256 start;
        /// @dev Unix timestamp of campaign deadline.
        uint256 deadline;
        /// @dev Total CELO raised so far.
        uint256 raised;
        /// @dev Whether creator has claimed the funds.
        bool claimed;
        /// @dev Whether campaign was cancelled by creator.
        bool cancelled;
    }

    /// @notice Campaigns by ID (1-indexed).
    mapping(uint256 => Campaign) public campaigns;

    /// @notice contributions[campaignId][contributor] = amount.
    mapping(uint256 => mapping(address => uint256)) public contributions;

    /// @notice Referral rewards: referrer => earned amount.
    mapping(address => uint256) public referralRewards;

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

    modifier campaignExists(uint256 id) {
        if (id == 0 || id > campaignCount) revert InvalidCampaign();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @notice Deploy the crowdfunding platform. Deployer becomes owner.
    constructor() {
        owner = msg.sender;
        referralRate = 100; // Default 1% referral reward
    }

    // ─── Core ──────────────────────────────────────────────────────────────────

    /// @notice Create a new crowdfunding campaign.
    /// @param title       Short campaign title. Max MAX_TITLE_LENGTH bytes.
    /// @param description Full campaign description.
    /// @param goal        Funding goal in wei. Must be >= MIN_GOAL.
    /// @param duration    Campaign duration in seconds. Must be between MIN_DURATION and MAX_DURATION.
    /// @return id         The new campaign ID.
    /// @dev Emits {CampaignCreated}.
    function createCampaign(
        string calldata title,
        string calldata description,
        uint256 goal,
        uint256 duration
    ) external override whenNotPaused returns (uint256) {
        if (bytes(title).length == 0 || bytes(title).length > MAX_TITLE_LENGTH) revert TitleTooLong();
        if (goal < MIN_GOAL) revert GoalTooLow();
        if (duration < MIN_DURATION) revert DeadlineTooShort();
        if (duration > MAX_DURATION) revert DeadlineTooLong();

        uint256 id = ++campaignCount;
        uint256 start = block.timestamp;
        uint256 deadline = start + duration;

        campaigns[id] = Campaign({
            creator: msg.sender,
            title: title,
            description: description,
            goal: goal,
            start: start,
            deadline: deadline,
            raised: 0,
            claimed: false,
            cancelled: false
        });

        emit CampaignCreated(id, msg.sender, goal, deadline, title);
        return id;
    }

    /// @notice Contribute CELO to a campaign.
    /// @param id Campaign ID to contribute to.
    /// @dev   Emits {Contributed}. Emits {GoalReached} if goal is hit.
    function contribute(uint256 id)
        external payable override whenNotPaused nonReentrant campaignExists(id)
    {
        Campaign storage c = campaigns[id];
        if (c.cancelled) revert CampaignAlreadyEnded();
        if (block.timestamp >= c.deadline) revert CampaignAlreadyEnded();
        if (msg.value < MIN_CONTRIBUTION) revert ContributionTooLow();

        contributions[id][msg.sender] += msg.value;
        c.raised += msg.value;

        emit Contributed(id, msg.sender, msg.value, c.raised);

        if (c.raised >= c.goal) {
            emit GoalReached(id, c.raised);
        }
    }

    /// @notice Contribute CELO to a campaign with an optional referral reward.
    /// @param id       Campaign ID to contribute to.
    /// @param referrer Optional referrer address for rewards.
    /// @dev   Emits {Contributed}. Emits {GoalReached} if goal is hit.
    function contributeWithReferral(uint256 id, address referrer)
        external payable override whenNotPaused nonReentrant campaignExists(id)
    {
        Campaign storage c = campaigns[id];
        if (c.cancelled) revert CampaignAlreadyEnded();
        if (block.timestamp >= c.deadline) revert CampaignAlreadyEnded();
        if (msg.value < MIN_CONTRIBUTION) revert ContributionTooLow();

        contributions[id][msg.sender] += msg.value;
        c.raised += msg.value;

        if (referrer != address(0) && referrer != msg.sender && referrer != c.creator) {
            uint256 referralReward = (msg.value * referralRate) / 10_000;
            referralRewards[referrer] += referralReward;
            emit ReferralReward(referrer, msg.sender, referralReward);
        }

        emit Contributed(id, msg.sender, msg.value, c.raised);

        if (c.raised >= c.goal) {
            emit GoalReached(id, c.raised);
        }
    }

    /// @notice Withdraw accumulated referral rewards.
    /// @dev Emits {ReferralRewardsWithdrawn}. Uses pull-payment pattern to prevent reentrancy issues.
    function withdrawReferralRewards() external override nonReentrant {
        uint256 amount = referralRewards[msg.sender];
        if (amount == 0) revert NothingToRefund();

        referralRewards[msg.sender] = 0;
        emit ReferralRewardsWithdrawn(msg.sender, amount);

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Creator claims funds after campaign ends with goal met.
    /// @param id Campaign ID to claim.
    /// @dev   Emits {FundsClaimed}. Only callable by campaign creator after deadline.
    function claimFunds(uint256 id)
        external override nonReentrant campaignExists(id)
    {
        Campaign storage c = campaigns[id];
        if (msg.sender != c.creator) revert NotCreator();
        if (c.cancelled) revert CampaignAlreadyEnded();
        if (block.timestamp < c.deadline) revert CampaignNotEnded();
        if (c.raised < c.goal) revert GoalNotMet();
        if (c.claimed) revert AlreadyClaimed();

        c.claimed = true;
        uint256 amount = c.raised;

        emit FundsClaimed(id, msg.sender, amount);

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Contributor claims refund if campaign failed or was cancelled.
    /// @param id Campaign ID to refund from.
    /// @dev   Emits {Refunded}. Pull-payment pattern.
    function refund(uint256 id)
        external override nonReentrant campaignExists(id)
    {
        Campaign storage c = campaigns[id];
        bool failed = block.timestamp >= c.deadline && c.raised < c.goal;
        bool cancelled = c.cancelled;
        if (!failed && !cancelled) revert GoalAlreadyMet();

        uint256 amount = contributions[id][msg.sender];
        if (amount == 0) revert NothingToRefund();

        contributions[id][msg.sender] = 0;

        emit Refunded(id, msg.sender, amount);

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Creator cancels an active campaign. All contributors can refund.
    /// @param id Campaign ID to cancel.
    /// @dev   Emits {CampaignCancelled}. Only works before deadline and before claimed.
    function cancelCampaign(uint256 id)
        external override nonReentrant campaignExists(id)
    {
        Campaign storage c = campaigns[id];
        if (msg.sender != c.creator) revert NotCreator();
        if (c.cancelled) revert CampaignAlreadyEnded();
        if (c.claimed) revert AlreadyClaimed();
        if (block.timestamp >= c.deadline) revert CampaignAlreadyEnded();

        c.cancelled = true;
        emit CampaignCancelled(id, msg.sender);
    }

    /// @notice Creator extends campaign deadline (only if goal not yet met).
    /// @param id             Campaign ID to extend.
    /// @param additionalTime Additional seconds to add to deadline.
    /// @dev   Emits {CampaignExtended}. Total duration from start cannot exceed MAX_DURATION.
    function extendCampaign(uint256 id, uint256 additionalTime)
        external override campaignExists(id)
    {
        Campaign storage c = campaigns[id];
        if (msg.sender != c.creator) revert NotCreator();
        if (c.cancelled) revert CampaignAlreadyEnded();
        if (c.claimed) revert AlreadyClaimed();
        if (c.raised >= c.goal) revert GoalAlreadyMet();
        if (additionalTime == 0) revert DeadlineTooShort();

        uint256 newDeadline = c.deadline + additionalTime;
        if (newDeadline > c.start + MAX_DURATION) revert DeadlineTooLong();

        uint256 oldDeadline = c.deadline;
        c.deadline = newDeadline;

        emit CampaignExtended(id, oldDeadline, newDeadline);
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Returns full details of a campaign.
    function getCampaign(uint256 id)
        external view override campaignExists(id)
        returns (address creator, string memory title, uint256 goal, uint256 deadline, uint256 raised, bool claimed, bool cancelled)
    {
        Campaign storage c = campaigns[id];
        return (c.creator, c.title, c.goal, c.deadline, c.raised, c.claimed, c.cancelled);
    }

    /// @notice Returns a contributor's contribution to a campaign.
    function getContribution(uint256 id, address contributor)
        external view override returns (uint256)
    {
        return contributions[id][contributor];
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Pause the contract — halts campaign creation and contributions.
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

    /// @notice Accept ownership (must be called by pendingOwner).
    function acceptOwnership() external override {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    /// @notice Set the referral reward rate. Only callable by owner.
    /// @param newRate New rate in basis points. 0 disables referrals. Max 500 (5%).
    function setReferralRate(uint256 newRate) external override onlyOwner {
        if (newRate > MAX_REFERRAL_RATE) revert ReferralRateTooHigh();
        emit ReferralRateUpdated(referralRate, newRate);
        referralRate = newRate;
    }

    /// @notice Reject accidental direct ETH sends.
    receive() external payable {
        revert TransferFailed();
    }
}
