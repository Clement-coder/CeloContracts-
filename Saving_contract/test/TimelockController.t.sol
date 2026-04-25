// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "../src/TimelockController.sol";
import {ITimelockController} from "../src/ITimelockController.sol";
import {Savings} from "../src/Savings.sol";

contract TimelockControllerTest is Test {
    TimelockController timelock;
    Savings savings;

    address admin = address(this);
    address proposer = makeAddr("proposer");
    address executor = makeAddr("executor");
    address stranger = makeAddr("stranger");

    uint256 constant DELAY = 2 days;

    // Mirror events
    event TransactionQueued(bytes32 indexed txHash, address indexed target, uint256 value, bytes data, uint256 eta);
    event TransactionExecuted(bytes32 indexed txHash, address indexed target, uint256 value, bytes data);
    event TransactionCancelled(bytes32 indexed txHash);
    event DelayUpdated(uint256 oldDelay, uint256 newDelay);
    event ProposerSet(address indexed account, bool status);
    event ExecutorSet(address indexed account, bool status);

    function setUp() public {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;

        timelock = new TimelockController(DELAY, proposers, executors);
        savings = new Savings();

        // Transfer savings ownership to timelock
        savings.transferOwnership(address(timelock));
        // Timelock accepts ownership (admin calls via timelock itself — simulate directly)
        vm.prank(address(timelock));
        savings.acceptOwnership();
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsDelay() public view {
        assertEq(timelock.delay(), DELAY);
    }

    function test_Constructor_SetsAdmins() public view {
        assertTrue(timelock.isAdmin(admin));
        assertTrue(timelock.isAdmin(address(timelock)));
    }

    function test_Constructor_EmitsProposerSet() public {
        address[] memory p = new address[](1);
        p[0] = makeAddr("p2");
        address[] memory e = new address[](0);
        vm.expectEmit(true, false, false, true);
        emit ProposerSet(p[0], true);
        new TimelockController(DELAY, p, e);
    }

    function test_Constructor_SetsProposer() public view {
        assertTrue(timelock.isProposer(proposer));
    }

    function test_Constructor_EmitsExecutorSet() public {
        address[] memory p = new address[](0);
        address[] memory e = new address[](1);
        e[0] = makeAddr("e2");
        vm.expectEmit(true, false, false, true);
        emit ExecutorSet(e[0], true);
        new TimelockController(DELAY, p, e);
    }

    function test_Constructor_SetsExecutor() public view {
        assertTrue(timelock.isExecutor(executor));
    }

    function test_Constructor_RevertDelayTooShort() public {
        address[] memory p = new address[](0);
        vm.expectRevert(ITimelockController.DelayTooShort.selector);
        new TimelockController(1 hours, p, p);
    }

    function test_Constructor_RevertDelayTooLong() public {
        address[] memory p = new address[](0);
        vm.expectRevert(ITimelockController.DelayTooLong.selector);
        new TimelockController(31 days, p, p);
    }

    function test_Constructor_RevertZeroAddressProposer() public {
        address[] memory p = new address[](1);
        p[0] = address(0);
        address[] memory e = new address[](0);
        vm.expectRevert(ITimelockController.ZeroAddress.selector);
        new TimelockController(DELAY, p, e);
    }

    function test_Constructor_RevertZeroAddressExecutor() public {
        address[] memory p = new address[](0);
        address[] memory e = new address[](1);
        e[0] = address(0);
        vm.expectRevert(ITimelockController.ZeroAddress.selector);
        new TimelockController(DELAY, p, e);
    }

    // ─── Queue ─────────────────────────────────────────────────────────────────

    function test_Queue_Success() public {
        bytes memory data = abi.encodeCall(savings.pause, ());
        vm.prank(proposer);
        (bytes32 txHash, uint256 eta) = timelock.queueTransaction(address(savings), 0, data);

        assertEq(eta, block.timestamp + DELAY);
        assertTrue(timelock.isQueued(txHash));
        assertEq(timelock.getEta(txHash), eta);
    }

    function test_Queue_EmitsEvent() public {
        bytes memory data = abi.encodeCall(savings.pause, ());
        uint256 expectedEta = block.timestamp + DELAY;
        bytes32 expectedHash = timelock.getTxHash(address(savings), 0, data, expectedEta);

        vm.expectEmit(true, true, false, true);
        emit TransactionQueued(expectedHash, address(savings), 0, data, expectedEta);

        vm.prank(proposer);
        timelock.queueTransaction(address(savings), 0, data);
    }

    function test_Queue_RevertNotProposer() public {
        bytes memory data = abi.encodeCall(savings.pause, ());
        vm.prank(stranger);
        vm.expectRevert(ITimelockController.NotProposer.selector);
        timelock.queueTransaction(address(savings), 0, data);
    }

    function test_Queue_RevertZeroTarget() public {
        vm.prank(proposer);
        vm.expectRevert(ITimelockController.ZeroAddress.selector);
        timelock.queueTransaction(address(0), 0, "");
    }

    function test_Queue_RevertAlreadyQueued() public {
        bytes memory data = abi.encodeCall(savings.pause, ());
        vm.prank(proposer);
        timelock.queueTransaction(address(savings), 0, data);

        vm.prank(proposer);
        vm.expectRevert(ITimelockController.TxAlreadyQueued.selector);
        timelock.queueTransaction(address(savings), 0, data);
    }

    function test_Queue_WithNonZeroValue() public {
        bytes memory data = "";
        vm.prank(proposer);
        (bytes32 txHash, uint256 eta) = timelock.queueTransaction(address(savings), 1 ether, data);
        assertEq(timelock.getEta(txHash), eta);
    }

    // ─── Execute ───────────────────────────────────────────────────────────────

    function _queue(bytes memory data) internal returns (bytes32 txHash, uint256 eta) {
        vm.prank(proposer);
        (txHash, eta) = timelock.queueTransaction(address(savings), 0, data);
    }

    function test_Execute_Success_Pause() public {
        bytes memory data = abi.encodeCall(savings.pause, ());
        (, uint256 eta) = _queue(data);

        skip(DELAY + 1);

        vm.prank(executor);
        timelock.executeTransaction(address(savings), 0, data, eta);

        assertTrue(savings.paused());
    }

    function test_Execute_Success_Unpause() public {
        // First pause via timelock
        bytes memory pauseData = abi.encodeCall(savings.pause, ());
        (, uint256 eta1) = _queue(pauseData);
        skip(DELAY + 1);
        vm.prank(executor);
        timelock.executeTransaction(address(savings), 0, pauseData, eta1);

        // Now unpause
        bytes memory unpauseData = abi.encodeCall(savings.unpause, ());
        (, uint256 eta2) = _queue(unpauseData);
        skip(DELAY + 1);
        vm.prank(executor);
        timelock.executeTransaction(address(savings), 0, unpauseData, eta2);

        assertFalse(savings.paused());
    }

    function test_Execute_EmitsEvent() public {
        bytes memory data = abi.encodeCall(savings.pause, ());
        (bytes32 txHash, uint256 eta) = _queue(data);
        skip(DELAY + 1);

        vm.expectEmit(true, true, false, true);
        emit TransactionExecuted(txHash, address(savings), 0, data);

        vm.prank(executor);
        timelock.executeTransaction(address(savings), 0, data, eta);
    }

    function test_Execute_MarksExecuted() public {
        bytes memory data = abi.encodeCall(savings.pause, ());
        (bytes32 txHash, uint256 eta) = _queue(data);
        skip(DELAY + 1);

        vm.prank(executor);
        timelock.executeTransaction(address(savings), 0, data, eta);

        assertTrue(timelock.isExecuted(txHash));
        assertFalse(timelock.isQueued(txHash));
    }

    function test_Execute_RevertNotExecutor() public {
        bytes memory data = abi.encodeCall(savings.pause, ());
        (, uint256 eta) = _queue(data);
        skip(DELAY + 1);

        vm.prank(stranger);
        vm.expectRevert(ITimelockController.NotExecutor.selector);
        timelock.executeTransaction(address(savings), 0, data, eta);
    }

    function test_Execute_RevertTxNotQueued() public {
        bytes memory data = abi.encodeCall(savings.pause, ());
        uint256 fakeEta = block.timestamp + DELAY;

        vm.prank(executor);
        vm.expectRevert(ITimelockController.TxNotQueued.selector);
        timelock.executeTransaction(address(savings), 0, data, fakeEta);
    }

    function test_Execute_RevertTimelockNotExpired() public {
        bytes memory data = abi.encodeCall(savings.pause, ());
        (, uint256 eta) = _queue(data);

        // Don't skip time
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(ITimelockController.TimelockNotExpired.selector, eta));
        timelock.executeTransaction(address(savings), 0, data, eta);
    }

    function test_Execute_RevertGracePeriodExpired() public {
        bytes memory data = abi.encodeCall(savings.pause, ());
        (, uint256 eta) = _queue(data);

        skip(DELAY + timelock.GRACE_PERIOD() + 1);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(ITimelockController.GracePeriodExpired.selector, eta));
        timelock.executeTransaction(address(savings), 0, data, eta);
    }

    function test_Execute_RevertAlreadyExecuted() public {
        bytes memory data = abi.encodeCall(savings.pause, ());
        (, uint256 eta) = _queue(data);
        skip(DELAY + 1);

        vm.prank(executor);
        timelock.executeTransaction(address(savings), 0, data, eta);

        // Re-queue and try to execute with same eta (won't be queued)
        vm.prank(executor);
        vm.expectRevert(ITimelockController.TxNotQueued.selector);
        timelock.executeTransaction(address(savings), 0, data, eta);
    }

    function test_Execute_RevertTxExecutionFailed() public {
        // Queue a call that will fail: transferOwnership(address(0))
        bytes memory data = abi.encodeCall(savings.transferOwnership, (address(0)));
        (, uint256 eta) = _queue(data);
        skip(DELAY + 1);

        vm.prank(executor);
        vm.expectRevert(ITimelockController.TxExecutionFailed.selector);
        timelock.executeTransaction(address(savings), 0, data, eta);
    }

    // ─── Cancel ────────────────────────────────────────────────────────────────

    function test_Cancel_Success() public {
        bytes memory data = abi.encodeCall(savings.pause, ());
        (bytes32 txHash,) = _queue(data);

        vm.expectEmit(true, false, false, false);
        emit TransactionCancelled(txHash);

        vm.prank(proposer);
        timelock.cancelTransaction(txHash);

        assertFalse(timelock.isQueued(txHash));
    }

    function test_Cancel_RevertNotProposer() public {
        bytes memory data = abi.encodeCall(savings.pause, ());
        (bytes32 txHash,) = _queue(data);

        vm.prank(stranger);
        vm.expectRevert(ITimelockController.NotProposer.selector);
        timelock.cancelTransaction(txHash);
    }

    function test_Cancel_RevertTxNotQueued() public {
        vm.prank(proposer);
        vm.expectRevert(ITimelockController.TxNotQueued.selector);
        timelock.cancelTransaction(bytes32(0));
    }

    function test_Cancel_GetEtaZeroAfterCancel() public {
        bytes memory data = abi.encodeCall(savings.pause, ());
        (bytes32 txHash,) = _queue(data);
        vm.prank(proposer);
        timelock.cancelTransaction(txHash);
        assertEq(timelock.getEta(txHash), 0);
    }

    // ─── SetDelay ──────────────────────────────────────────────────────────────

    function test_SetDelay_Success() public {
        uint256 newDelay = 3 days;
        vm.expectEmit(false, false, false, true);
        emit DelayUpdated(DELAY, newDelay);
        timelock.setDelay(newDelay);
        assertEq(timelock.delay(), newDelay);
    }

    function test_SetDelay_RevertNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(ITimelockController.NotAdmin.selector);
        timelock.setDelay(3 days);
    }

    function test_SetDelay_RevertTooShort() public {
        vm.expectRevert(ITimelockController.DelayTooShort.selector);
        timelock.setDelay(1 hours);
    }

    function test_SetDelay_RevertTooLong() public {
        vm.expectRevert(ITimelockController.DelayTooLong.selector);
        timelock.setDelay(31 days);
    }

    // ─── SetProposer ───────────────────────────────────────────────────────────

    function test_SetProposer_Grant() public {
        timelock.setProposer(stranger, true);
        assertTrue(timelock.isProposer(stranger));
    }

    function test_SetProposer_Revoke() public {
        timelock.setProposer(proposer, false);
        assertFalse(timelock.isProposer(proposer));
    }

    function test_SetProposer_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ProposerSet(stranger, true);
        timelock.setProposer(stranger, true);
    }

    function test_SetProposer_RevertNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(ITimelockController.NotAdmin.selector);
        timelock.setProposer(stranger, true);
    }

    function test_SetProposer_RevertZeroAddress() public {
        vm.expectRevert(ITimelockController.ZeroAddress.selector);
        timelock.setProposer(address(0), true);
    }

    // ─── SetExecutor ───────────────────────────────────────────────────────────

    function test_SetExecutor_Grant() public {
        timelock.setExecutor(stranger, true);
        assertTrue(timelock.isExecutor(stranger));
    }

    function test_SetExecutor_Revoke() public {
        timelock.setExecutor(executor, false);
        assertFalse(timelock.isExecutor(executor));
    }

    function test_SetExecutor_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ExecutorSet(stranger, true);
        timelock.setExecutor(stranger, true);
    }

    function test_SetExecutor_RevertNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(ITimelockController.NotAdmin.selector);
        timelock.setExecutor(stranger, true);
    }

    function test_SetExecutor_RevertZeroAddress() public {
        vm.expectRevert(ITimelockController.ZeroAddress.selector);
        timelock.setExecutor(address(0), true);
    }

    function test_Execute_IsExecutedFalseBeforeExecution() public {
        bytes memory data = abi.encodeCall(savings.pause, ());
        (bytes32 txHash,) = _queue(data);
        assertFalse(timelock.isExecuted(txHash));
    }

    // ─── GetTxHash ─────────────────────────────────────────────────────────────

    function test_GetTxHash_Deterministic() public view {
        bytes memory data = abi.encodeCall(savings.pause, ());
        uint256 eta = block.timestamp + DELAY;
        bytes32 h1 = timelock.getTxHash(address(savings), 0, data, eta);
        bytes32 h2 = timelock.getTxHash(address(savings), 0, data, eta);
        assertEq(h1, h2);
    }

    function test_GetTxHash_DifferentEta_DifferentHash() public view {
        bytes memory data = abi.encodeCall(savings.pause, ());
        bytes32 h1 = timelock.getTxHash(address(savings), 0, data, 100);
        bytes32 h2 = timelock.getTxHash(address(savings), 0, data, 200);
        assertTrue(h1 != h2);
    }

    // ─── Integration: full governance flow ─────────────────────────────────────

    function test_Integration_PauseViaTImelock() public {
        assertFalse(savings.paused());

        bytes memory data = abi.encodeCall(savings.pause, ());
        vm.prank(proposer);
        (, uint256 eta) = timelock.queueTransaction(address(savings), 0, data);

        skip(DELAY + 1);

        vm.prank(executor);
        timelock.executeTransaction(address(savings), 0, data, eta);

        assertTrue(savings.paused());
    }

    function test_Integration_TransferOwnershipViaTimelock() public {
        address newOwner = makeAddr("newOwner");

        bytes memory data = abi.encodeCall(savings.transferOwnership, (newOwner));
        vm.prank(proposer);
        (, uint256 eta) = timelock.queueTransaction(address(savings), 0, data);

        skip(DELAY + 1);

        vm.prank(executor);
        timelock.executeTransaction(address(savings), 0, data, eta);

        assertEq(savings.pendingOwner(), newOwner);
    }

    function test_Integration_CancelPreventsExecution() public {
        bytes memory data = abi.encodeCall(savings.pause, ());
        (bytes32 txHash, uint256 eta) = _queue(data);

        vm.prank(proposer);
        timelock.cancelTransaction(txHash);

        skip(DELAY + 1);

        vm.prank(executor);
        vm.expectRevert(ITimelockController.TxNotQueued.selector);
        timelock.executeTransaction(address(savings), 0, data, eta);
    }

    function test_Integration_RevokedProposerCannotQueue() public {
        timelock.setProposer(proposer, false);
        bytes memory data = abi.encodeCall(savings.pause, ());
        vm.prank(proposer);
        vm.expectRevert(ITimelockController.NotProposer.selector);
        timelock.queueTransaction(address(savings), 0, data);
    }

    function test_Integration_MultipleExecutorsCanExecute() public {
        address executor2 = makeAddr("executor2");
        timelock.setExecutor(executor2, true);
        bytes memory data = abi.encodeCall(savings.pause, ());
        vm.prank(proposer);
        (, uint256 eta) = timelock.queueTransaction(address(savings), 0, data);
        skip(DELAY + 1);
        vm.prank(executor2);
        timelock.executeTransaction(address(savings), 0, data, eta);
        assertTrue(savings.paused());
    }

    function test_Integration_MultipleProposersCanQueue() public {
        address proposer2 = makeAddr("proposer2");
        timelock.setProposer(proposer2, true);
        bytes memory data = abi.encodeCall(savings.pause, ());
        vm.prank(proposer2);
        (bytes32 txHash,) = timelock.queueTransaction(address(savings), 0, data);
        assertTrue(timelock.isQueued(txHash));
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_SetDelay(uint256 newDelay) public {
        newDelay = bound(newDelay, timelock.MIN_DELAY(), timelock.MAX_DELAY());
        timelock.setDelay(newDelay);
        assertEq(timelock.delay(), newDelay);
    }

    function testFuzz_QueueAndExecute(uint256 warpTime) public {
        warpTime = bound(warpTime, DELAY + 1, DELAY + timelock.GRACE_PERIOD());
        bytes memory data = abi.encodeCall(savings.pause, ());
        vm.prank(proposer);
        (, uint256 eta) = timelock.queueTransaction(address(savings), 0, data);

        skip(warpTime);

        vm.prank(executor);
        timelock.executeTransaction(address(savings), 0, data, eta);
        assertTrue(savings.paused());
    }

    // ─── Receive ───────────────────────────────────────────────────────────────

    function test_Receive_AcceptsETH() public {
        (bool ok,) = address(timelock).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(timelock).balance, 1 ether);
    }

    receive() external payable {}
}
