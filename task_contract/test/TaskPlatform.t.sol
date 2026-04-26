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
    event TaskRated(uint256 indexed id, address indexed worker, uint8 rating);
    event TaskCancelled(uint256 indexed id, address indexed poster, uint256 bountyRefunded);
    event TaskExpiredAndReclaimed(uint256 indexed id, address indexed poster, uint256 bountyRefunded);
    event TaskDisputed(uint256 indexed id, address indexed raisedBy);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event StuckFundsWithdrawn(address indexed to, uint256 amount);

    function setUp() public {
        platform = new TaskPlatform();
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────

    function _createAndClaim() internal returns (uint256 id) {
        vm.prank(alice);
        id = platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(bob);
        platform.claimTask(id);
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
        (,, address worker,,,,,) = platform.getTask(1);
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
        uint256 id = _createAndClaim();
        uint256 bobBefore = bob.balance;
        vm.prank(alice);
        platform.approveCompletion(id, 0);
        assertGt(bob.balance, bobBefore);
        assertEq(platform.totalBountyLocked(), 0);
    }

    function test_ApproveCompletion_EmitsEvent() public {
        uint256 id = _createAndClaim();
        vm.expectEmit(true, true, false, true);
        emit TaskCompleted(id, bob, BOUNTY);
        vm.prank(alice);
        platform.approveCompletion(id, 0);
    }

    function test_ApproveCompletion_WithRating_EmitsTaskRated() public {
        uint256 id = _createAndClaim();
        vm.expectEmit(true, true, false, true);
        emit TaskRated(id, bob, 5);
        vm.prank(alice);
        platform.approveCompletion(id, 5);
    }

    function test_ApproveCompletion_WithRating_UpdatesReputation() public {
        uint256 id = _createAndClaim();
        vm.prank(alice);
        platform.approveCompletion(id, 4);
        (uint256 avg, uint256 completed) = platform.getWorkerReputation(bob);
        assertEq(completed, 1);
        assertEq(avg, 400); // 4 * 100
    }

    function test_ApproveCompletion_RevertInvalidRating() public {
        uint256 id = _createAndClaim();
        vm.prank(alice);
        vm.expectRevert(ITaskPlatform.InvalidRating.selector);
        platform.approveCompletion(id, 6);
    }

    function test_ApproveCompletion_RevertNotPoster() public {
        uint256 id = _createAndClaim();
        vm.prank(bob);
        vm.expectRevert(ITaskPlatform.NotPoster.selector);
        platform.approveCompletion(id, 0);
    }

    function test_ApproveCompletion_RevertNotInProgress() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(alice);
        vm.expectRevert(ITaskPlatform.TaskNotInProgress.selector);
        platform.approveCompletion(1, 0);
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
        uint256 id = _createAndClaim();
        vm.prank(alice);
        vm.expectRevert(ITaskPlatform.TaskNotCancellable.selector);
        platform.cancelTask(id);
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
        uint256 id = _createAndClaim();
        skip(platform.TASK_DURATION() + 1);
        vm.prank(alice);
        platform.reclaimExpired(id);
        assertEq(platform.totalBountyLocked(), 0);
    }

    function test_ReclaimExpired_RevertNotPoster() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        skip(platform.TASK_DURATION() + 1);
        vm.prank(bob);
        vm.expectRevert(ITaskPlatform.NotPoster.selector);
        platform.reclaimExpired(1);
    }

    // ─── DisputeTask ───────────────────────────────────────────────────────────

    function test_DisputeTask_ByPoster() public {
        uint256 id = _createAndClaim();
        vm.prank(alice);
        platform.disputeTask(id);
        (,,,,,, uint8 status,) = platform.getTask(id);
        assertEq(status, uint8(5)); // Disputed
    }

    function test_DisputeTask_ByWorker() public {
        uint256 id = _createAndClaim();
        vm.prank(bob);
        platform.disputeTask(id);
        (,,,,,, uint8 status,) = platform.getTask(id);
        assertEq(status, uint8(5));
    }

    function test_DisputeTask_EmitsEvent() public {
        uint256 id = _createAndClaim();
        vm.expectEmit(true, true, false, false);
        emit TaskDisputed(id, alice);
        vm.prank(alice);
        platform.disputeTask(id);
    }

    function test_DisputeTask_RevertNotInProgress() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(alice);
        vm.expectRevert(ITaskPlatform.TaskNotInProgress.selector);
        platform.disputeTask(1);
    }

    function test_DisputeTask_RevertNotAuthorized() public {
        uint256 id = _createAndClaim();
        vm.prank(carol);
        vm.expectRevert(ITaskPlatform.NotAuthorized.selector);
        platform.disputeTask(id);
    }

    // ─── GetWorkerReputation ───────────────────────────────────────────────────

    function test_GetWorkerReputation_ZeroIfNoTasks() public view {
        (uint256 avg, uint256 completed) = platform.getWorkerReputation(bob);
        assertEq(avg, 0);
        assertEq(completed, 0);
    }

    function test_GetWorkerReputation_AverageScaledBy100() public {
        uint256 id = _createAndClaim();
        vm.prank(alice);
        platform.approveCompletion(id, 5);
        (uint256 avg,) = platform.getWorkerReputation(bob);
        assertEq(avg, 500);
    }

    function test_GetWorkerReputation_NoRating_ZeroAverage() public {
        uint256 id = _createAndClaim();
        vm.prank(alice);
        platform.approveCompletion(id, 0); // skip rating
        (uint256 avg, uint256 completed) = platform.getWorkerReputation(bob);
        assertEq(avg, 0);
        assertEq(completed, 0);
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
        (bool ok,) = address(platform).call{value: 1 ether}("");
        assertTrue(ok);
        uint256 before = owner.balance;
        platform.withdrawStuckFunds(1 ether);
        assertEq(owner.balance, before + 1 ether);
    }

    function test_WithdrawStuckFunds_EmitsEvent() public {
        (bool ok,) = address(platform).call{value: 1 ether}("");
        assertTrue(ok);
        vm.expectEmit(true, false, false, true);
        emit StuckFundsWithdrawn(owner, 1 ether);
        platform.withdrawStuckFunds(1 ether);
    }

    function test_WithdrawStuckFunds_CannotTouchLockedBounty() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.expectRevert(ITaskPlatform.InvalidAmount.selector);
        platform.withdrawStuckFunds(BOUNTY);
    }

    function test_WithdrawStuckFunds_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ITaskPlatform.NotOwner.selector);
        platform.withdrawStuckFunds(1);
    }

    function test_WithdrawStuckFunds_RevertZeroAmount() public {
        (bool ok,) = address(platform).call{value: 1 ether}("");
        assertTrue(ok);
        vm.expectRevert(ITaskPlatform.InvalidAmount.selector);
        platform.withdrawStuckFunds(0);
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

    function testFuzz_ApproveCompletion_Rating(uint8 rating) public {
        rating = uint8(bound(rating, 1, 5));
        uint256 id = _createAndClaim();
        vm.prank(alice);
        platform.approveCompletion(id, rating);
        (uint256 avg, uint256 completed) = platform.getWorkerReputation(bob);
        assertEq(completed, 1);
        assertEq(avg, uint256(rating) * 100);
    }

    // ─── Invariant ─────────────────────────────────────────────────────────────

    function test_Invariant_BalanceGteTotalBountyLocked() public {
        vm.prank(alice);
        platform.createTask{value: BOUNTY}("Fix bug", "Desc");
        vm.prank(bob);
        platform.createTask{value: BOUNTY}("Write docs", "Desc");
        assertGe(address(platform).balance, platform.totalBountyLocked());
    }

    function test_Invariant_BountyLockedDecreasesOnComplete() public {
        uint256 id = _createAndClaim();
        vm.prank(alice);
        platform.approveCompletion(id, 0);
        assertEq(platform.totalBountyLocked(), 0);
    }

    receive() external payable {}
}
