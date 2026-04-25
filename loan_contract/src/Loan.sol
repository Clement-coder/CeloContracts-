// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title Loan
/// @notice Collateral-backed CELO loan contract. Owner funds the pool; borrowers lock collateral to borrow.
contract Loan {
    address public owner;

    // Annual interest rate in basis points (e.g. 1000 = 10%)
    uint256 public interestRateBps;

    struct LoanRecord {
        uint256 collateral;    // CELO locked as collateral
        uint256 principal;     // CELO borrowed
        uint256 startTime;
        bool active;
    }

    mapping(address => LoanRecord) public loans;

    event LoanTaken(address indexed borrower, uint256 principal, uint256 collateral);
    event LoanRepaid(address indexed borrower, uint256 repaid, uint256 collateralReturned);
    event PoolFunded(uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(uint256 _interestRateBps) {
        owner = msg.sender;
        interestRateBps = _interestRateBps;
    }

    /// @notice Owner funds the lending pool.
    function fund() external payable onlyOwner {
        emit PoolFunded(msg.value);
    }

    /// @notice Borrow CELO by locking collateral (must send >= 150% of borrow amount as collateral).
    /// @param borrowAmount Amount of CELO to borrow (in wei).
    function borrow(uint256 borrowAmount) external payable {
        require(!loans[msg.sender].active, "Existing loan active");
        require(borrowAmount > 0, "Invalid amount");
        // Require 150% collateral ratio
        require(msg.value >= (borrowAmount * 150) / 100, "Insufficient collateral");
        require(address(this).balance - msg.value >= borrowAmount, "Pool insufficient");

        loans[msg.sender] = LoanRecord({
            collateral: msg.value,
            principal: borrowAmount,
            startTime: block.timestamp,
            active: true
        });

        (bool ok, ) = msg.sender.call{value: borrowAmount}("");
        require(ok, "Transfer failed");

        emit LoanTaken(msg.sender, borrowAmount, msg.value);
    }

    /// @notice Repay loan + interest to get collateral back.
    function repay() external payable {
        LoanRecord storage loan = loans[msg.sender];
        require(loan.active, "No active loan");

        uint256 interest = _interest(loan.principal, loan.startTime);
        uint256 due = loan.principal + interest;
        require(msg.value >= due, "Insufficient repayment");

        uint256 collateral = loan.collateral;
        loan.active = false;
        loan.collateral = 0;
        loan.principal = 0;

        // Refund overpayment
        if (msg.value > due) {
            (bool refund, ) = msg.sender.call{value: msg.value - due}("");
            require(refund, "Refund failed");
        }

        (bool ok, ) = msg.sender.call{value: collateral}("");
        require(ok, "Collateral return failed");

        emit LoanRepaid(msg.sender, due, collateral);
    }

    /// @notice Returns the total amount due (principal + accrued interest) for a borrower.
    function amountDue(address borrower) external view returns (uint256) {
        LoanRecord storage loan = loans[borrower];
        if (!loan.active) return 0;
        return loan.principal + _interest(loan.principal, loan.startTime);
    }

    /// @notice Owner withdraws idle pool funds (not locked as collateral).
    function withdrawPool(uint256 amount) external onlyOwner {
        (bool ok, ) = owner.call{value: amount}("");
        require(ok, "Withdraw failed");
    }

    function _interest(uint256 principal, uint256 startTime) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - startTime;
        // interest = principal * rate * elapsed / (365 days * 10000)
        return (principal * interestRateBps * elapsed) / (365 days * 10_000);
    }

    receive() external payable {}
}
