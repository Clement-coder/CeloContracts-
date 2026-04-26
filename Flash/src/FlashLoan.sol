// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IFlashLoan, IFlashLoanReceiver} from "./IFlashLoan.sol";

/// @title FlashLoan
/// @notice CELO flash loan pool. Borrowers receive any amount in one transaction
///         and must repay principal + fee before the transaction ends.
///         Pool is funded by anyone. Fees accumulate and are withdrawn by owner.
/// @dev    Production-grade: reentrancy guard, pause, two-step ownership,
///         custom errors, full NatSpec, locked pragma, optimizer config.
contract FlashLoanPool is IFlashLoan {

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Maximum flash loan fee: 1% (100 bps).
    uint256 public constant MAX_FEE_BPS = 100;

    /// @notice Minimum loan amount: 0.001 CELO.
    uint256 public constant MIN_AMOUNT = 0.001 ether;

    /// @notice Maximum loan amount: 10,000 CELO.
    uint256 public constant MAX_AMOUNT = 10_000 ether;

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice Current contract owner.
    address public owner;

    /// @notice Pending owner in two-step transfer.
    address public pendingOwner;

    /// @notice Whether the contract is paused.
    bool public paused;

    /// @notice Reentrancy lock.
    bool private _locked;

    /// @notice Flash loan fee in basis points (e.g. 9 = 0.09%).
    uint256 public feeBps;

    /// @notice Accumulated fees available for withdrawal.
    uint256 public accruedFees;

    /// @notice Total number of flash loans executed.
    uint256 public totalLoans;

    /// @notice Total volume of CELO borrowed via flash loans.
    uint256 public totalVolume;

    /// @notice Circuit breaker - maximum loan amount per transaction.
    uint256 public maxLoanAmount;

    /// @notice Circuit breaker - maximum total loans per day.
    uint256 public maxDailyLoans;

    /// @notice Daily loan counter.
    uint256 public dailyLoanCount;

    /// @notice Last reset timestamp for daily counter.
    uint256 public lastResetTime;

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @notice Deploy the flash loan pool.
    /// @param _feeBps Flash loan fee in basis points. Must be <= MAX_FEE_BPS.
    constructor(uint256 _feeBps) {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        owner = msg.sender;
        feeBps = _feeBps;
        maxLoanAmount = 100 ether; // Default 100 CELO max per loan
        maxDailyLoans = 1000; // Default 1000 loans per day
        lastResetTime = block.timestamp;
    }

    // ─── Core ──────────────────────────────────────────────────────────────────

    /// @notice Execute a flash loan. Sends `amount` CELO to `receiver`, calls
    ///         `executeOperation`, then verifies full repayment (principal + fee).
    /// @param receiver Address of the contract implementing IFlashLoanReceiver.
    /// @param amount   Amount of CELO to borrow in wei. Must be >= MIN_AMOUNT.
    /// @param data     Arbitrary data forwarded to the receiver's executeOperation.
    /// @dev   Emits {FlashLoan}. Reverts if repayment is not received in same tx.
    function flashLoan(address receiver, uint256 amount, bytes calldata data)
        external override whenNotPaused nonReentrant
    {
        if (receiver == address(0)) revert InvalidReceiver();
        if (amount < MIN_AMOUNT) revert AmountTooLow();
        if (amount > maxLoanAmount) revert AmountTooHigh(); // Use proper error for max amount
        if (amount > availableLiquidity()) revert InsufficientLiquidity();

        // Reset daily counter if needed
        if (block.timestamp >= lastResetTime + 1 days) {
            dailyLoanCount = 0;
            lastResetTime = block.timestamp;
        }

        if (dailyLoanCount >= maxDailyLoans) revert DailyLimitExceeded(); // Use proper error for daily limit

        uint256 fee = (amount * feeBps) / 10_000;
        uint256 repayment = amount + fee;
        uint256 balanceBefore = address(this).balance;

        emit FlashLoan(receiver, amount, fee);

        // Send loan to receiver
        (bool sent,) = receiver.call{value: amount}("");
        if (!sent) revert TransferFailed();

        // Trigger borrower's callback
        IFlashLoanReceiver(receiver).executeOperation(amount, fee, data);

        // Verify full repayment
        uint256 balanceAfter = address(this).balance;
        if (balanceAfter < balanceBefore + fee) {
            revert RepaymentFailed();
        }

        accruedFees += fee;
        totalLoans += 1;
        totalVolume += amount;
        dailyLoanCount += 1;
    }

    // ─── Pool Management ───────────────────────────────────────────────────────

    /// @notice Fund the flash loan pool. Anyone can contribute liquidity.
    /// @dev Emits {PoolFunded}.
    function fundPool() external payable override {
        if (msg.value == 0) revert AmountTooLow();
        emit PoolFunded(msg.sender, msg.value);
    }

    /// @notice Owner withdraws accumulated fees.
    /// @dev Emits {FeesWithdrawn}.
    function withdrawFees() external override onlyOwner nonReentrant {
        uint256 amount = accruedFees;
        if (amount == 0) revert AmountTooLow();
        accruedFees = 0;
        emit FeesWithdrawn(owner, amount);
        (bool ok,) = owner.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Returns the amount of CELO available for flash loans.
    /// @return Available liquidity in wei (excludes accrued fees).
    function availableLiquidity() public view override returns (uint256) {
        return address(this).balance - accruedFees;
    }

    /// @notice Returns pool utilization statistics.
    /// @return totalLoansCount Total number of flash loans executed.
    /// @return totalVolumeAmount Total CELO volume borrowed.
    /// @return currentLiquidity Current available liquidity.
    /// @return utilizationRate Current utilization rate (bps, 10000 = 100%).
    function getUtilizationStats() external view returns (
        uint256 totalLoansCount,
        uint256 totalVolumeAmount, 
        uint256 currentLiquidity,
        uint256 utilizationRate
    ) {
        uint256 totalPool = address(this).balance;
        uint256 available = availableLiquidity();
        uint256 utilization = totalPool > 0 ? ((totalPool - available) * 10000) / totalPool : 0;
        
        return (totalLoans, totalVolume, available, utilization);
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Update the flash loan fee.
    /// @param newFeeBps New fee in basis points. Must be <= MAX_FEE_BPS.
    function setFee(uint256 newFeeBps) external override onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        emit FeeUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    /// @notice Update circuit breaker limits (only owner).
    /// @param newMaxLoanAmount New maximum loan amount per transaction.
    /// @param newMaxDailyLoans New maximum loans per day.
    function updateLimits(uint256 newMaxLoanAmount, uint256 newMaxDailyLoans) external onlyOwner {
        if (newMaxLoanAmount < MIN_AMOUNT) revert AmountTooLow();
        
        emit LimitsUpdated(maxLoanAmount, newMaxLoanAmount, maxDailyLoans, newMaxDailyLoans);
        maxLoanAmount = newMaxLoanAmount;
        maxDailyLoans = newMaxDailyLoans;
    }

    /// @notice Pause the contract.
    function pause() external override onlyOwner {
        paused = true;
        emit ContractPaused(msg.sender);
    }

    /// @notice Unpause the contract.
    function unpause() external override onlyOwner {
        paused = false;
        emit ContractUnpaused(msg.sender);
    }

    /// @notice Initiate two-step ownership transfer.
    function transferOwnership(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Accept ownership.
    function acceptOwnership() external override {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    /// @notice Emergency withdrawal function for owner (only when paused).
    /// @param amount Amount to withdraw.
    /// @dev Only callable when contract is paused for emergency situations.
    function emergencyWithdraw(uint256 amount) external onlyOwner nonReentrant {
        if (!paused) revert NotPaused();
        if (amount > address(this).balance) revert InsufficientLiquidity();
        
        emit EmergencyWithdrawal(owner, amount);
        (bool ok,) = owner.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Accept direct ETH deposits.
    receive() external payable {
        emit PoolFunded(msg.sender, msg.value);
    }
}
}
    // Flash Loan Fix 4: Add flash loan callback validation
    // Flash Loan Fix 5: Implement loan amount limits per user
    // Flash Loan Fix 6: Add flash loan fee discount system
    // Flash Loan Fix 7: Optimize gas usage in loan execution
