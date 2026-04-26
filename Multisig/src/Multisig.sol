// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IMultisig} from "./IMultisig.sol";

/// @title Multisig
/// @notice M-of-N multisig wallet. Owners submit, confirm, and execute transactions.
///         Requires `threshold` confirmations before a transaction can execute.
///         Owners can be added/removed and threshold changed — all via multisig itself.
/// @dev    Production-grade: reentrancy guard, custom errors, full NatSpec,
///         locked pragma, optimizer config.
contract Multisig is IMultisig {

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice List of current owners.
    address[] public owners;

    /// @notice Maximum number of owners allowed.
    uint256 public constant MAX_OWNERS = 50;

    /// @notice Number of confirmations required to execute a transaction.
    uint256 public threshold;

    /// @notice Reentrancy lock.
    bool private _locked;

    /// @notice Whether an address is an owner.
    mapping(address => bool) public isOwner;

    /// @dev Transaction record.
    struct Transaction {
        /// @dev Target address.
        address to;
        /// @dev CELO value to send.
        uint256 value;
        /// @dev Calldata to execute.
        bytes data;
        /// @dev Whether the transaction has been executed.
        bool executed;
        /// @dev Number of confirmations received.
        uint256 confirmations;
    }

    /// @notice All submitted transactions.
    Transaction[] public transactions;

    /// @notice confirmed[txId][owner] = true if owner confirmed.
    mapping(uint256 => mapping(address => bool)) public confirmed;

    /// @notice Whitelist of addresses that can be transaction targets.
    mapping(address => bool) public whitelist;

    /// @notice Whether whitelist is enabled.
    bool public whitelistEnabled;

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (!isOwner[msg.sender]) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    modifier txExists(uint256 txId) {
        if (txId >= transactions.length) revert TxNotFound();
        _;
    }

    modifier notExecuted(uint256 txId) {
        if (transactions[txId].executed) revert AlreadyExecuted();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @notice Deploy the multisig wallet.
    /// @param _owners    Initial list of owners. Must have no duplicates or zero addresses.
    /// @param _threshold Number of confirmations required. Must be >= 1 and <= owners.length.
    constructor(address[] memory _owners, uint256 _threshold) {
        if (_owners.length == 0) revert InvalidOwnerCount();
        if (_threshold == 0 || _threshold > _owners.length) revert InvalidThreshold();

        for (uint256 i; i < _owners.length; i++) {
            address o = _owners[i];
            if (o == address(0)) revert ZeroAddress();
            if (isOwner[o]) revert DuplicateOwner();
            isOwner[o] = true;
            owners.push(o);
            emit OwnerAdded(o);
        }
        threshold = _threshold;
    }

    // ─── Core ──────────────────────────────────────────────────────────────────

    /// @notice Submit a new transaction for confirmation.
    /// @param to    Target address.
    /// @param value CELO to send (wei).
    /// @param data  Calldata to execute.
    /// @return txId The new transaction ID.
    /// @dev Emits {TxSubmitted}.
    function submitTx(address to, uint256 value, bytes calldata data)
        external override onlyOwner returns (uint256 txId)
    {
        if (whitelistEnabled && !whitelist[to]) revert NotWhitelisted();
        
        txId = transactions.length;
        transactions.push(Transaction({to: to, value: value, data: data, executed: false, confirmations: 0}));
        emit TxSubmitted(txId, msg.sender, to, value, data);
    }

    /// @notice Confirm a pending transaction.
    /// @param txId Transaction ID to confirm.
    /// @dev Emits {TxConfirmed}.
    function confirmTx(uint256 txId)
        external override onlyOwner txExists(txId) notExecuted(txId)
    {
        if (confirmed[txId][msg.sender]) revert AlreadyConfirmed();
        confirmed[txId][msg.sender] = true;
        transactions[txId].confirmations++;
        emit TxConfirmed(txId, msg.sender);
    }

    /// @notice Confirm multiple transactions in a single call.
    /// @param txIds Array of transaction IDs to confirm.
    /// @dev Emits {TxConfirmed} for each successful confirmation.
    function batchConfirmTx(uint256[] calldata txIds) external onlyOwner {
        for (uint256 i = 0; i < txIds.length; i++) {
            uint256 txId = txIds[i];
            if (txId >= transactions.length) continue; // Skip invalid IDs
            if (transactions[txId].executed) continue; // Skip executed
            if (confirmed[txId][msg.sender]) continue; // Skip already confirmed
            
            confirmed[txId][msg.sender] = true;
            transactions[txId].confirmations++;
            emit TxConfirmed(txId, msg.sender);
        }
    }

    /// @notice Revoke a previously given confirmation.
    /// @param txId Transaction ID to revoke confirmation from.
    /// @dev Emits {TxRevoked}.
    function revokeTx(uint256 txId)
        external override onlyOwner txExists(txId) notExecuted(txId)
    {
        if (!confirmed[txId][msg.sender]) revert NotConfirmed();
        confirmed[txId][msg.sender] = false;
        transactions[txId].confirmations--;
        emit TxRevoked(txId, msg.sender);
    }

    /// @notice Execute a transaction that has enough confirmations.
    /// @param txId Transaction ID to execute.
    /// @dev Emits {TxExecuted}.
    function executeTx(uint256 txId)
        external override onlyOwner txExists(txId) notExecuted(txId) nonReentrant
    {
        Transaction storage t = transactions[txId];
        if (t.confirmations < threshold) revert NotEnoughConfirmations();

        t.executed = true;
        emit TxExecuted(txId, msg.sender);

        (bool ok,) = t.to.call{value: t.value}(t.data);
        if (!ok) revert TransferFailed();
    }

    // ─── Owner Management (via multisig) ───────────────────────────────────────

    /// @notice Add a new owner. Must be called via executeTx (self-call).
    /// @param owner Address to add as owner.
    /// @dev Emits {OwnerAdded}.
    function addOwner(address owner) external override {
        if (msg.sender != address(this)) revert NotOwner();
        if (owner == address(0)) revert ZeroAddress();
        if (isOwner[owner]) revert AlreadyOwner();
        if (owners.length >= MAX_OWNERS) revert MaxOwnersReached();
        isOwner[owner] = true;
        owners.push(owner);
        emit OwnerAdded(owner);
    }

    /// @notice Remove an existing owner. Must be called via executeTx (self-call).
    /// @param owner Address to remove.
    /// @dev Emits {OwnerRemoved}. Threshold is adjusted if needed.
    function removeOwner(address owner) external override {
        if (msg.sender != address(this)) revert NotOwner();
        if (!isOwner[owner]) revert NotOwner();
        if (owners.length - 1 == 0) revert InvalidOwnerCount();

        isOwner[owner] = false;
        for (uint256 i; i < owners.length; i++) {
            if (owners[i] == owner) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }

        // Adjust threshold if it now exceeds owner count
        if (threshold > owners.length) {
            emit ThresholdChanged(threshold, owners.length);
            threshold = owners.length;
        }

        emit OwnerRemoved(owner);
    }

    /// @notice Change the confirmation threshold. Must be called via executeTx (self-call).
    /// @param newThreshold New required confirmations. Must be >= 1 and <= owners.length.
    /// @dev Emits {ThresholdChanged}.
    function changeThreshold(uint256 newThreshold) external override {
        if (msg.sender != address(this)) revert NotOwner();
        if (newThreshold == 0 || newThreshold > owners.length) revert InvalidThreshold();
        emit ThresholdChanged(threshold, newThreshold);
        threshold = newThreshold;
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Returns details of a transaction.
    /// @param txId Transaction ID.
    /// @return to            Target address.
    /// @return value         CELO value in wei.
    /// @return data          Calldata.
    /// @return executed      Whether it has been executed.
    /// @return confirmations Number of confirmations received.
    function getTx(uint256 txId)
        external view override txExists(txId)
        returns (address to, uint256 value, bytes memory data, bool executed, uint256 confirmations)
    {
        Transaction storage t = transactions[txId];
        return (t.to, t.value, t.data, t.executed, t.confirmations);
    }

    /// @notice Returns whether an owner has confirmed a transaction.
    /// @param txId  Transaction ID.
    /// @param owner Owner address to check.
    /// @return True if confirmed.
    function isConfirmed(uint256 txId, address owner)
        external view override returns (bool)
    {
        return confirmed[txId][owner];
    }

    /// @notice Returns the list of all owners.
    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    /// @notice Returns the total number of transactions submitted.
    function txCount() external view returns (uint256) {
        return transactions.length;
    }

    /// @notice Add address to whitelist (must be called via executeTx).
    /// @param target Address to add to whitelist.
    function addToWhitelist(address target) external {
        if (msg.sender != address(this)) revert NotOwner();
        whitelist[target] = true;
        emit WhitelistUpdated(target, true);
    }

    /// @notice Remove address from whitelist (must be called via executeTx).
    /// @param target Address to remove from whitelist.
    function removeFromWhitelist(address target) external {
        if (msg.sender != address(this)) revert NotOwner();
        whitelist[target] = false;
        emit WhitelistUpdated(target, false);
    }

    /// @notice Enable/disable whitelist (must be called via executeTx).
    /// @param enabled Whether to enable whitelist.
    function setWhitelistEnabled(bool enabled) external {
        if (msg.sender != address(this)) revert NotOwner();
        whitelistEnabled = enabled;
        emit WhitelistToggled(enabled);
    }

    /// @notice Accept CELO deposits.
    receive() external payable {
        emit Deposit(msg.sender, msg.value, address(this).balance);
    }
}
// Multisig fix 1: submitTx whitelist rejection used NotOwner - replaced with NotWhitelisted
// Multisig fix 2: addOwner() enforce MAX_OWNERS limit - constant was declared but never checked
// Multisig fix 3: Add NotWhitelisted error to IMultisig interface
// Multisig fix 4: Add MaxOwnersReached error to IMultisig interface
// Multisig fix 5: Add batchConfirmTx() to IMultisig interface (was missing)
// Multisig fix 6: Add getOwners() to IMultisig interface (was missing)
// Multisig fix 7: Add txCount() to IMultisig interface (was missing)
// Multisig fix 8: Add addToWhitelist() to IMultisig interface (was missing)
// Multisig fix 9: Add removeFromWhitelist() to IMultisig interface (was missing)
// Multisig fix 10: Add setWhitelistEnabled() to IMultisig interface (was missing)
// Multisig fix 11: Add test_BatchConfirm_Success
// Multisig fix 12: Add test_BatchConfirm_SkipsInvalid
// Multisig fix 13: Add test_BatchConfirm_SkipsAlreadyConfirmed
// Multisig fix 14: Add test_BatchConfirm_RevertNotOwner
// Multisig fix 15: Add test_GetOwners_ReturnsAll
