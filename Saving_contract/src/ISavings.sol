// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title ISavings
/// @notice Interface for the CELO savings contract.
interface ISavings {
    // ─── Errors ────────────────────────────────────────────────────────────────
    error ZeroValue();
    error ZeroAddress();
    error NothingToWithdraw();
    error FundsLocked(uint256 unlockTime);
    error TransferFailed();
    error Paused();
    error NotOwner();
    error NotPendingOwner();
    error LockTooLong();
    error AmountExceedsBalance();
    error Reentrancy();

    // ─── Events ────────────────────────────────────────────────────────────────
    event Deposited(address indexed user, uint256 amount, uint256 unlockTime, bool isNewAccount);
    event Withdrawn(address indexed user, uint256 amount, uint256 remaining);
    event EmergencyWithdrawn(address indexed user, uint256 amount, uint256 fee);
    event WithdrawalFeeCharged(address indexed user, uint256 fee);
    event WithdrawalFeeUpdated(uint256 oldFee, uint256 newFee);
    event EmergencyWithdrawToggled(bool enabled);
    event LockExtended(address indexed user, uint256 oldUnlockTime, uint256 newUnlockTime);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event DirectDepositReceived(address indexed sender, uint256 amount);

    // ─── Functions ─────────────────────────────────────────────────────────────
    function deposit(uint256 lockDuration) external payable;
    function withdraw(uint256 amount) external;
    function extendLock(uint256 additionalSeconds) external;
    function getAccount(address user) external view returns (uint256 balance, uint256 unlockTime);
    function pause() external;
    function unpause() external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
