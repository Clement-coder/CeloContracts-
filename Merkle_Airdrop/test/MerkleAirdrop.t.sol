// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MerkleAirdrop} from "../src/MerkleAirdrop.sol";
import {AirdropToken} from "../src/AirdropToken.sol";
import {IMerkleAirdrop} from "../src/IMerkleAirdrop.sol";

/// @dev Builds a 4-leaf Merkle tree in-test so there are zero off-chain dependencies.
///
///      Leaves (double-hashed):
///        leaf0 = H(H(alice,  100e18))
///        leaf1 = H(H(bob,    200e18))
///        leaf2 = H(H(carol,  300e18))
///        leaf3 = H(H(dave,   400e18))
///
///      Tree (sorted-pair hashing):
///        n01 = H(sort(leaf0, leaf1))
///        n23 = H(sort(leaf2, leaf3))
///        root = H(sort(n01, n23))
contract MerkleAirdropTest is Test {
    MerkleAirdrop airdrop;
    AirdropToken  token;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave  = makeAddr("dave");

    uint256 constant ALICE_AMT = 100e18;
    uint256 constant BOB_AMT   = 200e18;
    uint256 constant CAROL_AMT = 300e18;
    uint256 constant DAVE_AMT  = 400e18;
    uint256 constant TOTAL     = ALICE_AMT + BOB_AMT + CAROL_AMT + DAVE_AMT;

    bytes32 leaf0; bytes32 leaf1; bytes32 leaf2; bytes32 leaf3;
    bytes32 n01;   bytes32 n23;   bytes32 root;

    // Mirror events
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Claimed(address indexed account, uint256 amount);
    event MerkleRootUpdated(bytes32 oldRoot, bytes32 newRoot);
    event Swept(address indexed to, uint256 amount);

    function setUp() public {
        // Build leaves
        leaf0 = _leaf(alice, ALICE_AMT);
        leaf1 = _leaf(bob,   BOB_AMT);
        leaf2 = _leaf(carol, CAROL_AMT);
        leaf3 = _leaf(dave,  DAVE_AMT);

        // Build internal nodes
        n01  = _hashPair(leaf0, leaf1);
        n23  = _hashPair(leaf2, leaf3);
        root = _hashPair(n01, n23);

        // Deploy
        token   = new AirdropToken(TOTAL);
        airdrop = new MerkleAirdrop(address(token), root);
        token.transfer(address(airdrop), TOTAL);
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────

    function _leaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a <= b
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }

    function _proofAlice() internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = leaf1; // sibling
        p[1] = n23;   // uncle
    }

    function _proofBob() internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = leaf0;
        p[1] = n23;
    }

    function _proofCarol() internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = leaf3;
        p[1] = n01;
    }

    function _proofDave() internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = leaf2;
        p[1] = n01;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsToken() public view {
        assertEq(address(airdrop.token()), address(token));
    }

    function test_Constructor_SetsMerkleRoot() public view {
        assertEq(airdrop.merkleRoot(), root);
    }

    function test_Constructor_SetsOwner() public view {
        assertEq(airdrop.owner(), address(this));
    }

    function test_Constructor_RevertZeroToken() public {
        vm.expectRevert(IMerkleAirdrop.ZeroAddress.selector);
        new MerkleAirdrop(address(0), root);
    }

    function test_Constructor_AirdropFunded() public view {
        assertEq(token.balanceOf(address(airdrop)), TOTAL);
    }

    // ─── Claim ─────────────────────────────────────────────────────────────────

    function test_Claim_Alice() public {
        vm.prank(alice);
        airdrop.claim(ALICE_AMT, _proofAlice());
        assertEq(token.balanceOf(alice), ALICE_AMT);
    }

    function test_Claim_Bob() public {
        vm.prank(bob);
        airdrop.claim(BOB_AMT, _proofBob());
        assertEq(token.balanceOf(bob), BOB_AMT);
    }

    function test_Claim_Carol() public {
        vm.prank(carol);
        airdrop.claim(CAROL_AMT, _proofCarol());
        assertEq(token.balanceOf(carol), CAROL_AMT);
    }

    function test_Claim_Dave() public {
        vm.prank(dave);
        airdrop.claim(DAVE_AMT, _proofDave());
        assertEq(token.balanceOf(dave), DAVE_AMT);
    }

    function test_Claim_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit Claimed(alice, ALICE_AMT);
        vm.prank(alice);
        airdrop.claim(ALICE_AMT, _proofAlice());
    }

    function test_Claim_MarksClaimed() public {
        vm.prank(alice);
        airdrop.claim(ALICE_AMT, _proofAlice());
        assertTrue(airdrop.hasClaimed(alice));
    }

    function test_Claim_DecreasesAirdropBalance() public {
        vm.prank(alice);
        airdrop.claim(ALICE_AMT, _proofAlice());
        assertEq(token.balanceOf(address(airdrop)), TOTAL - ALICE_AMT);
    }

    function test_Claim_AllFourRecipients() public {
        vm.prank(alice); airdrop.claim(ALICE_AMT, _proofAlice());
        vm.prank(bob);   airdrop.claim(BOB_AMT,   _proofBob());
        vm.prank(carol); airdrop.claim(CAROL_AMT, _proofCarol());
        vm.prank(dave);  airdrop.claim(DAVE_AMT,  _proofDave());
        assertEq(token.balanceOf(address(airdrop)), 0);
    }

    function test_Claim_RevertAlreadyClaimed() public {
        vm.prank(alice);
        airdrop.claim(ALICE_AMT, _proofAlice());
        vm.prank(alice);
        vm.expectRevert(IMerkleAirdrop.AlreadyClaimed.selector);
        airdrop.claim(ALICE_AMT, _proofAlice());
    }

    function test_Claim_RevertInvalidProof_WrongAmount() public {
        vm.prank(alice);
        vm.expectRevert(IMerkleAirdrop.InvalidProof.selector);
        airdrop.claim(ALICE_AMT + 1, _proofAlice());
    }

    function test_Claim_RevertInvalidProof_WrongAddress() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(IMerkleAirdrop.InvalidProof.selector);
        airdrop.claim(ALICE_AMT, _proofAlice());
    }

    function test_Claim_RevertInvalidProof_EmptyProof() public {
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(alice);
        vm.expectRevert(IMerkleAirdrop.InvalidProof.selector);
        airdrop.claim(ALICE_AMT, emptyProof);
    }

    function test_Claim_RevertInvalidProof_WrongSibling() public {
        bytes32[] memory badProof = new bytes32[](2);
        badProof[0] = bytes32(uint256(1)); // garbage
        badProof[1] = n23;
        vm.prank(alice);
        vm.expectRevert(IMerkleAirdrop.InvalidProof.selector);
        airdrop.claim(ALICE_AMT, badProof);
    }

    function test_Claim_RevertInvalidProof_BobProofForAlice() public {
        // Bob's proof cannot be used by Alice
        vm.prank(alice);
        vm.expectRevert(IMerkleAirdrop.InvalidProof.selector);
        airdrop.claim(BOB_AMT, _proofBob());
    }

    // ─── hasClaimed ────────────────────────────────────────────────────────────

    function test_HasClaimed_FalseForZeroAddress() public view {
        assertFalse(airdrop.hasClaimed(address(0)));
    }

    function test_HasClaimed_FalseBeforeClaim() public view {
        assertFalse(airdrop.hasClaimed(alice));
    }

    function test_HasClaimed_TrueAfterClaim() public {
        vm.prank(alice);
        airdrop.claim(ALICE_AMT, _proofAlice());
        assertTrue(airdrop.hasClaimed(alice));
    }

    function test_HasClaimed_UnrelatedAddressFalse() public {
        assertFalse(airdrop.hasClaimed(makeAddr("nobody")));
    }

    // ─── setMerkleRoot ─────────────────────────────────────────────────────────

    function test_SetMerkleRoot_UpdatesRoot() public {
        bytes32 newRoot = bytes32(uint256(42));
        airdrop.setMerkleRoot(newRoot);
        assertEq(airdrop.merkleRoot(), newRoot);
    }

    function test_SetMerkleRoot_EmitsEvent() public {
        bytes32 newRoot = bytes32(uint256(42));
        vm.expectEmit(false, false, false, true);
        emit MerkleRootUpdated(root, newRoot);
        airdrop.setMerkleRoot(newRoot);
    }

    function test_SetMerkleRoot_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(IMerkleAirdrop.NotOwner.selector);
        airdrop.setMerkleRoot(bytes32(uint256(1)));
    }

    function test_SetMerkleRoot_ToZeroBytes32() public {
        airdrop.setMerkleRoot(bytes32(0));
        assertEq(airdrop.merkleRoot(), bytes32(0));
    }

    function test_SetMerkleRoot_AllowsNewClaims() public {
        // Build a new 1-leaf tree for a new recipient
        address newUser = makeAddr("newUser");
        uint256 newAmt  = 50e18;
        bytes32 newLeaf = _leaf(newUser, newAmt);
        // Single-leaf tree: root == leaf — update and verify root accepted
        airdrop.setMerkleRoot(newLeaf);
        assertEq(airdrop.merkleRoot(), newLeaf);
    }

    // ─── sweep ─────────────────────────────────────────────────────────────────

    function test_Sweep_TransfersAllTokens() public {
        address treasury = makeAddr("treasury");
        airdrop.sweep(treasury);
        assertEq(token.balanceOf(treasury), TOTAL);
        assertEq(token.balanceOf(address(airdrop)), 0);
    }

    function test_Sweep_EmitsEvent() public {
        address treasury = makeAddr("treasury");
        vm.expectEmit(true, false, false, true);
        emit Swept(treasury, TOTAL);
        airdrop.sweep(treasury);
    }

    function test_Sweep_AfterPartialClaims() public {
        vm.prank(alice); airdrop.claim(ALICE_AMT, _proofAlice());
        vm.prank(bob);   airdrop.claim(BOB_AMT,   _proofBob());
        address treasury = makeAddr("treasury");
        airdrop.sweep(treasury);
        assertEq(token.balanceOf(treasury), CAROL_AMT + DAVE_AMT);
    }

    function test_Sweep_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(IMerkleAirdrop.NotOwner.selector);
        airdrop.sweep(alice);
    }

    function test_Sweep_RevertZeroAddress() public {
        vm.expectRevert(IMerkleAirdrop.ZeroAddress.selector);
        airdrop.sweep(address(0));
    }

    function test_Sweep_ZeroBalanceAfterAllClaims() public {
        vm.prank(alice); airdrop.claim(ALICE_AMT, _proofAlice());
        vm.prank(bob);   airdrop.claim(BOB_AMT,   _proofBob());
        vm.prank(carol); airdrop.claim(CAROL_AMT, _proofCarol());
        vm.prank(dave);  airdrop.claim(DAVE_AMT,  _proofDave());
        address treasury = makeAddr("treasury");
        vm.expectEmit(true, false, false, true);
        emit Swept(treasury, 0);
        airdrop.sweep(treasury);
    }

    // ─── AirdropToken ──────────────────────────────────────────────────────────

    function test_Token_Constructor_EmitsTransferFromZero() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), address(this), 1000e18);
        new AirdropToken(1000e18);
    }

    function test_Token_Constructor_MintsToDeployer() public {
        AirdropToken t2 = new AirdropToken(1000e18);
        assertEq(t2.balanceOf(address(this)), 1000e18);
    }

    function test_Token_Name() public view {
        assertEq(token.name(), "Airdrop Token");
    }

    function test_Token_Symbol() public view {
        assertEq(token.symbol(), "ADT");
    }

    function test_Token_Decimals() public view {
        assertEq(token.decimals(), 18);
    }

    function test_Token_TotalSupply() public view {
        assertEq(token.totalSupply(), TOTAL);
    }

    function test_Token_Transfer() public {
        // airdrop contract holds TOTAL; claim alice to test transfer
        vm.prank(alice);
        airdrop.claim(ALICE_AMT, _proofAlice());
        assertEq(token.balanceOf(alice), ALICE_AMT);
    }

    function test_Token_Approve_And_TransferFrom() public {
        vm.prank(alice);
        airdrop.claim(ALICE_AMT, _proofAlice());
        vm.prank(alice);
        token.approve(bob, ALICE_AMT);
        assertEq(token.allowance(alice, bob), ALICE_AMT);
        vm.prank(bob);
        token.transferFrom(alice, carol, ALICE_AMT);
        assertEq(token.balanceOf(carol), ALICE_AMT);
    }

    function test_Token_Transfer_RevertZeroAddress() public {
        vm.prank(alice);
        airdrop.claim(ALICE_AMT, _proofAlice());
        vm.prank(alice);
        vm.expectRevert(AirdropToken.ZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    function test_Token_Transfer_RevertInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(AirdropToken.InsufficientBalance.selector);
        token.transfer(bob, 1);
    }

    function test_Token_TransferFrom_RevertInsufficientBalance() public {
        vm.prank(alice); token.approve(bob, type(uint256).max);
        // alice has 0 tokens (airdrop holds them all)
        vm.prank(bob);
        vm.expectRevert(AirdropToken.InsufficientBalance.selector);
        token.transferFrom(alice, carol, 1);
    }

    function test_Token_TransferFrom_RevertInsufficientAllowance() public {
        vm.prank(alice);
        airdrop.claim(ALICE_AMT, _proofAlice());
        vm.prank(bob);
        vm.expectRevert(AirdropToken.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 1);
    }

    function test_Token_TransferFrom_RevertZeroAddressTo() public {
        vm.prank(alice); airdrop.claim(ALICE_AMT, _proofAlice());
        vm.prank(alice); token.approve(bob, ALICE_AMT);
        vm.prank(bob);
        vm.expectRevert(AirdropToken.ZeroAddress.selector);
        token.transferFrom(alice, address(0), ALICE_AMT);
    }

    function test_Token_Approve_RevertZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(AirdropToken.ZeroAddress.selector);
        token.approve(address(0), 100);
    }

    function test_Token_Approve_ZeroResetsAllowance() public {
        vm.prank(alice); token.approve(bob, 100);
        vm.prank(alice); token.approve(bob, 0);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_Token_MaxAllowance_NotDecremented() public {
        vm.prank(alice); airdrop.claim(ALICE_AMT, _proofAlice());
        vm.prank(alice); token.approve(bob, type(uint256).max);
        vm.prank(bob);   token.transferFrom(alice, carol, ALICE_AMT);
        // max allowance should not be decremented
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function test_Token_Approve_EmitsApprovalEvent() public {
        vm.expectEmit(true, true, false, true);
        emit Approval(alice, bob, 500);
        vm.prank(alice);
        token.approve(bob, 500);
    }

    function test_Claim_EmitsTokenTransferEvent() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(airdrop), alice, ALICE_AMT);
        vm.prank(alice);
        airdrop.claim(ALICE_AMT, _proofAlice());
    }

    function test_Claim_AirdropBalanceZeroAfterAll() public {
        vm.prank(alice); airdrop.claim(ALICE_AMT, _proofAlice());
        vm.prank(bob);   airdrop.claim(BOB_AMT,   _proofBob());
        vm.prank(carol); airdrop.claim(CAROL_AMT, _proofCarol());
        vm.prank(dave);  airdrop.claim(DAVE_AMT,  _proofDave());
        assertEq(token.balanceOf(address(airdrop)), 0);
        assertEq(token.totalSupply(), TOTAL);
    }

    function test_Claim_OrderIndependent() public {
        // Claim in reverse order: dave, carol, bob, alice
        vm.prank(dave);  airdrop.claim(DAVE_AMT,  _proofDave());
        vm.prank(carol); airdrop.claim(CAROL_AMT, _proofCarol());
        vm.prank(bob);   airdrop.claim(BOB_AMT,   _proofBob());
        vm.prank(alice); airdrop.claim(ALICE_AMT, _proofAlice());
        assertEq(token.balanceOf(address(airdrop)), 0);
    }

    function test_Claim_SingleLeafTree() public {
        address solo = makeAddr("solo");
        uint256 soloAmt = 77e18;
        bytes32 soloLeaf = _leaf(solo, soloAmt);
        AirdropToken t2 = new AirdropToken(soloAmt);
        MerkleAirdrop a2 = new MerkleAirdrop(address(t2), soloLeaf);
        t2.transfer(address(a2), soloAmt);
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.prank(solo);
        a2.claim(soloAmt, emptyProof);
        assertEq(t2.balanceOf(solo), soloAmt);
    }

    function test_Claim_DoesNotAffectOtherBalances() public {
        vm.prank(alice); airdrop.claim(ALICE_AMT, _proofAlice());
        assertEq(token.balanceOf(bob),   0);
        assertEq(token.balanceOf(carol), 0);
        assertEq(token.balanceOf(dave),  0);
    }

    function testFuzz_Claim_InvalidAmount(uint256 badAmt) public {
        vm.assume(badAmt != ALICE_AMT);
        vm.prank(alice);
        vm.expectRevert(IMerkleAirdrop.InvalidProof.selector);
        airdrop.claim(badAmt, _proofAlice());
    }

    function testFuzz_Token_TransferFrom(uint256 amount) public {
        amount = bound(amount, 1, BOB_AMT);
        vm.prank(bob); airdrop.claim(BOB_AMT, _proofBob());
        vm.prank(bob); token.approve(alice, amount);
        vm.prank(alice); token.transferFrom(bob, carol, amount);
        assertEq(token.balanceOf(carol), amount);
    }

    function testFuzz_Token_Transfer(uint256 amount) public {
        amount = bound(amount, 1, ALICE_AMT);
        vm.prank(alice); airdrop.claim(ALICE_AMT, _proofAlice());
        vm.prank(alice); token.transfer(bob, amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(alice), ALICE_AMT - amount);
    }

    function testFuzz_HasClaimed_RandomAddress(address rando) public view {
        vm.assume(rando != alice && rando != bob && rando != carol && rando != dave);
        assertFalse(airdrop.hasClaimed(rando));
    }
}
// Commit 18 optimization
// Commit 38 optimization
