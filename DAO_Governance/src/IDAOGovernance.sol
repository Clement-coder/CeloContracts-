// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IDAOGovernance
/// @notice Interface for the token-weighted DAO governance contract.
interface IDAOGovernance {
    // ─── Errors ────────────────────────────────────────────────────────────────
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error Paused();
    error Reentrancy();
    error ProposalNotFound();
    error ProposalNotActive();
    error ProposalNotSucceeded();
    error ProposalAlreadyExecuted();
    error ProposalExpired();
    error AlreadyVoted();
    error NoVotingPower();
    error VotingPeriodTooShort();
    error VotingPeriodTooLong();
    error QuorumTooLow();
    error TransferFailed();
    error DescriptionEmpty();

    // ─── Events ────────────────────────────────────────────────────────────────
    event ProposalCreated(uint256 indexed id, address indexed proposer, string description, uint256 votingEnd);
    event Voted(uint256 indexed id, address indexed voter, bool support, uint256 weight);
    event VotingPowerDelegated(address indexed delegator, address indexed oldDelegate, address indexed newDelegate);
    event ProposalExecuted(uint256 indexed id, address indexed executor);
    event ProposalCancelled(uint256 indexed id);
    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);
    event VotingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event EmergencyPauseActivated(uint256 pauseUntil);
    event EmergencyPauseCancelled();
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ─── Functions ─────────────────────────────────────────────────────────────
    function propose(string calldata description, address target, bytes calldata callData) external returns (uint256);
    function vote(uint256 proposalId, bool support) external;
    function execute(uint256 proposalId) external;
    function cancel(uint256 proposalId) external;
    function getProposal(uint256 proposalId) external view returns (address proposer, string memory description, uint256 votingEnd, uint256 forVotes, uint256 againstVotes, bool executed, bool cancelled);
    function hasVoted(uint256 proposalId, address voter) external view returns (bool);
    function state(uint256 proposalId) external view returns (uint8);
    function setQuorum(uint256 newQuorum) external;
    function setVotingPeriod(uint256 newPeriod) external;
    function pause() external;
    function unpause() external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
