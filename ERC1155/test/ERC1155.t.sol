// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1155, IERC1155Receiver} from "../src/ERC1155.sol";
import {IERC1155} from "../src/IERC1155.sol";

/// @dev Receiver contract that accepts all ERC-1155 transfers.
contract GoodReceiver is IERC1155Receiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }
    function supportsInterface(bytes4) external pure returns (bool) { return true; }
}

/// @dev Receiver contract that rejects all ERC-1155 transfers.
contract BadReceiver {
    // Does not implement IERC1155Receiver — will cause revert
}

/// @dev Receiver that returns wrong selector.
contract WrongSelectorReceiver is IERC1155Receiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
    function supportsInterface(bytes4) external pure returns (bool) { return false; }
}

contract ERC1155Test is Test {
    ERC1155 token;

    address owner = address(this);
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant ID1 = 1;
    uint256 constant ID2 = 2;
    uint256 constant ID3 = 3;
    uint256 constant AMT = 100;

    // Mirror events
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);
    event TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values);
    event ApprovalForAll(address indexed account, address indexed operator, bool approved);

    function setUp() public {
        token = new ERC1155("ipfs://base/");
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsOwner() public view {
        assertEq(token.owner(), owner);
    }

    function test_Constructor_SetsBaseURI() public view {
        assertEq(token.baseURI(), "ipfs://base/");
    }

    // ─── Mint ──────────────────────────────────────────────────────────────────

    function test_Mint_UpdatesBalance() public {
        token.mint(alice, ID1, AMT, "");
        assertEq(token.balanceOf(alice, ID1), AMT);
    }

    function test_Mint_EmitsTransferSingle() public {
        vm.expectEmit(true, true, true, true);
        emit TransferSingle(owner, address(0), alice, ID1, AMT);
        token.mint(alice, ID1, AMT, "");
    }

    function test_Mint_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(IERC1155.NotOwner.selector);
        token.mint(alice, ID1, AMT, "");
    }

    function test_Mint_RevertZeroAddress() public {
        vm.expectRevert(IERC1155.ZeroAddress.selector);
        token.mint(address(0), ID1, AMT, "");
    }

    function test_Mint_MultipleIds() public {
        token.mint(alice, ID1, 10, "");
        token.mint(alice, ID2, 20, "");
        assertEq(token.balanceOf(alice, ID1), 10);
        assertEq(token.balanceOf(alice, ID2), 20);
    }

    function test_Mint_AccumulatesBalance() public {
        token.mint(alice, ID1, 50, "");
        token.mint(alice, ID1, 50, "");
        assertEq(token.balanceOf(alice, ID1), 100);
    }

    function test_Mint_ToGoodReceiver() public {
        GoodReceiver recv = new GoodReceiver();
        token.mint(address(recv), ID1, AMT, "");
        assertEq(token.balanceOf(address(recv), ID1), AMT);
    }

    function test_Mint_RevertBadReceiver() public {
        BadReceiver recv = new BadReceiver();
        vm.expectRevert(IERC1155.UnsafeRecipient.selector);
        token.mint(address(recv), ID1, AMT, "");
    }

    function test_Mint_RevertWrongSelectorReceiver() public {
        WrongSelectorReceiver recv = new WrongSelectorReceiver();
        vm.expectRevert(IERC1155.UnsafeRecipient.selector);
        token.mint(address(recv), ID1, AMT, "");
    }

    // ─── MintBatch ─────────────────────────────────────────────────────────────

    function test_MintBatch_UpdatesBalances() public {
        uint256[] memory ids = _ids(ID1, ID2, ID3);
        uint256[] memory amts = _amts(10, 20, 30);
        token.mintBatch(alice, ids, amts, "");
        assertEq(token.balanceOf(alice, ID1), 10);
        assertEq(token.balanceOf(alice, ID2), 20);
        assertEq(token.balanceOf(alice, ID3), 30);
    }

    function test_MintBatch_EmitsTransferBatch() public {
        uint256[] memory ids = _ids(ID1, ID2);
        uint256[] memory amts = _amts(10, 20);
        vm.expectEmit(true, true, true, false);
        emit TransferBatch(owner, address(0), alice, ids, amts);
        token.mintBatch(alice, ids, amts, "");
    }

    function test_MintBatch_RevertLengthMismatch() public {
        uint256[] memory ids = _ids(ID1, ID2);
        uint256[] memory amts = _amts(10);
        vm.expectRevert(IERC1155.LengthMismatch.selector);
        token.mintBatch(alice, ids, amts, "");
    }

    function test_MintBatch_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(IERC1155.NotOwner.selector);
        token.mintBatch(alice, _ids(ID1), _amts(10), "");
    }

    function test_MintBatch_RevertZeroAddress() public {
        vm.expectRevert(IERC1155.ZeroAddress.selector);
        token.mintBatch(address(0), _ids(ID1), _amts(10), "");
    }

    // ─── Burn ──────────────────────────────────────────────────────────────────

    function test_Burn_DecreasesBalance() public {
        token.mint(alice, ID1, AMT, "");
        vm.prank(alice);
        token.burn(alice, ID1, 40);
        assertEq(token.balanceOf(alice, ID1), 60);
    }

    function test_Burn_EmitsTransferSingle() public {
        token.mint(alice, ID1, AMT, "");
        vm.expectEmit(true, true, true, true);
        emit TransferSingle(alice, alice, address(0), ID1, AMT);
        vm.prank(alice);
        token.burn(alice, ID1, AMT);
    }

    function test_Burn_RevertInsufficientBalance() public {
        token.mint(alice, ID1, 10, "");
        vm.prank(alice);
        vm.expectRevert(); // arithmetic underflow
        token.burn(alice, ID1, 11);
    }

    function test_Burn_RevertNotApproved() public {
        token.mint(alice, ID1, AMT, "");
        vm.prank(bob);
        vm.expectRevert(IERC1155.NotOwnerOrApproved.selector);
        token.burn(alice, ID1, AMT);
    }

    function test_Burn_ByApprovedOperator() public {
        token.mint(alice, ID1, AMT, "");
        vm.prank(alice);
        token.setApprovalForAll(bob, true);
        vm.prank(bob);
        token.burn(alice, ID1, AMT);
        assertEq(token.balanceOf(alice, ID1), 0);
    }

    // ─── BurnBatch ─────────────────────────────────────────────────────────────

    function test_BurnBatch_DecreasesBalances() public {
        token.mintBatch(alice, _ids(ID1, ID2), _amts(50, 80), "");
        vm.prank(alice);
        token.burnBatch(alice, _ids(ID1, ID2), _amts(20, 30));
        assertEq(token.balanceOf(alice, ID1), 30);
        assertEq(token.balanceOf(alice, ID2), 50);
    }

    function test_BurnBatch_RevertLengthMismatch() public {
        token.mintBatch(alice, _ids(ID1, ID2), _amts(50, 80), "");
        vm.prank(alice);
        vm.expectRevert(IERC1155.LengthMismatch.selector);
        token.burnBatch(alice, _ids(ID1, ID2), _amts(20));
    }

    function test_BurnBatch_RevertNotApproved() public {
        token.mint(alice, ID1, AMT, "");
        vm.prank(bob);
        vm.expectRevert(IERC1155.NotOwnerOrApproved.selector);
        token.burnBatch(alice, _ids(ID1), _amts(AMT));
    }

    // ─── SafeTransferFrom ──────────────────────────────────────────────────────

    function test_SafeTransferFrom_UpdatesBalances() public {
        token.mint(alice, ID1, AMT, "");
        vm.prank(alice);
        token.safeTransferFrom(alice, bob, ID1, 40, "");
        assertEq(token.balanceOf(alice, ID1), 60);
        assertEq(token.balanceOf(bob,   ID1), 40);
    }

    function test_SafeTransferFrom_EmitsEvent() public {
        token.mint(alice, ID1, AMT, "");
        vm.expectEmit(true, true, true, true);
        emit TransferSingle(alice, alice, bob, ID1, AMT);
        vm.prank(alice);
        token.safeTransferFrom(alice, bob, ID1, AMT, "");
    }

    function test_SafeTransferFrom_ByApprovedOperator() public {
        token.mint(alice, ID1, AMT, "");
        vm.prank(alice);
        token.setApprovalForAll(bob, true);
        vm.prank(bob);
        token.safeTransferFrom(alice, carol, ID1, AMT, "");
        assertEq(token.balanceOf(carol, ID1), AMT);
    }

    function test_SafeTransferFrom_RevertNotApproved() public {
        token.mint(alice, ID1, AMT, "");
        vm.prank(bob);
        vm.expectRevert(IERC1155.NotOwnerOrApproved.selector);
        token.safeTransferFrom(alice, bob, ID1, AMT, "");
    }

    function test_SafeTransferFrom_RevertZeroAddress() public {
        token.mint(alice, ID1, AMT, "");
        vm.prank(alice);
        vm.expectRevert(IERC1155.ZeroAddress.selector);
        token.safeTransferFrom(alice, address(0), ID1, AMT, "");
    }

    function test_SafeTransferFrom_RevertInsufficientBalance() public {
        token.mint(alice, ID1, 10, "");
        vm.prank(alice);
        vm.expectRevert();
        token.safeTransferFrom(alice, bob, ID1, 11, "");
    }

    function test_SafeTransferFrom_ToGoodReceiver() public {
        GoodReceiver recv = new GoodReceiver();
        token.mint(alice, ID1, AMT, "");
        vm.prank(alice);
        token.safeTransferFrom(alice, address(recv), ID1, AMT, "");
        assertEq(token.balanceOf(address(recv), ID1), AMT);
    }

    function test_SafeTransferFrom_RevertBadReceiver() public {
        BadReceiver recv = new BadReceiver();
        token.mint(alice, ID1, AMT, "");
        vm.prank(alice);
        vm.expectRevert(IERC1155.UnsafeRecipient.selector);
        token.safeTransferFrom(alice, address(recv), ID1, AMT, "");
    }

    // ─── SafeBatchTransferFrom ─────────────────────────────────────────────────

    function test_SafeBatchTransferFrom_UpdatesBalances() public {
        token.mintBatch(alice, _ids(ID1, ID2), _amts(50, 80), "");
        vm.prank(alice);
        token.safeBatchTransferFrom(alice, bob, _ids(ID1, ID2), _amts(20, 30), "");
        assertEq(token.balanceOf(alice, ID1), 30);
        assertEq(token.balanceOf(alice, ID2), 50);
        assertEq(token.balanceOf(bob,   ID1), 20);
        assertEq(token.balanceOf(bob,   ID2), 30);
    }

    function test_SafeBatchTransferFrom_EmitsEvent() public {
        uint256[] memory ids  = _ids(ID1, ID2);
        uint256[] memory amts = _amts(10, 20);
        token.mintBatch(alice, ids, amts, "");
        vm.expectEmit(true, true, true, false);
        emit TransferBatch(alice, alice, bob, ids, amts);
        vm.prank(alice);
        token.safeBatchTransferFrom(alice, bob, ids, amts, "");
    }

    function test_SafeBatchTransferFrom_RevertLengthMismatch() public {
        token.mintBatch(alice, _ids(ID1, ID2), _amts(50, 80), "");
        vm.prank(alice);
        vm.expectRevert(IERC1155.LengthMismatch.selector);
        token.safeBatchTransferFrom(alice, bob, _ids(ID1, ID2), _amts(20), "");
    }

    function test_SafeBatchTransferFrom_RevertNotApproved() public {
        token.mintBatch(alice, _ids(ID1), _amts(50), "");
        vm.prank(bob);
        vm.expectRevert(IERC1155.NotOwnerOrApproved.selector);
        token.safeBatchTransferFrom(alice, bob, _ids(ID1), _amts(50), "");
    }

    function test_SafeBatchTransferFrom_RevertZeroAddress() public {
        token.mintBatch(alice, _ids(ID1), _amts(50), "");
        vm.prank(alice);
        vm.expectRevert(IERC1155.ZeroAddress.selector);
        token.safeBatchTransferFrom(alice, address(0), _ids(ID1), _amts(50), "");
    }

    function test_SafeBatchTransferFrom_ToGoodReceiver() public {
        GoodReceiver recv = new GoodReceiver();
        token.mintBatch(alice, _ids(ID1, ID2), _amts(10, 20), "");
        vm.prank(alice);
        token.safeBatchTransferFrom(alice, address(recv), _ids(ID1, ID2), _amts(10, 20), "");
        assertEq(token.balanceOf(address(recv), ID1), 10);
        assertEq(token.balanceOf(address(recv), ID2), 20);
    }

    function test_SafeBatchTransferFrom_RevertBadReceiver() public {
        BadReceiver recv = new BadReceiver();
        token.mintBatch(alice, _ids(ID1), _amts(50), "");
        vm.prank(alice);
        vm.expectRevert(IERC1155.UnsafeRecipient.selector);
        token.safeBatchTransferFrom(alice, address(recv), _ids(ID1), _amts(50), "");
    }

    function test_SafeBatchTransferFrom_ToSelf() public {
        token.mintBatch(alice, _ids(ID1, ID2), _amts(50, 80), "");
        vm.prank(alice);
        token.safeBatchTransferFrom(alice, alice, _ids(ID1, ID2), _amts(50, 80), "");
        assertEq(token.balanceOf(alice, ID1), 50);
        assertEq(token.balanceOf(alice, ID2), 80);
    }

    function test_SafeTransferFrom_ToSelf() public {
        token.mint(alice, ID1, AMT, "");
        vm.prank(alice);
        token.safeTransferFrom(alice, alice, ID1, AMT, "");
        assertEq(token.balanceOf(alice, ID1), AMT);
    }

    // ─── ApprovalForAll ────────────────────────────────────────────────────────

    function test_SetApprovalForAll_Grants() public {
        vm.prank(alice);
        token.setApprovalForAll(bob, true);
        assertTrue(token.isApprovedForAll(alice, bob));
    }

    function test_SetApprovalForAll_Revokes() public {
        vm.prank(alice);
        token.setApprovalForAll(bob, true);
        vm.prank(alice);
        token.setApprovalForAll(bob, false);
        assertFalse(token.isApprovedForAll(alice, bob));
    }

    function test_SetApprovalForAll_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit ApprovalForAll(alice, bob, true);
        vm.prank(alice);
        token.setApprovalForAll(bob, true);
    }

    function test_SetApprovalForAll_RevertZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(IERC1155.ZeroAddress.selector);
        token.setApprovalForAll(address(0), true);
    }

    // ─── BalanceOfBatch ────────────────────────────────────────────────────────

    function test_BalanceOfBatch_ReturnsCorrect() public {
        token.mint(alice, ID1, 10, "");
        token.mint(bob,   ID2, 20, "");
        address[] memory accs = new address[](2);
        accs[0] = alice; accs[1] = bob;
        uint256[] memory ids = _ids(ID1, ID2);
        uint256[] memory bals = token.balanceOfBatch(accs, ids);
        assertEq(bals[0], 10);
        assertEq(bals[1], 20);
    }

    function test_BalanceOfBatch_RevertLengthMismatch() public {
        address[] memory accs = new address[](2);
        accs[0] = alice; accs[1] = bob;
        vm.expectRevert(IERC1155.LengthMismatch.selector);
        token.balanceOfBatch(accs, _ids(ID1));
    }

    function test_BalanceOf_RevertZeroAddress() public {
        vm.expectRevert(IERC1155.ZeroAddress.selector);
        token.balanceOf(address(0), ID1);
    }

    // ─── URI ───────────────────────────────────────────────────────────────────

    function test_URI_ReturnsCorrect() public view {
        assertEq(token.uri(1),   "ipfs://base/1.json");
        assertEq(token.uri(42),  "ipfs://base/42.json");
        assertEq(token.uri(0),   "ipfs://base/0.json");
    }

    function test_SetBaseURI_Updates() public {
        token.setBaseURI("https://api.example.com/");
        assertEq(token.uri(7), "https://api.example.com/7.json");
    }

    function test_SetBaseURI_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(IERC1155.NotOwner.selector);
        token.setBaseURI("bad");
    }

    // ─── ERC-165 ───────────────────────────────────────────────────────────────

    function test_SupportsInterface_ERC1155() public view {
        assertTrue(token.supportsInterface(0xd9b67a26));
    }

    function test_SupportsInterface_ERC1155MetadataURI() public view {
        assertTrue(token.supportsInterface(0x0e89341c));
    }

    function test_SupportsInterface_ERC165() public view {
        assertTrue(token.supportsInterface(0x01ffc9a7));
    }

    function test_SupportsInterface_Unknown() public view {
        assertFalse(token.supportsInterface(0xdeadbeef));
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_Mint_BalanceOf(uint256 id, uint256 amount) public {
        amount = bound(amount, 0, type(uint128).max);
        token.mint(alice, id, amount, "");
        assertEq(token.balanceOf(alice, id), amount);
    }

    function testFuzz_SafeTransferFrom(uint256 amount, uint256 send) public {
        amount = bound(amount, 1, type(uint128).max);
        send   = bound(send, 0, amount);
        token.mint(alice, ID1, amount, "");
        vm.prank(alice);
        token.safeTransferFrom(alice, bob, ID1, send, "");
        assertEq(token.balanceOf(alice, ID1), amount - send);
        assertEq(token.balanceOf(bob,   ID1), send);
    }

    function testFuzz_Burn(uint256 amount, uint256 burnAmt) public {
        amount  = bound(amount,  1, type(uint128).max);
        burnAmt = bound(burnAmt, 0, amount);
        token.mint(alice, ID1, amount, "");
        vm.prank(alice);
        token.burn(alice, ID1, burnAmt);
        assertEq(token.balanceOf(alice, ID1), amount - burnAmt);
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────

    function _ids(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1); arr[0] = a;
    }
    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2); arr[0] = a; arr[1] = b;
    }
    function _ids(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](3); arr[0] = a; arr[1] = b; arr[2] = c;
    }
    function _amts(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1); arr[0] = a;
    }
    function _amts(uint256 a, uint256 b) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2); arr[0] = a; arr[1] = b;
    }
    function _amts(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](3); arr[0] = a; arr[1] = b; arr[2] = c;
    }
}
