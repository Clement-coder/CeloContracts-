// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title ITimelockController
/// @notice Interface for the TimelockController that governs the Savings contract.
interface ITimelockController {
    // ─── Errors ────────────────────────────────────────────────────────────────
    error NotAdmin();
    error NotProposer();
    error NotExecutor();
    error ZeroAddress();
    error DelayTooShort();
    error DelayTooLong();
    error TxNotQueued();
    error TxAlreadyQueued();
    error TxAlreadyExecuted();
    error TimelockNotExpired(uint256 eta);
    error GracePeriodExpired(uint256 eta);
    error TxExecutionFailed();

    // ─── Events ────────────────────────────────────────────────────────────────
    event TransactionQueued(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        bytes data,
        uint256 eta
    );
    event TransactionExecuted(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        bytes data
    );
    event TransactionCancelled(bytes32 indexed txHash);
    event DelayUpdated(uint256 oldDelay, uint256 newDelay);
    event ProposerSet(address indexed account, bool status);
    event ExecutorSet(address indexed account, bool status);

    // ─── Functions ─────────────────────────────────────────────────────────────
    function queueTransaction(address target, uint256 value, bytes calldata data) external returns (bytes32 txHash, uint256 eta);
    function executeTransaction(address target, uint256 value, bytes calldata data, uint256 eta) external payable returns (bytes memory);
    function cancelTransaction(bytes32 txHash) external; // proposer only
    function setDelay(uint256 newDelay) external; // admin only
    function setProposer(address account, bool status) external; // grant/revoke proposer role
    function setExecutor(address account, bool status) external; // grant/revoke executor role
    function getTxHash(address target, uint256 value, bytes calldata data, uint256 eta) external pure returns (bytes32);
    function isQueued(bytes32 txHash) external view returns (bool); // true if queued and not yet executed/cancelled
    function getEta(bytes32 txHash) external view returns (uint256);
    function isExecuted(bytes32 txHash) external view returns (bool);
}
