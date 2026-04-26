// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title ITimelock
/// @notice Interface for the timelock controller contract.
interface ITimelock {
    // ─── Errors ────────────────────────────────────────────────────────────────
    error AccessDenied();
    error InvalidDelay();
    error InvalidBatch();
    error OperationAlreadyScheduled();
    error OperationNotScheduled();
    error OperationNotReady();
    error ExecutionFailed();
    error Reentrancy();

    // ─── Events ────────────────────────────────────────────────────────────────
    event OperationScheduled(bytes32 indexed operationId, address indexed target, uint256 value, bytes data, uint256 timestamp);
    event OperationExecuted(bytes32 indexed operationId, address indexed target, uint256 value, bytes data);
    event OperationCancelled(bytes32 indexed operationId);
    event BatchScheduled(bytes32 indexed operationId, address[] targets, uint256[] values, bytes[] datas, uint256 timestamp);
    event BatchExecuted(bytes32 indexed operationId, address[] targets, uint256[] values, bytes[] datas);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event DelayUpdated(uint256 oldDelay, uint256 newDelay);

    // ─── Functions ─────────────────────────────────────────────────────────────
    function schedule(address target, uint256 value, bytes calldata data, bytes32 salt) external returns (bytes32);
    function execute(address target, uint256 value, bytes calldata data, bytes32 salt) external payable;
    function cancel(bytes32 operationId) external;
    function scheduleBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas, bytes32 salt) external returns (bytes32);
    function executeBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas, bytes32 salt) external payable;
    function isOperationPending(bytes32 operationId) external view returns (bool);
    function isOperationReady(bytes32 operationId) external view returns (bool);
    function isOperationDone(bytes32 operationId) external view returns (bool);
    function getTimestamp(bytes32 operationId) external view returns (uint256);
    function hashOperation(address target, uint256 value, bytes calldata data, bytes32 salt) external pure returns (bytes32);
    function hashOperationBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas, bytes32 salt) external pure returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role) external;
    function updateDelay(uint256 newDelay) external;
}
