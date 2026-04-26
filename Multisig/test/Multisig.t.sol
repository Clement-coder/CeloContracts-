// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {Multisig} from "../src/Multisig.sol";
import {IMultisig} from "../src/IMultisig.sol";

contract MultisigTest is Test {
    Multisig ms;
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave  = makeAddr("dave");

    // Mirror events
    event TxSubmitted(uint256 indexed txId, address indexed submitter, address indexed to, uint256 value, bytes data);
    event TxConfirmed(uint256 indexed txId, address indexed owner);
    event TxRevoked(uint256 indexed txId, address indexed owner);
    event TxExecuted(uint256 indexed txId, address indexed executor);
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event ThresholdChanged(uint256 oldThreshold, uint256 newThreshold);
    event Deposit(address indexed sender, uint256 amount, uint256 balance);

    function setUp() public {
        address[] memory owners = new address[](3);
        owners[0] = alice;
        owners[1] = bob;
        owners[2] = carol;
        ms = new Multisig(owners, 2); // 2-of-3
        vm.deal(address(ms), 10 ether);
        vm.deal(alice, 5 ether);
        vm.deal(bob,   5 ether);
        vm.deal(carol, 5 ether);
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────

    function _submit() internal returns (uint256 txId) {
        vm.prank(alice);
        txId = ms.submitTx(dave, 1 ether, "");
    }

    function _submitAndConfirm2() internal returns (uint256 txId) {
        txId = _submit();
        vm.prank(alice);
        ms.confirmTx(txId);
        vm.prank(bob);
        ms.confirmTx(txId);
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsOwners() public view {
        assertTrue(ms.isOwner(alice));
        assertTrue(ms.isOwner(bob));
        assertTrue(ms.isOwner(carol));
        assertEq(ms.threshold(), 2);
    }

    function test_Constructor_RevertInvalidThreshold() public {
        address[] memory o = new address[](2);
        o[0] = alice; o[1] = bob;
        vm.expectRevert(IMultisig.InvalidThreshold.selector);
        new Multisig(o, 3);
    }

    function test_Constructor_RevertZeroThreshold() public {
        address[] memory o = new address[](2);
        o[0] = alice; o[1] = bob;
        vm.expectRevert(IMultisig.InvalidThreshold.selector);
        new Multisig(o, 0);
    }

    function test_Constructor_RevertDuplicateOwner() public {
        address[] memory o = new address[](2);
        o[0] = alice; o[1] = alice;
        vm.expectRevert(IMultisig.DuplicateOwner.selector);
        new Multisig(o, 1);
    }

    function test_Constructor_RevertZeroAddress() public {
        address[] memory o = new address[](2);
        o[0] = alice; o[1] = address(0);
        vm.expectRevert(IMultisig.ZeroAddress.selector);
        new Multisig(o, 1);
    }

    function test_Constructor_RevertEmptyOwners() public {
        address[] memory o = new address[](0);
        vm.expectRevert(IMultisig.InvalidOwnerCount.selector);
        new Multisig(o, 0);
    }

    // ─── SubmitTx ──────────────────────────────────────────────────────────────

    function test_Submit_Success() public {
        uint256 id = _submit();
        assertEq(id, 0);
        assertEq(ms.txCount(), 1);
    }

    function test_Submit_EmitsEvent() public {
        vm.expectEmit(true, true, true, false);
        emit TxSubmitted(0, alice, dave, 1 ether, "");
        vm.prank(alice);
        ms.submitTx(dave, 1 ether, "");
    }

    function test_Submit_RevertNotOwner() public {
        vm.prank(dave);
        vm.expectRevert(IMultisig.NotOwner.selector);
        ms.submitTx(dave, 0, "");
    }

    // ─── ConfirmTx ─────────────────────────────────────────────────────────────

    function test_Confirm_Success() public {
        uint256 id = _submit();
        vm.prank(alice);
        ms.confirmTx(id);
        assertTrue(ms.isConfirmed(id, alice));
        (,,,, uint256 confs) = ms.getTx(id);
        assertEq(confs, 1);
    }

    function test_Confirm_EmitsEvent() public {
        uint256 id = _submit();
        vm.expectEmit(true, true, false, false);
        emit TxConfirmed(id, alice);
        vm.prank(alice);
        ms.confirmTx(id);
    }

    function test_Confirm_RevertAlreadyConfirmed() public {
        uint256 id = _submit();
        vm.prank(alice);
        ms.confirmTx(id);
        vm.prank(alice);
        vm.expectRevert(IMultisig.AlreadyConfirmed.selector);
        ms.confirmTx(id);
    }

    function test_Confirm_RevertTxNotFound() public {
        vm.prank(alice);
        vm.expectRevert(IMultisig.TxNotFound.selector);
        ms.confirmTx(99);
    }

    function test_Confirm_RevertNotOwner() public {
        uint256 id = _submit();
        vm.prank(dave);
        vm.expectRevert(IMultisig.NotOwner.selector);
        ms.confirmTx(id);
    }

    // ─── RevokeTx ──────────────────────────────────────────────────────────────

    function test_Revoke_Success() public {
        uint256 id = _submit();
        vm.prank(alice);
        ms.confirmTx(id);
        vm.prank(alice);
        ms.revokeTx(id);
        assertFalse(ms.isConfirmed(id, alice));
        (,,,, uint256 confs) = ms.getTx(id);
        assertEq(confs, 0);
    }

    function test_Revoke_EmitsEvent() public {
        uint256 id = _submit();
        vm.prank(alice);
        ms.confirmTx(id);
        vm.expectEmit(true, true, false, false);
        emit TxRevoked(id, alice);
        vm.prank(alice);
        ms.revokeTx(id);
    }

    function test_Revoke_RevertNotConfirmed() public {
        uint256 id = _submit();
        vm.prank(alice);
        vm.expectRevert(IMultisig.NotConfirmed.selector);
        ms.revokeTx(id);
    }

    // ─── ExecuteTx ─────────────────────────────────────────────────────────────

    function test_Execute_Success() public {
        uint256 id = _submitAndConfirm2();
        uint256 daveBefore = dave.balance;
        vm.prank(alice);
        ms.executeTx(id);
        assertEq(dave.balance, daveBefore + 1 ether);
        (,,, bool executed,) = ms.getTx(id);
        assertTrue(executed);
    }

    function test_Execute_EmitsEvent() public {
        uint256 id = _submitAndConfirm2();
        vm.expectEmit(true, true, false, false);
        emit TxExecuted(id, alice);
        vm.prank(alice);
        ms.executeTx(id);
    }

    function test_Execute_RevertNotEnoughConfirmations() public {
        uint256 id = _submit();
        vm.prank(alice);
        ms.confirmTx(id); // only 1, need 2
        vm.prank(alice);
        vm.expectRevert(IMultisig.NotEnoughConfirmations.selector);
        ms.executeTx(id);
    }

    function test_Execute_RevertAlreadyExecuted() public {
        uint256 id = _submitAndConfirm2();
        vm.prank(alice);
        ms.executeTx(id);
        vm.prank(alice);
        vm.expectRevert(IMultisig.AlreadyExecuted.selector);
        ms.executeTx(id);
    }

    function test_Execute_RevertNotOwner() public {
        uint256 id = _submitAndConfirm2();
        vm.prank(dave);
        vm.expectRevert(IMultisig.NotOwner.selector);
        ms.executeTx(id);
    }

    function test_Execute_WithCalldata() public {
        // Submit a tx that calls a function on a target contract
        Counter counter = new Counter();
        vm.prank(alice);
        uint256 id = ms.submitTx(address(counter), 0, abi.encodeWithSignature("increment()"));
        vm.prank(alice);
        ms.confirmTx(id);
        vm.prank(bob);
        ms.confirmTx(id);
        vm.prank(alice);
        ms.executeTx(id);
        assertEq(counter.count(), 1);
    }

    // ─── AddOwner / RemoveOwner / ChangeThreshold (via self-call) ─────────────

    function test_AddOwner_ViaSelfCall() public {
        bytes memory data = abi.encodeWithSignature("addOwner(address)", dave);
        vm.prank(alice);
        uint256 id = ms.submitTx(address(ms), 0, data);
        vm.prank(alice); ms.confirmTx(id);
        vm.prank(bob);   ms.confirmTx(id);
        vm.prank(alice); ms.executeTx(id);
        assertTrue(ms.isOwner(dave));
    }

    function test_RemoveOwner_ViaSelfCall() public {
        bytes memory data = abi.encodeWithSignature("removeOwner(address)", carol);
        vm.prank(alice);
        uint256 id = ms.submitTx(address(ms), 0, data);
        vm.prank(alice); ms.confirmTx(id);
        vm.prank(bob);   ms.confirmTx(id);
        vm.prank(alice); ms.executeTx(id);
        assertFalse(ms.isOwner(carol));
    }

    function test_ChangeThreshold_ViaSelfCall() public {
        bytes memory data = abi.encodeWithSignature("changeThreshold(uint256)", 3);
        vm.prank(alice);
        uint256 id = ms.submitTx(address(ms), 0, data);
        vm.prank(alice); ms.confirmTx(id);
        vm.prank(bob);   ms.confirmTx(id);
        vm.prank(alice); ms.executeTx(id);
        assertEq(ms.threshold(), 3);
    }

    function test_AddOwner_RevertDirectCall() public {
        vm.prank(alice);
        vm.expectRevert(IMultisig.NotOwner.selector);
        ms.addOwner(dave);
    }

    function test_RemoveOwner_AdjustsThreshold() public {
        // 2-of-3, remove bob → 2-of-2 (alice+carol)
        bytes memory rm1 = abi.encodeWithSignature("removeOwner(address)", bob);
        vm.prank(alice); uint256 id1 = ms.submitTx(address(ms), 0, rm1);
        vm.prank(alice); ms.confirmTx(id1);
        vm.prank(bob);   ms.confirmTx(id1);
        vm.prank(alice); ms.executeTx(id1);

        // Now 2-of-2 (alice+carol), remove carol → threshold auto-adjusts to 1
        bytes memory rm2 = abi.encodeWithSignature("removeOwner(address)", carol);
        vm.prank(alice); uint256 id2 = ms.submitTx(address(ms), 0, rm2);
        vm.prank(alice); ms.confirmTx(id2);
        vm.prank(carol); ms.confirmTx(id2); // carol confirms her own removal
        vm.prank(alice); ms.executeTx(id2);
        assertEq(ms.threshold(), 1);
    }

    // ─── Deposit ───────────────────────────────────────────────────────────────

    function test_Deposit_EmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit Deposit(alice, 1 ether, 0);
        vm.prank(alice);
        (bool ok,) = address(ms).call{value: 1 ether}("");
        assertTrue(ok);
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_SubmitAndExecute(uint256 amount) public {
        amount = bound(amount, 0, 5 ether);
        vm.deal(address(ms), amount);
        vm.prank(alice);
        uint256 id = ms.submitTx(dave, amount, "");
        vm.prank(alice); ms.confirmTx(id);
        vm.prank(bob);   ms.confirmTx(id);
        uint256 before = dave.balance;
        vm.prank(alice); ms.executeTx(id);
        assertEq(dave.balance, before + amount);
    }

    // ─── Invariant ─────────────────────────────────────────────────────────────

    function test_Invariant_ThresholdNeverExceedsOwners() public {
        assertLe(ms.threshold(), ms.getOwners().length);
    }

    receive() external payable {}

    event WhitelistUpdated(address indexed target, bool enabled);
    event WhitelistToggled(bool enabled);

    // ─── BatchConfirmTx ────────────────────────────────────────────────────────

    function test_BatchConfirm_Success() public {
        uint256 id0 = _submit();
        vm.prank(alice); ms.submitTx(dave, 0, ""); // id1
        uint256[] memory ids = new uint256[](2);
        ids[0] = id0; ids[1] = 1;
        vm.prank(alice);
        ms.batchConfirmTx(ids);
        assertTrue(ms.isConfirmed(id0, alice));
        assertTrue(ms.isConfirmed(1, alice));
    }

    function test_BatchConfirm_SkipsInvalid() public {
        _submit(); // id 0
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0; ids[1] = 99; // 99 doesn't exist
        vm.prank(alice);
        ms.batchConfirmTx(ids); // should not revert
        assertTrue(ms.isConfirmed(0, alice));
    }

    function test_BatchConfirm_SkipsAlreadyConfirmed() public {
        uint256 id = _submit();
        vm.prank(alice); ms.confirmTx(id);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(alice);
        ms.batchConfirmTx(ids); // should not revert or double-count
        (,,,, uint256 confs) = ms.getTx(id);
        assertEq(confs, 1);
    }

    function test_BatchConfirm_RevertNotOwner() public {
        _submit();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.prank(dave);
        vm.expectRevert(IMultisig.NotOwner.selector);
        ms.batchConfirmTx(ids);
    }

    // ─── GetOwners / TxCount ───────────────────────────────────────────────────

    function test_GetOwners_ReturnsAll() public view {
        address[] memory o = ms.getOwners();
        assertEq(o.length, 3);
    }

    function test_TxCount_StartsZero() public view {
        assertEq(ms.txCount(), 0);
    }

    function test_TxCount_IncrementsOnSubmit() public {
        _submit();
        assertEq(ms.txCount(), 1);
        _submit();
        assertEq(ms.txCount(), 2);
    }

    // ─── Whitelist ─────────────────────────────────────────────────────────────

    function _enableWhitelist(address target) internal {
        // addToWhitelist via self-call
        bytes memory data = abi.encodeWithSignature("addToWhitelist(address)", target);
        vm.prank(alice); uint256 id = ms.submitTx(address(ms), 0, data);
        vm.prank(alice); ms.confirmTx(id);
        vm.prank(bob);   ms.confirmTx(id);
        vm.prank(alice); ms.executeTx(id);

        // setWhitelistEnabled(true) via self-call
        bytes memory data2 = abi.encodeWithSignature("setWhitelistEnabled(bool)", true);
        vm.prank(alice); uint256 id2 = ms.submitTx(address(ms), 0, data2);
        vm.prank(alice); ms.confirmTx(id2);
        vm.prank(bob);   ms.confirmTx(id2);
        vm.prank(alice); ms.executeTx(id2);
    }

    function test_Whitelist_AllowsWhitelistedTarget() public {
        _enableWhitelist(dave);
        vm.prank(alice);
        uint256 id = ms.submitTx(dave, 0, ""); // should not revert
        assertEq(id, 2);
    }

    function test_Whitelist_RevertNotWhitelisted() public {
        _enableWhitelist(dave);
        address stranger = makeAddr("stranger");
        vm.prank(alice);
        vm.expectRevert(IMultisig.NotWhitelisted.selector);
        ms.submitTx(stranger, 0, "");
    }

    function test_Whitelist_RemoveFromWhitelist() public {
        _enableWhitelist(dave);
        bytes memory data = abi.encodeWithSignature("removeFromWhitelist(address)", dave);
        vm.prank(alice); uint256 id = ms.submitTx(address(ms), 0, data);
        vm.prank(alice); ms.confirmTx(id);
        vm.prank(bob);   ms.confirmTx(id);
        vm.prank(alice); ms.executeTx(id);
        assertFalse(ms.whitelist(dave));
    }

    function test_Whitelist_DirectCallReverts() public {
        vm.prank(alice);
        vm.expectRevert(IMultisig.NotOwner.selector);
        ms.addToWhitelist(dave);
    }

    // ─── MaxOwners ─────────────────────────────────────────────────────────────

    function test_AddOwner_RevertMaxOwners() public {
        // Fill up to MAX_OWNERS (50) via self-calls
        // We already have 3; add 47 more to hit 50, then try one more
        uint256 max = ms.MAX_OWNERS();
        for (uint256 i = 3; i < max; i++) {
            address newOwner = address(uint160(0xDEAD0000 + i));
            bytes memory data = abi.encodeWithSignature("addOwner(address)", newOwner);
            vm.prank(alice); uint256 id = ms.submitTx(address(ms), 0, data);
            vm.prank(alice); ms.confirmTx(id);
            vm.prank(bob);   ms.confirmTx(id);
            vm.prank(alice); ms.executeTx(id);
        }
        assertEq(ms.getOwners().length, max);
        address oneMore = address(uint160(0xDEAD9999));
        bytes memory data = abi.encodeWithSignature("addOwner(address)", oneMore);
        vm.prank(alice); uint256 id = ms.submitTx(address(ms), 0, data);
        vm.prank(alice); ms.confirmTx(id);
        vm.prank(bob);   ms.confirmTx(id);
        vm.expectRevert(); // MaxOwnersReached inside executeTx -> TransferFailed
        vm.prank(alice); ms.executeTx(id);
    }

    // ─── GetTx ─────────────────────────────────────────────────────────────────

    function test_GetTx_RevertNotFound() public {
        vm.expectRevert(IMultisig.TxNotFound.selector);
        ms.getTx(0);
    }

    function test_GetTx_ReturnsCorrectData() public {
        vm.prank(alice);
        ms.submitTx(dave, 1 ether, hex"1234");
        (address to, uint256 val, bytes memory data, bool exec, uint256 confs) = ms.getTx(0);
        assertEq(to, dave);
        assertEq(val, 1 ether);
        assertEq(data, hex"1234");
        assertFalse(exec);
        assertEq(confs, 0);
    }

    // ─── Revoke after execute ──────────────────────────────────────────────────

    function test_Revoke_RevertAlreadyExecuted() public {
        uint256 id = _submitAndConfirm2();
        vm.prank(alice); ms.executeTx(id);
        vm.prank(alice);
        vm.expectRevert(IMultisig.AlreadyExecuted.selector);
        ms.revokeTx(id);
    }

    // ─── ChangeThreshold edge cases ────────────────────────────────────────────

    function test_ChangeThreshold_RevertDirectCall() public {
        vm.prank(alice);
        vm.expectRevert(IMultisig.NotOwner.selector);
        ms.changeThreshold(1);
    }

    function test_ChangeThreshold_RevertZero() public {
        bytes memory data = abi.encodeWithSignature("changeThreshold(uint256)", 0);
        vm.prank(alice); uint256 id = ms.submitTx(address(ms), 0, data);
        vm.prank(alice); ms.confirmTx(id);
        vm.prank(bob);   ms.confirmTx(id);
        vm.expectRevert(); // InvalidThreshold inside executeTx -> TransferFailed
        vm.prank(alice); ms.executeTx(id);
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_ConfirmCount(uint8 n) public {
        n = uint8(bound(n, 1, 3));
        uint256 id = _submit();
        address[3] memory o = [alice, bob, carol];
        for (uint256 i = 0; i < n; i++) {
            vm.prank(o[i]);
            ms.confirmTx(id);
        }
        (,,,, uint256 confs) = ms.getTx(id);
        assertEq(confs, n);
    }

}

/// @dev Simple counter for calldata execution test.
contract Counter {
    uint256 public count;
    function increment() external { count++; }
}