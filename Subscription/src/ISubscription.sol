// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title ISubscription
/// @notice Interface for the recurring CELO subscription contract.
interface ISubscription {
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error Paused();
    error Reentrancy();
    error PlanNotFound();
    error AlreadySubscribed();
    error NotSubscribed();
    error InsufficientPayment();
    error PaymentNotDue();
    error PlanInactive();
    error AmountTooLow();
    error PeriodTooShort();
    error TransferFailed();

    event PlanCreated(uint256 indexed planId, address indexed provider, uint256 price, uint256 period);
    event PlanDeactivated(uint256 indexed planId);
    event Subscribed(uint256 indexed planId, address indexed subscriber, uint256 nextPayment);
    event PaymentProcessed(uint256 indexed planId, address indexed subscriber, uint256 amount, uint256 nextPayment);
    event Unsubscribed(uint256 indexed planId, address indexed subscriber);
    event EarningsWithdrawn(address indexed provider, uint256 amount);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function createPlan(uint256 price, uint256 period) external returns (uint256);
    function subscribe(uint256 planId) external payable;
    function processPayment(uint256 planId, address subscriber) external payable;
    function unsubscribe(uint256 planId) external;
    function deactivatePlan(uint256 planId) external;
    function withdrawEarnings() external;
    function getPlan(uint256 planId) external view returns (address provider, uint256 price, uint256 period, bool active);
    function getSubscription(uint256 planId, address subscriber) external view returns (bool active, uint256 nextPayment);
    function pause() external;
    function unpause() external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
