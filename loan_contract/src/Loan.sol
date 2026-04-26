// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ILoan} from "./ILoan.sol";

/// @title Loan
/// @notice Collateral-backed CELO loan protocol.
///         Borrowers lock ≥150% collateral to borrow from the pool.
///         Loans expire after `LOAN_DURATION`; expired or unhealthy loans can be liquidated.
///         Origination fees are collected on each borrow and withdrawable by owner.
contract Loan is ILoan {

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Collateral ratio denominator (150 = 150%).
    uint256 public constant COLLATERAL_RATIO = 150;

    /// @notice Maximum allowed annual interest rate: 50% (5000 bps).
    uint256 public constant MAX_RATE_BPS = 5_000;

    /// @notice Maximum origination fee: 2% (200 bps).
    uint256 public constant MAX_ORIGINATION_FEE = 200;

    /// @notice Loan duration before liquidation is allowed: 30 days.
    uint256 public constant LOAN_DURATION = 30 days;

    /// @notice Liquidation protection period after loan start: 24 hours.
    uint256 public constant LIQUIDATION_PROTECTION = 24 hours;

    /// @notice Minimum borrow amount: 0.1 CELO.
    uint256 public constant MIN_BORROW = 0.1 ether;

    /// @notice Health factor below which a loan can be liquidated (120 = 120%).
    uint256 public constant LIQUIDATION_THRESHOLD = 120;

    /// @notice Maximum number of extensions per loan.
    uint256 public constant MAX_EXTENSIONS = 3;

    /// @notice Extension duration: 7 days per extension.
    uint256 public constant EXTENSION_DURATION = 7 days;

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice Current contract owner.
    address public owner;

    /// @notice Pending owner in two-step transfer.
    address public pendingOwner;

    /// @notice Annual interest rate in basis points (e.g. 1000 = 10%).
    uint256 public interestRateBps;

    /// @notice Origination fee in basis points charged on each borrow.
    uint256 public originationFeeBps;

    /// @notice Accumulated origination fees available for owner withdrawal.
    uint256 public accumulatedFees;

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
        /// @dev Number of times this loan has been extended.
        uint256 extensionCount;
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
        // Default origination fee: 0 (no fee unless set)
        originationFeeBps = 0;
    }

    // ─── Pool Management ───────────────────────────────────────────────────────

    /// @notice Fund the lending pool. Anyone can contribute liquidity.
    /// @dev Emits {PoolFunded}.
    function fund() external payable override whenNotPaused {
        if (msg.value == 0) revert InvalidAmount();
        emit PoolFunded(msg.sender, msg.value, address(this).balance);
    }

    /// @notice Owner withdraws idle pool funds (cannot touch locked collateral or fees).
    /// @param amount Amount of CELO to withdraw (wei).
    /// @dev Emits {PoolWithdrawn}.
    function withdrawPool(uint256 amount) external override onlyOwner nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (amount > freePoolBalance()) revert WithdrawExceedsFree();
        emit PoolWithdrawn(owner, amount);
        (bool ok,) = owner.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Owner withdraws accumulated origination fees.
    /// @dev Emits {FeesCollected}.
    function withdrawFees() external override onlyOwner nonReentrant {
        uint256 fees = accumulatedFees;
        if (fees == 0) revert InvalidAmount();
        accumulatedFees = 0;
        emit FeesCollected(owner, fees);
        (bool ok,) = owner.call{value: fees}("");
        if (!ok) revert TransferFailed();
    }

    // ─── Borrowing ─────────────────────────────────────────────────────────────

    /// @notice Borrow CELO by locking collateral (≥150% of borrow amount).
    /// @param borrowAmount Amount of CELO to borrow (wei). Must be ≥ MIN_BORROW.
    /// @dev Emits {LoanTaken}. Reverts if borrower has an active loan.
    ///      Origination fee is deducted from the borrowed amount sent to borrower.
    function borrow(uint256 borrowAmount) external payable override whenNotPaused nonReentrant {
        if (loans[msg.sender].active) revert ExistingLoanActive();
        if (borrowAmount < MIN_BORROW) revert InvalidAmount();
        if (msg.value < (borrowAmount * COLLATERAL_RATIO) / 100) revert InsufficientCollateral();

        // Free pool = total balance minus collateral just deposited minus already-locked collateral minus fees
        // address(this).balance already includes msg.value at this point
        uint256 freePool = address(this).balance - msg.value - totalLockedCollateral - accumulatedFees;
        if (freePool < borrowAmount) revert PoolInsufficient();

        // Calculate origination fee
        uint256 fee = (borrowAmount * originationFeeBps) / 10_000;
        uint256 disbursement = borrowAmount - fee;
        accumulatedFees += fee;

        uint256 deadline = block.timestamp + LOAN_DURATION;

        loans[msg.sender] = LoanRecord({
            collateral: msg.value,
            principal: borrowAmount,
            startTime: block.timestamp,
            deadline: deadline,
            active: true,
            extensionCount: 0
        });

        totalLockedCollateral += msg.value;
        totalOutstandingPrincipal += borrowAmount;

        emit LoanTaken(msg.sender, borrowAmount, msg.value, deadline);

        (bool ok,) = msg.sender.call{value: disbursement}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Repay your loan (principal + accrued interest) to reclaim collateral.
    /// @dev Send at least `amountDue()` as msg.value. Overpayment is refunded.
    ///      Emits {LoanRepaid}. Works even when paused so borrowers can always repay.
    function repay() external payable override nonReentrant {
        LoanRecord storage loan = loans[msg.sender];
        if (!loan.active) revert NoActiveLoan();

        uint256 interest = _calcInterest(loan.principal, loan.startTime);
        uint256 due = loan.principal + interest;
        if (msg.value < due) revert InsufficientRepayment();

        uint256 collateral = loan.collateral;
        uint256 principal = loan.principal;

        // Clear state before any external calls (CEI pattern)
        loan.active = false;
        loan.collateral = 0;
        loan.principal = 0;
        loan.startTime = 0;
        loan.deadline = 0;
        loan.extensionCount = 0;

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

    /// @notice Liquidate an expired or unhealthy loan. Caller receives the collateral.
    /// @param borrower Address of the borrower to liquidate.
    /// @dev Loan must be past its deadline OR health factor below LIQUIDATION_THRESHOLD.
    ///      Emits {LoanLiquidated}.
    function liquidate(address borrower) external override nonReentrant whenNotPaused {
        LoanRecord storage loan = loans[borrower];
        if (!loan.active) revert NoActiveLoan();

        bool pastDeadline = block.timestamp >= loan.deadline;
        uint256 healthFactor = getHealthFactor(borrower);
        bool unhealthy = healthFactor > 0 && healthFactor < LIQUIDATION_THRESHOLD;

        if (!pastDeadline && !unhealthy) revert LoanNotExpired();

        // Unhealthy loans still get the protection window after origination
        if (unhealthy && !pastDeadline) {
            if (block.timestamp < loan.startTime + LIQUIDATION_PROTECTION) {
                revert LoanNotExpired();
            }
        }

        uint256 collateral = loan.collateral;
        uint256 principal = loan.principal;

        loan.active = false;
        loan.collateral = 0;
        loan.principal = 0;
        loan.startTime = 0;
        loan.deadline = 0;
        loan.extensionCount = 0;

        totalLockedCollateral -= collateral;
        totalOutstandingPrincipal -= principal;

        emit LoanLiquidated(borrower, msg.sender, collateral);

        (bool ok,) = msg.sender.call{value: collateral}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Extend an active loan's deadline by EXTENSION_DURATION.
    /// @dev Borrower must pay the accrued interest so far to extend.
    ///      Maximum MAX_EXTENSIONS extensions allowed per loan.
    ///      Emits {LoanExtended}.
    function extendLoan() external payable override nonReentrant whenNotPaused {
        LoanRecord storage loan = loans[msg.sender];
        if (!loan.active) revert NoActiveLoan();
        if (loan.extensionCount >= MAX_EXTENSIONS) revert ExtensionLimitReached();

        // Borrower must pay accrued interest to extend
        uint256 interest = _calcInterest(loan.principal, loan.startTime);
        if (msg.value < interest) revert InsufficientRepayment();

        // Reset start time (interest clock restarts) and extend deadline
        loan.startTime = block.timestamp;
        loan.deadline += EXTENSION_DURATION;
        loan.extensionCount += 1;

        // Refund overpayment
        if (msg.value > interest) {
            (bool refund,) = msg.sender.call{value: msg.value - interest}("");
            if (!refund) revert TransferFailed();
        }

        emit LoanExtended(msg.sender, loan.deadline, loan.extensionCount);
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

    /// @notice Returns the pool balance available for new loans.
    /// @dev Excludes locked collateral and accumulated fees.
    /// @return Free pool balance in wei.
    function freePoolBalance() public view override returns (uint256) {
        return address(this).balance - totalLockedCollateral - accumulatedFees;
    }

    /// @notice Calculate the health factor of a loan (collateral / total debt × 100).
    /// @param borrower Address to check.
    /// @return healthFactor Ratio as percentage (e.g. 150 = 150%). 0 if no active loan.
    function getHealthFactor(address borrower) public view override returns (uint256 healthFactor) {
        LoanRecord storage loan = loans[borrower];
        if (!loan.active) return 0;
        uint256 interest = _calcInterest(loan.principal, loan.startTime);
        uint256 totalDebt = loan.principal + interest;
        if (totalDebt == 0) return type(uint256).max;
        return (loan.collateral * 100) / totalDebt;
    }

    /// @notice Returns full loan info for a borrower.
    function getLoanInfo(address borrower)
        external
        view
        override
        returns (
            uint256 collateral,
            uint256 principal,
            uint256 startTime,
            uint256 deadline,
            bool active,
            uint256 extensionCount
        )
    {
        LoanRecord storage loan = loans[borrower];
        return (
            loan.collateral,
            loan.principal,
            loan.startTime,
            loan.deadline,
            loan.active,
            loan.extensionCount
        );
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

    /// @notice Update the origination fee.
    /// @param newFeeBps New fee in basis points. Must be ≤ MAX_ORIGINATION_FEE.
    /// @dev Emits {OriginationFeeUpdated}. Only affects new loans.
    function setOriginationFee(uint256 newFeeBps) external override onlyOwner {
        if (newFeeBps > MAX_ORIGINATION_FEE) revert FeeTooHigh();
        emit OriginationFeeUpdated(originationFeeBps, newFeeBps);
        originationFeeBps = newFeeBps;
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

    /// @notice Pause the contract — halts borrow, fund, liquidate, extendLoan.
    /// @dev Emits {ContractPaused}. repay() remains available when paused.
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

    // ─── Internal ──────────────────────────────────────────────────────────────

    /// @dev Calculates accrued simple interest.
    ///      interest = principal × rateBps × elapsed / (365 days × 10_000)
    /// @param principal  Loan principal in wei.
    /// @param startTime  Timestamp when loan (or last extension) started.
    /// @return Accrued interest in wei.
    function _calcInterest(uint256 principal, uint256 startTime) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - startTime;
        return (principal * interestRateBps * elapsed) / (365 days * 10_000);
    }

    /// @notice Accept direct ETH/CELO deposits.
    /// @dev Emits {DirectDepositReceived} for traceability.
    receive() external payable {
        emit DirectDepositReceived(msg.sender, msg.value);
    }
}
// Loan fix 1: Define LIQUIDATION_THRESHOLD constant (was undefined, caused compile error)
// Loan fix 2: Fix freePoolBalance calculation in borrow() - was double-subtracting msg.value
// Loan fix 3: Apply originationFee in borrow() - fee was declared but never deducted
// Loan fix 4: Add accumulatedFees state variable to track collected fees
