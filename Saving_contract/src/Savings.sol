// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ISavings} from "./ISavings.sol";

/// @title Savings
/// @notice A CELO savings contract where users deposit, optionally lock funds for a duration,
///         and withdraw partially or fully after the lock expires.
/// @dev    Implements reentrancy guard, pause, two-step ownership, partial withdrawals,
///         lock extension, full NatSpec, custom errors, and complete event coverage.
contract Savings is ISavings {

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Maximum lock duration: 5 years.
    uint256 public constant MAX_LOCK_DURATION = 5 * 365 days;

    /// @notice Minimum deposit amount: 0.0001 CELO.
    uint256 public constant MIN_DEPOSIT = 0.0001 ether;

    /// @notice Sentinel value meaning "no lock".
    uint256 public constant NO_LOCK = 0;

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice Current contract owner.
    address public owner;

    /// @notice Pending owner in two-step transfer.
    address public pendingOwner;

    /// @notice Whether the contract is paused.
    bool public paused;

    /// @notice Reentrancy lock.
    bool private _locked;

    /// @notice Total CELO deposited across all accounts (TVL).
    uint256 public totalDeposited;

    /// @notice Total number of unique depositors.
    uint256 public totalUsers;

    /// @dev Savings account per user.
    struct Account {
        /// @dev Current balance in wei.
        uint256 balance;
        /// @dev Timestamp after which funds can be withdrawn. 0 = no lock.
        uint256 unlockTime;
    }

    /// @notice Savings accounts by user address.
    mapping(address => Account) public accounts;

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

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @notice Deploy the savings contract. Deployer becomes owner.
    constructor() {
        owner = msg.sender;
    }

    // ─── Core ──────────────────────────────────────────────────────────────────

    /// @notice Deposit CELO into your savings account.
    /// @param lockDuration Seconds to lock the funds from now (0 for no lock, max MAX_LOCK_DURATION).
    /// @dev   If a longer lock already exists, it is preserved. Emits {LockExtended} if lock is pushed forward.
    ///        Emits {Deposited} with isNewAccount=true on first deposit.
    function deposit(uint256 lockDuration) external payable override whenNotPaused nonReentrant {
        if (msg.value < MIN_DEPOSIT) revert ZeroValue();
        if (lockDuration > MAX_LOCK_DURATION) revert LockTooLong();

        Account storage acc = accounts[msg.sender];
        bool isNew = acc.balance == 0 && acc.unlockTime == 0;
        if (isNew) totalUsers += 1;

        acc.balance += msg.value;
        totalDeposited += msg.value;

        uint256 oldUnlock = acc.unlockTime;
        if (lockDuration > 0) {
            uint256 newUnlock = block.timestamp + lockDuration;
            if (newUnlock > acc.unlockTime) {
                acc.unlockTime = newUnlock;
                if (oldUnlock > 0) {
                    emit LockExtended(msg.sender, oldUnlock, newUnlock);
                }
            }
        }

        emit Deposited(msg.sender, msg.value, acc.unlockTime, isNew);
    }

    /// @notice Withdraw a specific amount from your savings account.
    /// @param amount Amount of CELO to withdraw (wei). Must be <= your balance.
    /// @dev   Funds must be unlocked. Emits {Withdrawn} with remaining balance.
    function withdraw(uint256 amount) external override nonReentrant {
        Account storage acc = accounts[msg.sender];
        if (acc.balance == 0) revert NothingToWithdraw();
        if (amount == 0 || amount > acc.balance) revert AmountExceedsBalance();
        if (block.timestamp < acc.unlockTime) revert FundsLocked(acc.unlockTime);

        acc.balance -= amount;
        totalDeposited -= amount;

        // Reset unlockTime only when fully withdrawn
        if (acc.balance == 0) acc.unlockTime = NO_LOCK;

        uint256 remaining = acc.balance;

        emit Withdrawn(msg.sender, amount, remaining);

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Extend your lock duration without depositing more funds.
    /// @param additionalSeconds Seconds to add to the current unlock time (from now if no lock set).
    /// @dev   Cannot shorten an existing lock. Emits {LockExtended}.
    function extendLock(uint256 additionalSeconds) external override whenNotPaused {
        if (additionalSeconds == 0) revert ZeroValue();
        if (additionalSeconds > MAX_LOCK_DURATION) revert LockTooLong();

        Account storage acc = accounts[msg.sender];
        if (acc.balance == 0) revert NothingToWithdraw();

        uint256 oldUnlock = acc.unlockTime;
        uint256 base = oldUnlock > block.timestamp ? oldUnlock : block.timestamp;
        uint256 newUnlock = base + additionalSeconds;

        acc.unlockTime = newUnlock;
        emit LockExtended(msg.sender, oldUnlock, newUnlock);
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Returns the savings account for any address.
    /// @param user Address to query.
    /// @return balance    Current balance in wei.
    /// @return unlockTime Timestamp after which funds can be withdrawn. 0 = no lock.
    function getAccount(address user) external view override returns (uint256 balance, uint256 unlockTime) {
        Account storage acc = accounts[user];
        return (acc.balance, acc.unlockTime);
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Pause the contract — halts deposits and lock extensions.
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

    // ─── Receive ───────────────────────────────────────────────────────────────

    /// @notice Accept direct ETH transfers. Tracked via event.
    /// @dev Emits {DirectDepositReceived}.
    receive() external payable {
        emit DirectDepositReceived(msg.sender, msg.value);
    }
}
