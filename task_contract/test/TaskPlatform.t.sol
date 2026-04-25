// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TaskPlatform} from "../src/TaskPlatform.sol";
import {ITaskPlatform} from "../src/ITaskPlatform.sol";

contract TaskPlatformTest is Test {
    TaskPlatform platform;
    address owner = address(this);
    address alice = makeAddr("alice"); // poster
    address bob = makeAddr("bob");     // worker
    address carol = makeAddr("carol");

    uint256 constant BOUNTY = 0.1 ether;

    // Mirror events
    event TaskCreated(uint256 indexed id, address indexed poster, uint256 bounty, string title, uint256 deadline);
    event TaskClaimed(uint256 indexed id, address indexed worker);
    event TaskCompleted(uint256 indexed id, address indexed worker, uint256 bounty);
    event TaskCancelled(uint256 indexed id, address indexed poster, uint256 bountyRefunded);
    event TaskExpiredAndReclaimed(uint256 indexed id, address indexed poster, uint256 bountyRefunded);
    event TaskDisputed(uint256 indexed id, address indexed raisedBy);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        platform = new TaskPlatform();
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsOwner() public view {
        assertEq(platform.owner(), owner);
    }

    // ─── CreateTask ────────────────────────────────────────────────────────────

    function test_CreateTask_Success() public {
        vm.prank(alice);
        uint256 id = platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        assertEq(id, 1);
        assertEq(platform.taskCount(), 1);
        assertEq(platform.totalBountyLocked(), BOUNTY);
    }

    function test_CreateTask_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit TaskCreated(1, alice, BOUNTY, "Fix bug", 0);
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
    }

    function test_CreateTask_RevertBountyTooLow() public {
        vm.prank(alice);
        vm.expectRevert(ITaskPlatform.BountyTooLow.selector);
        platform.createTask{value: 1}("Fix bug", "Desc");
    }

    function test_CreateTask_RevertEmptyTitle() public {
        vm.prank(alice);
        vm.expectRevert(ITaskPlatform.TitleTooLong.selector);
        platform.createTask{value: BOUNTY}("", "Desc");
    }

    function test_CreateTask_RevertTitleTooLong() public {
        string memory longTitle = new string(101);
        vm.prank(alice);
        vm.expectRevert(ITaskPlatform.TitleTooLong.selector);
        platform.createTask{value: BOUNTY}(longTitle, "Desc");
    }

    function test_CreateTask_RevertWhenPaused() public {
        platform.pause();
        vm.prank(alice);
        vm.expectRevert(ITaskPlatform.Paused.selector);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
    }

    // ─── ClaimTask ─────────────────────────────────────────────────────────────

    function test_ClaimTask_Success() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(bob);
        platform.claimTask(1);
        (,, address worker,,,,, ) = platform.getTask(1);
        assertEq(worker, bob);
    }

    function test_ClaimTask_EmitsEvent() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.expectEmit(true, true, false, false);
        emit TaskClaimed(1, bob);
        vm.prank(bob);
        platform.claimTask(1);
    }

    function test_ClaimTask_RevertNotOpen() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(bob);
        platform.claimTask(1);
        vm.prank(carol);
        vm.expectRevert(ITaskPlatform.TaskNotOpen.selector);
        platform.claimTask(1);
    }

    function test_ClaimTask_RevertPosterCannotClaim() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(alice);
        vm.expectRevert(ITaskPlatform.PosterCannotClaim.selector);
        platform.claimTask(1);
    }

    function test_ClaimTask_RevertExpired() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        skip(platform.TASK_DURATION() + 1);
        vm.prank(bob);
        vm.expectRevert(ITaskPlatform.TaskExpired.selector);
        platform.claimTask(1);
    }

    function test_ClaimTask_RevertWhenPaused() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        platform.pause();
        vm.prank(bob);
        vm.expectRevert(ITaskPlatform.Paused.selector);
        platform.claimTask(1);
    }

    // ─── ApproveCompletion ─────────────────────────────────────────────────────

    function test_ApproveCompletion_Success() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(bob);
        platform.claimTask(1);
        uint256 bobBefore = bob.balance;
        vm.prank(alice);
        platform.approveCompletion(1);
        assertGt(bob.balance, bobBefore);
        assertEq(platform.totalBountyLocked(), 0);
    }

    function test_ApproveCompletion_EmitsEvent() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(bob);
        platform.claimTask(1);
        vm.expectEmit(true, true, false, true);
        emit TaskCompleted(1, bob, BOUNTY);
        vm.prank(alice);
        platform.approveCompletion(1);
    }

    function test_ApproveCompletion_RevertNotPoster() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(bob);
        platform.claimTask(1);
        vm.prank(bob);
        vm.expectRevert(ITaskPlatform.NotPoster.selector);
        platform.approveCompletion(1);
    }

    function test_ApproveCompletion_RevertNotInProgress() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(alice);
        vm.expectRevert(ITaskPlatform.TaskNotInProgress.selector);
        platform.approveCompletion(1);
    }

    // ─── CancelTask ────────────────────────────────────────────────────────────

    function test_CancelTask_Success() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        platform.cancelTask(1);
        assertGt(alice.balance, aliceBefore);
        assertEq(platform.totalBountyLocked(), 0);
    }

    function test_CancelTask_EmitsEvent() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.expectEmit(true, true, false, true);
        emit TaskCancelled(1, alice, BOUNTY);
        vm.prank(alice);
        platform.cancelTask(1);
    }

    function test_CancelTask_RevertNotOpen() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(bob);
        platform.claimTask(1);
        vm.prank(alice);
        vm.expectRevert(ITaskPlatform.TaskNotCancellable.selector);
        platform.cancelTask(1);
    }

    function test_CancelTask_RevertNotPoster() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(bob);
        vm.expectRevert(ITaskPlatform.NotPoster.selector);
        platform.cancelTask(1);
    }

    // ─── ReclaimExpired ────────────────────────────────────────────────────────

    function test_ReclaimExpired_Success() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        skip(platform.TASK_DURATION() + 1);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        platform.reclaimExpired(1);
        assertGt(alice.balance, aliceBefore);
    }

    function test_ReclaimExpired_EmitsEvent() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        skip(platform.TASK_DURATION() + 1);
        vm.expectEmit(true, true, false, true);
        emit TaskExpiredAndReclaimed(1, alice, BOUNTY);
        vm.prank(alice);
        platform.reclaimExpired(1);
    }

    function test_ReclaimExpired_RevertNotExpired() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(alice);
        vm.expectRevert(ITaskPlatform.TaskNotExpired.selector);
        platform.reclaimExpired(1);
    }

    function test_ReclaimExpired_WorksOnInProgress() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(bob);
        platform.claimTask(1);
        skip(platform.TASK_DURATION() + 1);
        vm.prank(alice);
        platform.reclaimExpired(1); // poster reclaims from abandoned InProgress task
        assertEq(platform.totalBountyLocked(), 0);
    }

    // ─── DisputeTask ───────────────────────────────────────────────────────────

    function test_DisputeTask_ByPoster() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(bob);
        platform.claimTask(1);
        vm.prank(alice);
        platform.disputeTask(1);
        (,,,,,, uint8 status,) = platform.getTask(1);
        assertEq(status, uint8(5)); // Disputed
    }

    function test_DisputeTask_ByWorker() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(bob);
        platform.claimTask(1);
        vm.prank(bob);
        platform.disputeTask(1);
        (,,,,,, uint8 status,) = platform.getTask(1);
        assertEq(status, uint8(5));
    }

    function test_DisputeTask_EmitsEvent() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(bob);
        platform.claimTask(1);
        vm.expectEmit(true, true, false, false);
        emit TaskDisputed(1, alice);
        vm.prank(alice);
        platform.disputeTask(1);
    }

    function test_DisputeTask_RevertNotInProgress() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(alice);
        vm.expectRevert(ITaskPlatform.TaskNotInProgress.selector);
        platform.disputeTask(1);
    }

    // ─── Pause ─────────────────────────────────────────────────────────────────

    function test_Pause_Unpause() public {
        platform.pause();
        assertTrue(platform.paused());
        platform.unpause();
        assertFalse(platform.paused());
    }

    function test_Pause_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ITaskPlatform.NotOwner.selector);
        platform.pause();
    }

    // ─── Ownership ─────────────────────────────────────────────────────────────

    function test_TwoStepOwnership() public {
        platform.transferOwnership(alice);
        assertEq(platform.pendingOwner(), alice);
        vm.prank(alice);
        platform.acceptOwnership();
        assertEq(platform.owner(), alice);
        assertEq(platform.pendingOwner(), address(0));
    }

    function test_TransferOwnership_RevertZeroAddress() public {
        vm.expectRevert(ITaskPlatform.ZeroAddress.selector);
        platform.transferOwnership(address(0));
    }

    function test_AcceptOwnership_RevertNotPending() public {
        platform.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(ITaskPlatform.NotPendingOwner.selector);
        platform.acceptOwnership();
    }

    function test_TransferOwnership_EmitsEvents() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferStarted(owner, alice);
        platform.transferOwnership(alice);
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, alice);
        vm.prank(alice);
        platform.acceptOwnership();
    }

    // ─── WithdrawStuckFunds ────────────────────────────────────────────────────

    function test_WithdrawStuckFunds_Success() public {
        // Send ETH directly (not via createTask) — becomes "stuck"
        (bool ok,) = address(platform).call{value: 1 ether}("");
        assertTrue(ok);
        uint256 before = owner.balance;
        platform.withdrawStuckFunds(1 ether);
        assertEq(owner.balance, before + 1 ether);
    }

    function test_WithdrawStuckFunds_CannotTouchLockedBounty() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.expectRevert(ITaskPlatform.BountyTooLow.selector);
        platform.withdrawStuckFunds(BOUNTY); // bounty is locked
    }

    function test_WithdrawStuckFunds_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ITaskPlatform.NotOwner.selector);
        platform.withdrawStuckFunds(1);
    }

    // ─── GetTask ───────────────────────────────────────────────────────────────

    function test_GetTask_ReturnsCorrectData() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        (uint256 id, address poster,, string memory title,,,,) = platform.getTask(1);
        assertEq(id, 1);
        assertEq(poster, alice);
        assertEq(title, "Fix bug");
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_CreateTask(uint256 bounty) public {
        bounty = bound(bounty, platform.MIN_BOUNTY(), 5 ether);
        vm.deal(alice, bounty);
        vm.prank(alice);
        uint256 id = platform.createTask{value: bounty}("Task", "Desc");
        assertEq(platform.totalBountyLocked(), bounty);
        assertEq(id, 1);
    }

    // ─── Invariant ─────────────────────────────────────────────────────────────

    function test_Invariant_BalanceGteTotalBountyLocked() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(bob);
        platform.createTask{value: BOUNTY}("Write docs", "Desc");
        assertGe(address(platform).balance, platform.totalBountyLocked());
    }

    receive() external payable {}
}
