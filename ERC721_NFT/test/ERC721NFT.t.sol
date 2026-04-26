// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC721NFT} from "../src/ERC721NFT.sol";
import {IERC721NFT} from "../src/IERC721NFT.sol";

contract ERC721NFTTest is Test {
    ERC721NFT nft;
    address owner = address(this);
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    uint256 constant CAP = 100;
    string  constant URI = "ipfs://QmTest/1.json";

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event Minted(address indexed to, uint256 indexed tokenId, string tokenURI);
    event Burned(address indexed from, uint256 indexed tokenId);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        nft = new ERC721NFT("CeloNFT", "CNFT", CAP);
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsMetadata() public view {
        assertEq(nft.name(), "CeloNFT");
        assertEq(nft.symbol(), "CNFT");
        assertEq(nft.CAP(), CAP);
        assertEq(nft.owner(), owner);
        assertEq(nft.totalSupply(), 0);
    }

    function test_Constructor_RevertZeroCap() public {
        vm.expectRevert(IERC721NFT.ZeroAmount.selector);
        new ERC721NFT("T", "T", 0);
    }

    // ─── Mint ──────────────────────────────────────────────────────────────────

    function test_Mint_Success() public {
        uint256 id = nft.mint(alice, URI);
        assertEq(id, 1);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.totalSupply(), 1);
        assertEq(nft.tokenURI(1), URI);
    }

    function test_Mint_IncrementsTokenId() public {
        uint256 id1 = nft.mint(alice, URI);
        uint256 id2 = nft.mint(bob, URI);
        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    function test_Mint_EmitsEvents() public {
        vm.expectEmit(true, true, true, false);
        emit Transfer(address(0), alice, 1);
        vm.expectEmit(true, true, false, true);
        emit Minted(alice, 1, URI);
        nft.mint(alice, URI);
    }

    function test_Mint_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(IERC721NFT.NotOwner.selector);
        nft.mint(alice, URI);
    }

    function test_Mint_RevertZeroAddress() public {
        vm.expectRevert(IERC721NFT.ZeroAddress.selector);
        nft.mint(address(0), URI);
    }

    function test_Mint_RevertCapExceeded() public {
        for (uint256 i = 0; i < CAP; i++) nft.mint(alice, URI);
        vm.expectRevert(IERC721NFT.CapExceeded.selector);
        nft.mint(alice, URI);
    }

    function test_Mint_RevertWhenPaused() public {
        nft.pause();
        vm.expectRevert(IERC721NFT.Paused.selector);
        nft.mint(alice, URI);
    }

    // ─── Burn ──────────────────────────────────────────────────────────────────

    function test_Burn_ByOwner() public {
        nft.mint(alice, URI);
        vm.prank(alice);
        nft.burn(1);
        assertEq(nft.totalSupply(), 0);
        assertEq(nft.balanceOf(alice), 0);
    }

    function test_Burn_EmitsEvents() public {
        nft.mint(alice, URI);
        vm.expectEmit(true, true, true, false);
        emit Transfer(alice, address(0), 1);
        vm.expectEmit(true, true, false, false);
        emit Burned(alice, 1);
        vm.prank(alice);
        nft.burn(1);
    }

    function test_Burn_ByApproved() public {
        nft.mint(alice, URI);
        vm.prank(alice);
        nft.approve(bob, 1);
        vm.prank(bob);
        nft.burn(1);
        assertEq(nft.totalSupply(), 0);
    }

    function test_Burn_ByOperator() public {
        nft.mint(alice, URI);
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        vm.prank(bob);
        nft.burn(1);
        assertEq(nft.totalSupply(), 0);
    }

    function test_Burn_RevertNotApproved() public {
        nft.mint(alice, URI);
        vm.prank(bob);
        vm.expectRevert(IERC721NFT.NotApproved.selector);
        nft.burn(1);
    }

    function test_Burn_RevertTokenNotFound() public {
        vm.expectRevert(IERC721NFT.TokenNotFound.selector);
        nft.burn(99);
    }

    function test_Burn_ClearsTokenURI() public {
        nft.mint(alice, URI);
        vm.prank(alice);
        nft.burn(1);
        vm.expectRevert(IERC721NFT.TokenNotFound.selector);
        nft.tokenURI(1);
    }

    // ─── TransferFrom ──────────────────────────────────────────────────────────

    function test_TransferFrom_ByOwner() public {
        nft.mint(alice, URI);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        assertEq(nft.ownerOf(1), bob);
        assertEq(nft.balanceOf(alice), 0);
        assertEq(nft.balanceOf(bob), 1);
    }

    function test_TransferFrom_EmitsEvent() public {
        nft.mint(alice, URI);
        vm.expectEmit(true, true, true, false);
        emit Transfer(alice, bob, 1);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
    }

    function test_TransferFrom_ByApproved() public {
        nft.mint(alice, URI);
        vm.prank(alice);
        nft.approve(bob, 1);
        vm.prank(bob);
        nft.transferFrom(alice, bob, 1);
        assertEq(nft.ownerOf(1), bob);
    }

    function test_TransferFrom_ClearsApproval() public {
        nft.mint(alice, URI);
        vm.prank(alice);
        nft.approve(bob, 1);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        assertEq(nft.getApproved(1), address(0));
    }

    function test_TransferFrom_ByOperator() public {
        nft.mint(alice, URI);
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        vm.prank(bob);
        nft.transferFrom(alice, bob, 1);
        assertEq(nft.ownerOf(1), bob);
    }

    function test_TransferFrom_RevertNotApproved() public {
        nft.mint(alice, URI);
        vm.prank(bob);
        vm.expectRevert(IERC721NFT.NotApproved.selector);
        nft.transferFrom(alice, bob, 1);
    }

    function test_TransferFrom_RevertWrongFrom() public {
        nft.mint(alice, URI);
        vm.prank(alice);
        vm.expectRevert(IERC721NFT.NotTokenOwner.selector);
        nft.transferFrom(bob, alice, 1);
    }

    function test_TransferFrom_RevertZeroAddress() public {
        nft.mint(alice, URI);
        vm.prank(alice);
        vm.expectRevert(IERC721NFT.ZeroAddress.selector);
        nft.transferFrom(alice, address(0), 1);
    }

    function test_TransferFrom_RevertWhenPaused() public {
        nft.mint(alice, URI);
        nft.pause();
        vm.prank(alice);
        vm.expectRevert(IERC721NFT.Paused.selector);
        nft.transferFrom(alice, bob, 1);
    }

    // ─── Approve ───────────────────────────────────────────────────────────────

    function test_Approve_Success() public {
        nft.mint(alice, URI);
        vm.prank(alice);
        nft.approve(bob, 1);
        assertEq(nft.getApproved(1), bob);
    }

    function test_Approve_EmitsEvent() public {
        nft.mint(alice, URI);
        vm.expectEmit(true, true, true, false);
        emit Approval(alice, bob, 1);
        vm.prank(alice);
        nft.approve(bob, 1);
    }

    function test_Approve_ByOperator() public {
        nft.mint(alice, URI);
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        vm.prank(bob);
        nft.approve(bob, 1); // operator can approve
        assertEq(nft.getApproved(1), bob);
    }

    function test_Approve_RevertNotOwner() public {
        nft.mint(alice, URI);
        vm.prank(bob);
        vm.expectRevert(IERC721NFT.NotTokenOwner.selector);
        nft.approve(bob, 1);
    }

    function test_Approve_RevertTokenNotFound() public {
        vm.expectRevert(IERC721NFT.TokenNotFound.selector);
        nft.getApproved(99);
    }

    // ─── SetApprovalForAll ─────────────────────────────────────────────────────

    function test_SetApprovalForAll_Success() public {
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        assertTrue(nft.isApprovedForAll(alice, bob));
    }

    function test_SetApprovalForAll_Revoke() public {
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        vm.prank(alice);
        nft.setApprovalForAll(bob, false);
        assertFalse(nft.isApprovedForAll(alice, bob));
    }

    function test_SetApprovalForAll_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit ApprovalForAll(alice, bob, true);
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
    }

    function test_SetApprovalForAll_RevertZeroAddress() public {
        vm.expectRevert(IERC721NFT.ZeroAddress.selector);
        nft.setApprovalForAll(address(0), true);
    }

    // ─── BalanceOf / OwnerOf ───────────────────────────────────────────────────

    function test_BalanceOf_RevertZeroAddress() public {
        vm.expectRevert(IERC721NFT.ZeroAddress.selector);
        nft.balanceOf(address(0));
    }

    function test_OwnerOf_RevertTokenNotFound() public {
        vm.expectRevert(IERC721NFT.TokenNotFound.selector);
        nft.ownerOf(99);
    }

    // ─── Pause ─────────────────────────────────────────────────────────────────

    function test_Pause_Unpause() public {
        nft.pause();
        assertTrue(nft.paused());
        nft.unpause();
        assertFalse(nft.paused());
    }

    function test_Pause_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(IERC721NFT.NotOwner.selector);
        nft.pause();
    }

    // ─── Ownership ─────────────────────────────────────────────────────────────

    function test_TwoStepOwnership() public {
        nft.transferOwnership(alice);
        assertEq(nft.pendingOwner(), alice);
        vm.prank(alice);
        nft.acceptOwnership();
        assertEq(nft.owner(), alice);
        assertEq(nft.pendingOwner(), address(0));
    }

    function test_TransferOwnership_RevertZeroAddress() public {
        vm.expectRevert(IERC721NFT.ZeroAddress.selector);
        nft.transferOwnership(address(0));
    }

    function test_AcceptOwnership_RevertNotPending() public {
        nft.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(IERC721NFT.NotPendingOwner.selector);
        nft.acceptOwnership();
    }

    function test_Ownership_EmitsEvents() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferStarted(owner, alice);
        nft.transferOwnership(alice);

        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, alice);
        vm.prank(alice);
        nft.acceptOwnership();
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_MintMultiple(uint256 count) public {
        count = bound(count, 1, CAP);
        for (uint256 i = 0; i < count; i++) nft.mint(alice, URI);
        assertEq(nft.totalSupply(), count);
        assertEq(nft.balanceOf(alice), count);
    }

    // ─── Invariant ─────────────────────────────────────────────────────────────

    function test_Invariant_TotalSupplyLeqCap() public {
        for (uint256 i = 0; i < 10; i++) nft.mint(alice, URI);
        assertLe(nft.totalSupply(), nft.CAP());
    }

    function test_Invariant_BalanceSumAfterTransfer() public {
        nft.mint(alice, URI);
        nft.mint(alice, URI);
        vm.startPrank(alice);
        nft.transferFrom(alice, bob, 1);
        vm.stopPrank();
        assertEq(nft.balanceOf(alice) + nft.balanceOf(bob), 2);
    }
}
// Commit 16 optimization
// Commit 36 optimization
