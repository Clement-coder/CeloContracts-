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

    // ─── Events ────────────────────────────────────────────────────────────────
    event LoanTaken(address indexed borrower, uint256 principal, uint256 collateral, uint256 deadline);
    event LoanRepaid(address indexed borrower, uint256 repaid, uint256 collateralReturned);
    event LoanLiquidated(address indexed borrower, address indexed liquidator, uint256 collateralSeized);
    event PoolFunded(address indexed funder, uint256 amount, uint256 newTotal);
    event PoolWithdrawn(address indexed owner, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event InterestRateUpdated(uint256 oldRate, uint256 newRate);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);
    event DirectDepositReceived(address indexed sender, uint256 amount);

    // ─── Functions ─────────────────────────────────────────────────────────────
    function fund() external payable;
    function borrow(uint256 borrowAmount) external payable;
    function repay() external payable;
    function liquidate(address borrower) external;
    function withdrawPool(uint256 amount) external;
    function setInterestRate(uint256 newRateBps) external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function pause() external;
    function unpause() external;
    function amountDue(address borrower) external view returns (uint256 due, uint256 principal, uint256 interest);
    function freePoolBalance() external view returns (uint256);
}
