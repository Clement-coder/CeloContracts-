// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {Crowdfunding} from "../src/Crowdfunding.sol";
import {ICrowdfunding} from "../src/ICrowdfunding.sol";

contract CrowdfundingTest is Test {
    Crowdfunding cf;
    address owner = address(this);
    address alice = makeAddr("alice"); // creator
    address bob   = makeAddr("bob");   // contributor
    address carol = makeAddr("carol"); // contributor

    uint256 constant GOAL     = 1 ether;
    uint256 constant DURATION = 7 days;
    uint256 constant CONTRIB  = 0.5 ether;

    // Mirror events
    event CampaignCreated(uint256 indexed id, address indexed creator, uint256 goal, uint256 deadline, string title);
    event Contributed(uint256 indexed id, address indexed contributor, uint256 amount, uint256 totalRaised);
    event GoalReached(uint256 indexed id, uint256 totalRaised);
    event FundsClaimed(uint256 indexed id, address indexed creator, uint256 amount);
    event Refunded(uint256 indexed id, address indexed contributor, uint256 amount);
    event CampaignCancelled(uint256 indexed id, address indexed creator);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        cf = new Crowdfunding();
        vm.deal(alice, 10 ether);
        vm.deal(bob,   10 ether);
        vm.deal(carol, 10 ether);
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────

    function _create() internal returns (uint256 id) {
        vm.prank(alice);
        id = cf.createCampaign("Build dApp", "A great dApp", GOAL, DURATION);
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsOwner() public view {
        assertEq(cf.owner(), owner);
    }

    // ─── CreateCampaign ────────────────────────────────────────────────────────

    function test_Create_Success() public {
        uint256 id = _create();
        assertEq(id, 1);
        assertEq(cf.campaignCount(), 1);
        (address creator,,uint256 goal,,,, ) = cf.getCampaign(1);
        assertEq(creator, alice);
        assertEq(goal, GOAL);
    }

    function test_Create_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit CampaignCreated(1, alice, GOAL, 0, "Build dApp");
        vm.prank(alice);
        cf.createCampaign("Build dApp", "desc", GOAL, DURATION);
    }

    function test_Create_RevertGoalTooLow() public {
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.GoalTooLow.selector);
        cf.createCampaign("title", "desc", 1, DURATION);
    }

    function test_Create_RevertDeadlineTooShort() public {
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.DeadlineTooShort.selector);
        cf.createCampaign("title", "desc", GOAL, 1 hours);
    }

    function test_Create_RevertDeadlineTooLong() public {
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.DeadlineTooLong.selector);
        cf.createCampaign("title", "desc", GOAL, 91 days);
    }

    function test_Create_RevertEmptyTitle() public {
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.TitleTooLong.selector);
        cf.createCampaign("", "desc", GOAL, DURATION);
    }

    function test_Create_RevertWhenPaused() public {
        cf.pause();
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.Paused.selector);
        cf.createCampaign("title", "desc", GOAL, DURATION);
    }

    // ─── Contribute ────────────────────────────────────────────────────────────

    function test_Contribute_Success() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: CONTRIB}(1);
        assertEq(cf.getContribution(1, bob), CONTRIB);
        (,,,,uint256 raised,,) = cf.getCampaign(1);
        assertEq(raised, CONTRIB);
    }

    function test_Contribute_EmitsEvent() public {
        _create();
        vm.expectEmit(true, true, false, true);
        emit Contributed(1, bob, CONTRIB, CONTRIB);
        vm.prank(bob);
        cf.contribute{value: CONTRIB}(1);
    }

    function test_Contribute_EmitsGoalReached() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: 0.5 ether}(1);
        vm.expectEmit(true, false, false, true);
        emit GoalReached(1, GOAL);
        vm.prank(carol);
        cf.contribute{value: 0.5 ether}(1);
    }

    function test_Contribute_MultipleContributors() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: 0.3 ether}(1);
        vm.prank(carol);
        cf.contribute{value: 0.4 ether}(1);
        (,,,,uint256 raised,,) = cf.getCampaign(1);
        assertEq(raised, 0.7 ether);
    }

    function test_Contribute_RevertAfterDeadline() public {
        _create();
        skip(DURATION + 1);
        vm.prank(bob);
        vm.expectRevert(ICrowdfunding.CampaignAlreadyEnded.selector);
        cf.contribute{value: CONTRIB}(1);
    }

    function test_Contribute_RevertTooLow() public {
        _create();
        vm.prank(bob);
        vm.expectRevert(ICrowdfunding.ContributionTooLow.selector);
        cf.contribute{value: 1}(1);
    }

    function test_Contribute_RevertInvalidCampaign() public {
        vm.prank(bob);
        vm.expectRevert(ICrowdfunding.InvalidCampaign.selector);
        cf.contribute{value: CONTRIB}(99);
    }

    function test_Contribute_RevertCancelled() public {
        _create();
        vm.prank(alice);
        cf.cancelCampaign(1);
        vm.prank(bob);
        vm.expectRevert(ICrowdfunding.CampaignAlreadyEnded.selector);
        cf.contribute{value: CONTRIB}(1);
    }

    function test_Contribute_RevertWhenPaused() public {
        _create();
        cf.pause();
        vm.prank(bob);
        vm.expectRevert(ICrowdfunding.Paused.selector);
        cf.contribute{value: CONTRIB}(1);
    }

    // ─── ClaimFunds ────────────────────────────────────────────────────────────

    function test_ClaimFunds_Success() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: GOAL}(1);
        skip(DURATION + 1);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        cf.claimFunds(1);
        assertEq(alice.balance, aliceBefore + GOAL);
    }

    function test_ClaimFunds_EmitsEvent() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: GOAL}(1);
        skip(DURATION + 1);
        vm.expectEmit(true, true, false, true);
        emit FundsClaimed(1, alice, GOAL);
        vm.prank(alice);
        cf.claimFunds(1);
    }

    function test_ClaimFunds_RevertGoalNotMet() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: 0.5 ether}(1);
        skip(DURATION + 1);
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.GoalNotMet.selector);
        cf.claimFunds(1);
    }

    function test_ClaimFunds_RevertBeforeDeadline() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: GOAL}(1);
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.CampaignNotEnded.selector);
        cf.claimFunds(1);
    }

    function test_ClaimFunds_RevertAlreadyClaimed() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: GOAL}(1);
        skip(DURATION + 1);
        vm.prank(alice);
        cf.claimFunds(1);
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.AlreadyClaimed.selector);
        cf.claimFunds(1);
    }

    function test_ClaimFunds_RevertNotCreator() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: GOAL}(1);
        skip(DURATION + 1);
        vm.prank(bob);
        vm.expectRevert(ICrowdfunding.NotCreator.selector);
        cf.claimFunds(1);
    }

    // ─── Refund ────────────────────────────────────────────────────────────────

    function test_Refund_FailedCampaign() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: 0.5 ether}(1);
        skip(DURATION + 1);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        cf.refund(1);
        assertEq(bob.balance, bobBefore + 0.5 ether);
    }

    function test_Refund_CancelledCampaign() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: CONTRIB}(1);
        vm.prank(alice);
        cf.cancelCampaign(1);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        cf.refund(1);
        assertEq(bob.balance, bobBefore + CONTRIB);
    }

    function test_Refund_EmitsEvent() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: CONTRIB}(1);
        skip(DURATION + 1);
        vm.expectEmit(true, true, false, true);
        emit Refunded(1, bob, CONTRIB);
        vm.prank(bob);
        cf.refund(1);
    }

    function test_Refund_RevertGoalMet() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: GOAL}(1);
        skip(DURATION + 1);
        vm.prank(bob);
        vm.expectRevert(ICrowdfunding.GoalAlreadyMet.selector);
        cf.refund(1);
    }

    function test_Refund_RevertNothingToRefund() public {
        _create();
        skip(DURATION + 1);
        vm.prank(bob);
        vm.expectRevert(ICrowdfunding.NothingToRefund.selector);
        cf.refund(1);
    }

    function test_Refund_ClearsContribution() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: CONTRIB}(1);
        skip(DURATION + 1);
        vm.prank(bob);
        cf.refund(1);
        assertEq(cf.getContribution(1, bob), 0);
    }

    // ─── CancelCampaign ────────────────────────────────────────────────────────

    function test_Cancel_Success() public {
        _create();
        vm.prank(alice);
        cf.cancelCampaign(1);
        (,,,,,, bool cancelled) = cf.getCampaign(1);
        assertTrue(cancelled);
    }

    function test_Cancel_EmitsEvent() public {
        _create();
        vm.expectEmit(true, true, false, false);
        emit CampaignCancelled(1, alice);
        vm.prank(alice);
        cf.cancelCampaign(1);
    }

    function test_Cancel_RevertNotCreator() public {
        _create();
        vm.prank(bob);
        vm.expectRevert(ICrowdfunding.NotCreator.selector);
        cf.cancelCampaign(1);
    }

    function test_Cancel_RevertAfterDeadline() public {
        _create();
        skip(DURATION + 1);
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.CampaignAlreadyEnded.selector);
        cf.cancelCampaign(1);
    }

    function test_Cancel_RevertAlreadyCancelled() public {
        _create();
        vm.prank(alice);
        cf.cancelCampaign(1);
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.CampaignAlreadyEnded.selector);
        cf.cancelCampaign(1);
    }

    // ─── Pause ─────────────────────────────────────────────────────────────────

    function test_Pause_Unpause() public {
        cf.pause();
        assertTrue(cf.paused());
        cf.unpause();
        assertFalse(cf.paused());
    }

    function test_Pause_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.NotOwner.selector);
        cf.pause();
    }

    // ─── Ownership ─────────────────────────────────────────────────────────────

    function test_TwoStepOwnership() public {
        cf.transferOwnership(alice);
        assertEq(cf.pendingOwner(), alice);
        vm.prank(alice);
        cf.acceptOwnership();
        assertEq(cf.owner(), alice);
        assertEq(cf.pendingOwner(), address(0));
    }

    function test_TransferOwnership_RevertZeroAddress() public {
        vm.expectRevert(ICrowdfunding.ZeroAddress.selector);
        cf.transferOwnership(address(0));
    }

    function test_AcceptOwnership_RevertNotPending() public {
        cf.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(ICrowdfunding.NotPendingOwner.selector);
        cf.acceptOwnership();
    }

    function test_TransferOwnership_EmitsEvents() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferStarted(owner, alice);
        cf.transferOwnership(alice);
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, alice);
        vm.prank(alice);
        cf.acceptOwnership();
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_Contribute(uint256 amount) public {
        _create();
        amount = bound(amount, cf.MIN_CONTRIBUTION(), 5 ether);
        vm.deal(bob, amount);
        vm.prank(bob);
        cf.contribute{value: amount}(1);
        assertEq(cf.getContribution(1, bob), amount);
    }

    function testFuzz_CreateCampaign(uint256 goal, uint256 duration) public {
        goal     = bound(goal, cf.MIN_GOAL(), 100 ether);
        duration = bound(duration, cf.MIN_DURATION(), cf.MAX_DURATION());
        vm.prank(alice);
        uint256 id = cf.createCampaign("title", "desc", goal, duration);
        assertEq(id, 1);
    }

    // ─── Invariant ─────────────────────────────────────────────────────────────

    function test_Invariant_BalanceEqualsRaised() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: 0.3 ether}(1);
        vm.prank(carol);
        cf.contribute{value: 0.4 ether}(1);
        (,,,,uint256 raised,,) = cf.getCampaign(1);
        assertEq(address(cf).balance, raised);
    }

    receive() external payable {}
}
