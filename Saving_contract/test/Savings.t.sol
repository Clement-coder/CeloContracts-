// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {Savings} from "../src/Savings.sol";
import {ISavings} from "../src/ISavings.sol";

contract SavingsTest is Test {
    Savings savings;
    address owner = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant DEPOSIT = 1 ether;
    uint256 constant LOCK = 7 days;

    // Mirror events
    event Deposited(address indexed user, uint256 amount, uint256 unlockTime, bool isNewAccount);
    event Withdrawn(address indexed user, uint256 amount, uint256 remaining);
    event EmergencyWithdrawn(address indexed user, uint256 amount, uint256 fee);
    event WithdrawalFeeCharged(address indexed user, uint256 fee);
    event WithdrawalFeeUpdated(uint256 oldFee, uint256 newFee);
    event EmergencyWithdrawToggled(bool enabled);
    event LockExtended(address indexed user, uint256 oldUnlockTime, uint256 newUnlockTime);
    event DirectDepositReceived(address indexed sender, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        savings = new Savings();
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsOwner() public view {
        assertEq(savings.owner(), owner);
    }

    // ─── Deposit ───────────────────────────────────────────────────────────────

    function test_Deposit_NoLock() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
        (uint256 bal, uint256 unlock) = savings.getAccount(alice);
        assertEq(bal, DEPOSIT);
        assertEq(unlock, 0);
    }

    function test_Deposit_WithLock() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(LOCK);
        (, uint256 unlock) = savings.getAccount(alice);
        assertApproxEqAbs(unlock, block.timestamp + LOCK, 1);
    }

    function test_Deposit_IsNewAccount_True() public {
        vm.expectEmit(true, false, false, false);
        emit Deposited(alice, DEPOSIT, 0, true);
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
    }

    function test_Deposit_IsNewAccount_False_OnSecondDeposit() public {
        vm.startPrank(alice);
        savings.deposit{value: DEPOSIT}(0);
        vm.expectEmit(true, false, false, false);
        emit Deposited(alice, DEPOSIT, 0, false);
        savings.deposit{value: DEPOSIT}(0);
        vm.stopPrank();
    }

    function test_Deposit_IncrementsTotalUsers() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
        assertEq(savings.totalUsers(), 1);
        vm.prank(bob);
        savings.deposit{value: DEPOSIT}(0);
        assertEq(savings.totalUsers(), 2);
    }

    function test_Deposit_IncrementsTotalDeposited() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
        assertEq(savings.totalDeposited(), DEPOSIT);
    }

    function test_Deposit_RevertBelowMinimum() public {
        vm.prank(alice);
        vm.expectRevert(ISavings.ZeroValue.selector);
        savings.deposit{value: 1}(0);
    }

    function test_Deposit_RevertAboveMaximum() public {
        vm.deal(alice, 1001 ether);
        vm.prank(alice);
        vm.expectRevert(ISavings.DepositTooLarge.selector);
        savings.deposit{value: 1001 ether}(0);
    }

    function test_Deposit_RevertLockTooLong() public {
        uint256 tooLong = savings.MAX_LOCK_DURATION() + 1 days;
        vm.prank(alice);
        vm.expectRevert(ISavings.LockTooLong.selector);
        savings.deposit{value: DEPOSIT}(tooLong);
    }

    function test_Deposit_RevertWhenPaused() public {
        savings.pause();
        vm.prank(alice);
        vm.expectRevert(ISavings.Paused.selector);
        savings.deposit{value: DEPOSIT}(0);
    }

    function test_Deposit_PreservesLongerExistingLock() public {
        vm.startPrank(alice);
        savings.deposit{value: DEPOSIT}(30 days);
        (, uint256 unlock1) = savings.getAccount(alice);
        savings.deposit{value: DEPOSIT}(1 days);
        (, uint256 unlock2) = savings.getAccount(alice);
        assertEq(unlock1, unlock2);
        vm.stopPrank();
    }

    function test_Deposit_EmitsLockExtended_WhenLockPushedForward() public {
        vm.startPrank(alice);
        savings.deposit{value: DEPOSIT}(7 days);
        (, uint256 oldUnlock) = savings.getAccount(alice);
        vm.expectEmit(true, false, false, false);
        emit LockExtended(alice, oldUnlock, oldUnlock + 30 days);
        savings.deposit{value: DEPOSIT}(37 days);
        vm.stopPrank();
    }

    // ─── Withdraw ──────────────────────────────────────────────────────────────

    function test_Withdraw_Full() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
        uint256 before = alice.balance;
        vm.prank(alice);
        savings.withdraw(DEPOSIT);
        // no fee set, full amount returned
        assertEq(alice.balance, before + DEPOSIT);
        assertEq(savings.totalDeposited(), 0);
    }

    function test_Withdraw_Partial() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
        vm.prank(alice);
        savings.withdraw(0.4 ether);
        (uint256 bal,) = savings.getAccount(alice);
        assertEq(bal, 0.6 ether);
    }

    function test_Withdraw_EmitsEvent() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(alice, DEPOSIT, 0);
        vm.prank(alice);
        savings.withdraw(DEPOSIT);
    }

    function test_Withdraw_AfterLockExpires() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(LOCK);
        skip(LOCK + 1);
        vm.prank(alice);
        savings.withdraw(DEPOSIT);
        (uint256 bal,) = savings.getAccount(alice);
        assertEq(bal, 0);
    }

    function test_Withdraw_ResetsUnlockOnFullWithdraw() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(LOCK);
        skip(LOCK + 1);
        vm.prank(alice);
        savings.withdraw(DEPOSIT);
        (, uint256 unlock) = savings.getAccount(alice);
        assertEq(unlock, 0);
    }

    function test_Withdraw_KeepsUnlockOnPartialWithdraw() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(LOCK);
        skip(LOCK + 1);
        vm.prank(alice);
        savings.withdraw(0.5 ether);
        (, uint256 unlock) = savings.getAccount(alice);
        assertGt(unlock, 0);
    }

    function test_Withdraw_RevertNothingToWithdraw() public {
        vm.prank(alice);
        vm.expectRevert(ISavings.NothingToWithdraw.selector);
        savings.withdraw(1 ether);
    }

    function test_Withdraw_RevertFundsLocked() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(LOCK);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ISavings.FundsLocked.selector, block.timestamp + LOCK));
        savings.withdraw(DEPOSIT);
    }

    function test_Withdraw_RevertAmountExceedsBalance() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
        vm.prank(alice);
        vm.expectRevert(ISavings.AmountExceedsBalance.selector);
        savings.withdraw(2 ether);
    }

    function test_Withdraw_RevertZeroAmount() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
        vm.prank(alice);
        vm.expectRevert(ISavings.AmountExceedsBalance.selector);
        savings.withdraw(0);
    }

    function test_Withdraw_FeeDeducted() public {
        savings.setWithdrawalFee(100); // 1%
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
        uint256 before = alice.balance;
        vm.prank(alice);
        savings.withdraw(DEPOSIT);
        uint256 expectedFee = DEPOSIT / 100;
        assertEq(alice.balance, before + DEPOSIT - expectedFee);
    }

    function test_Withdraw_EmitsFeeCharged() public {
        savings.setWithdrawalFee(100); // 1%
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
        vm.expectEmit(true, false, false, true);
        emit WithdrawalFeeCharged(alice, DEPOSIT / 100);
        vm.prank(alice);
        savings.withdraw(DEPOSIT);
    }

    // ─── EmergencyWithdraw ─────────────────────────────────────────────────────

    function test_EmergencyWithdraw_Success() public {
        savings.setEmergencyWithdrawEnabled(true);
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(LOCK);
        uint256 before = alice.balance;
        vm.prank(alice);
        savings.emergencyWithdraw(DEPOSIT);
        uint256 expectedFee = DEPOSIT / 10; // 10%
        assertEq(alice.balance, before + DEPOSIT - expectedFee);
        (uint256 bal,) = savings.getAccount(alice);
        assertEq(bal, 0);
    }

    function test_EmergencyWithdraw_EmitsEvent() public {
        savings.setEmergencyWithdrawEnabled(true);
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(LOCK);
        uint256 expectedFee = DEPOSIT / 10;
        vm.expectEmit(true, false, false, true);
        emit EmergencyWithdrawn(alice, DEPOSIT - expectedFee, expectedFee);
        vm.prank(alice);
        savings.emergencyWithdraw(DEPOSIT);
    }

    function test_EmergencyWithdraw_RevertDisabled() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(LOCK);
        vm.prank(alice);
        vm.expectRevert(ISavings.EmergencyWithdrawDisabled.selector);
        savings.emergencyWithdraw(DEPOSIT);
    }

    function test_EmergencyWithdraw_RevertNothingToWithdraw() public {
        savings.setEmergencyWithdrawEnabled(true);
        vm.prank(alice);
        vm.expectRevert(ISavings.NothingToWithdraw.selector);
        savings.emergencyWithdraw(1 ether);
    }

    function test_EmergencyWithdraw_RevertAmountExceedsBalance() public {
        savings.setEmergencyWithdrawEnabled(true);
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(LOCK);
        vm.prank(alice);
        vm.expectRevert(ISavings.AmountExceedsBalance.selector);
        savings.emergencyWithdraw(2 ether);
    }

    function test_EmergencyWithdraw_RevertZeroAmount() public {
        savings.setEmergencyWithdrawEnabled(true);
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(LOCK);
        vm.prank(alice);
        vm.expectRevert(ISavings.AmountExceedsBalance.selector);
        savings.emergencyWithdraw(0);
    }

    function test_EmergencyWithdraw_ResetsUnlockOnFullWithdraw() public {
        savings.setEmergencyWithdrawEnabled(true);
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(LOCK);
        vm.prank(alice);
        savings.emergencyWithdraw(DEPOSIT);
        (, uint256 unlock) = savings.getAccount(alice);
        assertEq(unlock, 0);
    }

    // ─── SetWithdrawalFee ──────────────────────────────────────────────────────

    function test_SetWithdrawalFee_Success() public {
        savings.setWithdrawalFee(200);
        assertEq(savings.withdrawalFeeBps(), 200);
    }

    function test_SetWithdrawalFee_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit WithdrawalFeeUpdated(0, 200);
        savings.setWithdrawalFee(200);
    }

    function test_SetWithdrawalFee_RevertFeeTooHigh() public {
        vm.expectRevert(ISavings.FeeTooHigh.selector);
        savings.setWithdrawalFee(501);
    }

    function test_SetWithdrawalFee_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ISavings.NotOwner.selector);
        savings.setWithdrawalFee(100);
    }

    // ─── SetEmergencyWithdrawEnabled ───────────────────────────────────────────

    function test_SetEmergencyWithdrawEnabled_True() public {
        savings.setEmergencyWithdrawEnabled(true);
        assertTrue(savings.emergencyWithdrawEnabled());
    }

    function test_SetEmergencyWithdrawEnabled_False() public {
        savings.setEmergencyWithdrawEnabled(true);
        savings.setEmergencyWithdrawEnabled(false);
        assertFalse(savings.emergencyWithdrawEnabled());
    }

    function test_SetEmergencyWithdrawEnabled_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit EmergencyWithdrawToggled(true);
        savings.setEmergencyWithdrawEnabled(true);
    }

    function test_SetEmergencyWithdrawEnabled_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ISavings.NotOwner.selector);
        savings.setEmergencyWithdrawEnabled(true);
    }

    // ─── IsLocked / TimeUntilUnlock ────────────────────────────────────────────

    function test_IsLocked_True() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(LOCK);
        assertTrue(savings.isLocked(alice));
    }

    function test_IsLocked_False_NoLock() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
        assertFalse(savings.isLocked(alice));
    }

    function test_IsLocked_False_AfterExpiry() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(LOCK);
        skip(LOCK + 1);
        assertFalse(savings.isLocked(alice));
    }

    function test_TimeUntilUnlock_ReturnsRemaining() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(LOCK);
        assertApproxEqAbs(savings.timeUntilUnlock(alice), LOCK, 1);
    }

    function test_TimeUntilUnlock_ReturnsZero_WhenUnlocked() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(LOCK);
        skip(LOCK + 1);
        assertEq(savings.timeUntilUnlock(alice), 0);
    }

    function test_TimeUntilUnlock_ReturnsZero_NoLock() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
        assertEq(savings.timeUntilUnlock(alice), 0);
    }

    // ─── ExtendLock ────────────────────────────────────────────────────────────

    function test_ExtendLock_Success() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(LOCK);
        (, uint256 oldUnlock) = savings.getAccount(alice);
        vm.prank(alice);
        savings.extendLock(7 days);
        (, uint256 newUnlock) = savings.getAccount(alice);
        assertGt(newUnlock, oldUnlock);
    }

    function test_ExtendLock_EmitsEvent() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(LOCK);
        (, uint256 oldUnlock) = savings.getAccount(alice);
        vm.expectEmit(true, false, false, false);
        emit LockExtended(alice, oldUnlock, oldUnlock + 7 days);
        vm.prank(alice);
        savings.extendLock(7 days);
    }

    function test_ExtendLock_RevertNoBalance() public {
        vm.prank(alice);
        vm.expectRevert(ISavings.NothingToWithdraw.selector);
        savings.extendLock(7 days);
    }

    function test_ExtendLock_RevertZeroSeconds() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
        vm.prank(alice);
        vm.expectRevert(ISavings.ZeroValue.selector);
        savings.extendLock(0);
    }

    function test_ExtendLock_RevertTooLong() public {
        uint256 tooLong = savings.MAX_LOCK_DURATION() + 1 days;
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
        vm.prank(alice);
        vm.expectRevert(ISavings.LockTooLong.selector);
        savings.extendLock(tooLong);
    }

    // ─── GetAccount ────────────────────────────────────────────────────────────

    function test_GetAccount_AnyAddress() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
        (uint256 bal,) = savings.getAccount(alice);
        assertEq(bal, DEPOSIT);
    }

    // ─── Pause ─────────────────────────────────────────────────────────────────

    function test_Pause_Unpause() public {
        savings.pause();
        assertTrue(savings.paused());
        savings.unpause();
        assertFalse(savings.paused());
    }

    function test_Pause_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ISavings.NotOwner.selector);
        savings.pause();
    }

    // ─── Ownership ─────────────────────────────────────────────────────────────

    function test_TwoStepOwnership() public {
        savings.transferOwnership(alice);
        assertEq(savings.pendingOwner(), alice);
        vm.prank(alice);
        savings.acceptOwnership();
        assertEq(savings.owner(), alice);
        assertEq(savings.pendingOwner(), address(0));
    }

    function test_TransferOwnership_RevertZeroAddress() public {
        vm.expectRevert(ISavings.ZeroAddress.selector);
        savings.transferOwnership(address(0));
    }

    function test_AcceptOwnership_RevertNotPending() public {
        savings.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(ISavings.NotPendingOwner.selector);
        savings.acceptOwnership();
    }

    function test_TransferOwnership_EmitsEvents() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferStarted(owner, alice);
        savings.transferOwnership(alice);

        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, alice);
        vm.prank(alice);
        savings.acceptOwnership();
    }

    // ─── Receive ───────────────────────────────────────────────────────────────

    function test_Receive_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit DirectDepositReceived(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(savings).call{value: 1 ether}("");
        assertTrue(ok);
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_Deposit(uint256 amount, uint256 lockDuration) public {
        amount = bound(amount, savings.MIN_DEPOSIT(), 5 ether);
        lockDuration = bound(lockDuration, 0, savings.MAX_LOCK_DURATION());
        vm.deal(alice, amount);
        vm.prank(alice);
        savings.deposit{value: amount}(lockDuration);
        (uint256 bal,) = savings.getAccount(alice);
        assertEq(bal, amount);
    }

    function testFuzz_WithdrawPartial(uint256 withdrawAmount) public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
        withdrawAmount = bound(withdrawAmount, 1, DEPOSIT);
        vm.prank(alice);
        savings.withdraw(withdrawAmount);
        (uint256 bal,) = savings.getAccount(alice);
        // fee is 0 by default, balance decremented by full withdrawAmount
        assertEq(bal, DEPOSIT - withdrawAmount);
    }

    function testFuzz_EmergencyWithdraw(uint256 amount) public {
        savings.setEmergencyWithdrawEnabled(true);
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(LOCK);
        amount = bound(amount, 1, DEPOSIT);
        uint256 before = alice.balance;
        vm.prank(alice);
        savings.emergencyWithdraw(amount);
        uint256 fee = (amount * savings.EMERGENCY_FEE_BPS()) / 10_000;
        assertEq(alice.balance, before + amount - fee);
    }

    // ─── Invariant ─────────────────────────────────────────────────────────────

    function test_Invariant_ContractBalanceGteTotalDeposited() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
        vm.prank(bob);
        savings.deposit{value: DEPOSIT}(0);
        assertGe(address(savings).balance, savings.totalDeposited());
    }

    receive() external payable {}
}
