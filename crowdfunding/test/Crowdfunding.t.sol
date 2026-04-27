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
    address dave  = makeAddr("dave");  // referrer

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
    event CampaignExtended(uint256 indexed id, uint256 oldDeadline, uint256 newDeadline);
    event ReferralReward(address indexed referrer, address indexed contributor, uint256 reward);
    event ReferralRewardsWithdrawn(address indexed referrer, uint256 amount);
    event ReferralRateUpdated(uint256 oldRate, uint256 newRate);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        cf = new Crowdfunding();
        vm.deal(alice, 10 ether);
        vm.deal(bob,   10 ether);
        vm.deal(carol, 10 ether);
        vm.deal(dave,  10 ether);
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

    function test_Constructor_SetsDefaultReferralRate() public view {
        assertEq(cf.referralRate(), 100);
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

    // ─── ContributeWithReferral ────────────────────────────────────────────────

    function test_ContributeWithReferral_AccruesToReferrer() public {
        _create();
        vm.prank(bob);
        cf.contributeWithReferral{value: 1 ether}(1, dave);
        // 1% of 1 ether = 0.01 ether
        assertEq(cf.referralRewards(dave), 0.01 ether);
    }

    function test_ContributeWithReferral_EmitsReferralReward() public {
        _create();
        uint256 expectedReward = (1 ether * 100) / 10_000; // 1%
        vm.expectEmit(true, true, false, true);
        emit ReferralReward(dave, bob, expectedReward);
        vm.prank(bob);
        cf.contributeWithReferral{value: 1 ether}(1, dave);
    }

    function test_ContributeWithReferral_ZeroAddressReferrer_NoReward() public {
        _create();
        vm.prank(bob);
        cf.contributeWithReferral{value: 1 ether}(1, address(0));
        assertEq(cf.referralRewards(address(0)), 0);
    }

    function test_ContributeWithReferral_SelfReferral_NoReward() public {
        _create();
        vm.prank(bob);
        cf.contributeWithReferral{value: 1 ether}(1, bob);
        assertEq(cf.referralRewards(bob), 0);
    }

    function test_ContributeWithReferral_CreatorReferral_NoReward() public {
        _create();
        vm.prank(bob);
        cf.contributeWithReferral{value: 1 ether}(1, alice);
        assertEq(cf.referralRewards(alice), 0);
    }

    function test_ContributeWithReferral_StillContributes() public {
        _create();
        vm.prank(bob);
        cf.contributeWithReferral{value: CONTRIB}(1, dave);
        assertEq(cf.getContribution(1, bob), CONTRIB);
    }

    // ─── WithdrawReferralRewards ───────────────────────────────────────────────

    function test_WithdrawReferralRewards_Success() public {
        _create();
        vm.prank(bob);
        cf.contributeWithReferral{value: 1 ether}(1, dave);
        uint256 reward = cf.referralRewards(dave);
        uint256 daveBefore = dave.balance;
        vm.prank(dave);
        cf.withdrawReferralRewards();
        assertEq(dave.balance, daveBefore + reward);
        assertEq(cf.referralRewards(dave), 0);
    }

    function test_WithdrawReferralRewards_EmitsEvent() public {
        _create();
        vm.prank(bob);
        cf.contributeWithReferral{value: 1 ether}(1, dave);
        uint256 reward = cf.referralRewards(dave);
        vm.expectEmit(true, false, false, true);
        emit ReferralRewardsWithdrawn(dave, reward);
        vm.prank(dave);
        cf.withdrawReferralRewards();
    }

    function test_WithdrawReferralRewards_RevertNothingToRefund() public {
        vm.prank(dave);
        vm.expectRevert(ICrowdfunding.NothingToRefund.selector);
        cf.withdrawReferralRewards();
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

    // ─── ExtendCampaign ────────────────────────────────────────────────────────

    function test_Extend_Success() public {
        _create();
        (,,,uint256 oldDeadline,,,) = cf.getCampaign(1);
        vm.prank(alice);
        cf.extendCampaign(1, 1 days);
        (,,,uint256 newDeadline,,,) = cf.getCampaign(1);
        assertEq(newDeadline, oldDeadline + 1 days);
    }

    function test_Extend_EmitsEvent() public {
        _create();
        (,,,uint256 oldDeadline,,,) = cf.getCampaign(1);
        vm.expectEmit(true, false, false, true);
        emit CampaignExtended(1, oldDeadline, oldDeadline + 1 days);
        vm.prank(alice);
        cf.extendCampaign(1, 1 days);
    }

    function test_Extend_RevertExceedsMaxDuration() public {
        _create();
        // Campaign has 7 days duration; max is 90 days from start → can add at most 83 days
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.DeadlineTooLong.selector);
        cf.extendCampaign(1, 84 days);
    }

    function test_Extend_RevertNotCreator() public {
        _create();
        vm.prank(bob);
        vm.expectRevert(ICrowdfunding.NotCreator.selector);
        cf.extendCampaign(1, 1 days);
    }

    function test_Extend_RevertCancelled() public {
        _create();
        vm.prank(alice);
        cf.cancelCampaign(1);
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.CampaignAlreadyEnded.selector);
        cf.extendCampaign(1, 1 days);
    }

    function test_Extend_RevertGoalAlreadyMet() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: GOAL}(1);
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.GoalAlreadyMet.selector);
        cf.extendCampaign(1, 1 days);
    }

    function test_Extend_RevertZeroTime() public {
        _create();
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.DeadlineTooShort.selector);
        cf.extendCampaign(1, 0);
    }

    // ─── SetReferralRate ───────────────────────────────────────────────────────

    function test_SetReferralRate_Success() public {
        vm.expectEmit(false, false, false, true);
        emit ReferralRateUpdated(100, 200);
        cf.setReferralRate(200);
        assertEq(cf.referralRate(), 200);
    }

    function test_SetReferralRate_RevertTooHigh() public {
        vm.expectRevert(ICrowdfunding.ReferralRateTooHigh.selector);
        cf.setReferralRate(501);
    }

    function test_SetReferralRate_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.NotOwner.selector);
        cf.setReferralRate(200);
    }

    function test_SetReferralRate_MaxAllowed() public {
        cf.setReferralRate(500);
        assertEq(cf.referralRate(), 500);
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

    function testFuzz_ReferralReward(uint256 amount, uint256 rate) public {
        rate   = bound(rate, 0, cf.MAX_REFERRAL_RATE());
        amount = bound(amount, cf.MIN_CONTRIBUTION(), 5 ether);
        cf.setReferralRate(rate);
        _create();
        vm.deal(bob, amount);
        vm.prank(bob);
        cf.contributeWithReferral{value: amount}(1, dave);
        uint256 expectedReward = (amount * rate) / 10_000;
        assertEq(cf.referralRewards(dave), expectedReward);
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


    // ─── Multiple Campaigns ────────────────────────────────────────────────────

    function test_MultipleCampaigns_IndependentIds() public {
        vm.prank(alice);
        uint256 id1 = cf.createCampaign("Camp 1", "desc", GOAL, DURATION);
        vm.prank(bob);
        uint256 id2 = cf.createCampaign("Camp 2", "desc", GOAL * 2, DURATION);
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(cf.campaignCount(), 2);
    }


    function test_Contribute_AccumulatesForSameContributor() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: 0.3 ether}(1);
        vm.prank(bob);
        cf.contribute{value: 0.2 ether}(1);
        assertEq(cf.getContribution(1, bob), 0.5 ether);
    }


    function test_Create_TitleAtMaxLength_Succeeds() public {
        string memory maxTitle = new string(100);
        bytes memory b = bytes(maxTitle);
        for (uint i = 0; i < 100; i++) b[i] = 'a';
        vm.prank(alice);
        uint256 id = cf.createCampaign(string(b), "desc", GOAL, DURATION);
        assertEq(id, 1);
    }


    function test_Create_TitleOverMaxLength_Reverts() public {
        bytes memory b = new bytes(101);
        for (uint i = 0; i < 101; i++) b[i] = 'a';
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.TitleTooLong.selector);
        cf.createCampaign(string(b), "desc", GOAL, DURATION);
    }


    function test_Contribute_AtExactMinimum_Succeeds() public {
        _create();
        uint256 minContrib = cf.MIN_CONTRIBUTION();
        vm.deal(bob, minContrib);
        vm.prank(bob);
        cf.contribute{value: minContrib}(1);
        assertEq(cf.getContribution(1, bob), minContrib);
    }


    function test_Create_AtMinGoal_Succeeds() public {
        vm.prank(alice);
        uint256 id = cf.createCampaign("title", "desc", cf.MIN_GOAL(), DURATION);
        assertEq(id, 1);
    }


    function test_Create_AtMaxDuration_Succeeds() public {
        vm.prank(alice);
        uint256 id = cf.createCampaign("title", "desc", GOAL, cf.MAX_DURATION());
        assertEq(id, 1);
    }


    function test_Create_AtMinDuration_Succeeds() public {
        vm.prank(alice);
        uint256 id = cf.createCampaign("title", "desc", GOAL, cf.MIN_DURATION());
        assertEq(id, 1);
    }


    function test_Refund_MultipleContributors_EachGetsOwn() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: 0.3 ether}(1);
        vm.prank(carol);
        cf.contribute{value: 0.4 ether}(1);
        skip(DURATION + 1);
        uint256 bobBefore = bob.balance;
        uint256 carolBefore = carol.balance;
        vm.prank(bob);
        cf.refund(1);
        vm.prank(carol);
        cf.refund(1);
        assertEq(bob.balance, bobBefore + 0.3 ether);
        assertEq(carol.balance, carolBefore + 0.4 ether);
    }


    function test_Extend_CanExtendUpToMaxDuration() public {
        _create();
        // Campaign has 7 days; max is 90 days from start → can add exactly 83 days
        vm.prank(alice);
        cf.extendCampaign(1, 83 days);
        (,,,uint256 newDeadline,,,) = cf.getCampaign(1);
        assertEq(newDeadline, block.timestamp + 90 days);
    }


    function test_Cancel_AfterContribution_ContributorCanRefund() public {
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


    function test_ClaimFunds_RevertCancelled() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: GOAL}(1);
        vm.prank(alice);
        cf.cancelCampaign(1);
        skip(DURATION + 1);
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.CampaignAlreadyEnded.selector);
        cf.claimFunds(1);
    }


    function test_Contribute_ZeroCampaignId_Reverts() public {
        vm.prank(bob);
        vm.expectRevert(ICrowdfunding.InvalidCampaign.selector);
        cf.contribute{value: CONTRIB}(0);
    }


    function test_GetContribution_NonExistentCampaign_ReturnsZero() public view {
        assertEq(cf.getContribution(999, bob), 0);
    }


    function test_Unpause_RevertNotOwner() public {
        cf.pause();
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.NotOwner.selector);
        cf.unpause();
    }


    function test_ContributeWithReferral_MultipleReferrals_Accumulate() public {
        _create();
        vm.prank(bob);
        cf.contributeWithReferral{value: 1 ether}(1, dave);
        vm.prank(carol);
        cf.contributeWithReferral{value: 1 ether}(1, dave);
        // 1% of 2 ether = 0.02 ether
        assertEq(cf.referralRewards(dave), 0.02 ether);
    }


    function test_SetReferralRate_Zero_DisablesReferrals() public {
        cf.setReferralRate(0);
        _create();
        vm.prank(bob);
        cf.contributeWithReferral{value: 1 ether}(1, dave);
        assertEq(cf.referralRewards(dave), 0);
    }


    function test_Extend_AfterDeadlinePassed_Reverts() public {
        _create();
        skip(DURATION + 1);
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.CampaignAlreadyEnded.selector);
        cf.extendCampaign(1, 1 days);
    }


    function test_Extend_AlreadyClaimed_Reverts() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: GOAL}(1);
        skip(DURATION + 1);
        vm.prank(alice);
        cf.claimFunds(1);
        vm.prank(alice);
        vm.expectRevert(ICrowdfunding.AlreadyClaimed.selector);
        cf.extendCampaign(1, 1 days);
    }


    function test_Contribute_ExactlyAtDeadline_Reverts() public {
        _create();
        (,,,uint256 deadline,,,) = cf.getCampaign(1);
        vm.warp(deadline);
        vm.prank(bob);
        vm.expectRevert(ICrowdfunding.CampaignAlreadyEnded.selector);
        cf.contribute{value: CONTRIB}(1);
    }


    function test_ClaimFunds_ExactlyAtDeadline_Succeeds() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: GOAL}(1);
        (,,,uint256 deadline,,,) = cf.getCampaign(1);
        vm.warp(deadline);
        vm.prank(alice);
        cf.claimFunds(1);
        (,,,,,bool claimed,) = cf.getCampaign(1);
        assertTrue(claimed);
    }


    function test_Refund_ExactlyAtDeadline_Succeeds() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: 0.5 ether}(1);
        (,,,uint256 deadline,,,) = cf.getCampaign(1);
        vm.warp(deadline);
        vm.prank(bob);
        cf.refund(1);
        assertEq(cf.getContribution(1, bob), 0);
    }


    function test_ContributeWithReferral_AfterDeadline_Reverts() public {
        _create();
        skip(DURATION + 1);
        vm.prank(bob);
        vm.expectRevert(ICrowdfunding.CampaignAlreadyEnded.selector);
        cf.contributeWithReferral{value: CONTRIB}(1, dave);
    }


    function test_ContributeWithReferral_WhenPaused_Reverts() public {
        _create();
        cf.pause();
        vm.prank(bob);
        vm.expectRevert(ICrowdfunding.Paused.selector);
        cf.contributeWithReferral{value: CONTRIB}(1, dave);
    }


    function test_ContributeWithReferral_TooLow_Reverts() public {
        _create();
        vm.prank(bob);
        vm.expectRevert(ICrowdfunding.ContributionTooLow.selector);
        cf.contributeWithReferral{value: 1}(1, dave);
    }


    function test_ContributeWithReferral_InvalidCampaign_Reverts() public {
        vm.prank(bob);
        vm.expectRevert(ICrowdfunding.InvalidCampaign.selector);
        cf.contributeWithReferral{value: CONTRIB}(99, dave);
    }


    function test_ContributeWithReferral_CancelledCampaign_Reverts() public {
        _create();
        vm.prank(alice);
        cf.cancelCampaign(1);
        vm.prank(bob);
        vm.expectRevert(ICrowdfunding.CampaignAlreadyEnded.selector);
        cf.contributeWithReferral{value: CONTRIB}(1, dave);
    }


    function test_WithdrawReferralRewards_ClearsBalance() public {
        _create();
        vm.prank(bob);
        cf.contributeWithReferral{value: 1 ether}(1, dave);
        vm.prank(dave);
        cf.withdrawReferralRewards();
        assertEq(cf.referralRewards(dave), 0);
    }


    function test_Invariant_ContractBalanceNeverNegative() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: 0.5 ether}(1);
        skip(DURATION + 1);
        vm.prank(bob);
        cf.refund(1);
        assertEq(address(cf).balance, 0);
    }


    function test_Invariant_ClaimedFundsReduceBalance() public {
        _create();
        vm.prank(bob);
        cf.contribute{value: GOAL}(1);
        skip(DURATION + 1);
        vm.prank(alice);
        cf.claimFunds(1);
        assertEq(address(cf).balance, 0);
    }


    function test_Invariant_ReferralRewardsNotExceedContributions() public {
        _create();
        vm.prank(bob);
        cf.contributeWithReferral{value: 1 ether}(1, dave);
        uint256 reward = cf.referralRewards(dave);
        // reward (1%) must be <= contribution
        assertLe(reward, 1 ether);
    }


    function test_Fuzz_ExtendCampaign(uint256 extra) public {
        _create();
        // max additional = MAX_DURATION - DURATION = 83 days
        extra = bound(extra, 1, 83 days);
        (,,,uint256 oldDeadline,,,) = cf.getCampaign(1);
        vm.prank(alice);
        cf.extendCampaign(1, extra);
        (,,,uint256 newDeadline,,,) = cf.getCampaign(1);
        assertEq(newDeadline, oldDeadline + extra);
    }


    function test_Fuzz_SetReferralRate(uint256 rate) public {
        rate = bound(rate, 0, cf.MAX_REFERRAL_RATE());
        cf.setReferralRate(rate);
        assertEq(cf.referralRate(), rate);
    }


    function test_Fuzz_SetReferralRate_AboveMax_Reverts(uint256 rate) public {
        rate = bound(rate, cf.MAX_REFERRAL_RATE() + 1, type(uint256).max);
        vm.expectRevert(ICrowdfunding.ReferralRateTooHigh.selector);
        cf.setReferralRate(rate);
    }


    function test_Fuzz_Refund(uint256 amount) public {
        _create();
        amount = bound(amount, cf.MIN_CONTRIBUTION(), GOAL - 1);
        vm.deal(bob, amount);
        vm.prank(bob);
        cf.contribute{value: amount}(1);
        skip(DURATION + 1);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        cf.refund(1);
        assertEq(bob.balance, bobBefore + amount);
    }


    function test_Fuzz_ClaimFunds(uint256 amount) public {
        amount = bound(amount, GOAL, 10 ether);
        vm.prank(alice);
        cf.createCampaign("title", "desc", GOAL, DURATION);
        vm.deal(bob, amount);
        vm.prank(bob);
        cf.contribute{value: amount}(1);
        skip(DURATION + 1);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        cf.claimFunds(1);
        assertEq(alice.balance, aliceBefore + amount);
    }


    function test_MultipleCampaigns_ContributionsIsolated() public {
        vm.prank(alice);
        cf.createCampaign("Camp 1", "desc", GOAL, DURATION);
        vm.prank(alice);
        cf.createCampaign("Camp 2", "desc", GOAL, DURATION);
        vm.prank(bob);
        cf.contribute{value: CONTRIB}(1);
        assertEq(cf.getContribution(1, bob), CONTRIB);
        assertEq(cf.getContribution(2, bob), 0);
    }


    function test_MultipleCampaigns_CancelOneDoesNotAffectOther() public {
        vm.prank(alice);
        cf.createCampaign("Camp 1", "desc", GOAL, DURATION);
        vm.prank(alice);
        cf.createCampaign("Camp 2", "desc", GOAL, DURATION);
        vm.prank(alice);
        cf.cancelCampaign(1);
        (,,,,,, bool cancelled2) = cf.getCampaign(2);
        assertFalse(cancelled2);
    }

    // ─── Receive ───────────────────────────────────────────────────────────────

    function test_Receive_RevertDirectSend() public {
        // Direct CELO send hits receive() which reverts with TransferFailed
        (bool ok, bytes memory data) = address(cf).call{value: 1 ether}("");
        assertFalse(ok);
        // Verify the revert reason is TransferFailed
        bytes4 selector = bytes4(data);
        assertEq(selector, ICrowdfunding.TransferFailed.selector);
    }

    receive() external payable {}
}
