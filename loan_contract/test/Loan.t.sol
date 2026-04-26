// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {Loan} from "../src/Loan.sol";
import {ILoan} from "../src/ILoan.sol";

contract LoanTest is Test {
    Loan loan;
    address owner = address(this);
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant RATE       = 1_000;  // 10% APR
    uint256 constant POOL       = 10 ether;
    uint256 constant BORROW     = 1 ether;
    uint256 constant COLLATERAL = 1.5 ether;

    // Mirror events
    event LoanTaken(address indexed borrower, uint256 principal, uint256 collateral, uint256 deadline);
    event LoanRepaid(address indexed borrower, uint256 repaid, uint256 collateralReturned);
    event LoanLiquidated(address indexed borrower, address indexed liquidator, uint256 collateralSeized);
    event PoolFunded(address indexed funder, uint256 amount, uint256 newTotal);
    event PoolWithdrawn(address indexed owner, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event InterestRateUpdated(uint256 oldRate, uint256 newRate);
    event OriginationFeeUpdated(uint256 oldFee, uint256 newFee);
    event DirectDepositReceived(address indexed sender, uint256 amount);
    event LoanExtended(address indexed borrower, uint256 newDeadline, uint256 extensionCount);
    event FeesCollected(address indexed owner, uint256 amount);

    function setUp() public {
        loan = new Loan(RATE);
        loan.fund{value: POOL}();
        vm.deal(alice, 20 ether);
        vm.deal(bob,   20 ether);
        vm.deal(carol, 20 ether);
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsOwnerAndRate() public view {
        assertEq(loan.owner(), owner);
        assertEq(loan.interestRateBps(), RATE);
    }

    function test_Constructor_DefaultOriginationFeeZero() public view {
        assertEq(loan.originationFeeBps(), 0);
    }

    function test_Constructor_RevertZeroRate() public {
        vm.expectRevert(ILoan.RateTooHigh.selector);
        new Loan(0);
    }

    function test_Constructor_RevertRateTooHigh() public {
        vm.expectRevert(ILoan.RateTooHigh.selector);
        new Loan(5_001);
    }

    function test_Constructor_MaxRateAllowed() public {
        Loan l = new Loan(5_000);
        assertEq(l.interestRateBps(), 5_000);
    }

    // ─── Fund ──────────────────────────────────────────────────────────────────

    function test_Fund_AnyoneCanFund() public {
        vm.prank(alice);
        loan.fund{value: 1 ether}();
        assertEq(loan.freePoolBalance(), POOL + 1 ether);
    }

    function test_Fund_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit PoolFunded(alice, 1 ether, POOL + 1 ether);
        vm.prank(alice);
        loan.fund{value: 1 ether}();
    }

    function test_Fund_RevertZeroValue() public {
        vm.expectRevert(ILoan.InvalidAmount.selector);
        loan.fund{value: 0}();
    }

    function test_Fund_RevertWhenPaused() public {
        loan.pause();
        vm.expectRevert(ILoan.Paused.selector);
        loan.fund{value: 1 ether}();
    }

    // ─── Borrow ────────────────────────────────────────────────────────────────

    function test_Borrow_Success() public {
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        // No origination fee, so alice gets full BORROW back minus collateral
        assertEq(alice.balance, balBefore - COLLATERAL + BORROW);
        assertEq(loan.totalLockedCollateral(), COLLATERAL);
        assertEq(loan.totalOutstandingPrincipal(), BORROW);
    }

    function test_Borrow_EmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit LoanTaken(alice, BORROW, COLLATERAL, 0);
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
    }

    function test_Borrow_RevertExistingLoan() public {
        vm.startPrank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        vm.expectRevert(ILoan.ExistingLoanActive.selector);
        loan.borrow{value: COLLATERAL}(BORROW);
        vm.stopPrank();
    }

    function test_Borrow_RevertBelowMinimum() public {
        vm.prank(alice);
        vm.expectRevert(ILoan.InvalidAmount.selector);
        loan.borrow{value: 1}(1);
    }

    function test_Borrow_RevertInsufficientCollateral() public {
        vm.prank(alice);
        vm.expectRevert(ILoan.InsufficientCollateral.selector);
        loan.borrow{value: 1 ether}(BORROW); // 1 ether < 1.5 ether required
    }

    function test_Borrow_RevertPoolInsufficient() public {
        vm.deal(alice, 30 ether);
        vm.prank(alice);
        vm.expectRevert(ILoan.PoolInsufficient.selector);
        loan.borrow{value: 20 ether}(11 ether); // pool only has 10
    }

    function test_Borrow_RevertWhenPaused() public {
        loan.pause();
        vm.prank(alice);
        vm.expectRevert(ILoan.Paused.selector);
        loan.borrow{value: COLLATERAL}(BORROW);
    }

    function test_Borrow_WithOriginationFee() public {
        loan.setOriginationFee(100); // 1%
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        uint256 fee = BORROW / 100; // 1%
        assertEq(alice.balance, balBefore - COLLATERAL + BORROW - fee);
        assertEq(loan.accumulatedFees(), fee);
    }

    function test_Borrow_FreePoolExcludesFees() public {
        loan.setOriginationFee(100); // 1%
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        // freePool = balance - lockedCollateral - fees
        uint256 expected = address(loan).balance - loan.totalLockedCollateral() - loan.accumulatedFees();
        assertEq(loan.freePoolBalance(), expected);
    }

    // ─── Repay ─────────────────────────────────────────────────────────────────

    function test_Repay_Success() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        skip(30 days);
        (uint256 due,,) = loan.amountDue(alice);
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        loan.repay{value: due}();
        assertEq(loan.totalLockedCollateral(), 0);
        assertEq(loan.totalOutstandingPrincipal(), 0);
        assertGt(alice.balance, balBefore); // got collateral back
    }

    function test_Repay_OverpaymentRefunded() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        (uint256 due,,) = loan.amountDue(alice);
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        loan.repay{value: due + 0.5 ether}();
        // Should get overpayment + collateral back
        assertGt(alice.balance, balBefore);
    }

    function test_Repay_EmitsEvent() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        (uint256 due,,) = loan.amountDue(alice);
        vm.expectEmit(true, false, false, false);
        emit LoanRepaid(alice, due, COLLATERAL);
        vm.prank(alice);
        loan.repay{value: due}();
    }

    function test_Repay_RevertNoActiveLoan() public {
        vm.prank(alice);
        vm.expectRevert(ILoan.NoActiveLoan.selector);
        loan.repay{value: 1 ether}();
    }

    function test_Repay_RevertInsufficientRepayment() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        vm.prank(alice);
        vm.expectRevert(ILoan.InsufficientRepayment.selector);
        loan.repay{value: 0.5 ether}();
    }

    function test_Repay_ClearsLoanState() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        (uint256 due,,) = loan.amountDue(alice);
        vm.prank(alice);
        loan.repay{value: due}();
        (uint256 dueAfter,,) = loan.amountDue(alice);
        assertEq(dueAfter, 0);
        (,,,,bool active,) = loan.getLoanInfo(alice);
        assertFalse(active);
    }

    function test_Repay_WorksWhenPaused() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        loan.pause();
        (uint256 due,,) = loan.amountDue(alice);
        // repay should NOT revert when paused
        vm.prank(alice);
        loan.repay{value: due}();
        assertEq(loan.totalLockedCollateral(), 0);
    }

    // ─── Liquidate ─────────────────────────────────────────────────────────────

    function test_Liquidate_Success() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        skip(loan.LOAN_DURATION() + 1);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        loan.liquidate(alice);
        assertGt(bob.balance, bobBefore);
        assertEq(loan.totalLockedCollateral(), 0);
    }

    function test_Liquidate_EmitsEvent() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        skip(loan.LOAN_DURATION() + 1);
        vm.expectEmit(true, true, false, true);
        emit LoanLiquidated(alice, bob, COLLATERAL);
        vm.prank(bob);
        loan.liquidate(alice);
    }

    function test_Liquidate_RevertNotExpired() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        vm.prank(bob);
        vm.expectRevert(ILoan.LoanNotExpired.selector);
        loan.liquidate(alice);
    }

    function test_Liquidate_RevertNoActiveLoan() public {
        vm.prank(bob);
        vm.expectRevert(ILoan.NoActiveLoan.selector);
        loan.liquidate(alice);
    }

    function test_Liquidate_RevertWhenPaused() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        skip(loan.LOAN_DURATION() + 1);
        loan.pause();
        vm.prank(bob);
        vm.expectRevert(ILoan.Paused.selector);
        loan.liquidate(alice);
    }

    function test_Liquidate_ClearsState() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        skip(loan.LOAN_DURATION() + 1);
        vm.prank(bob);
        loan.liquidate(alice);
        assertEq(loan.totalOutstandingPrincipal(), 0);
        (,,,,bool active,) = loan.getLoanInfo(alice);
        assertFalse(active);
    }

    // ─── ExtendLoan ────────────────────────────────────────────────────────────

    function test_ExtendLoan_Success() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        skip(15 days);
        (uint256 due,,uint256 interest) = loan.amountDue(alice);
        (,,,uint256 deadlineBefore,,) = loan.getLoanInfo(alice);
        vm.prank(alice);
        loan.extendLoan{value: interest}();
        (,,,uint256 deadlineAfter,,uint256 extCount) = loan.getLoanInfo(alice);
        assertEq(deadlineAfter, deadlineBefore + loan.EXTENSION_DURATION());
        assertEq(extCount, 1);
        (due,,) = loan.amountDue(alice); // interest should be near 0 after reset
        assertLt(due - BORROW, interest); // new interest < old interest
    }

    function test_ExtendLoan_EmitsEvent() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        skip(1 days);
        (,,uint256 interest) = loan.amountDue(alice);
        (,,,uint256 deadlineBefore,,) = loan.getLoanInfo(alice);
        vm.expectEmit(true, false, false, false);
        emit LoanExtended(alice, deadlineBefore + loan.EXTENSION_DURATION(), 1);
        vm.prank(alice);
        loan.extendLoan{value: interest}();
    }

    function test_ExtendLoan_RevertNoActiveLoan() public {
        vm.prank(alice);
        vm.expectRevert(ILoan.NoActiveLoan.selector);
        loan.extendLoan{value: 0}();
    }

    function test_ExtendLoan_RevertMaxExtensions() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        for (uint256 i = 0; i < loan.MAX_EXTENSIONS(); i++) {
            skip(1 days);
            (,,uint256 interest) = loan.amountDue(alice);
            vm.prank(alice);
            loan.extendLoan{value: interest + 1}();
        }
        skip(1 days);
        (,,uint256 interest) = loan.amountDue(alice);
        vm.prank(alice);
        vm.expectRevert(ILoan.ExtensionLimitReached.selector);
        loan.extendLoan{value: interest + 1}();
    }

    function test_ExtendLoan_RevertInsufficientPayment() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        skip(10 days);
        (,,uint256 interest) = loan.amountDue(alice);
        vm.prank(alice);
        vm.expectRevert(ILoan.InsufficientRepayment.selector);
        loan.extendLoan{value: interest - 1}();
    }

    function test_ExtendLoan_OverpaymentRefunded() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        skip(1 days);
        (,,uint256 interest) = loan.amountDue(alice);
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        loan.extendLoan{value: interest + 1 ether}();
        // Should get 1 ether back
        assertApproxEqAbs(alice.balance, balBefore - interest, 1e9);
    }

    function test_ExtendLoan_RevertWhenPaused() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        loan.pause();
        vm.prank(alice);
        vm.expectRevert(ILoan.Paused.selector);
        loan.extendLoan{value: 0}();
    }

    // ─── WithdrawPool ──────────────────────────────────────────────────────────

    function test_WithdrawPool_Success() public {
        uint256 before = owner.balance;
        loan.withdrawPool(1 ether);
        assertEq(owner.balance, before + 1 ether);
    }

    function test_WithdrawPool_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit PoolWithdrawn(owner, 1 ether);
        loan.withdrawPool(1 ether);
    }

    function test_WithdrawPool_RevertExceedsFree() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        vm.expectRevert(ILoan.WithdrawExceedsFree.selector);
        loan.withdrawPool(10 ether);
    }

    function test_WithdrawPool_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ILoan.NotOwner.selector);
        loan.withdrawPool(1 ether);
    }

    function test_WithdrawPool_CannotTouchLockedCollateral() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        // free pool = 10 ether (pool) - 1 ether (lent out) = 9 ether
        assertEq(loan.freePoolBalance(), 9 ether);
        loan.withdrawPool(9 ether);
        vm.expectRevert(ILoan.WithdrawExceedsFree.selector);
        loan.withdrawPool(1);
    }

    function test_WithdrawPool_RevertZeroAmount() public {
        vm.expectRevert(ILoan.InvalidAmount.selector);
        loan.withdrawPool(0);
    }

    // ─── WithdrawFees ──────────────────────────────────────────────────────────

    function test_WithdrawFees_Success() public {
        loan.setOriginationFee(100); // 1%
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        uint256 fee = BORROW / 100;
        uint256 before = owner.balance;
        loan.withdrawFees();
        assertEq(owner.balance, before + fee);
        assertEq(loan.accumulatedFees(), 0);
    }

    function test_WithdrawFees_EmitsEvent() public {
        loan.setOriginationFee(100);
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        uint256 fee = BORROW / 100;
        vm.expectEmit(true, false, false, true);
        emit FeesCollected(owner, fee);
        loan.withdrawFees();
    }

    function test_WithdrawFees_RevertNoFees() public {
        vm.expectRevert(ILoan.InvalidAmount.selector);
        loan.withdrawFees();
    }

    function test_WithdrawFees_RevertNotOwner() public {
        loan.setOriginationFee(100);
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        vm.prank(alice);
        vm.expectRevert(ILoan.NotOwner.selector);
        loan.withdrawFees();
    }

    // ─── SetOriginationFee ─────────────────────────────────────────────────────

    function test_SetOriginationFee_Success() public {
        vm.expectEmit(false, false, false, true);
        emit OriginationFeeUpdated(0, 100);
        loan.setOriginationFee(100);
        assertEq(loan.originationFeeBps(), 100);
    }

    function test_SetOriginationFee_RevertTooHigh() public {
        vm.expectRevert(ILoan.FeeTooHigh.selector);
        loan.setOriginationFee(201);
    }

    function test_SetOriginationFee_MaxAllowed() public {
        loan.setOriginationFee(200);
        assertEq(loan.originationFeeBps(), 200);
    }

    function test_SetOriginationFee_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ILoan.NotOwner.selector);
        loan.setOriginationFee(100);
    }

    // ─── Ownership ─────────────────────────────────────────────────────────────

    function test_TwoStepOwnership() public {
        loan.transferOwnership(alice);
        assertEq(loan.pendingOwner(), alice);
        vm.prank(alice);
        loan.acceptOwnership();
        assertEq(loan.owner(), alice);
        assertEq(loan.pendingOwner(), address(0));
    }

    function test_TransferOwnership_EmitsEvents() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferStarted(owner, alice);
        loan.transferOwnership(alice);

        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, alice);
        vm.prank(alice);
        loan.acceptOwnership();
    }

    function test_TransferOwnership_RevertZeroAddress() public {
        vm.expectRevert(ILoan.ZeroAddress.selector);
        loan.transferOwnership(address(0));
    }

    function test_AcceptOwnership_RevertNotPending() public {
        loan.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(ILoan.NotPendingOwner.selector);
        loan.acceptOwnership();
    }

    // ─── Interest Rate ─────────────────────────────────────────────────────────

    function test_SetInterestRate_Success() public {
        vm.expectEmit(false, false, false, true);
        emit InterestRateUpdated(RATE, 500);
        loan.setInterestRate(500);
        assertEq(loan.interestRateBps(), 500);
    }

    function test_SetInterestRate_RevertZero() public {
        vm.expectRevert(ILoan.RateTooHigh.selector);
        loan.setInterestRate(0);
    }

    function test_SetInterestRate_RevertTooHigh() public {
        vm.expectRevert(ILoan.RateTooHigh.selector);
        loan.setInterestRate(5_001);
    }

    function test_SetInterestRate_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ILoan.NotOwner.selector);
        loan.setInterestRate(500);
    }

    // ─── Pause ─────────────────────────────────────────────────────────────────

    function test_Pause_Unpause() public {
        loan.pause();
        assertTrue(loan.paused());
        loan.unpause();
        assertFalse(loan.paused());
    }

    function test_Pause_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ILoan.NotOwner.selector);
        loan.pause();
    }

    function test_Unpause_RevertNotOwner() public {
        loan.pause();
        vm.prank(alice);
        vm.expectRevert(ILoan.NotOwner.selector);
        loan.unpause();
    }

    // ─── AmountDue ─────────────────────────────────────────────────────────────

    function test_AmountDue_InactiveLoanReturnsZero() public view {
        (uint256 due, uint256 principal, uint256 interest) = loan.amountDue(alice);
        assertEq(due, 0);
        assertEq(principal, 0);
        assertEq(interest, 0);
    }

    function test_AmountDue_AccruesOverTime() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        (uint256 due1,,) = loan.amountDue(alice);
        skip(30 days);
        (uint256 due2,,) = loan.amountDue(alice);
        assertGt(due2, due1);
    }

    // ─── HealthFactor ──────────────────────────────────────────────────────────

    function test_HealthFactor_InitiallyAboveThreshold() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        uint256 hf = loan.getHealthFactor(alice);
        assertGe(hf, loan.LIQUIDATION_THRESHOLD());
    }

    function test_HealthFactor_ZeroForInactiveLoan() public view {
        assertEq(loan.getHealthFactor(alice), 0);
    }

    // ─── GetLoanInfo ───────────────────────────────────────────────────────────

    function test_GetLoanInfo_ReturnsCorrectData() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        (uint256 col, uint256 prin, uint256 start, uint256 deadline, bool active, uint256 extCount) =
            loan.getLoanInfo(alice);
        assertEq(col, COLLATERAL);
        assertEq(prin, BORROW);
        assertEq(start, block.timestamp);
        assertEq(deadline, block.timestamp + loan.LOAN_DURATION());
        assertTrue(active);
        assertEq(extCount, 0);
    }

    // ─── Receive ───────────────────────────────────────────────────────────────

    function test_Receive_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit DirectDepositReceived(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(loan).call{value: 1 ether}("");
        assertTrue(ok);
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_Borrow(uint256 borrowAmount) public {
        borrowAmount = bound(borrowAmount, loan.MIN_BORROW(), 5 ether);
        uint256 collateral = (borrowAmount * 150) / 100;
        vm.deal(alice, collateral + 1 ether);
        vm.prank(alice);
        loan.borrow{value: collateral}(borrowAmount);
        assertEq(loan.totalLockedCollateral(), collateral);
    }

    function testFuzz_InterestBounded(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 365 days);
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        skip(elapsed);
        (, uint256 principal, uint256 interest) = loan.amountDue(alice);
        assertLe(interest, principal); // interest never exceeds principal in 1 year at max 50% APR
    }

    function testFuzz_OriginationFee(uint256 feeBps) public {
        feeBps = bound(feeBps, 0, 200);
        loan.setOriginationFee(feeBps);
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        uint256 fee = (BORROW * feeBps) / 10_000;
        assertEq(alice.balance, balBefore - COLLATERAL + BORROW - fee);
        assertEq(loan.accumulatedFees(), fee);
    }

    // ─── Invariants ────────────────────────────────────────────────────────────

    function test_Invariant_BalanceGteLockedCollateral() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        assertGe(address(loan).balance, loan.totalLockedCollateral());
    }

    function test_Invariant_FreePoolNeverNegative() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        assertGe(loan.freePoolBalance(), 0);
    }

    function test_Invariant_MultipleLoans() public {
        vm.prank(alice);
        loan.borrow{value: COLLATERAL}(BORROW);
        vm.prank(bob);
        loan.borrow{value: COLLATERAL}(BORROW);
        assertEq(loan.totalLockedCollateral(), COLLATERAL * 2);
        assertEq(loan.totalOutstandingPrincipal(), BORROW * 2);
        assertGe(address(loan).balance, loan.totalLockedCollateral());
    }

    receive() external payable {}
}
