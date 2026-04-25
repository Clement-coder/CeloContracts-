// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ITimelockController} from "./ITimelockController.sol";

/// @title TimelockController
/// @notice Governance timelock for the Savings contract.
///
///         Workflow:
///           1. Proposer calls `queueTransaction(target, value, data)` → gets back (txHash, eta).
///           2. After `delay` seconds, executor calls `executeTransaction(target, value, data, eta)`.
///           3. Execution must happen within GRACE_PERIOD after eta, else the tx expires.
///           4. Proposer can cancel any queued tx before execution.
///
///         The Savings contract owner should be transferred to this TimelockController
///         so that admin actions (pause, unpause, transferOwnership) go through the timelock.
///
/// @dev    Role model:
///           - Admin  : can update delay and manage proposer/executor roles.
///                      The deployer and address(this) are admins by default.
///           - Proposer: can queue and cancel transactions.
///           - Executor: can execute queued transactions after the delay.
contract TimelockController is ITimelockController {

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Minimum allowed delay: 1 day (86400 seconds).
    uint256 public constant MIN_DELAY = 1 days;

    /// @notice Maximum allowed delay: 30 days (2592000 seconds).
    uint256 public constant MAX_DELAY = 30 days;

    /// @notice Window after eta in which a tx must be executed before it expires (14 days).
    uint256 public constant GRACE_PERIOD = 14 days;

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice Current timelock delay in seconds.
    uint256 public delay;

    /// @notice Proposer role: accounts that can queue and cancel transactions.
    mapping(address => bool) public isProposer;

    /// @notice Executor role: accounts that can execute queued transactions.
    mapping(address => bool) public isExecutor;

    /// @notice Admin role: accounts that can update delay and manage roles.
    mapping(address => bool) public isAdmin;

    /// @notice txHash => eta. 0 means not queued or already executed/cancelled.
    mapping(bytes32 => uint256) private _queue;

    /// @notice txHash => executed flag. Prevents replay of executed transactions.
    mapping(bytes32 => bool) private _executed;

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    /// @dev Reverts with NotAdmin if caller is not in isAdmin mapping.
    modifier onlyAdmin() {
        if (!isAdmin[msg.sender]) revert NotAdmin();
        _;
    }

    /// @dev Reverts with NotProposer if caller is not in isProposer mapping.
    modifier onlyProposer() {
        if (!isProposer[msg.sender]) revert NotProposer();
        _;
    }

    /// @dev Reverts with NotExecutor if caller is not in isExecutor mapping.
    modifier onlyExecutor() {
        if (!isExecutor[msg.sender]) revert NotExecutor();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @notice Deploy the timelock.
    /// @param _delay     Initial delay (MIN_DELAY <= _delay <= MAX_DELAY).
    /// @param _proposers Addresses granted proposer role at deploy.
    /// @param _executors Addresses granted executor role at deploy.
    constructor(
        uint256 _delay,
        address[] memory _proposers,
        address[] memory _executors
    ) {
        if (_delay < MIN_DELAY) revert DelayTooShort();
        if (_delay > MAX_DELAY) revert DelayTooLong();

        delay = _delay;

        // Deployer and this contract are admins.
        // address(this) allows self-governance: setDelay can be called via executeTransaction.
        isAdmin[msg.sender] = true;
        isAdmin[address(this)] = true;

        for (uint256 i; i < _proposers.length; ++i) {
            if (_proposers[i] == address(0)) revert ZeroAddress();
            isProposer[_proposers[i]] = true;
            emit ProposerSet(_proposers[i], true);
        }

        for (uint256 i; i < _executors.length; ++i) {
            if (_executors[i] == address(0)) revert ZeroAddress();
            isExecutor[_executors[i]] = true;
            emit ExecutorSet(_executors[i], true);
        }
    }

    // ─── Core ──────────────────────────────────────────────────────────────────

    /// @notice Queue a transaction for future execution.
    /// @param target Contract to call.
    /// @param value  ETH value to forward.
    /// @param data   Calldata to forward.
    /// @return txHash Unique identifier for this queued transaction.
    /// @return eta    Earliest timestamp at which the tx can be executed.
    function queueTransaction(
        address target,
        uint256 value,
        bytes calldata data
    ) external override onlyProposer returns (bytes32 txHash, uint256 eta) {
        if (target == address(0)) revert ZeroAddress();

        // eta is fixed at queue time; the same delay applies regardless of future delay changes
        eta = block.timestamp + delay;
        txHash = getTxHash(target, value, data, eta);

        if (_queue[txHash] != 0) revert TxAlreadyQueued();

        _queue[txHash] = eta;
        emit TransactionQueued(txHash, target, value, data, eta);
    }

    /// @notice Execute a queued transaction after its delay has passed.
    /// @param target Contract to call.
    /// @param value  ETH value to forward (must match msg.value).
    /// @param data   Calldata to forward.
    /// @param eta    The ETA returned when the tx was queued.
    /// @return returnData ABI-encoded return value from the call.
    function executeTransaction(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 eta
    ) external payable override onlyExecutor returns (bytes memory returnData) {
        bytes32 txHash = getTxHash(target, value, data, eta);

        // Validate: queued, not yet executed, within time window
        if (_queue[txHash] == 0) revert TxNotQueued();
        if (_executed[txHash]) revert TxAlreadyExecuted();
        if (block.timestamp < eta) revert TimelockNotExpired(eta);
        if (block.timestamp > eta + GRACE_PERIOD) revert GracePeriodExpired(eta);

        _executed[txHash] = true;
        delete _queue[txHash]; // free storage; eta no longer needed

        emit TransactionExecuted(txHash, target, value, data);

        bool ok;
        (ok, returnData) = target.call{value: value}(data);
        if (!ok) revert TxExecutionFailed();
    }

    /// @notice Cancel a queued transaction before it is executed.
    /// @param txHash Hash of the transaction to cancel.
    function cancelTransaction(bytes32 txHash) external override onlyProposer {
        if (_queue[txHash] == 0) revert TxNotQueued();
        delete _queue[txHash]; // frees storage slot
        emit TransactionCancelled(txHash);
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Update the timelock delay.
    /// @dev    Should itself be called via a queued transaction for full governance.
    /// @param newDelay New delay in seconds (MIN_DELAY <= newDelay <= MAX_DELAY).
    function setDelay(uint256 newDelay) external override onlyAdmin {
        if (newDelay < MIN_DELAY) revert DelayTooShort();
        if (newDelay > MAX_DELAY) revert DelayTooLong();
        emit DelayUpdated(delay, newDelay);
        delay = newDelay;
    }

    /// @notice Grant or revoke proposer role.
    function setProposer(address account, bool status) external override onlyAdmin {
        if (account == address(0)) revert ZeroAddress();
        isProposer[account] = status;
        emit ProposerSet(account, status);
    }

    /// @notice Grant or revoke executor role.
    function setExecutor(address account, bool status) external override onlyAdmin {
        if (account == address(0)) revert ZeroAddress();
        isExecutor[account] = status;
        emit ExecutorSet(account, status);
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Compute the unique hash for a transaction.
    /// @param target Contract to call.
    /// @param value  ETH value.
    /// @param data   Calldata.
    /// @param eta    Execution timestamp.
    function getTxHash(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 eta
    ) public pure override returns (bytes32) {
        return keccak256(abi.encode(target, value, data, eta));
    }

    /// @notice Returns true if txHash is currently queued.
    function isQueued(bytes32 txHash) external view override returns (bool) {
        return _queue[txHash] != 0;
    }

    /// @notice Returns the ETA for a queued txHash (0 if not queued / already executed).
    function getEta(bytes32 txHash) external view returns (uint256) {
        return _queue[txHash];
    }

    /// @notice Returns true if txHash has been executed.
    function isExecuted(bytes32 txHash) external view returns (bool) {
        return _executed[txHash];
    }

    // ─── Receive ───────────────────────────────────────────────────────────────

    /// @notice Accept ETH so the timelock can forward value in transactions.
    /// @dev    Required for executing transactions that forward ETH to target contracts.
    receive() external payable {}
}
