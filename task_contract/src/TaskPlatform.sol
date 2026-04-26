// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ITaskPlatform} from "./ITaskPlatform.sol";

/// @title TaskPlatform
/// @notice Decentralized task bounty platform on Celo.
///         Posters create tasks with CELO bounties; workers claim and complete them.
///         Includes expiry, dispute, pause, two-step ownership, and full reentrancy protection.
contract TaskPlatform is ITaskPlatform {

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Minimum bounty: 0.001 CELO.
    uint256 public constant MIN_BOUNTY = 0.001 ether;

    /// @notice Task expires and can be reclaimed after this duration.
    uint256 public constant TASK_DURATION = 7 days;

    /// @notice Task completion timeout: 30 days.
    uint256 public constant TASK_TIMEOUT = 30 days;

    /// @notice Maximum title length in bytes.
    uint256 public constant MAX_TITLE_LENGTH = 100;

    /// @notice Maximum description length in bytes.
    uint256 public constant MAX_DESC_LENGTH = 1000;

    // ─── Types ─────────────────────────────────────────────────────────────────

    /// @notice Task lifecycle status.
    enum Status {
        /// @dev Task is open and available to claim.
        Open,
        /// @dev Task has been claimed by a worker.
        InProgress,
        /// @dev Task completed and bounty paid.
        Completed,
        /// @dev Task cancelled by poster (only from Open).
        Cancelled,
        /// @dev Task expired and bounty reclaimed by poster.
        Expired,
        /// @dev Task is under dispute.
        Disputed
    }

    /// @dev On-chain task record.
    struct Task {
        /// @dev Address that created the task.
        address poster;
        /// @dev Address that claimed the task. Zero if unclaimed.
        address worker;
        /// @dev Short task title.
        string title;
        /// @dev Full task description.
        string description;
        /// @dev Bounty amount in wei.
        uint256 bounty;
        /// @dev Timestamp after which poster can reclaim bounty.
        uint256 deadline;
        /// @dev Current lifecycle status.
        Status status;
        /// @dev Rating given by poster (1-5, 0 = not rated).
        uint8 rating;
    }

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice Current contract owner.
    address public owner;

    /// @notice Pending owner in two-step transfer.
    address public pendingOwner;

    /// @notice Whether the contract is paused.
    bool public paused;

    /// @notice Reentrancy lock.
    bool private _locked;

    /// @notice Total number of tasks ever created.
    uint256 public taskCount;

    /// @notice Total bounty currently locked in active tasks.
    uint256 public totalBountyLocked;

    /// @notice Tasks by ID (1-indexed).
    mapping(uint256 => Task) public tasks;

    /// @notice Worker reputation: address => (totalRating, completedTasks).
    mapping(address => WorkerReputation) public workerReputation;

    struct WorkerReputation {
        uint256 totalRating;
        uint256 completedTasks;
    }

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    /// @dev Reverts if caller is not the owner.
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Reverts if contract is paused.
    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    /// @dev Simple reentrancy guard.
    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    /// @dev Reverts if caller is not the task poster.
    modifier onlyPoster(uint256 id) {
        if (msg.sender != tasks[id].poster) revert NotPoster();
        _;
    }

    /// @dev Reverts if caller is not the task worker.
    modifier onlyWorker(uint256 id) {
        if (msg.sender != tasks[id].worker) revert NotWorker();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @notice Deploy the task platform. Deployer becomes owner.
    constructor() {
        owner = msg.sender;
    }

    // ─── Core ──────────────────────────────────────────────────────────────────

    /// @notice Create a new task with a CELO bounty.
    /// @param title       Short task title. Max MAX_TITLE_LENGTH bytes.
    /// @param description Full task description. Max MAX_DESC_LENGTH bytes.
    /// @return id         The new task ID.
    /// @dev Emits {TaskCreated}. Bounty must be >= MIN_BOUNTY.
    function createTask(string calldata title, string calldata description)
        external payable override whenNotPaused nonReentrant returns (uint256)
    {
        if (msg.value < MIN_BOUNTY) revert BountyTooLow();
        if (bytes(title).length == 0 || bytes(title).length > MAX_TITLE_LENGTH) revert TitleTooLong();
        if (bytes(description).length > MAX_DESC_LENGTH) revert DescTooLong();

        uint256 id = ++taskCount;
        uint256 deadline = block.timestamp + TASK_DURATION;

        tasks[id] = Task({
            poster: msg.sender,
            worker: address(0),
            title: title,
            description: description,
            bounty: msg.value,
            deadline: deadline,
            status: Status.Open,
            rating: 0
        });

        totalBountyLocked += msg.value;

        emit TaskCreated(id, msg.sender, msg.value, title, deadline);
        return id;
    }

    /// @notice Claim an open task as a worker.
    /// @param id Task ID to claim.
    /// @dev Emits {TaskClaimed}. Poster cannot claim their own task.
    function claimTask(uint256 id) external override whenNotPaused nonReentrant {
        Task storage t = tasks[id];
        if (t.poster == address(0)) revert InvalidTask();
        if (t.status != Status.Open) revert TaskNotOpen();
        if (msg.sender == t.poster) revert PosterCannotClaim();
        if (block.timestamp >= t.deadline) revert TaskExpired();

        t.worker = msg.sender;
        t.status = Status.InProgress;

        emit TaskClaimed(id, msg.sender);
    }

    /// @notice Poster approves task completion and releases bounty to worker.
    /// @param id Task ID to approve.
    /// @param workerRating Rating for the worker (1-5, 0 to skip rating).
    /// @dev Emits {TaskCompleted}. Only callable by poster when task is InProgress.
    function approveCompletion(uint256 id, uint8 workerRating) external override onlyPoster(id) nonReentrant {
        Task storage t = tasks[id];
        if (t.status != Status.InProgress) revert TaskNotInProgress();
        if (workerRating > 5) revert InvalidRating();

        address worker = t.worker;
        uint256 bounty = t.bounty;

        t.status = Status.Completed;
        t.bounty = 0;
        t.rating = workerRating;
        totalBountyLocked -= bounty;

        // Update worker reputation
        if (workerRating > 0) {
            WorkerReputation storage rep = workerReputation[worker];
            rep.totalRating += workerRating;
            rep.completedTasks += 1;
        }

        emit TaskCompleted(id, worker, bounty);
        if (workerRating > 0) {
            emit TaskRated(id, worker, workerRating);
        }

        (bool ok,) = worker.call{value: bounty}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Poster cancels an open task and reclaims bounty.
    /// @param id Task ID to cancel.
    /// @dev Emits {TaskCancelled}. Only works on Open tasks.
    function cancelTask(uint256 id) external override onlyPoster(id) nonReentrant {
        Task storage t = tasks[id];
        if (t.status != Status.Open) revert TaskNotCancellable();

        address poster = t.poster;
        uint256 bounty = t.bounty;

        t.status = Status.Cancelled;
        t.bounty = 0;
        totalBountyLocked -= bounty;

        emit TaskCancelled(id, poster, bounty);

        (bool ok,) = poster.call{value: bounty}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Poster reclaims bounty from an expired uncompleted task.
    /// @param id Task ID to reclaim.
    /// @dev Task must be past its deadline and not Completed/Cancelled. Emits {TaskExpiredAndReclaimed}.
    function reclaimExpired(uint256 id) external override onlyPoster(id) nonReentrant {
        Task storage t = tasks[id];
        if (t.status == Status.Completed || t.status == Status.Cancelled || t.status == Status.Expired)
            revert TaskNotCancellable();
        if (block.timestamp < t.deadline) revert TaskNotExpired();

        address poster = t.poster;
        uint256 bounty = t.bounty;

        t.status = Status.Expired;
        t.bounty = 0;
        totalBountyLocked -= bounty;

        emit TaskExpiredAndReclaimed(id, poster, bounty);

        (bool ok,) = poster.call{value: bounty}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Raise a dispute on an InProgress task.
    /// @param id Task ID to dispute.
    /// @dev Either poster or worker can raise a dispute. Emits {TaskDisputed}.
    function disputeTask(uint256 id) external override whenNotPaused {
        Task storage t = tasks[id];
        if (t.status != Status.InProgress) revert TaskNotInProgress();
        if (msg.sender != t.poster && msg.sender != t.worker) revert NotAuthorized();

        t.status = Status.Disputed;
        emit TaskDisputed(id, msg.sender);
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Returns full details of a task.
    /// @param id Task ID to query.
    /// @return taskId      The task ID.
    /// @return poster      Address that created the task.
    /// @return worker      Address that claimed the task (zero if unclaimed).
    /// @return title       Task title.
    /// @return description Task description.
    /// @return bounty      Current bounty in wei.
    /// @return status      Current status as uint8.
    /// @return deadline    Expiry timestamp.
    /// @return rating      Worker rating (1-5, 0 = not rated).
    function getTask(uint256 id) external view override returns (
        uint256 taskId, address poster, address worker,
        string memory title, string memory description,
        uint256 bounty, uint8 status, uint256 deadline, uint8 rating
    ) {
        Task storage t = tasks[id];
        return (id, t.poster, t.worker, t.title, t.description, t.bounty, uint8(t.status), t.deadline, t.rating);
    }

    /// @notice Get worker reputation and average rating.
    /// @param worker Worker address to query.
    /// @return averageRating Average rating (scaled by 100, e.g., 450 = 4.5 stars).
    /// @return completedTasks Number of completed tasks.
    function getWorkerReputation(address worker) external view override returns (uint256 averageRating, uint256 completedTasks) {
        WorkerReputation storage rep = workerReputation[worker];
        completedTasks = rep.completedTasks;
        if (completedTasks > 0) {
            averageRating = (rep.totalRating * 100) / completedTasks;
        } else {
            averageRating = 0;
        }
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Pause the contract — halts task creation and claiming.
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

    /// @notice Owner withdraws ETH not accounted for in totalBountyLocked.
    /// @param amount Amount to withdraw in wei.
    /// @dev Emits {StuckFundsWithdrawn}. Cannot touch locked bounties.
    function withdrawStuckFunds(uint256 amount) external override onlyOwner nonReentrant {
        uint256 free = address(this).balance - totalBountyLocked;
        if (amount == 0 || amount > free) revert InvalidAmount();
        emit StuckFundsWithdrawn(owner, amount);
        (bool ok,) = owner.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Accept direct ETH transfers.
    receive() external payable {}
}
