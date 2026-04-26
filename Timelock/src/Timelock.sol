// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ITimelock} from "./ITimelock.sol";

/// @title Timelock
/// @notice A timelock controller that delays execution of transactions.
///         Proposers can schedule transactions, and executors can execute them
///         after the delay period. Supports role-based access control.
/// @dev    Production-grade: reentrancy guard, role management, batch operations,
///         custom errors, full NatSpec, locked pragma.
contract Timelock is ITimelock {

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Minimum delay: 1 hour.
    uint256 public constant MIN_DELAY = 1 hours;

    /// @notice Maximum delay: 30 days.
    uint256 public constant MAX_DELAY = 30 days;

    /// @notice Role identifier for proposers.
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");

    /// @notice Role identifier for executors.
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /// @notice Role identifier for admin.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice Minimum delay for operations.
    uint256 public delay;

    /// @notice Reentrancy lock.
    bool private _locked;

    /// @notice Role assignments: role => account => hasRole.
    mapping(bytes32 => mapping(address => bool)) private _roles;

    /// @notice Scheduled operations: operationId => timestamp.
    mapping(bytes32 => uint256) private _timestamps;

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyRole(bytes32 role) {
        if (!hasRole(role, msg.sender)) revert AccessDenied();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @notice Deploy the timelock controller.
    /// @param _delay Minimum delay for operations.
    /// @param proposers Array of addresses with proposer role.
    /// @param executors Array of addresses with executor role.
    /// @param admin Address with admin role (can be zero to renounce).
    constructor(
        uint256 _delay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) {
        if (_delay < MIN_DELAY || _delay > MAX_DELAY) revert InvalidDelay();
        
        delay = _delay;

        // Grant proposer role
        for (uint256 i = 0; i < proposers.length; i++) {
            _grantRole(PROPOSER_ROLE, proposers[i]);
        }

        // Grant executor role
        for (uint256 i = 0; i < executors.length; i++) {
            _grantRole(EXECUTOR_ROLE, executors[i]);
        }

        // Grant admin role
        if (admin != address(0)) {
            _grantRole(ADMIN_ROLE, admin);
        }
    }

    // ─── Core Operations ───────────────────────────────────────────────────────

    /// @notice Schedule an operation for future execution.
    /// @param target Target contract address.
    /// @param value CELO value to send.
    /// @param data Calldata to execute.
    /// @param salt Unique salt for operation ID.
    /// @return operationId The unique operation identifier.
    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 salt
    ) external onlyRole(PROPOSER_ROLE) returns (bytes32 operationId) {
        operationId = hashOperation(target, value, data, salt);
        
        if (isOperationPending(operationId)) revert OperationAlreadyScheduled();
        
        uint256 timestamp = block.timestamp + delay;
        _timestamps[operationId] = timestamp;
        
        emit OperationScheduled(operationId, target, value, data, timestamp);
    }

    /// @notice Execute a scheduled operation.
    /// @param target Target contract address.
    /// @param value CELO value to send.
    /// @param data Calldata to execute.
    /// @param salt Salt used when scheduling.
    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 salt
    ) external payable onlyRole(EXECUTOR_ROLE) nonReentrant {
        bytes32 operationId = hashOperation(target, value, data, salt);
        
        if (!isOperationReady(operationId)) revert OperationNotReady();
        
        _timestamps[operationId] = 1; // Mark as executed
        
        emit OperationExecuted(operationId, target, value, data);
        
        (bool success,) = target.call{value: value}(data);
        if (!success) revert ExecutionFailed();
    }

    /// @notice Cancel a scheduled operation.
    /// @param operationId Operation to cancel.
    function cancel(bytes32 operationId) external onlyRole(PROPOSER_ROLE) {
        if (!isOperationPending(operationId)) revert OperationNotScheduled();
        
        delete _timestamps[operationId];
        emit OperationCancelled(operationId);
    }

    // ─── Batch Operations ──────────────────────────────────────────────────────

    /// @notice Schedule multiple operations in batch.
    /// @param targets Array of target addresses.
    /// @param values Array of CELO values.
    /// @param datas Array of calldatas.
    /// @param salt Unique salt for batch operation.
    /// @return operationId The batch operation identifier.
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas,
        bytes32 salt
    ) external onlyRole(PROPOSER_ROLE) returns (bytes32 operationId) {
        if (targets.length != values.length || targets.length != datas.length) {
            revert InvalidBatch();
        }
        
        operationId = hashOperationBatch(targets, values, datas, salt);
        
        if (isOperationPending(operationId)) revert OperationAlreadyScheduled();
        
        uint256 timestamp = block.timestamp + delay;
        _timestamps[operationId] = timestamp;
        
        emit BatchScheduled(operationId, targets, values, datas, timestamp);
    }

    /// @notice Execute a batch of scheduled operations.
    /// @param targets Array of target addresses.
    /// @param values Array of CELO values.
    /// @param datas Array of calldatas.
    /// @param salt Salt used when scheduling.
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas,
        bytes32 salt
    ) external payable onlyRole(EXECUTOR_ROLE) nonReentrant {
        if (targets.length != values.length || targets.length != datas.length) {
            revert InvalidBatch();
        }
        
        bytes32 operationId = hashOperationBatch(targets, values, datas, salt);
        
        if (!isOperationReady(operationId)) revert OperationNotReady();
        
        _timestamps[operationId] = 1; // Mark as executed
        
        emit BatchExecuted(operationId, targets, values, datas);
        
        for (uint256 i = 0; i < targets.length; i++) {
            (bool success,) = targets[i].call{value: values[i]}(datas[i]);
            if (!success) revert ExecutionFailed();
        }
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Check if an operation is pending.
    /// @param operationId Operation to check.
    /// @return True if operation is scheduled but not executed.
    function isOperationPending(bytes32 operationId) public view returns (bool) {
        return _timestamps[operationId] > 1;
    }

    /// @notice Check if an operation is ready for execution.
    /// @param operationId Operation to check.
    /// @return True if operation is scheduled and delay has passed.
    function isOperationReady(bytes32 operationId) public view returns (bool) {
        uint256 timestamp = _timestamps[operationId];
        return timestamp > 1 && block.timestamp >= timestamp;
    }

    /// @notice Check if an operation is done (executed).
    /// @param operationId Operation to check.
    /// @return True if operation has been executed.
    function isOperationDone(bytes32 operationId) public view returns (bool) {
        return _timestamps[operationId] == 1;
    }

    /// @notice Get the timestamp when an operation becomes ready.
    /// @param operationId Operation to check.
    /// @return Timestamp when operation can be executed.
    function getTimestamp(bytes32 operationId) external view returns (uint256) {
        return _timestamps[operationId];
    }

    /// @notice Hash a single operation.
    /// @param target Target address.
    /// @param value CELO value.
    /// @param data Calldata.
    /// @param salt Salt.
    /// @return Operation hash.
    function hashOperation(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 salt
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(target, value, data, salt));
    }

    /// @notice Hash a batch operation.
    /// @param targets Target addresses.
    /// @param values CELO values.
    /// @param datas Calldatas.
    /// @param salt Salt.
    /// @return Batch operation hash.
    function hashOperationBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas,
        bytes32 salt
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(targets, values, datas, salt));
    }

    // ─── Role Management ───────────────────────────────────────────────────────

    /// @notice Check if an account has a role.
    /// @param role Role to check.
    /// @param account Account to check.
    /// @return True if account has the role.
    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    /// @notice Grant a role to an account (admin only).
    /// @param role Role to grant.
    /// @param account Account to grant role to.
    function grantRole(bytes32 role, address account) external onlyRole(ADMIN_ROLE) {
        _grantRole(role, account);
    }

    /// @notice Revoke a role from an account (admin only).
    /// @param role Role to revoke.
    /// @param account Account to revoke role from.
    function revokeRole(bytes32 role, address account) external onlyRole(ADMIN_ROLE) {
        _revokeRole(role, account);
    }

    /// @notice Renounce a role (self only).
    /// @param role Role to renounce.
    function renounceRole(bytes32 role) external {
        _revokeRole(role, msg.sender);
    }

    /// @notice Update the minimum delay (admin only).
    /// @param newDelay New minimum delay.
    function updateDelay(uint256 newDelay) external onlyRole(ADMIN_ROLE) {
        if (newDelay < MIN_DELAY || newDelay > MAX_DELAY) revert InvalidDelay();
        emit DelayUpdated(delay, newDelay);
        delay = newDelay;
    }

    // ─── Internal ──────────────────────────────────────────────────────────────

    function _grantRole(bytes32 role, address account) internal {
        if (!_roles[role][account]) {
            _roles[role][account] = true;
            emit RoleGranted(role, account, msg.sender);
        }
    }

    function _revokeRole(bytes32 role, address account) internal {
        if (_roles[role][account]) {
            _roles[role][account] = false;
            emit RoleRevoked(role, account, msg.sender);
        }
    }

    /// @notice Accept CELO deposits.
    receive() external payable {}
}
