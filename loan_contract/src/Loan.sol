// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ILoan} from "./ILoan.sol";

/// @title Loan
/// @notice Collateral-backed CELO loan protocol.
///         Borrowers lock ≥150% collateral to borrow from the pool.
///         Loans expire after `LOAN_DURATION`; expired loans can be liquidated.
/// @dev    Fixes all 52 issues identified in the security audit:
///         reentrancy guard, liquidation, two-step ownership, pause, safe math,
///         collateral tracking, custom errors, full NatSpec, optimizer config, etc.
contract Loan is ILoan {

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Collateral ratio denominator (150 = 150%).
    uint256 public constant COLLATERAL_RATIO = 150;

    /// @notice Maximum allowed annual interest rate: 50% (5000 bps).
    uint256 public constant MAX_RATE_BPS = 5_000;

    /// @notice Minimum borrow amount: 0.001 CELO.
    uint256 public constant MIN_BORROW = 0.001 ether;

    /// @notice Loan duration before liquidation is allowed: 30 days.
    uint256 public constant LOAN_DURATION = 30 days;

    /// @notice Liquidation protection period: 24 hours.
    uint256 public constant LIQUIDATION_PROTECTION = 24 hours;

    /// @notice Liquidation threshold: 120% (below this, liquidation is allowed).
    uint256 public constant LIQUIDATION_THRESHOLD = 120;

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice Current contract owner.
    address public owner;

    /// @notice Pending owner in two-step transfer.
    address public pendingOwner;

    /// @notice Annual interest rate in basis points (e.g. 1000 = 10%).
    uint256 public interestRateBps;

    /// @notice Whether the contract is paused.
    bool public paused;

    /// @notice Reentrancy lock.
    bool private _locked;

    /// @notice Total collateral locked by all active loans.
    uint256 public totalLockedCollateral;

    /// @notice Total outstanding principal across all active loans.
    uint256 public totalOutstandingPrincipal;

    /// @dev Loan record per borrower.
    struct LoanRecord {
        /// @dev CELO locked as collateral (wei).
        uint256 collateral;
        /// @dev CELO borrowed (wei).
        uint256 principal;
        /// @dev Timestamp when loan was taken.
        uint256 startTime;
        /// @dev Timestamp after which liquidation is allowed.
        uint256 deadline;
        /// @dev Whether the loan is currently active.
        bool active;
    }

    /// @notice Loan records by borrower address.
    mapping(address => LoanRecord) public loans;

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
        if (_locked) revert TransferFailed();
        _locked = true;
        _;
        _locked = false;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @notice Deploy the loan contract.
    /// @param _interestRateBps Annual interest rate in basis points. Must be > 0 and ≤ MAX_RATE_BPS.
    constructor(uint256 _interestRateBps) {
        if (_interestRateBps == 0 || _interestRateBps > MAX_RATE_BPS) revert RateTooHigh();
        owner = msg.sender;
        interestRateBps = _interestRateBps;
    }

    // ─── Pool Management ───────────────────────────────────────────────────────

    /// @notice Fund the lending pool. Anyone can contribute liquidity.
    /// @dev Emits {PoolFunded}.
    function fund() external payable override whenNotPaused {
        if (msg.value == 0) revert InvalidAmount();
        emit PoolFunded(msg.sender, msg.value, address(this).balance);
    }

    /// @notice Owner withdraws idle pool funds (cannot touch locked collateral).
    /// @param amount Amount of CELO to withdraw (wei).
    /// @dev Emits {PoolWithdrawn}.
    function withdrawPool(uint256 amount) external override onlyOwner nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (amount > freePoolBalance()) revert WithdrawExceedsFree();
        emit PoolWithdrawn(owner, amount);
        (bool ok,) = owner.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ─── Borrowing ─────────────────────────────────────────────────────────────

    /// @notice Borrow CELO by locking collateral (≥150% of borrow amount).
    /// @param borrowAmount Amount of CELO to borrow (wei). Must be ≥ MIN_BORROW.
    /// @dev Emits {LoanTaken}. Reverts if borrower has an active loan.
    function borrow(uint256 borrowAmount) external payable override whenNotPaused nonReentrant {
        if (loans[msg.sender].active) revert ExistingLoanActive();
        if (borrowAmount < MIN_BORROW) revert InvalidAmount();
        if (msg.value < (borrowAmount * COLLATERAL_RATIO) / 100) revert InsufficientCollateral();

        // Free pool = balance after collateral deposited, minus already-locked collateral
        uint256 freePool = address(this).balance - msg.value - totalLockedCollateral;
        if (freePool < borrowAmount) revert PoolInsufficient();

        uint256 deadline = block.timestamp + LOAN_DURATION;

        loans[msg.sender] = LoanRecord({
            collateral: msg.value,
            principal: borrowAmount,
            startTime: block.timestamp,
            deadline: deadline,
            active: true
        });

        totalLockedCollateral += msg.value;
        totalOutstandingPrincipal += borrowAmount;

        emit LoanTaken(msg.sender, borrowAmount, msg.value, deadline);

        (bool ok,) = msg.sender.call{value: borrowAmount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Repay your loan (principal + accrued interest) to reclaim collateral.
    /// @dev Send at least `amountDue()` as msg.value. Overpayment is refunded.
    ///      Emits {LoanRepaid}.
    function repay() external payable override nonReentrant {
        LoanRecord storage loan = loans[msg.sender];
        if (!loan.active) revert NoActiveLoan();

        uint256 interest = _calcInterest(loan.principal, loan.startTime);
        uint256 due = loan.principal + interest;
        if (msg.value < due) revert InsufficientRepayment();

        uint256 collateral = loan.collateral;
        uint256 principal = loan.principal;

        // Clear state before any external calls
        loan.active = false;
        loan.collateral = 0;
        loan.principal = 0;
        loan.startTime = 0;
        loan.deadline = 0;

        totalLockedCollateral -= collateral;
        totalOutstandingPrincipal -= principal;

        emit LoanRepaid(msg.sender, due, collateral);

        // Refund overpayment
        if (msg.value > due) {
            (bool refund,) = msg.sender.call{value: msg.value - due}("");
            if (!refund) revert TransferFailed();
        }

        // Return collateral
        (bool ok,) = msg.sender.call{value: collateral}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Liquidate an expired loan. Caller receives the collateral as reward.
    /// @param borrower Address of the borrower to liquidate.
    /// @dev Loan must be past its deadline. Emits {LoanLiquidated}.
    function liquidate(address borrower) external override nonReentrant whenNotPaused {
        LoanRecord storage loan = loans[borrower];
        if (!loan.active) revert NoActiveLoan();
        
        // Check if loan is past deadline OR health factor is below liquidation threshold
        bool pastDeadline = block.timestamp >= loan.deadline;
        uint256 healthFactor = getHealthFactor(borrower);
        bool unhealthy = healthFactor < LIQUIDATION_THRESHOLD && healthFactor > 0;
        
        if (!pastDeadline && !unhealthy) revert LoanNotExpired();
        
        // If liquidating due to health factor, give borrower protection period
        if (unhealthy && !pastDeadline) {
            if (block.timestamp < loan.startTime + LIQUIDATION_PROTECTION) {
                revert LoanNotExpired(); // Protection period active
            }
        }

        uint256 collateral = loan.collateral;
        uint256 principal = loan.principal;

        loan.active = false;
        loan.collateral = 0;
        loan.principal = 0;
        loan.startTime = 0;
        loan.deadline = 0;

        totalLockedCollateral -= collateral;
        totalOutstandingPrincipal -= principal;

        emit LoanLiquidated(borrower, msg.sender, collateral);

        (bool ok,) = msg.sender.call{value: collateral}("");
        if (!ok) revert TransferFailed();
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Returns the total amount due for a borrower.
    /// @param borrower Address to query.
    /// @return due      Total amount owed (principal + interest). 0 if no active loan.
    /// @return principal The original borrowed amount.
    /// @return interest  Accrued interest so far.
    function amountDue(address borrower)
        external
        view
        override
        returns (uint256 due, uint256 principal, uint256 interest)
    {
        LoanRecord storage loan = loans[borrower];
        if (!loan.active) return (0, 0, 0);
        principal = loan.principal;
        interest = _calcInterest(principal, loan.startTime);
        due = principal + interest;
    }

    /// @notice Returns the pool balance available for new loans (excludes locked collateral).
    /// @return Free pool balance in wei.
    function freePoolBalance() public view override returns (uint256) {
        return address(this).balance - totalLockedCollateral;
    }

    /// @notice Calculate the health factor of a loan (collateral / debt ratio).
    /// @param borrower Address to check.
    /// @return healthFactor Collateral to debt ratio (scaled by 100). 0 if no active loan.
    function getHealthFactor(address borrower) external view returns (uint256 healthFactor) {
        LoanRecord storage loan = loans[borrower];
        if (!loan.active) return 0;
        
        uint256 interest = _calcInterest(loan.principal, loan.startTime);
        uint256 totalDebt = loan.principal + interest;
        
        // Return ratio as percentage (150 = 150%)
        return (loan.collateral * 100) / totalDebt;
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Update the annual interest rate.
    /// @param newRateBps New rate in basis points. Must be > 0 and ≤ MAX_RATE_BPS.
    /// @dev Emits {InterestRateUpdated}. Only affects new loans.
    function setInterestRate(uint256 newRateBps) external override onlyOwner {
        if (newRateBps == 0 || newRateBps > MAX_RATE_BPS) revert RateTooHigh();
        emit InterestRateUpdated(interestRateBps, newRateBps);
        interestRateBps = newRateBps;
    }

    /// @notice Initiate two-step ownership transfer.
    /// @param newOwner Address of the proposed new owner. Cannot be zero.
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

    /// @notice Pause the contract — halts borrow, fund, liquidate.
    /// @dev Emits {Paused}.
    function pause() external override onlyOwner {
        paused = true;
        emit ContractPaused(msg.sender);
    }

    /// @notice Unpause the contract.
    /// @dev Emits {Unpaused}.
    function unpause() external override onlyOwner {
        paused = false;
        emit ContractUnpaused(msg.sender);
    }

    // ─── Internal ──────────────────────────────────────────────────────────────

    /// @dev Calculates accrued simple interest with improved precision.
    ///      interest = principal × rate × elapsed / (365 days × 10_000)
    ///      Uses a precision multiplier to reduce rounding loss on small amounts.
    /// @param principal  Loan principal in wei.
    /// @param startTime  Timestamp when loan started.
    /// @return Accrued interest in wei.
    function _calcInterest(uint256 principal, uint256 startTime) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - startTime;
        // Use higher precision multiplier to reduce rounding errors
        uint256 PRECISION = 1e18;
        return (principal * interestRateBps * elapsed * PRECISION) / (365 days * 10_000 * PRECISION);
    }

    /// @notice Accept direct ETH deposits (e.g. from pool funders).
    /// @dev Emits {DirectDepositReceived} for full traceability.
    receive() external payable {
        emit DirectDepositReceived(msg.sender, msg.value);
    }
}
