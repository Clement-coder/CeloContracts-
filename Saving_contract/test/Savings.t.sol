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
        savings.deposit{value: DEPOSIT}(1 days); // shorter lock
        (, uint256 unlock2) = savings.getAccount(alice);
        assertEq(unlock1, unlock2); // original lock preserved
        vm.stopPrank();
    }

    function test_Deposit_EmitsLockExtended_WhenLockPushedForward() public {
        vm.startPrank(alice);
        savings.deposit{value: DEPOSIT}(7 days);
        (, uint256 oldUnlock) = savings.getAccount(alice);
        vm.expectEmit(true, false, false, false);
        emit LockExtended(alice, oldUnlock, oldUnlock + 30 days);
        savings.deposit{value: DEPOSIT}(37 days); // longer lock
        vm.stopPrank();
    }

    // ─── Withdraw ──────────────────────────────────────────────────────────────

    function test_Withdraw_Full() public {
        vm.prank(alice);
        savings.deposit{value: DEPOSIT}(0);
        uint256 before = alice.balance;
        vm.prank(alice);
        savings.withdraw(DEPOSIT);
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
        assertGt(unlock, 0); // lock preserved until fully withdrawn
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
        assertEq(bal, DEPOSIT - withdrawAmount);
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
