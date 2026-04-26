// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title ILoan
/// @notice Interface for the collateral-backed CELO loan protocol.
interface ILoan {
    // ─── Errors ────────────────────────────────────────────────────────────────
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error Paused();
    error ExistingLoanActive();
    error InvalidAmount();
    error RateTooHigh();
    error InsufficientCollateral();
    error PoolInsufficient();
    error NoActiveLoan();
    error InsufficientRepayment();
    error LoanNotExpired();
    error TransferFailed();
    error WithdrawExceedsFree();
    error FeeTooHigh();
    error ExtensionLimitReached();

    // ─── Events ────────────────────────────────────────────────────────────────
    event LoanTaken(address indexed borrower, uint256 principal, uint256 collateral, uint256 deadline);
    event LoanRepaid(address indexed borrower, uint256 repaid, uint256 collateralReturned);
    event LoanLiquidated(address indexed borrower, address indexed liquidator, uint256 collateralSeized);
    event PoolFunded(address indexed funder, uint256 amount, uint256 newTotal);
    event PoolWithdrawn(address indexed owner, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event InterestRateUpdated(uint256 oldRate, uint256 newRate);
    event OriginationFeeUpdated(uint256 oldFee, uint256 newFee);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);
    event DirectDepositReceived(address indexed sender, uint256 amount);
    event LoanExtended(address indexed borrower, uint256 newDeadline, uint256 extensionCount);
    event FeesCollected(address indexed owner, uint256 amount);

    // ─── Functions ─────────────────────────────────────────────────────────────
    function fund() external payable;
    function borrow(uint256 borrowAmount) external payable;
    function repay() external payable;
    function liquidate(address borrower) external;
    function extendLoan() external payable;
    function withdrawPool(uint256 amount) external;
    function withdrawFees() external;
    function setInterestRate(uint256 newRateBps) external;
    function setOriginationFee(uint256 newFeeBps) external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function pause() external;
    function unpause() external;
    function amountDue(address borrower) external view returns (uint256 due, uint256 principal, uint256 interest);
    function freePoolBalance() external view returns (uint256);
    function getHealthFactor(address borrower) external view returns (uint256);
    function getLoanInfo(address borrower) external view returns (
        uint256 collateral,
        uint256 principal,
        uint256 startTime,
        uint256 deadline,
        bool active,
        uint256 extensionCount
    );
}
