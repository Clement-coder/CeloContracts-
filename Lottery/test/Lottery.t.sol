// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {Lottery} from "../src/Lottery.sol";
import {ILottery} from "../src/ILottery.sol";

contract LotteryTest is Test {
    Lottery lottery;
    address owner = address(this);
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant FEE      = 250;        // 2.5%
    uint256 constant PRICE    = 0.01 ether;
    uint256 constant DURATION = 1 days;

    event RoundStarted(uint256 indexed round, uint256 ticketPrice, uint256 endTime);
    event TicketBought(uint256 indexed round, address indexed buyer, uint256 tickets, uint256 totalPot);
    event WinnerDrawn(uint256 indexed round, address indexed winner, uint256 prize);
    event NoWinner(uint256 indexed round);
    event FeeWithdrawn(address indexed to, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        lottery = new Lottery(FEE);
        vm.deal(alice, 10 ether);
        vm.deal(bob,   10 ether);
        vm.deal(carol, 10 ether);
    }

    function _start() internal { lottery.startRound(PRICE, DURATION); }

    function _buyAndDraw() internal returns (address winner) {
        _start();
        vm.prank(alice); lottery.buyTickets{value: PRICE}(1);
        vm.prank(bob);   lottery.buyTickets{value: PRICE}(1);
        skip(DURATION + 1);
        lottery.drawWinner();
        (,,,, winner,) = lottery.getRound(1);
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsParams() public view {
        assertEq(lottery.owner(), owner);
        assertEq(lottery.feeBps(), FEE);
    }

    function test_Constructor_RevertFeeTooHigh() public {
        vm.expectRevert(ILottery.InvalidFee.selector);
        new Lottery(1_001);
    }

    // ─── StartRound ────────────────────────────────────────────────────────────

    function test_StartRound_Success() public {
        _start();
        assertEq(lottery.currentRound(), 1);
    }

    function test_StartRound_EmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit RoundStarted(1, PRICE, 0);
        _start();
    }

    function test_StartRound_RevertTicketPriceTooLow() public {
        vm.expectRevert(ILottery.InvalidTicketPrice.selector);
        lottery.startRound(1, DURATION);
    }

    function test_StartRound_RevertDurationTooShort() public {
        vm.expectRevert(ILottery.InvalidDuration.selector);
        lottery.startRound(PRICE, 1 minutes);
    }

    function test_StartRound_RevertDurationTooLong() public {
        vm.expectRevert(ILottery.InvalidDuration.selector);
        lottery.startRound(PRICE, 31 days);
    }

    function test_StartRound_RevertPreviousNotDrawn() public {
        _start();
        vm.expectRevert(ILottery.LotteryNotEnded.selector);
        lottery.startRound(PRICE, DURATION);
    }

    function test_StartRound_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ILottery.NotOwner.selector);
        lottery.startRound(PRICE, DURATION);
    }

    function test_StartRound_RevertWhenPaused() public {
        lottery.pause();
        vm.expectRevert(ILottery.Paused.selector);
        lottery.startRound(PRICE, DURATION);
    }

    // ─── BuyTickets ────────────────────────────────────────────────────────────

    function test_BuyTickets_Success() public {
        _start();
        vm.prank(alice);
        lottery.buyTickets{value: PRICE}(1);
        assertEq(lottery.getTickets(1, alice), 1);
    }

    function test_BuyTickets_Multiple() public {
        _start();
        vm.prank(alice);
        lottery.buyTickets{value: PRICE * 5}(5);
        assertEq(lottery.getTickets(1, alice), 5);
    }

    function test_BuyTickets_EmitsEvent() public {
        _start();
        uint256 net = PRICE - (PRICE * FEE / 10_000);
        vm.expectEmit(true, true, false, true);
        emit TicketBought(1, alice, 1, net);
        vm.prank(alice);
        lottery.buyTickets{value: PRICE}(1);
    }

    function test_BuyTickets_FeeDeducted() public {
        _start();
        vm.prank(alice);
        lottery.buyTickets{value: PRICE}(1);
        uint256 expectedFee = (PRICE * FEE) / 10_000;
        assertEq(lottery.accruedFees(), expectedFee);
    }

    function test_BuyTickets_RevertNoRound() public {
        vm.prank(alice);
        vm.expectRevert(ILottery.LotteryNotOpen.selector);
        lottery.buyTickets{value: PRICE}(1);
    }

    function test_BuyTickets_RevertAfterEnd() public {
        _start();
        skip(DURATION + 1);
        vm.prank(alice);
        vm.expectRevert(ILottery.LotteryNotOpen.selector);
        lottery.buyTickets{value: PRICE}(1);
    }

    function test_BuyTickets_RevertWrongValue() public {
        _start();
        vm.prank(alice);
        vm.expectRevert(ILottery.TicketPriceMismatch.selector);
        lottery.buyTickets{value: PRICE + 1}(1);
    }

    function test_BuyTickets_RevertZeroCount() public {
        _start();
        vm.prank(alice);
        vm.expectRevert(ILottery.NoTickets.selector);
        lottery.buyTickets{value: 0}(0);
    }

    function test_BuyTickets_RevertWhenPaused() public {
        _start();
        lottery.pause();
        vm.prank(alice);
        vm.expectRevert(ILottery.Paused.selector);
        lottery.buyTickets{value: PRICE}(1);
    }

    // ─── DrawWinner ────────────────────────────────────────────────────────────

    function test_DrawWinner_Success() public {
        address winner = _buyAndDraw();
        assertTrue(winner == alice || winner == bob);
    }

    function test_DrawWinner_EmitsEvent() public {
        _start();
        vm.prank(alice); lottery.buyTickets{value: PRICE}(1);
        skip(DURATION + 1);
        vm.expectEmit(true, false, false, false);
        emit WinnerDrawn(1, address(0), 0);
        lottery.drawWinner();
    }

    function test_DrawWinner_NoEntries_EmitsNoWinner() public {
        _start();
        skip(DURATION + 1);
        vm.expectEmit(true, false, false, false);
        emit NoWinner(1);
        lottery.drawWinner();
    }

    function test_DrawWinner_WinnerReceivesPrize() public {
        _start();
        vm.prank(alice); lottery.buyTickets{value: PRICE * 10}(10); // alice gets all tickets
        skip(DURATION + 1);
        uint256 before = alice.balance;
        lottery.drawWinner();
        assertGt(alice.balance, before);
    }

    function test_DrawWinner_RevertBeforeEnd() public {
        _start();
        vm.prank(alice); lottery.buyTickets{value: PRICE}(1);
        vm.expectRevert(ILottery.LotteryNotEnded.selector);
        lottery.drawWinner();
    }

    function test_DrawWinner_RevertAlreadyDrawn() public {
        _buyAndDraw();
        vm.expectRevert(ILottery.LotteryAlreadyDrawn.selector);
        lottery.drawWinner();
    }

    function test_DrawWinner_AnyoneCanDraw() public {
        _start();
        vm.prank(alice); lottery.buyTickets{value: PRICE}(1);
        skip(DURATION + 1);
        vm.prank(carol); // not owner
        lottery.drawWinner();
        (,,,,, bool drawn) = lottery.getRound(1);
        assertTrue(drawn);
    }

    // ─── MultiRound ────────────────────────────────────────────────────────────

    function test_MultipleRounds() public {
        _buyAndDraw();
        lottery.startRound(PRICE, DURATION);
        assertEq(lottery.currentRound(), 2);
        vm.prank(carol); lottery.buyTickets{value: PRICE}(1);
        skip(DURATION + 1);
        lottery.drawWinner();
        (,,,, address winner2,) = lottery.getRound(2);
        assertEq(winner2, carol);
    }

    // ─── WithdrawFees ──────────────────────────────────────────────────────────

    function test_WithdrawFees_Success() public {
        _start();
        vm.prank(alice); lottery.buyTickets{value: PRICE}(1);
        uint256 fee = lottery.accruedFees();
        uint256 before = owner.balance;
        lottery.withdrawFees();
        assertEq(owner.balance, before + fee);
        assertEq(lottery.accruedFees(), 0);
    }

    function test_WithdrawFees_EmitsEvent() public {
        _start();
        vm.prank(alice); lottery.buyTickets{value: PRICE}(1);
        uint256 fee = lottery.accruedFees();
        vm.expectEmit(true, false, false, true);
        emit FeeWithdrawn(owner, fee);
        lottery.withdrawFees();
    }

    function test_WithdrawFees_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ILottery.NotOwner.selector);
        lottery.withdrawFees();
    }

    // ─── Pause / Ownership ─────────────────────────────────────────────────────

    function test_Pause_Unpause() public {
        lottery.pause();
        assertTrue(lottery.paused());
        lottery.unpause();
        assertFalse(lottery.paused());
    }

    function test_TwoStepOwnership() public {
        lottery.transferOwnership(alice);
        assertEq(lottery.pendingOwner(), alice);
        vm.prank(alice);
        lottery.acceptOwnership();
        assertEq(lottery.owner(), alice);
    }

    function test_TransferOwnership_RevertZeroAddress() public {
        vm.expectRevert(ILottery.ZeroAddress.selector);
        lottery.transferOwnership(address(0));
    }

    function test_AcceptOwnership_RevertNotPending() public {
        lottery.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(ILottery.NotPendingOwner.selector);
        lottery.acceptOwnership();
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_BuyMultipleTickets(uint256 count) public {
        count = bound(count, 1, 20);
        _start();
        vm.deal(alice, PRICE * count);
        vm.prank(alice);
        lottery.buyTickets{value: PRICE * count}(count);
        assertEq(lottery.getTickets(1, alice), count);
    }

    // ─── Invariant ─────────────────────────────────────────────────────────────

    function test_Invariant_BalanceEqualsPotPlusFees() public {
        _start();
        vm.prank(alice); lottery.buyTickets{value: PRICE * 3}(3);
        vm.prank(bob);   lottery.buyTickets{value: PRICE * 2}(2);
        (,, uint256 pot,,,) = lottery.getRound(1);
        assertEq(address(lottery).balance, pot + lottery.accruedFees());
    }

    receive() external payable {}
}
// Commit 8 optimization
// Commit 28 optimization
// Commit 48 optimization
