// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20Token} from "../src/ERC20Token.sol";
import {IERC20Token} from "../src/IERC20Token.sol";

contract ERC20TokenTest is Test {
    ERC20Token token;
    address owner = address(this);
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    uint256 constant CAP    = 1_000_000 ether;
    uint256 constant AMOUNT = 1_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        token = new ERC20Token("CeloToken", "CTK", CAP);
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsMetadata() public view {
        assertEq(token.name(), "CeloToken");
        assertEq(token.symbol(), "CTK");
        assertEq(token.decimals(), 18);
        assertEq(token.CAP(), CAP);
        assertEq(token.owner(), owner);
    }

    function test_Constructor_RevertZeroCap() public {
        vm.expectRevert(IERC20Token.ZeroAmount.selector);
        new ERC20Token("T", "T", 0);
    }

    // ─── Mint ──────────────────────────────────────────────────────────────────

    function test_Mint_Success() public {
        token.mint(alice, AMOUNT);
        assertEq(token.balanceOf(alice), AMOUNT);
        assertEq(token.totalSupply(), AMOUNT);
    }

    function test_Mint_EmitsEvents() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), alice, AMOUNT);
        vm.expectEmit(true, false, false, true);
        emit Minted(alice, AMOUNT);
        token.mint(alice, AMOUNT);
    }

    function test_Mint_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(IERC20Token.NotOwner.selector);
        token.mint(alice, AMOUNT);
    }

    function test_Mint_RevertZeroAddress() public {
        vm.expectRevert(IERC20Token.ZeroAddress.selector);
        token.mint(address(0), AMOUNT);
    }

    function test_Mint_RevertZeroAmount() public {
        vm.expectRevert(IERC20Token.ZeroAmount.selector);
        token.mint(alice, 0);
    }

    function test_Mint_RevertCapExceeded() public {
        vm.expectRevert(IERC20Token.CapExceeded.selector);
        token.mint(alice, CAP + 1);
    }

    function test_Mint_RevertWhenPaused() public {
        token.pause();
        vm.expectRevert(IERC20Token.Paused.selector);
        token.mint(alice, AMOUNT);
    }

    // ─── Burn ──────────────────────────────────────────────────────────────────

    function test_Burn_Success() public {
        token.mint(alice, AMOUNT);
        vm.prank(alice);
        token.burn(AMOUNT);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
    }

    function test_Burn_EmitsEvents() public {
        token.mint(alice, AMOUNT);
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, address(0), AMOUNT);
        vm.expectEmit(true, false, false, true);
        emit Burned(alice, AMOUNT);
        vm.prank(alice);
        token.burn(AMOUNT);
    }

    function test_Burn_RevertInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(IERC20Token.InsufficientBalance.selector);
        token.burn(1);
    }

    function test_Burn_RevertZeroAmount() public {
        token.mint(alice, AMOUNT);
        vm.prank(alice);
        vm.expectRevert(IERC20Token.ZeroAmount.selector);
        token.burn(0);
    }

    // ─── Transfer ──────────────────────────────────────────────────────────────

    function test_Transfer_Success() public {
        token.mint(alice, AMOUNT);
        vm.prank(alice);
        token.transfer(bob, AMOUNT);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), AMOUNT);
    }

    function test_Transfer_EmitsEvent() public {
        token.mint(alice, AMOUNT);
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, AMOUNT);
        vm.prank(alice);
        token.transfer(bob, AMOUNT);
    }

    function test_Transfer_RevertInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(IERC20Token.InsufficientBalance.selector);
        token.transfer(bob, 1);
    }

    function test_Transfer_RevertZeroAddress() public {
        token.mint(alice, AMOUNT);
        vm.prank(alice);
        vm.expectRevert(IERC20Token.ZeroAddress.selector);
        token.transfer(address(0), AMOUNT);
    }

    function test_Transfer_RevertWhenPaused() public {
        token.mint(alice, AMOUNT);
        token.pause();
        vm.prank(alice);
        vm.expectRevert(IERC20Token.Paused.selector);
        token.transfer(bob, AMOUNT);
    }

    // ─── Approve / TransferFrom ────────────────────────────────────────────────

    function test_Approve_Success() public {
        vm.prank(alice);
        token.approve(bob, AMOUNT);
        assertEq(token.allowance(alice, bob), AMOUNT);
    }

    function test_Approve_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit Approval(alice, bob, AMOUNT);
        vm.prank(alice);
        token.approve(bob, AMOUNT);
    }

    function test_TransferFrom_Success() public {
        token.mint(alice, AMOUNT);
        vm.prank(alice);
        token.approve(bob, AMOUNT);
        vm.prank(bob);
        token.transferFrom(alice, bob, AMOUNT);
        assertEq(token.balanceOf(bob), AMOUNT);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_TransferFrom_UnlimitedAllowance() public {
        token.mint(alice, AMOUNT);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, bob, AMOUNT);
        assertEq(token.allowance(alice, bob), type(uint256).max); // not decremented
    }

    function test_TransferFrom_RevertInsufficientAllowance() public {
        token.mint(alice, AMOUNT);
        vm.prank(bob);
        vm.expectRevert(IERC20Token.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, AMOUNT);
    }

    // ─── Pause ─────────────────────────────────────────────────────────────────

    function test_Pause_Unpause() public {
        token.pause();
        assertTrue(token.paused());
        token.unpause();
        assertFalse(token.paused());
    }

    function test_Pause_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(IERC20Token.NotOwner.selector);
        token.pause();
    }

    // ─── Ownership ─────────────────────────────────────────────────────────────

    function test_TwoStepOwnership() public {
        token.transferOwnership(alice);
        assertEq(token.pendingOwner(), alice);
        vm.prank(alice);
        token.acceptOwnership();
        assertEq(token.owner(), alice);
        assertEq(token.pendingOwner(), address(0));
    }

    function test_TransferOwnership_RevertZeroAddress() public {
        vm.expectRevert(IERC20Token.ZeroAddress.selector);
        token.transferOwnership(address(0));
    }

    function test_AcceptOwnership_RevertNotPending() public {
        token.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(IERC20Token.NotPendingOwner.selector);
        token.acceptOwnership();
    }

    function test_Ownership_EmitsEvents() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferStarted(owner, alice);
        token.transferOwnership(alice);

        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, alice);
        vm.prank(alice);
        token.acceptOwnership();
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_MintAndBurn(uint256 amount) public {
        amount = bound(amount, 1, CAP);
        token.mint(alice, amount);
        assertEq(token.totalSupply(), amount);
        vm.prank(alice);
        token.burn(amount);
        assertEq(token.totalSupply(), 0);
    }

    function testFuzz_Transfer(uint256 amount) public {
        amount = bound(amount, 1, CAP);
        token.mint(alice, amount);
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(bob), amount);
    }

    // ─── Invariant ─────────────────────────────────────────────────────────────

    function test_Invariant_TotalSupplyLeqCap() public {
        token.mint(alice, CAP / 2);
        token.mint(bob, CAP / 2);
        assertLe(token.totalSupply(), token.CAP());
    }
}
