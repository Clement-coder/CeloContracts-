// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {Escrow} from "../src/Escrow.sol";
import {IEscrow} from "../src/IEscrow.sol";

contract EscrowTest is Test {
    Escrow escrow;
    address owner = address(this);
    address alice = makeAddr("alice"); // depositor
    address bob   = makeAddr("bob");   // beneficiary
    address carol = makeAddr("carol");

    uint256 constant FEE      = 100;   // 1%
    uint256 constant AMOUNT   = 1 ether;
    uint256 constant DEADLINE = 7 days;

    event EscrowCreated(uint256 indexed id, address indexed depositor, address indexed beneficiary, uint256 amount, uint256 deadline);
    event EscrowReleased(uint256 indexed id, address indexed beneficiary, uint256 amount);
    event EscrowRefunded(uint256 indexed id, address indexed depositor, uint256 amount);
    event EscrowDisputed(uint256 indexed id, address indexed raisedBy);
    event DisputeResolved(uint256 indexed id, address indexed winner, uint256 amount);
    event FeeWithdrawn(address indexed to, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        escrow = new Escrow(FEE);
        vm.deal(alice, 10 ether);
        vm.deal(bob,   10 ether);
        vm.deal(carol, 10 ether);
    }

    function _create() internal returns (uint256 id) {
        vm.prank(alice);
        id = escrow.createEscrow{value: AMOUNT}(bob, block.timestamp + DEADLINE);
    }

    function _net() internal pure returns (uint256) {
        return AMOUNT - (AMOUNT * FEE / 10_000);
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsParams() public view {
        assertEq(escrow.owner(), owner);
        assertEq(escrow.feeBps(), FEE);
    }

    function test_Constructor_RevertFeeTooHigh() public {
        vm.expectRevert(IEscrow.FeeTooHigh.selector);
        new Escrow(501);
    }

    // ─── CreateEscrow ──────────────────────────────────────────────────────────

    function test_Create_Success() public {
        uint256 id = _create();
        assertEq(id, 1);
        assertEq(escrow.escrowCount(), 1);
        assertEq(escrow.accruedFees(), AMOUNT * FEE / 10_000);
    }

    function test_Create_EmitsEvent() public {
        vm.expectEmit(true, true, true, false);
        emit EscrowCreated(1, alice, bob, _net(), block.timestamp + DEADLINE);
        vm.prank(alice);
        escrow.createEscrow{value: AMOUNT}(bob, block.timestamp + DEADLINE);
    }

    function test_Create_RevertZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(IEscrow.ZeroAddress.selector);
        escrow.createEscrow{value: AMOUNT}(address(0), block.timestamp + DEADLINE);
    }

    function test_Create_RevertSelfBeneficiary() public {
        vm.prank(alice);
        vm.expectRevert(IEscrow.NotBeneficiary.selector);
        escrow.createEscrow{value: AMOUNT}(alice, block.timestamp + DEADLINE);
    }

    function test_Create_RevertAmountTooLow() public {
        vm.prank(alice);
        vm.expectRevert(IEscrow.AmountTooLow.selector);
        escrow.createEscrow{value: 1}(bob, block.timestamp + DEADLINE);
    }

    function test_Create_RevertDeadlineTooShort() public {
        vm.prank(alice);
        vm.expectRevert(IEscrow.DeadlineTooShort.selector);
        escrow.createEscrow{value: AMOUNT}(bob, block.timestamp + 1 minutes);
    }

    function test_Create_RevertDeadlineTooLong() public {
        vm.prank(alice);
        vm.expectRevert(IEscrow.DeadlineTooLong.selector);
        escrow.createEscrow{value: AMOUNT}(bob, block.timestamp + 366 days);
    }

    function test_Create_RevertWhenPaused() public {
        escrow.pause();
        vm.prank(alice);
        vm.expectRevert(IEscrow.Paused.selector);
        escrow.createEscrow{value: AMOUNT}(bob, block.timestamp + DEADLINE);
    }

    // ─── Release ───────────────────────────────────────────────────────────────

    function test_Release_Success() public {
        _create();
        uint256 bobBefore = bob.balance;
        vm.prank(alice);
        escrow.release(1);
        assertEq(bob.balance, bobBefore + _net());
    }

    function test_Release_EmitsEvent() public {
        _create();
        vm.expectEmit(true, true, false, true);
        emit EscrowReleased(1, bob, _net());
        vm.prank(alice);
        escrow.release(1);
    }

    function test_Release_RevertNotDepositor() public {
        _create();
        vm.prank(bob);
        vm.expectRevert(IEscrow.NotDepositor.selector);
        escrow.release(1);
    }

    function test_Release_RevertAlreadyReleased() public {
        _create();
        vm.prank(alice); escrow.release(1);
        vm.prank(alice);
        vm.expectRevert(IEscrow.AlreadyReleased.selector);
        escrow.release(1);
    }

    // ─── Refund (by beneficiary) ───────────────────────────────────────────────

    function test_Refund_ByBeneficiary() public {
        _create();
        uint256 aliceBefore = alice.balance;
        vm.prank(bob);
        escrow.refund(1);
        assertEq(alice.balance, aliceBefore + _net());
    }

    function test_Refund_EmitsEvent() public {
        _create();
        vm.expectEmit(true, true, false, true);
        emit EscrowRefunded(1, alice, _net());
        vm.prank(bob);
        escrow.refund(1);
    }

    function test_Refund_RevertNotBeneficiary() public {
        _create();
        vm.prank(alice);
        vm.expectRevert(IEscrow.NotBeneficiary.selector);
        escrow.refund(1);
    }

    // ─── ClaimExpired ──────────────────────────────────────────────────────────

    function test_ClaimExpired_Success() public {
        _create();
        skip(DEADLINE + 1);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        escrow.claimExpired(1);
        assertEq(alice.balance, aliceBefore + _net());
    }

    function test_ClaimExpired_EmitsEvent() public {
        _create();
        skip(DEADLINE + 1);
        vm.expectEmit(true, true, false, true);
        emit EscrowRefunded(1, alice, _net());
        vm.prank(alice);
        escrow.claimExpired(1);
    }

    function test_ClaimExpired_RevertBeforeDeadline() public {
        _create();
        vm.prank(alice);
        vm.expectRevert(IEscrow.DeadlineNotPassed.selector);
        escrow.claimExpired(1);
    }

    function test_ClaimExpired_RevertNotDepositor() public {
        _create();
        skip(DEADLINE + 1);
        vm.prank(bob);
        vm.expectRevert(IEscrow.NotDepositor.selector);
        escrow.claimExpired(1);
    }

    // ─── Dispute ───────────────────────────────────────────────────────────────

    function test_Dispute_ByDepositor() public {
        _create();
        vm.prank(alice);
        escrow.dispute(1);
        (,,,, uint8 status) = escrow.getEscrow(1);
        assertEq(status, escrow.STATUS_DISPUTED());
    }

    function test_Dispute_ByBeneficiary() public {
        _create();
        vm.prank(bob);
        escrow.dispute(1);
        (,,,, uint8 status) = escrow.getEscrow(1);
        assertEq(status, escrow.STATUS_DISPUTED());
    }

    function test_Dispute_EmitsEvent() public {
        _create();
        vm.expectEmit(true, true, false, false);
        emit EscrowDisputed(1, alice);
        vm.prank(alice);
        escrow.dispute(1);
    }

    function test_Dispute_RevertNotParty() public {
        _create();
        vm.prank(carol);
        vm.expectRevert(IEscrow.NotParty.selector);
        escrow.dispute(1);
    }

    function test_Dispute_RevertAfterDeadline() public {
        _create();
        skip(DEADLINE + 1);
        vm.prank(alice);
        vm.expectRevert(IEscrow.DeadlinePassed.selector);
        escrow.dispute(1);
    }

    function test_Dispute_RevertAlreadyDisputed() public {
        _create();
        vm.prank(alice); escrow.dispute(1);
        vm.prank(bob);
        vm.expectRevert(IEscrow.AlreadyDisputed.selector);
        escrow.dispute(1);
    }

    // ─── ResolveDispute ────────────────────────────────────────────────────────

    function test_ResolveDispute_ToBeneficiary() public {
        _create();
        vm.prank(alice); escrow.dispute(1);
        uint256 bobBefore = bob.balance;
        escrow.resolveDispute(1, true);
        assertEq(bob.balance, bobBefore + _net());
    }

    function test_ResolveDispute_ToDepositor() public {
        _create();
        vm.prank(alice); escrow.dispute(1);
        uint256 aliceBefore = alice.balance;
        escrow.resolveDispute(1, false);
        assertEq(alice.balance, aliceBefore + _net());
    }

    function test_ResolveDispute_EmitsEvent() public {
        _create();
        vm.prank(alice); escrow.dispute(1);
        vm.expectEmit(true, true, false, true);
        emit DisputeResolved(1, bob, _net());
        escrow.resolveDispute(1, true);
    }

    function test_ResolveDispute_RevertNotDisputed() public {
        _create();
        vm.expectRevert(IEscrow.NotDisputed.selector);
        escrow.resolveDispute(1, true);
    }

    function test_ResolveDispute_RevertNotOwner() public {
        _create();
        vm.prank(alice); escrow.dispute(1);
        vm.prank(alice);
        vm.expectRevert(IEscrow.NotOwner.selector);
        escrow.resolveDispute(1, true);
    }

    // ─── WithdrawFees ──────────────────────────────────────────────────────────

    function test_WithdrawFees_Success() public {
        _create();
        uint256 fee = escrow.accruedFees();
        uint256 before = owner.balance;
        escrow.withdrawFees();
        assertEq(owner.balance, before + fee);
        assertEq(escrow.accruedFees(), 0);
    }

    function test_WithdrawFees_RevertNotOwner() public {
        _create();
        vm.prank(alice);
        vm.expectRevert(IEscrow.NotOwner.selector);
        escrow.withdrawFees();
    }

    // ─── Pause / Ownership ─────────────────────────────────────────────────────

    function test_Pause_Unpause() public {
        escrow.pause();
        assertTrue(escrow.paused());
        escrow.unpause();
        assertFalse(escrow.paused());
    }

    function test_TwoStepOwnership() public {
        escrow.transferOwnership(alice);
        assertEq(escrow.pendingOwner(), alice);
        vm.prank(alice);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), alice);
    }

    function test_TransferOwnership_RevertZeroAddress() public {
        vm.expectRevert(IEscrow.ZeroAddress.selector);
        escrow.transferOwnership(address(0));
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_CreateAndRelease(uint256 amount) public {
        amount = bound(amount, escrow.MIN_AMOUNT(), 5 ether);
        vm.deal(alice, amount);
        vm.prank(alice);
        uint256 id = escrow.createEscrow{value: amount}(bob, block.timestamp + DEADLINE);
        vm.prank(alice);
        escrow.release(id);
        (,,,, uint8 status) = escrow.getEscrow(id);
        assertEq(status, escrow.STATUS_RELEASED());
    }

    // ─── Invariant ─────────────────────────────────────────────────────────────

    function test_Invariant_BalanceEqualsFundsAndFees() public {
        _create();
        (,, uint256 held,, ) = escrow.getEscrow(1);
        assertEq(address(escrow).balance, held + escrow.accruedFees());
    }

    receive() external payable {}
}
