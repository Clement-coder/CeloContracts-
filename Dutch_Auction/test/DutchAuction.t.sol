// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {DutchAuction} from "../src/DutchAuction.sol";
import {IDutchAuction} from "../src/IDutchAuction.sol";

contract DutchAuctionTest is Test {
    DutchAuction da;
    address owner = address(this);
    address alice = makeAddr("alice"); // seller
    address bob   = makeAddr("bob");   // buyer
    address carol = makeAddr("carol");

    uint256 constant FEE        = 250;       // 2.5%
    uint256 constant START      = 10 ether;
    uint256 constant END_PRICE  = 1 ether;
    uint256 constant DURATION   = 1 days;
    uint256 constant ITEM_VALUE = 0.5 ether;

    event AuctionCreated(uint256 indexed id, address indexed seller, uint256 startPrice, uint256 endPrice, uint256 endTime);
    event AuctionSold(uint256 indexed id, address indexed buyer, uint256 price);
    event AuctionCancelled(uint256 indexed id, address indexed seller);
    event AuctionExpiredReclaimed(uint256 indexed id, address indexed seller);
    event FeeWithdrawn(address indexed to, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        da = new DutchAuction(FEE);
        vm.deal(alice, 20 ether);
        vm.deal(bob,   20 ether);
        vm.deal(carol, 20 ether);
    }

    function _create() internal returns (uint256 id) {
        vm.prank(alice);
        id = da.createAuction{value: ITEM_VALUE}(START, END_PRICE, DURATION);
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsParams() public view {
        assertEq(da.owner(), owner);
        assertEq(da.feeBps(), FEE);
    }

    function test_Constructor_RevertFeeTooHigh() public {
        vm.expectRevert(IDutchAuction.FeeTooHigh.selector);
        new DutchAuction(501);
    }

    // ─── CreateAuction ─────────────────────────────────────────────────────────

    function test_Create_Success() public {
        uint256 id = _create();
        assertEq(id, 1);
        assertEq(da.auctionCount(), 1);
    }

    function test_Create_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit AuctionCreated(1, alice, START, END_PRICE, 0);
        vm.prank(alice);
        da.createAuction{value: ITEM_VALUE}(START, END_PRICE, DURATION);
    }

    function test_Create_RevertStartLteEnd() public {
        vm.prank(alice);
        vm.expectRevert(IDutchAuction.InvalidPrice.selector);
        da.createAuction{value: ITEM_VALUE}(1 ether, 1 ether, DURATION);
    }

    function test_Create_RevertEndPriceTooLow() public {
        vm.prank(alice);
        vm.expectRevert(IDutchAuction.InvalidPrice.selector);
        da.createAuction{value: ITEM_VALUE}(1 ether, 0, DURATION);
    }

    function test_Create_RevertZeroItemValue() public {
        vm.prank(alice);
        vm.expectRevert(IDutchAuction.InvalidPrice.selector);
        da.createAuction{value: 0}(START, END_PRICE, DURATION);
    }

    function test_Create_RevertDurationTooShort() public {
        vm.prank(alice);
        vm.expectRevert(IDutchAuction.InvalidDuration.selector);
        da.createAuction{value: ITEM_VALUE}(START, END_PRICE, 1 minutes);
    }

    function test_Create_RevertDurationTooLong() public {
        vm.prank(alice);
        vm.expectRevert(IDutchAuction.InvalidDuration.selector);
        da.createAuction{value: ITEM_VALUE}(START, END_PRICE, 31 days);
    }

    function test_Create_RevertWhenPaused() public {
        da.pause();
        vm.prank(alice);
        vm.expectRevert(IDutchAuction.Paused.selector);
        da.createAuction{value: ITEM_VALUE}(START, END_PRICE, DURATION);
    }

    // ─── CurrentPrice ──────────────────────────────────────────────────────────

    function test_CurrentPrice_AtStart() public {
        _create();
        assertEq(da.currentPrice(1), START);
    }

    function test_CurrentPrice_AtHalfway() public {
        _create();
        skip(DURATION / 2);
        uint256 expected = START - (START - END_PRICE) / 2;
        assertApproxEqAbs(da.currentPrice(1), expected, 1e9);
    }

    function test_CurrentPrice_AtEnd() public {
        _create();
        skip(DURATION + 1);
        assertEq(da.currentPrice(1), END_PRICE);
    }

    function test_CurrentPrice_Decreases() public {
        _create();
        uint256 p1 = da.currentPrice(1);
        skip(DURATION / 4);
        uint256 p2 = da.currentPrice(1);
        assertGt(p1, p2);
    }

    // ─── Buy ───────────────────────────────────────────────────────────────────

    function test_Buy_AtStartPrice() public {
        _create();
        uint256 price = da.currentPrice(1);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        da.buy{value: price}(1);
        // Bob receives item value
        assertEq(bob.balance, bobBefore - price + ITEM_VALUE);
    }

    function test_Buy_SellerReceivesProceeds() public {
        _create();
        uint256 price = da.currentPrice(1);
        uint256 fee = (price * FEE) / 10_000;
        uint256 aliceBefore = alice.balance;
        vm.prank(bob);
        da.buy{value: price}(1);
        assertEq(alice.balance, aliceBefore + price - fee);
    }

    function test_Buy_OverpaymentRefunded() public {
        _create();
        uint256 price = da.currentPrice(1);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        da.buy{value: price + 5 ether}(1);
        // Bob paid price, got item value back, overpay refunded
        assertEq(bob.balance, bobBefore - price + ITEM_VALUE);
    }

    function test_Buy_EmitsEvent() public {
        _create();
        uint256 price = da.currentPrice(1);
        vm.expectEmit(true, true, false, true);
        emit AuctionSold(1, bob, price);
        vm.prank(bob);
        da.buy{value: price}(1);
    }

    function test_Buy_AtLowerPrice() public {
        _create();
        skip(DURATION / 2);
        uint256 price = da.currentPrice(1);
        assertLt(price, START);
        vm.prank(bob);
        da.buy{value: price}(1);
        (,,,,,, bool sold,) = da.getAuction(1);
        assertTrue(sold);
    }

    function test_Buy_RevertInsufficientPayment() public {
        _create();
        vm.prank(bob);
        vm.expectRevert(IDutchAuction.InsufficientPayment.selector);
        da.buy{value: 0.001 ether}(1);
    }

    function test_Buy_RevertAlreadySold() public {
        _create();
        uint256 price = da.currentPrice(1);
        vm.prank(bob); da.buy{value: price}(1);
        vm.prank(carol);
        vm.expectRevert(IDutchAuction.AuctionAlreadySold.selector);
        da.buy{value: price}(1);
    }

    function test_Buy_RevertExpired() public {
        _create();
        skip(DURATION + 1);
        vm.prank(bob);
        vm.expectRevert(IDutchAuction.AuctionExpired.selector);
        da.buy{value: END_PRICE}(1);
    }

    function test_Buy_RevertWhenPaused() public {
        _create();
        da.pause();
        vm.prank(bob);
        vm.expectRevert(IDutchAuction.Paused.selector);
        da.buy{value: START}(1);
    }

    // ─── Cancel ────────────────────────────────────────────────────────────────

    function test_Cancel_Success() public {
        _create();
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        da.cancel(1);
        assertEq(alice.balance, aliceBefore + ITEM_VALUE);
        (,,,,,,, bool cancelled) = da.getAuction(1);
        assertTrue(cancelled);
    }

    function test_Cancel_EmitsEvent() public {
        _create();
        vm.expectEmit(true, true, false, false);
        emit AuctionCancelled(1, alice);
        vm.prank(alice);
        da.cancel(1);
    }

    function test_Cancel_RevertNotSeller() public {
        _create();
        vm.prank(bob);
        vm.expectRevert(IDutchAuction.NotSeller.selector);
        da.cancel(1);
    }

    function test_Cancel_RevertAfterExpiry() public {
        _create();
        skip(DURATION + 1);
        vm.prank(alice);
        vm.expectRevert(IDutchAuction.AuctionExpired.selector);
        da.cancel(1);
    }

    // ─── ReclaimExpired ────────────────────────────────────────────────────────

    function test_ReclaimExpired_Success() public {
        _create();
        skip(DURATION + 1);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        da.reclaimExpired(1);
        assertEq(alice.balance, aliceBefore + ITEM_VALUE);
    }

    function test_ReclaimExpired_EmitsEvent() public {
        _create();
        skip(DURATION + 1);
        vm.expectEmit(true, true, false, false);
        emit AuctionExpiredReclaimed(1, alice);
        vm.prank(alice);
        da.reclaimExpired(1);
    }

    function test_ReclaimExpired_RevertNotExpired() public {
        _create();
        vm.prank(alice);
        vm.expectRevert(IDutchAuction.AuctionNotExpired.selector);
        da.reclaimExpired(1);
    }

    function test_ReclaimExpired_RevertNotSeller() public {
        _create();
        skip(DURATION + 1);
        vm.prank(bob);
        vm.expectRevert(IDutchAuction.NotSeller.selector);
        da.reclaimExpired(1);
    }

    // ─── WithdrawFees ──────────────────────────────────────────────────────────

    function test_WithdrawFees_Success() public {
        _create();
        uint256 price = da.currentPrice(1);
        vm.prank(bob); da.buy{value: price}(1);
        uint256 fee = da.accruedFees();
        uint256 before = owner.balance;
        da.withdrawFees();
        assertEq(owner.balance, before + fee);
        assertEq(da.accruedFees(), 0);
    }

    function test_WithdrawFees_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(IDutchAuction.NotOwner.selector);
        da.withdrawFees();
    }

    // ─── Pause / Ownership ─────────────────────────────────────────────────────

    function test_Pause_Unpause() public {
        da.pause();
        assertTrue(da.paused());
        da.unpause();
        assertFalse(da.paused());
    }

    function test_TwoStepOwnership() public {
        da.transferOwnership(alice);
        assertEq(da.pendingOwner(), alice);
        vm.prank(alice);
        da.acceptOwnership();
        assertEq(da.owner(), alice);
    }

    function test_TransferOwnership_RevertZeroAddress() public {
        vm.expectRevert(IDutchAuction.ZeroAddress.selector);
        da.transferOwnership(address(0));
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_PriceDecay(uint256 elapsed) public {
        _create();
        elapsed = bound(elapsed, 0, DURATION);
        skip(elapsed);
        uint256 price = da.currentPrice(1);
        assertGe(price, END_PRICE);
        assertLe(price, START);
    }

    function testFuzz_BuyAtAnyTime(uint256 elapsed) public {
        _create();
        elapsed = bound(elapsed, 0, DURATION - 1);
        skip(elapsed);
        uint256 price = da.currentPrice(1);
        vm.deal(bob, price + 1 ether);
        vm.prank(bob);
        da.buy{value: price}(1);
        (,,,,,, bool sold,) = da.getAuction(1);
        assertTrue(sold);
    }

    // ─── Invariant ─────────────────────────────────────────────────────────────

    function test_Invariant_BalanceEqualsItemValuePlusFees() public {
        _create();
        assertEq(address(da).balance, ITEM_VALUE + da.accruedFees());
    }

    receive() external payable {}
}
