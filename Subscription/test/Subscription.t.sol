// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {Subscription} from "../src/Subscription.sol";
import {ISubscription} from "../src/ISubscription.sol";

contract SubscriptionTest is Test {
    Subscription sub;
    address owner = address(this);
    address provider = makeAddr("provider");
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");

    uint256 constant PRICE  = 0.01 ether;
    uint256 constant PERIOD = 30 days;

    event PlanCreated(uint256 indexed planId, address indexed provider, uint256 price, uint256 period);
    event Subscribed(uint256 indexed planId, address indexed subscriber, uint256 nextPayment);
    event PaymentProcessed(uint256 indexed planId, address indexed subscriber, uint256 amount, uint256 nextPayment);
    event Unsubscribed(uint256 indexed planId, address indexed subscriber);
    event PlanDeactivated(uint256 indexed planId);
    event EarningsWithdrawn(address indexed provider, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        sub = new Subscription();
        vm.deal(alice,    5 ether);
        vm.deal(bob,      5 ether);
        vm.deal(provider, 5 ether);
    }

    function _createPlan() internal returns (uint256 planId) {
        vm.prank(provider);
        planId = sub.createPlan(PRICE, PERIOD);
    }

    function _subscribe(address user) internal returns (uint256 planId) {
        planId = _createPlan();
        vm.prank(user);
        sub.subscribe{value: PRICE}(planId);
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsOwner() public view {
        assertEq(sub.owner(), owner);
    }

    // ─── CreatePlan ────────────────────────────────────────────────────────────

    function test_CreatePlan_Success() public {
        uint256 id = _createPlan();
        assertEq(id, 1);
        assertEq(sub.planCount(), 1);
        (address p, uint256 price, uint256 period, bool active) = sub.getPlan(1);
        assertEq(p, provider);
        assertEq(price, PRICE);
        assertEq(period, PERIOD);
        assertTrue(active);
    }

    function test_CreatePlan_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit PlanCreated(1, provider, PRICE, PERIOD);
        vm.prank(provider);
        sub.createPlan(PRICE, PERIOD);
    }

    function test_CreatePlan_RevertPriceTooLow() public {
        vm.prank(provider);
        vm.expectRevert(ISubscription.AmountTooLow.selector);
        sub.createPlan(1, PERIOD);
    }

    function test_CreatePlan_RevertPeriodTooShort() public {
        vm.prank(provider);
        vm.expectRevert(ISubscription.PeriodTooShort.selector);
        sub.createPlan(PRICE, 1 hours);
    }

    function test_CreatePlan_RevertWhenPaused() public {
        sub.pause();
        vm.prank(provider);
        vm.expectRevert(ISubscription.Paused.selector);
        sub.createPlan(PRICE, PERIOD);
    }

    // ─── Subscribe ─────────────────────────────────────────────────────────────

    function test_Subscribe_Success() public {
        uint256 planId = _subscribe(alice);
        (bool active, uint256 nextPayment) = sub.getSubscription(planId, alice);
        assertTrue(active);
        assertApproxEqAbs(nextPayment, block.timestamp + PERIOD, 1);
    }

    function test_Subscribe_EmitsEvent() public {
        _createPlan();
        vm.expectEmit(true, true, false, false);
        emit Subscribed(1, alice, 0);
        vm.prank(alice);
        sub.subscribe{value: PRICE}(1);
    }

    function test_Subscribe_ProviderEarns() public {
        _subscribe(alice);
        assertEq(sub.earnings(provider), PRICE);
    }

    function test_Subscribe_RevertAlreadySubscribed() public {
        uint256 planId = _subscribe(alice);
        vm.prank(alice);
        vm.expectRevert(ISubscription.AlreadySubscribed.selector);
        sub.subscribe{value: PRICE}(planId);
    }

    function test_Subscribe_RevertWrongPrice() public {
        _createPlan();
        vm.prank(alice);
        vm.expectRevert(ISubscription.InsufficientPayment.selector);
        sub.subscribe{value: PRICE + 1}(1);
    }

    function test_Subscribe_RevertPlanInactive() public {
        _createPlan();
        vm.prank(provider);
        sub.deactivatePlan(1);
        vm.prank(alice);
        vm.expectRevert(ISubscription.PlanInactive.selector);
        sub.subscribe{value: PRICE}(1);
    }

    function test_Subscribe_RevertWhenPaused() public {
        _createPlan();
        sub.pause();
        vm.prank(alice);
        vm.expectRevert(ISubscription.Paused.selector);
        sub.subscribe{value: PRICE}(1);
    }

    // ─── ProcessPayment ────────────────────────────────────────────────────────

    function test_ProcessPayment_Success() public {
        uint256 planId = _subscribe(alice);
        skip(PERIOD + 1);
        uint256 earningsBefore = sub.earnings(provider);
        sub.processPayment{value: PRICE}(planId, alice);
        assertEq(sub.earnings(provider), earningsBefore + PRICE);
    }

    function test_ProcessPayment_EmitsEvent() public {
        uint256 planId = _subscribe(alice);
        skip(PERIOD + 1);
        vm.expectEmit(true, true, false, false);
        emit PaymentProcessed(planId, alice, PRICE, 0);
        sub.processPayment{value: PRICE}(planId, alice);
    }

    function test_ProcessPayment_AdvancesNextPayment() public {
        uint256 planId = _subscribe(alice);
        (, uint256 next1) = sub.getSubscription(planId, alice);
        skip(PERIOD + 1);
        sub.processPayment{value: PRICE}(planId, alice);
        (, uint256 next2) = sub.getSubscription(planId, alice);
        assertEq(next2, next1 + PERIOD);
    }

    function test_ProcessPayment_RevertNotDue() public {
        uint256 planId = _subscribe(alice);
        vm.expectRevert(ISubscription.PaymentNotDue.selector);
        sub.processPayment{value: PRICE}(planId, alice);
    }

    function test_ProcessPayment_RevertNotSubscribed() public {
        _createPlan();
        vm.expectRevert(ISubscription.NotSubscribed.selector);
        sub.processPayment{value: PRICE}(1, alice);
    }

    function test_ProcessPayment_CalledByAnyone() public {
        uint256 planId = _subscribe(alice);
        skip(PERIOD + 1);
        vm.prank(bob); // third party pays
        sub.processPayment{value: PRICE}(planId, alice);
        assertEq(sub.earnings(provider), PRICE * 2);
    }

    // ─── Unsubscribe ───────────────────────────────────────────────────────────

    function test_Unsubscribe_Success() public {
        uint256 planId = _subscribe(alice);
        vm.prank(alice);
        sub.unsubscribe(planId);
        (bool active,) = sub.getSubscription(planId, alice);
        assertFalse(active);
    }

    function test_Unsubscribe_EmitsEvent() public {
        uint256 planId = _subscribe(alice);
        vm.expectEmit(true, true, false, false);
        emit Unsubscribed(planId, alice);
        vm.prank(alice);
        sub.unsubscribe(planId);
    }

    function test_Unsubscribe_RevertNotSubscribed() public {
        _createPlan();
        vm.prank(alice);
        vm.expectRevert(ISubscription.NotSubscribed.selector);
        sub.unsubscribe(1);
    }

    // ─── DeactivatePlan ────────────────────────────────────────────────────────

    function test_DeactivatePlan_Success() public {
        _createPlan();
        vm.prank(provider);
        sub.deactivatePlan(1);
        (,,, bool active) = sub.getPlan(1);
        assertFalse(active);
    }

    function test_DeactivatePlan_EmitsEvent() public {
        _createPlan();
        vm.expectEmit(true, false, false, false);
        emit PlanDeactivated(1);
        vm.prank(provider);
        sub.deactivatePlan(1);
    }

    function test_DeactivatePlan_RevertNotProvider() public {
        _createPlan();
        vm.prank(alice);
        vm.expectRevert(ISubscription.NotOwner.selector);
        sub.deactivatePlan(1);
    }

    // ─── WithdrawEarnings ──────────────────────────────────────────────────────

    function test_WithdrawEarnings_Success() public {
        _subscribe(alice);
        uint256 before = provider.balance;
        vm.prank(provider);
        sub.withdrawEarnings();
        assertEq(provider.balance, before + PRICE);
        assertEq(sub.earnings(provider), 0);
    }

    function test_WithdrawEarnings_EmitsEvent() public {
        _subscribe(alice);
        vm.expectEmit(true, false, false, true);
        emit EarningsWithdrawn(provider, PRICE);
        vm.prank(provider);
        sub.withdrawEarnings();
    }

    function test_WithdrawEarnings_RevertNoEarnings() public {
        vm.prank(provider);
        vm.expectRevert(ISubscription.AmountTooLow.selector);
        sub.withdrawEarnings();
    }

    // ─── Pause / Ownership ─────────────────────────────────────────────────────

    function test_Pause_Unpause() public {
        sub.pause();
        assertTrue(sub.paused());
        sub.unpause();
        assertFalse(sub.paused());
    }

    function test_TwoStepOwnership() public {
        sub.transferOwnership(alice);
        assertEq(sub.pendingOwner(), alice);
        vm.prank(alice);
        sub.acceptOwnership();
        assertEq(sub.owner(), alice);
    }

    function test_TransferOwnership_RevertZeroAddress() public {
        vm.expectRevert(ISubscription.ZeroAddress.selector);
        sub.transferOwnership(address(0));
    }

    function test_AcceptOwnership_RevertNotPending() public {
        sub.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(ISubscription.NotPendingOwner.selector);
        sub.acceptOwnership();
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_CreateAndSubscribe(uint256 price, uint256 period) public {
        price  = bound(price, sub.MIN_PRICE(), 1 ether);
        period = bound(period, sub.MIN_PERIOD(), 365 days);
        vm.prank(provider);
        uint256 planId = sub.createPlan(price, period);
        vm.deal(alice, price);
        vm.prank(alice);
        sub.subscribe{value: price}(planId);
        (bool active,) = sub.getSubscription(planId, alice);
        assertTrue(active);
    }

    // ─── Invariant ─────────────────────────────────────────────────────────────

    function test_Invariant_BalanceEqualsEarnings() public {
        _subscribe(alice);
        vm.prank(bob);
        sub.subscribe{value: PRICE}(1);
        assertEq(address(sub).balance, sub.earnings(provider));
    }

    receive() external payable {}
}
