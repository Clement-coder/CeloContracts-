// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTMarketplace} from "../src/NFTMarketplace.sol";
import {INFTMarketplace} from "../src/INFTMarketplace.sol";
import {MockERC721} from "../src/MockERC721.sol";

contract NFTMarketplaceTest is Test {
    NFTMarketplace market;
    MockERC721 nft;

    address owner = address(this);
    address alice = makeAddr("alice"); // seller
    address bob   = makeAddr("bob");   // buyer
    address carol = makeAddr("carol");

    uint256 constant FEE  = 250;        // 2.5%
    uint256 constant PRICE = 1 ether;

    // Mirror events
    event Listed(address indexed nft, uint256 indexed tokenId, address indexed seller, uint256 price);
    event Delisted(address indexed nft, uint256 indexed tokenId, address indexed seller);
    event Sold(address indexed nft, uint256 indexed tokenId, address indexed buyer, address seller, uint256 price);
    event PriceUpdated(address indexed nft, uint256 indexed tokenId, uint256 oldPrice, uint256 newPrice);
    event EarningsWithdrawn(address indexed seller, uint256 amount);
    event FeeWithdrawn(address indexed to, uint256 amount);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        market = new NFTMarketplace(FEE);
        nft    = new MockERC721();
        vm.deal(alice, 10 ether);
        vm.deal(bob,   10 ether);
        vm.deal(carol, 10 ether);
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────

    function _mintAndApprove(address to) internal returns (uint256 id) {
        id = nft.mint(to);
        vm.prank(to);
        nft.approve(address(market), id);
    }

    function _listToken(address seller, uint256 price) internal returns (uint256 id) {
        id = _mintAndApprove(seller);
        vm.prank(seller);
        market.listNFT(address(nft), id, price);
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsOwnerAndFee() public view {
        assertEq(market.owner(), owner);
        assertEq(market.feeBps(), FEE);
    }

    function test_Constructor_RevertFeeTooHigh() public {
        vm.expectRevert(INFTMarketplace.FeeTooHigh.selector);
        new NFTMarketplace(1_001);
    }

    // ─── ListNFT ───────────────────────────────────────────────────────────────

    function test_ListNFT_Success() public {
        uint256 id = _listToken(alice, PRICE);
        (address seller, uint256 price, bool active) = market.getListing(address(nft), id);
        assertEq(seller, alice);
        assertEq(price, PRICE);
        assertTrue(active);
    }

    function test_ListNFT_EmitsEvent() public {
        uint256 id = _mintAndApprove(alice);
        vm.expectEmit(true, true, true, true);
        emit Listed(address(nft), id, alice, PRICE);
        vm.prank(alice);
        market.listNFT(address(nft), id, PRICE);
    }

    function test_ListNFT_RevertNotTokenOwner() public {
        uint256 id = _mintAndApprove(alice);
        vm.prank(bob);
        vm.expectRevert(INFTMarketplace.NotTokenOwner.selector);
        market.listNFT(address(nft), id, PRICE);
    }

    function test_ListNFT_RevertNotApproved() public {
        uint256 id = nft.mint(alice); // no approval
        vm.prank(alice);
        vm.expectRevert(INFTMarketplace.NotApproved.selector);
        market.listNFT(address(nft), id, PRICE);
    }

    function test_ListNFT_RevertAlreadyListed() public {
        uint256 id = _listToken(alice, PRICE);
        vm.prank(alice);
        nft.approve(address(market), id);
        vm.prank(alice);
        vm.expectRevert(INFTMarketplace.AlreadyListed.selector);
        market.listNFT(address(nft), id, PRICE);
    }

    function test_ListNFT_RevertPriceTooLow() public {
        uint256 id = _mintAndApprove(alice);
        vm.prank(alice);
        vm.expectRevert(INFTMarketplace.PriceTooLow.selector);
        market.listNFT(address(nft), id, 1);
    }

    function test_ListNFT_RevertZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(INFTMarketplace.ZeroAddress.selector);
        market.listNFT(address(0), 1, PRICE);
    }

    function test_ListNFT_RevertWhenPaused() public {
        market.pause();
        uint256 id = _mintAndApprove(alice);
        vm.prank(alice);
        vm.expectRevert(INFTMarketplace.Paused.selector);
        market.listNFT(address(nft), id, PRICE);
    }

    // ─── DelistNFT ─────────────────────────────────────────────────────────────

    function test_DelistNFT_Success() public {
        uint256 id = _listToken(alice, PRICE);
        vm.prank(alice);
        market.delistNFT(address(nft), id);
        (,, bool active) = market.getListing(address(nft), id);
        assertFalse(active);
    }

    function test_DelistNFT_EmitsEvent() public {
        uint256 id = _listToken(alice, PRICE);
        vm.expectEmit(true, true, true, false);
        emit Delisted(address(nft), id, alice);
        vm.prank(alice);
        market.delistNFT(address(nft), id);
    }

    function test_DelistNFT_RevertNotListed() public {
        vm.prank(alice);
        vm.expectRevert(INFTMarketplace.NotListed.selector);
        market.delistNFT(address(nft), 999);
    }

    function test_DelistNFT_RevertNotSeller() public {
        uint256 id = _listToken(alice, PRICE);
        vm.prank(bob);
        vm.expectRevert(INFTMarketplace.NotTokenOwner.selector);
        market.delistNFT(address(nft), id);
    }

    // ─── UpdatePrice ───────────────────────────────────────────────────────────

    function test_UpdatePrice_Success() public {
        uint256 id = _listToken(alice, PRICE);
        vm.prank(alice);
        market.updatePrice(address(nft), id, 2 ether);
        (, uint256 price,) = market.getListing(address(nft), id);
        assertEq(price, 2 ether);
    }

    function test_UpdatePrice_EmitsEvent() public {
        uint256 id = _listToken(alice, PRICE);
        vm.expectEmit(true, true, false, true);
        emit PriceUpdated(address(nft), id, PRICE, 2 ether);
        vm.prank(alice);
        market.updatePrice(address(nft), id, 2 ether);
    }

    function test_UpdatePrice_RevertNotListed() public {
        vm.prank(alice);
        vm.expectRevert(INFTMarketplace.NotListed.selector);
        market.updatePrice(address(nft), 999, 2 ether);
    }

    function test_UpdatePrice_RevertNotSeller() public {
        uint256 id = _listToken(alice, PRICE);
        vm.prank(bob);
        vm.expectRevert(INFTMarketplace.NotTokenOwner.selector);
        market.updatePrice(address(nft), id, 2 ether);
    }

    function test_UpdatePrice_RevertPriceTooLow() public {
        uint256 id = _listToken(alice, PRICE);
        vm.prank(alice);
        vm.expectRevert(INFTMarketplace.PriceTooLow.selector);
        market.updatePrice(address(nft), id, 1);
    }

    // ─── BuyNFT ────────────────────────────────────────────────────────────────

    function test_BuyNFT_Success() public {
        uint256 id = _listToken(alice, PRICE);
        vm.prank(bob);
        market.buyNFT{value: PRICE}(address(nft), id);
        assertEq(nft.ownerOf(id), bob);
        (,, bool active) = market.getListing(address(nft), id);
        assertFalse(active);
    }

    function test_BuyNFT_SellerEarningsCorrect() public {
        uint256 id = _listToken(alice, PRICE);
        vm.prank(bob);
        market.buyNFT{value: PRICE}(address(nft), id);
        uint256 fee = (PRICE * FEE) / 10_000;
        assertEq(market.earnings(alice), PRICE - fee);
        assertEq(market.accruedFees(), fee);
    }

    function test_BuyNFT_EmitsEvent() public {
        uint256 id = _listToken(alice, PRICE);
        vm.expectEmit(true, true, true, true);
        emit Sold(address(nft), id, bob, alice, PRICE);
        vm.prank(bob);
        market.buyNFT{value: PRICE}(address(nft), id);
    }

    function test_BuyNFT_OverpaymentRefunded() public {
        uint256 id = _listToken(alice, PRICE);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        market.buyNFT{value: 2 ether}(address(nft), id);
        assertEq(bob.balance, bobBefore - PRICE); // only PRICE deducted
    }

    function test_BuyNFT_RevertNotListed() public {
        vm.prank(bob);
        vm.expectRevert(INFTMarketplace.NotListed.selector);
        market.buyNFT{value: PRICE}(address(nft), 999);
    }

    function test_BuyNFT_RevertInsufficientPayment() public {
        uint256 id = _listToken(alice, PRICE);
        vm.prank(bob);
        vm.expectRevert(INFTMarketplace.InsufficientPayment.selector);
        market.buyNFT{value: 0.5 ether}(address(nft), id);
    }

    function test_BuyNFT_RevertCannotBuyOwnListing() public {
        uint256 id = _listToken(alice, PRICE);
        vm.prank(alice);
        vm.expectRevert(INFTMarketplace.CannotBuyOwnListing.selector);
        market.buyNFT{value: PRICE}(address(nft), id);
    }

    function test_BuyNFT_RevertWhenPaused() public {
        uint256 id = _listToken(alice, PRICE);
        market.pause();
        vm.prank(bob);
        vm.expectRevert(INFTMarketplace.Paused.selector);
        market.buyNFT{value: PRICE}(address(nft), id);
    }

    // ─── WithdrawEarnings ──────────────────────────────────────────────────────

    function test_WithdrawEarnings_Success() public {
        uint256 id = _listToken(alice, PRICE);
        vm.prank(bob);
        market.buyNFT{value: PRICE}(address(nft), id);
        uint256 expected = market.earnings(alice);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        market.withdrawEarnings();
        assertEq(alice.balance, aliceBefore + expected);
        assertEq(market.earnings(alice), 0);
    }

    function test_WithdrawEarnings_EmitsEvent() public {
        uint256 id = _listToken(alice, PRICE);
        vm.prank(bob);
        market.buyNFT{value: PRICE}(address(nft), id);
        uint256 expected = market.earnings(alice);
        vm.expectEmit(true, false, false, true);
        emit EarningsWithdrawn(alice, expected);
        vm.prank(alice);
        market.withdrawEarnings();
    }

    function test_WithdrawEarnings_RevertNoEarnings() public {
        vm.prank(alice);
        vm.expectRevert(INFTMarketplace.NoEarnings.selector);
        market.withdrawEarnings();
    }

    // ─── WithdrawFees ──────────────────────────────────────────────────────────

    function test_WithdrawFees_Success() public {
        uint256 id = _listToken(alice, PRICE);
        vm.prank(bob);
        market.buyNFT{value: PRICE}(address(nft), id);
        uint256 fee = market.accruedFees();
        uint256 ownerBefore = owner.balance;
        market.withdrawFees();
        assertEq(owner.balance, ownerBefore + fee);
        assertEq(market.accruedFees(), 0);
    }

    function test_WithdrawFees_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(INFTMarketplace.NotOwner.selector);
        market.withdrawFees();
    }

    function test_WithdrawFees_RevertNoFees() public {
        vm.expectRevert(INFTMarketplace.NoEarnings.selector);
        market.withdrawFees();
    }

    // ─── SetFee ────────────────────────────────────────────────────────────────

    function test_SetFee_Success() public {
        vm.expectEmit(false, false, false, true);
        emit FeeUpdated(FEE, 500);
        market.setFee(500);
        assertEq(market.feeBps(), 500);
    }

    function test_SetFee_RevertFeeTooHigh() public {
        vm.expectRevert(INFTMarketplace.FeeTooHigh.selector);
        market.setFee(1_001);
    }

    function test_SetFee_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(INFTMarketplace.NotOwner.selector);
        market.setFee(100);
    }

    // ─── Pause ─────────────────────────────────────────────────────────────────

    function test_Pause_Unpause() public {
        market.pause();
        assertTrue(market.paused());
        market.unpause();
        assertFalse(market.paused());
    }

    function test_Pause_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(INFTMarketplace.NotOwner.selector);
        market.pause();
    }

    // ─── Ownership ─────────────────────────────────────────────────────────────

    function test_TwoStepOwnership() public {
        market.transferOwnership(alice);
        assertEq(market.pendingOwner(), alice);
        vm.prank(alice);
        market.acceptOwnership();
        assertEq(market.owner(), alice);
        assertEq(market.pendingOwner(), address(0));
    }

    function test_TransferOwnership_RevertZeroAddress() public {
        vm.expectRevert(INFTMarketplace.ZeroAddress.selector);
        market.transferOwnership(address(0));
    }

    function test_AcceptOwnership_RevertNotPending() public {
        market.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(INFTMarketplace.NotPendingOwner.selector);
        market.acceptOwnership();
    }

    function test_TransferOwnership_EmitsEvents() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferStarted(owner, alice);
        market.transferOwnership(alice);
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, alice);
        vm.prank(alice);
        market.acceptOwnership();
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_ListAndBuy(uint256 price) public {
        price = bound(price, market.MIN_PRICE(), 5 ether);
        vm.deal(bob, price + 1 ether);
        uint256 id = _listToken(alice, price);
        vm.prank(bob);
        market.buyNFT{value: price}(address(nft), id);
        assertEq(nft.ownerOf(id), bob);
    }

    function testFuzz_FeeCalculation(uint256 price, uint256 fee) public {
        price = bound(price, market.MIN_PRICE(), 5 ether);
        fee   = bound(fee, 0, market.MAX_FEE_BPS());
        market.setFee(fee);
        vm.deal(bob, price + 1 ether);
        uint256 id = _listToken(alice, price);
        vm.prank(bob);
        market.buyNFT{value: price}(address(nft), id);
        uint256 expectedFee = (price * fee) / 10_000;
        assertEq(market.accruedFees(), expectedFee);
        assertEq(market.earnings(alice), price - expectedFee);
    }

    // ─── Invariant ─────────────────────────────────────────────────────────────

    function test_Invariant_BalanceCoversEarningsAndFees() public {
        uint256 id = _listToken(alice, PRICE);
        vm.prank(bob);
        market.buyNFT{value: PRICE}(address(nft), id);
        assertGe(address(market).balance, market.earnings(alice) + market.accruedFees());
    }

    receive() external payable {}
}
// Commit 11 optimization
