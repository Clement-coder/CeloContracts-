// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IEscrow
/// @notice Interface for the two-party CELO escrow contract.
interface IEscrow {
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error Paused();
    error Reentrancy();
    error EscrowNotFound();
    error NotDepositor();
    error NotBeneficiary();
    error NotParty();
    error AlreadyReleased();
    error AlreadyRefunded();
    error AlreadyDisputed();
    error NotDisputed();
    error AmountTooLow();
    error DeadlineTooShort();
    error DeadlineTooLong();
    error DeadlineNotPassed();
    error DeadlinePassed();
    error TransferFailed();
    error FeeTooHigh();

    event EscrowCreated(uint256 indexed id, address indexed depositor, address indexed beneficiary, uint256 amount, uint256 deadline);
    event EscrowReleased(uint256 indexed id, address indexed beneficiary, uint256 amount);
    event EscrowPartiallyReleased(uint256 indexed id, address indexed beneficiary, uint256 amount, uint256 remaining);
    event EscrowRefunded(uint256 indexed id, address indexed depositor, uint256 amount);
    event EscrowDisputed(uint256 indexed id, address indexed raisedBy);
    event DisputeResolved(uint256 indexed id, address indexed winner, uint256 amount);
    event EscrowExtended(uint256 indexed id, uint256 oldDeadline, uint256 newDeadline);
    event FeeWithdrawn(address indexed to, uint256 amount);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function createEscrow(address beneficiary, uint256 deadline) external payable returns (uint256);
    function release(uint256 id) external;
    function refund(uint256 id) external;
    function dispute(uint256 id) external;
    function resolveDispute(uint256 id, bool releaseToBeneficiary) external;
    function claimExpired(uint256 id) external;
    function getEscrow(uint256 id) external view returns (address depositor, address beneficiary, uint256 amount, uint256 deadline, uint8 status);
    function withdrawFees() external;
    function setFee(uint256 newFeeBps) external;
    function pause() external;
    function unpause() external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
