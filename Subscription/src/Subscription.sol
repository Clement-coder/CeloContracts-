// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ISubscription} from "./ISubscription.sol";

/// @title Subscription
/// @notice Recurring CELO subscription platform. Providers create plans with a
///         price and billing period. Subscribers pay upfront for the first period
///         and anyone can trigger subsequent payments when due.
///         Providers withdraw accumulated earnings via pull-payment.
/// @dev    Production-grade: reentrancy guard, pause, two-step ownership,
///         custom errors, full NatSpec, locked pragma, optimizer config.
contract Subscription is ISubscription {

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Minimum subscription price: 0.001 CELO.
    uint256 public constant MIN_PRICE = 0.001 ether;

    /// @notice Minimum billing period: 1 day.
    uint256 public constant MIN_PERIOD = 1 days;

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice Current contract owner.
    address public owner;

    /// @notice Pending owner in two-step transfer.
    address public pendingOwner;

    /// @notice Whether the contract is paused.
    bool public paused;

    /// @notice Reentrancy lock.
    bool private _locked;

    /// @notice Total plans created.
    uint256 public planCount;

    /// @dev Subscription plan record.
    struct Plan {
        /// @dev Provider address that receives payments.
        address provider;
        /// @dev Price per billing period in wei.
        uint256 price;
        /// @dev Billing period in seconds.
        uint256 period;
        /// @dev Whether the plan is accepting new subscribers.
        bool active;
    }

    /// @dev Subscriber record per plan.
    struct Sub {
        /// @dev Whether the subscription is active.
        bool active;
        /// @dev Timestamp when next payment is due.
        uint256 nextPayment;
    }

    /// @notice Plans by ID (1-indexed).
    mapping(uint256 => Plan) public plans;

    /// @notice subscriptions[planId][subscriber] => Sub.
    mapping(uint256 => mapping(address => Sub)) public subscriptions;

    /// @notice Pending earnings per provider (pull-payment).
    mapping(address => uint256) public earnings;

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    modifier planExists(uint256 planId) {
        if (planId == 0 || planId > planCount) revert PlanNotFound();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @notice Deploy the subscription contract. Deployer becomes owner.
    constructor() {
        owner = msg.sender;
    }

    // ─── Provider Actions ──────────────────────────────────────────────────────

    /// @notice Create a new subscription plan.
    /// @param price  Price per billing period in wei. Must be >= MIN_PRICE.
    /// @param period Billing period in seconds. Must be >= MIN_PERIOD.
    /// @return planId The new plan ID.
    /// @dev Emits {PlanCreated}.
    function createPlan(uint256 price, uint256 period)
        external override whenNotPaused returns (uint256)
    {
        if (price < MIN_PRICE) revert AmountTooLow();
        if (period < MIN_PERIOD) revert PeriodTooShort();

        uint256 planId = ++planCount;
        plans[planId] = Plan({provider: msg.sender, price: price, period: period, active: true});

        emit PlanCreated(planId, msg.sender, price, period);
        return planId;
    }

    /// @notice Deactivate a plan. Existing subscribers keep access until they unsubscribe.
    /// @param planId Plan ID to deactivate.
    /// @dev Only callable by the plan provider. Emits {PlanDeactivated}.
    function deactivatePlan(uint256 planId) external override planExists(planId) {
        Plan storage p = plans[planId];
        if (msg.sender != p.provider) revert NotOwner();
        p.active = false;
        emit PlanDeactivated(planId);
    }

    /// @notice Provider withdraws accumulated earnings.
    /// @dev Emits {EarningsWithdrawn}.
    function withdrawEarnings() external override nonReentrant {
        uint256 amount = earnings[msg.sender];
        if (amount == 0) revert AmountTooLow();
        earnings[msg.sender] = 0;
        emit EarningsWithdrawn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ─── Subscriber Actions ────────────────────────────────────────────────────

    /// @notice Subscribe to a plan. Pays the first period upfront.
    /// @param planId Plan ID to subscribe to.
    /// @dev   Send exactly plan.price as msg.value. Emits {Subscribed}.
    function subscribe(uint256 planId)
        external payable override whenNotPaused nonReentrant planExists(planId)
    {
        Plan storage p = plans[planId];
        if (!p.active) revert PlanInactive();
        if (subscriptions[planId][msg.sender].active) revert AlreadySubscribed();
        if (msg.value != p.price) revert InsufficientPayment();

        uint256 nextPayment = block.timestamp + p.period;
        subscriptions[planId][msg.sender] = Sub({active: true, nextPayment: nextPayment});
        earnings[p.provider] += msg.value;

        emit Subscribed(planId, msg.sender, nextPayment);
    }

    /// @notice Process a due payment for a subscriber. Callable by anyone.
    /// @param planId     Plan ID.
    /// @param subscriber Address of the subscriber to charge.
    /// @dev   Subscriber must have sent CELO to this contract or caller pays.
    ///        Actually: caller sends the payment on behalf of subscriber.
    ///        Emits {PaymentProcessed}.
    function processPayment(uint256 planId, address subscriber)
        external payable override nonReentrant planExists(planId)
    {
        Plan storage p = plans[planId];
        Sub storage s = subscriptions[planId][subscriber];
        if (!s.active) revert NotSubscribed();
        if (block.timestamp < s.nextPayment) revert PaymentNotDue();
        if (msg.value != p.price) revert InsufficientPayment();

        s.nextPayment += p.period;
        earnings[p.provider] += msg.value;

        emit PaymentProcessed(planId, subscriber, msg.value, s.nextPayment);
    }

    /// @notice Cancel your subscription to a plan.
    /// @param planId Plan ID to unsubscribe from.
    /// @dev Emits {Unsubscribed}.
    function unsubscribe(uint256 planId)
        external override planExists(planId)
    {
        Sub storage s = subscriptions[planId][msg.sender];
        if (!s.active) revert NotSubscribed();
        s.active = false;
        s.nextPayment = 0;
        emit Unsubscribed(planId, msg.sender);
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Returns details of a subscription plan.
    /// @param planId Plan ID to query.
    /// @return provider Address of the plan provider.
    /// @return price    Price per period in wei.
    /// @return period   Billing period in seconds.
    /// @return active   Whether the plan is active.
    function getPlan(uint256 planId)
        external view override planExists(planId)
        returns (address provider, uint256 price, uint256 period, bool active)
    {
        Plan storage p = plans[planId];
        return (p.provider, p.price, p.period, p.active);
    }

    /// @notice Returns a subscriber's subscription status.
    /// @param planId     Plan ID.
    /// @param subscriber Address to query.
    /// @return active      Whether the subscription is active.
    /// @return nextPayment Timestamp when next payment is due.
    function getSubscription(uint256 planId, address subscriber)
        external view override returns (bool active, uint256 nextPayment)
    {
        Sub storage s = subscriptions[planId][subscriber];
        return (s.active, s.nextPayment);
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Pause the contract.
    function pause() external override onlyOwner {
        paused = true;
        emit ContractPaused(msg.sender);
    }

    /// @notice Unpause the contract.
    function unpause() external override onlyOwner {
        paused = false;
        emit ContractUnpaused(msg.sender);
    }

    /// @notice Initiate two-step ownership transfer.
    function transferOwnership(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Accept ownership.
    function acceptOwnership() external override {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}
