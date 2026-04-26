// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IMultisig
/// @notice Interface for the M-of-N multisig wallet.
interface IMultisig {
    // ─── Errors ────────────────────────────────────────────────────────────────
    error NotOwner();
    error AlreadyOwner();
    error InvalidThreshold();
    error InvalidOwnerCount();
    error ZeroAddress();
    error Reentrancy();
    error TxNotFound();
    error AlreadyConfirmed();
    error NotConfirmed();
    error AlreadyExecuted();
    error NotEnoughConfirmations();
    error TransferFailed();
    error DuplicateOwner();

    // ─── Events ────────────────────────────────────────────────────────────────
    event Deposit(address indexed sender, uint256 amount, uint256 balance);
    event TxSubmitted(uint256 indexed txId, address indexed submitter, address indexed to, uint256 value, bytes data);
    event TxConfirmed(uint256 indexed txId, address indexed owner);
    event TxRevoked(uint256 indexed txId, address indexed owner);
    event TxExecuted(uint256 indexed txId, address indexed executor);
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event ThresholdChanged(uint256 oldThreshold, uint256 newThreshold);
    event WhitelistUpdated(address indexed target, bool enabled);
    event WhitelistToggled(bool enabled);

    // ─── Functions ─────────────────────────────────────────────────────────────
    function submitTx(address to, uint256 value, bytes calldata data) external returns (uint256);
    function confirmTx(uint256 txId) external;
    function revokeTx(uint256 txId) external;
    function executeTx(uint256 txId) external;
    function addOwner(address owner) external;
    function removeOwner(address owner) external;
    function changeThreshold(uint256 newThreshold) external;
    function getTx(uint256 txId) external view returns (address to, uint256 value, bytes memory data, bool executed, uint256 confirmations);
    function isConfirmed(uint256 txId, address owner) external view returns (bool);
}
