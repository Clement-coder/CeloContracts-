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
        uint256 deadline = block.timestamp + duration;

        campaigns[id] = Campaign({
            creator: msg.sender,
            title: title,
            description: description,
            goal: goal,
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
    ///        Campaign must be active (not ended, not cancelled).
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

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Returns full details of a campaign.
    /// @param id Campaign ID to query.
    /// @return creator    Address that created the campaign.
    /// @return title      Campaign title.
    /// @return goal       Funding goal in wei.
    /// @return deadline   Campaign deadline timestamp.
    /// @return raised     Total CELO raised.
    /// @return claimed    Whether creator has claimed funds.
    /// @return cancelled  Whether campaign was cancelled.
    function getCampaign(uint256 id)
        external view override campaignExists(id)
        returns (address creator, string memory title, uint256 goal, uint256 deadline, uint256 raised, bool claimed, bool cancelled)
    {
        Campaign storage c = campaigns[id];
        return (c.creator, c.title, c.goal, c.deadline, c.raised, c.claimed, c.cancelled);
    }

    /// @notice Returns a contributor's contribution to a campaign.
    /// @param id          Campaign ID.
    /// @param contributor Address to query.
    /// @return Amount contributed in wei.
    function getContribution(uint256 id, address contributor)
        external view override returns (uint256)
    {
        return contributions[id][contributor];
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Pause the contract — halts campaign creation and contributions.
    /// @dev Emits {ContractPaused}.
    function pause() external override onlyOwner {
        paused = true;
        emit ContractPaused(msg.sender);
    }

    /// @notice Unpause the contract.
    /// @dev Emits {ContractUnpaused}.
    function unpause() external override onlyOwner {
        paused = false;
        emit ContractUnpaused(msg.sender);
    }

    /// @notice Initiate two-step ownership transfer.
    /// @param newOwner Proposed new owner. Cannot be zero address.
    /// @dev Emits {OwnershipTransferStarted}.
    function transferOwnership(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Accept ownership (must be called by pendingOwner).
    /// @dev Emits {OwnershipTransferred}.
    function acceptOwnership() external override {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    /// @notice Reject accidental direct ETH sends.
    receive() external payable {
        revert TransferFailed();
    }
}
