// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {DAOGovernance} from "../src/DAOGovernance.sol";
import {IDAOGovernance} from "../src/IDAOGovernance.sol";

/// @dev Minimal ERC20 mock for testing.
contract MockToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; totalSupply += amount; }
}

/// @dev Simple target contract for execution tests.
contract Target {
    uint256 public value;
    function setValue(uint256 v) external { value = v; }
}

contract DAOGovernanceTest is Test {
    DAOGovernance dao;
    MockToken token;
    Target target;

    address owner = address(this);
    address alice = makeAddr("alice"); // proposer + voter
    address bob   = makeAddr("bob");   // voter
    address carol = makeAddr("carol"); // voter

    uint256 constant QUORUM  = 100 ether;
    uint256 constant PERIOD  = 3 days;

    // Mirror events
    event ProposalCreated(uint256 indexed id, address indexed proposer, string description, uint256 votingEnd);
    event Voted(uint256 indexed id, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed id, address indexed executor);
    event ProposalCancelled(uint256 indexed id);
    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);
    event VotingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        token  = new MockToken();
        target = new Target();
        dao    = new DAOGovernance(address(token), QUORUM, PERIOD);
        token.mint(alice, 200 ether);
        token.mint(bob,   100 ether);
        token.mint(carol,  50 ether);
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────

    function _propose() internal returns (uint256 id) {
        vm.prank(alice);
        id = dao.propose("Upgrade protocol", address(0), "");
    }

    function _proposeWithTarget() internal returns (uint256 id) {
        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);
        vm.prank(alice);
        id = dao.propose("Set value to 42", address(target), data);
    }

    function _passProposal() internal returns (uint256 id) {
        id = _propose();
        vm.prank(alice); dao.vote(id, true); // 200 ether FOR
        vm.prank(bob);   dao.vote(id, true); // 100 ether FOR → total 300 >= quorum 100
        skip(PERIOD + 1);
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsParams() public view {
        assertEq(dao.token(), address(token));
        assertEq(dao.quorum(), QUORUM);
        assertEq(dao.votingPeriod(), PERIOD);
        assertEq(dao.owner(), owner);
    }

    function test_Constructor_RevertZeroToken() public {
        vm.expectRevert(IDAOGovernance.ZeroAddress.selector);
        new DAOGovernance(address(0), QUORUM, PERIOD);
    }

    function test_Constructor_RevertZeroQuorum() public {
        vm.expectRevert(IDAOGovernance.QuorumTooLow.selector);
        new DAOGovernance(address(token), 0, PERIOD);
    }

    function test_Constructor_RevertPeriodTooShort() public {
        vm.expectRevert(IDAOGovernance.VotingPeriodTooShort.selector);
        new DAOGovernance(address(token), QUORUM, 1 hours);
    }

    function test_Constructor_RevertPeriodTooLong() public {
        vm.expectRevert(IDAOGovernance.VotingPeriodTooLong.selector);
        new DAOGovernance(address(token), QUORUM, 31 days);
    }

    // ─── Propose ───────────────────────────────────────────────────────────────

    function test_Propose_Success() public {
        uint256 id = _propose();
        assertEq(id, 1);
        assertEq(dao.proposalCount(), 1);
    }

    function test_Propose_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit ProposalCreated(1, alice, "Upgrade protocol", 0);
        vm.prank(alice);
        dao.propose("Upgrade protocol", address(0), "");
    }

    function test_Propose_RevertNoVotingPower() public {
        vm.prank(makeAddr("nobody"));
        vm.expectRevert(IDAOGovernance.NoVotingPower.selector);
        dao.propose("desc", address(0), "");
    }

    function test_Propose_RevertEmptyDescription() public {
        vm.prank(alice);
        vm.expectRevert(IDAOGovernance.DescriptionEmpty.selector);
        dao.propose("", address(0), "");
    }

    function test_Propose_RevertWhenPaused() public {
        dao.pause();
        vm.prank(alice);
        vm.expectRevert(IDAOGovernance.Paused.selector);
        dao.propose("desc", address(0), "");
    }

    // ─── Vote ──────────────────────────────────────────────────────────────────

    function test_Vote_For() public {
        uint256 id = _propose();
        vm.prank(alice);
        dao.vote(id, true);
        (,,, uint256 forVotes,,, ) = dao.getProposal(id);
        assertEq(forVotes, 200 ether);
    }

    function test_Vote_Against() public {
        uint256 id = _propose();
        vm.prank(carol);
        dao.vote(id, false);
        (,,,, uint256 againstVotes,,) = dao.getProposal(id);
        assertEq(againstVotes, 50 ether);
    }

    function test_Vote_EmitsEvent() public {
        uint256 id = _propose();
        vm.expectEmit(true, true, false, true);
        emit Voted(id, alice, true, 200 ether);
        vm.prank(alice);
        dao.vote(id, true);
    }

    function test_Vote_RevertAlreadyVoted() public {
        uint256 id = _propose();
        vm.prank(alice);
        dao.vote(id, true);
        vm.prank(alice);
        vm.expectRevert(IDAOGovernance.AlreadyVoted.selector);
        dao.vote(id, true);
    }

    function test_Vote_RevertAfterVotingEnd() public {
        uint256 id = _propose();
        skip(PERIOD + 1);
        vm.prank(alice);
        vm.expectRevert(IDAOGovernance.ProposalNotActive.selector);
        dao.vote(id, true);
    }

    function test_Vote_RevertNoVotingPower() public {
        uint256 id = _propose();
        vm.prank(makeAddr("nobody"));
        vm.expectRevert(IDAOGovernance.NoVotingPower.selector);
        dao.vote(id, true);
    }

    function test_Vote_RevertCancelled() public {
        uint256 id = _propose();
        vm.prank(alice);
        dao.cancel(id);
        vm.prank(bob);
        vm.expectRevert(IDAOGovernance.ProposalNotActive.selector);
        dao.vote(id, true);
    }

    function test_Vote_RevertWhenPaused() public {
        uint256 id = _propose();
        dao.pause();
        vm.prank(alice);
        vm.expectRevert(IDAOGovernance.Paused.selector);
        dao.vote(id, true);
    }

    // ─── Execute ───────────────────────────────────────────────────────────────

    function test_Execute_Success() public {
        uint256 id = _passProposal();
        dao.execute(id);
        (,,,,,bool executed,) = dao.getProposal(id);
        assertTrue(executed);
    }

    function test_Execute_WithCalldata() public {
        uint256 id = _proposeWithTarget();
        vm.prank(alice); dao.vote(id, true);
        vm.prank(bob);   dao.vote(id, true);
        skip(PERIOD + 1);
        dao.execute(id);
        assertEq(target.value(), 42);
    }

    function test_Execute_EmitsEvent() public {
        uint256 id = _passProposal();
        vm.expectEmit(true, true, false, false);
        emit ProposalExecuted(id, owner);
        dao.execute(id);
    }

    function test_Execute_RevertNotSucceeded_QuorumNotMet() public {
        uint256 id = _propose();
        vm.prank(carol); dao.vote(id, true); // 50 < quorum 100
        skip(PERIOD + 1);
        vm.expectRevert(IDAOGovernance.ProposalNotSucceeded.selector);
        dao.execute(id);
    }

    function test_Execute_RevertNotSucceeded_AgainstWins() public {
        uint256 id = _propose();
        vm.prank(alice); dao.vote(id, false); // 200 against
        vm.prank(bob);   dao.vote(id, true);  // 100 for
        skip(PERIOD + 1);
        vm.expectRevert(IDAOGovernance.ProposalNotSucceeded.selector);
        dao.execute(id);
    }

    function test_Execute_RevertBeforeVotingEnd() public {
        uint256 id = _propose();
        vm.prank(alice); dao.vote(id, true);
        vm.expectRevert(IDAOGovernance.ProposalNotActive.selector);
        dao.execute(id);
    }

    function test_Execute_RevertAlreadyExecuted() public {
        uint256 id = _passProposal();
        dao.execute(id);
        vm.expectRevert(IDAOGovernance.ProposalAlreadyExecuted.selector);
        dao.execute(id);
    }

    function test_Execute_RevertExpired() public {
        uint256 id = _passProposal();
        skip(dao.EXECUTION_WINDOW() + 1);
        vm.expectRevert(IDAOGovernance.ProposalExpired.selector);
        dao.execute(id);
    }

    // ─── Cancel ────────────────────────────────────────────────────────────────

    function test_Cancel_ByProposer() public {
        uint256 id = _propose();
        vm.prank(alice);
        dao.cancel(id);
        (,,,,,, bool cancelled) = dao.getProposal(id);
        assertTrue(cancelled);
    }

    function test_Cancel_ByOwner() public {
        uint256 id = _propose();
        dao.cancel(id);
        (,,,,,, bool cancelled) = dao.getProposal(id);
        assertTrue(cancelled);
    }

    function test_Cancel_EmitsEvent() public {
        uint256 id = _propose();
        vm.expectEmit(true, false, false, false);
        emit ProposalCancelled(id);
        vm.prank(alice);
        dao.cancel(id);
    }

    function test_Cancel_RevertNotProposerOrOwner() public {
        uint256 id = _propose();
        vm.prank(bob);
        vm.expectRevert(IDAOGovernance.NotOwner.selector);
        dao.cancel(id);
    }

    // ─── State ─────────────────────────────────────────────────────────────────

    function test_State_Active() public {
        uint256 id = _propose();
        assertEq(dao.state(id), dao.STATE_ACTIVE());
    }

    function test_State_Succeeded() public {
        uint256 id = _passProposal();
        assertEq(dao.state(id), dao.STATE_SUCCEEDED());
    }

    function test_State_Defeated() public {
        uint256 id = _propose();
        skip(PERIOD + 1);
        assertEq(dao.state(id), dao.STATE_DEFEATED());
    }

    function test_State_Executed() public {
        uint256 id = _passProposal();
        dao.execute(id);
        assertEq(dao.state(id), dao.STATE_EXECUTED());
    }

    function test_State_Cancelled() public {
        uint256 id = _propose();
        vm.prank(alice); dao.cancel(id);
        assertEq(dao.state(id), dao.STATE_CANCELLED());
    }

    function test_State_Expired() public {
        uint256 id = _passProposal();
        skip(dao.EXECUTION_WINDOW() + 1);
        assertEq(dao.state(id), dao.STATE_EXPIRED());
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    function test_SetQuorum_Success() public {
        vm.expectEmit(false, false, false, true);
        emit QuorumUpdated(QUORUM, 200 ether);
        dao.setQuorum(200 ether);
        assertEq(dao.quorum(), 200 ether);
    }

    function test_SetVotingPeriod_Success() public {
        vm.expectEmit(false, false, false, true);
        emit VotingPeriodUpdated(PERIOD, 7 days);
        dao.setVotingPeriod(7 days);
        assertEq(dao.votingPeriod(), 7 days);
    }

    function test_Pause_Unpause() public {
        dao.pause();
        assertTrue(dao.paused());
        dao.unpause();
        assertFalse(dao.paused());
    }

    function test_TwoStepOwnership() public {
        dao.transferOwnership(alice);
        assertEq(dao.pendingOwner(), alice);
        vm.prank(alice);
        dao.acceptOwnership();
        assertEq(dao.owner(), alice);
    }

    function test_TransferOwnership_RevertZeroAddress() public {
        vm.expectRevert(IDAOGovernance.ZeroAddress.selector);
        dao.transferOwnership(address(0));
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_VoteWeight(uint256 aliceAmt, uint256 bobAmt) public {
        aliceAmt = bound(aliceAmt, 1, 1_000_000 ether);
        bobAmt   = bound(bobAmt, 1, 1_000_000 ether);
        token.mint(makeAddr("a2"), aliceAmt);
        token.mint(makeAddr("b2"), bobAmt);
        vm.prank(makeAddr("a2"));
        uint256 id = dao.propose("test", address(0), "");
        vm.prank(makeAddr("a2")); dao.vote(id, true);
        vm.prank(makeAddr("b2")); dao.vote(id, false);
        (,,, uint256 fv, uint256 av,,) = dao.getProposal(id);
        assertEq(fv, aliceAmt);
        assertEq(av, bobAmt);
    }

    // ─── Invariant ─────────────────────────────────────────────────────────────

    function test_Invariant_HasVotedPreventsDouble() public {
        uint256 id = _propose();
        vm.prank(alice); dao.vote(id, true);
        assertTrue(dao.hasVoted(id, alice));
        assertFalse(dao.hasVoted(id, bob));
    }

    receive() external payable {}
}
// Commit 9 optimization
