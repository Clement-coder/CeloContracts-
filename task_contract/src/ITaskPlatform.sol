// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title ITaskPlatform
/// @notice Interface for the decentralized task bounty platform.
interface ITaskPlatform {
    // ─── Errors ────────────────────────────────────────────────────────────────
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error Paused();
    error Reentrancy();
    error BountyTooLow();
    error TaskNotOpen();
    error TaskNotInProgress();
    error TaskNotCancellable();
    error NotPoster();
    error NotWorker();
    error PosterCannotClaim();
    error TaskExpired();
    error TaskNotExpired();
    error TransferFailed();
    error TitleTooLong();
    error DescTooLong();
    error InvalidTask();

    // ─── Events ────────────────────────────────────────────────────────────────
    event TaskCreated(uint256 indexed id, address indexed poster, uint256 bounty, string title, uint256 deadline);
    event TaskClaimed(uint256 indexed id, address indexed worker);
    event TaskCompleted(uint256 indexed id, address indexed worker, uint256 bounty);
    event TaskCancelled(uint256 indexed id, address indexed poster, uint256 bountyRefunded);
    event TaskExpiredAndReclaimed(uint256 indexed id, address indexed poster, uint256 bountyRefunded);
    event TaskDisputed(uint256 indexed id, address indexed raisedBy);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event StuckFundsWithdrawn(address indexed to, uint256 amount);

    // ─── Functions ─────────────────────────────────────────────────────────────
    function createTask(string calldata title, string calldata description) external payable returns (uint256);
    function claimTask(uint256 id) external;
    function approveCompletion(uint256 id) external;
    function cancelTask(uint256 id) external;
    function reclaimExpired(uint256 id) external;
    function disputeTask(uint256 id) external;
    function getTask(uint256 id) external view returns (
        uint256 taskId, address poster, address worker,
        string memory title, string memory description,
        uint256 bounty, uint8 status, uint256 deadline
    );
    function pause() external;
    function unpause() external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function withdrawStuckFunds(uint256 amount) external;
}
