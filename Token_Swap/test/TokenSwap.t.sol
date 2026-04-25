// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TokenSwap} from "../src/TokenSwap.sol";
import {ITokenSwap} from "../src/ITokenSwap.sol";

/// @dev Minimal ERC20 mock.
contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function approve(address s, uint256 amt) external returns (bool) { allowance[msg.sender][s] = amt; return true; }
    function transfer(address to, uint256 amt) external returns (bool) { balanceOf[msg.sender] -= amt; balanceOf[to] += amt; return true; }
    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        allowance[f][msg.sender] -= amt; balanceOf[f] -= amt; balanceOf[to] += amt; return true;
    }
}

contract TokenSwapTest is Test {
    TokenSwap pool;
    MockToken tok;
    address owner = address(this);
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    uint256 constant FEE        = 30;       // 0.3%
    uint256 constant CELO_LIQ   = 10 ether;
    uint256 constant TOKEN_LIQ  = 10_000 ether;

    event LiquidityAdded(address indexed provider, uint256 celoAmount, uint256 tokenAmount, uint256 lpMinted);
    event LiquidityRemoved(address indexed provider, uint256 celoAmount, uint256 tokenAmount, uint256 lpBurned);
    event SwappedCeloForToken(address indexed user, uint256 celoIn, uint256 tokenOut);
    event SwappedTokenForCelo(address indexed user, uint256 tokenIn, uint256 celoOut);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        tok  = new MockToken();
        pool = new TokenSwap(address(tok), FEE);
        tok.mint(owner, 100_000 ether);
        tok.approve(address(pool), type(uint256).max);
        tok.mint(alice, 10_000 ether);
        tok.mint(bob,   10_000 ether);
        vm.deal(alice, 20 ether);
        vm.deal(bob,   20 ether);
    }

    function _addLiquidity() internal returns (uint256 lp) {
        lp = pool.addLiquidity{value: CELO_LIQ}(TOKEN_LIQ, 0);
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsParams() public view {
        assertEq(pool.token(), address(tok));
        assertEq(pool.feeBps(), FEE);
        assertEq(pool.owner(), owner);
    }

    function test_Constructor_RevertZeroToken() public {
        vm.expectRevert(ITokenSwap.ZeroAddress.selector);
        new TokenSwap(address(0), FEE);
    }

    function test_Constructor_RevertFeeTooHigh() public {
        vm.expectRevert(ITokenSwap.FeeTooHigh.selector);
        new TokenSwap(address(tok), 301);
    }

    // ─── AddLiquidity ──────────────────────────────────────────────────────────

    function test_AddLiquidity_FirstDeposit() public {
        uint256 lp = _addLiquidity();
        assertGt(lp, 0);
        assertEq(pool.totalLP(), lp);
        assertEq(pool.lpBalances(owner), lp);
    }

    function test_AddLiquidity_EmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit LiquidityAdded(owner, CELO_LIQ, TOKEN_LIQ, 0);
        _addLiquidity();
    }

    function test_AddLiquidity_SecondDeposit() public {
        _addLiquidity();
        vm.prank(alice);
        tok.approve(address(pool), type(uint256).max);
        uint256 lp2 = pool.addLiquidity{value: 1 ether}(1_000 ether, 0);
        assertGt(lp2, 0);
    }

    function test_AddLiquidity_RevertZeroValue() public {
        vm.expectRevert(ITokenSwap.ZeroAmount.selector);
        pool.addLiquidity{value: 0}(TOKEN_LIQ, 0);
    }

    function test_AddLiquidity_RevertSlippage() public {
        vm.expectRevert(ITokenSwap.SlippageExceeded.selector);
        pool.addLiquidity{value: CELO_LIQ}(TOKEN_LIQ, type(uint256).max);
    }

    function test_AddLiquidity_RevertWhenPaused() public {
        pool.pause();
        vm.expectRevert(ITokenSwap.Paused.selector);
        pool.addLiquidity{value: CELO_LIQ}(TOKEN_LIQ, 0);
    }

    // ─── RemoveLiquidity ───────────────────────────────────────────────────────

    function test_RemoveLiquidity_Success() public {
        uint256 lp = _addLiquidity();
        uint256 celoBefore = address(this).balance;
        (uint256 celoOut, uint256 tokenOut) = pool.removeLiquidity(lp, 0, 0);
        assertGt(celoOut, 0);
        assertGt(tokenOut, 0);
        assertEq(pool.totalLP(), 0);
        assertGt(address(this).balance, celoBefore);
    }

    function test_RemoveLiquidity_EmitsEvent() public {
        uint256 lp = _addLiquidity();
        vm.expectEmit(true, false, false, false);
        emit LiquidityRemoved(owner, 0, 0, lp);
        pool.removeLiquidity(lp, 0, 0);
    }

    function test_RemoveLiquidity_RevertInsufficientLP() public {
        _addLiquidity();
        vm.prank(alice);
        vm.expectRevert(ITokenSwap.InsufficientLPTokens.selector);
        pool.removeLiquidity(1, 0, 0);
    }

    function test_RemoveLiquidity_RevertSlippage() public {
        uint256 lp = _addLiquidity();
        vm.expectRevert(ITokenSwap.SlippageExceeded.selector);
        pool.removeLiquidity(lp, type(uint256).max, 0);
    }

    // ─── SwapCeloForToken ──────────────────────────────────────────────────────

    function test_SwapCeloForToken_Success() public {
        _addLiquidity();
        uint256 tokBefore = tok.balanceOf(alice);
        vm.prank(alice);
        uint256 out = pool.swapCeloForToken{value: 1 ether}(0);
        assertGt(out, 0);
        assertEq(tok.balanceOf(alice), tokBefore + out);
    }

    function test_SwapCeloForToken_EmitsEvent() public {
        _addLiquidity();
        vm.expectEmit(true, false, false, false);
        emit SwappedCeloForToken(alice, 1 ether, 0);
        vm.prank(alice);
        pool.swapCeloForToken{value: 1 ether}(0);
    }

    function test_SwapCeloForToken_RevertSlippage() public {
        _addLiquidity();
        vm.prank(alice);
        vm.expectRevert(ITokenSwap.SlippageExceeded.selector);
        pool.swapCeloForToken{value: 1 ether}(type(uint256).max);
    }

    function test_SwapCeloForToken_RevertNoLiquidity() public {
        vm.prank(alice);
        vm.expectRevert(ITokenSwap.InsufficientLiquidity.selector);
        pool.swapCeloForToken{value: 1 ether}(0);
    }

    function test_SwapCeloForToken_RevertWhenPaused() public {
        _addLiquidity();
        pool.pause();
        vm.prank(alice);
        vm.expectRevert(ITokenSwap.Paused.selector);
        pool.swapCeloForToken{value: 1 ether}(0);
    }

    // ─── SwapTokenForCelo ──────────────────────────────────────────────────────

    function test_SwapTokenForCelo_Success() public {
        _addLiquidity();
        vm.prank(alice);
        tok.approve(address(pool), type(uint256).max);
        uint256 celoBefore = alice.balance;
        vm.prank(alice);
        uint256 out = pool.swapTokenForCelo(100 ether, 0);
        assertGt(out, 0);
        assertEq(alice.balance, celoBefore + out);
    }

    function test_SwapTokenForCelo_EmitsEvent() public {
        _addLiquidity();
        vm.prank(alice);
        tok.approve(address(pool), type(uint256).max);
        vm.expectEmit(true, false, false, false);
        emit SwappedTokenForCelo(alice, 100 ether, 0);
        vm.prank(alice);
        pool.swapTokenForCelo(100 ether, 0);
    }

    function test_SwapTokenForCelo_RevertSlippage() public {
        _addLiquidity();
        vm.prank(alice);
        tok.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(ITokenSwap.SlippageExceeded.selector);
        pool.swapTokenForCelo(100 ether, type(uint256).max);
    }

    // ─── GetAmountOut ──────────────────────────────────────────────────────────

    function test_GetAmountOut_ConstantProduct() public {
        _addLiquidity();
        uint256 out = pool.getAmountOut(1 ether, CELO_LIQ, TOKEN_LIQ);
        assertGt(out, 0);
        assertLt(out, TOKEN_LIQ); // cannot drain pool
    }

    function test_GetAmountOut_RevertZeroInput() public {
        vm.expectRevert(ITokenSwap.ZeroAmount.selector);
        pool.getAmountOut(0, 10 ether, 10 ether);
    }

    // ─── SetFee / Pause / Ownership ────────────────────────────────────────────

    function test_SetFee_Success() public {
        vm.expectEmit(false, false, false, true);
        emit FeeUpdated(FEE, 10);
        pool.setFee(10);
        assertEq(pool.feeBps(), 10);
    }

    function test_SetFee_RevertFeeTooHigh() public {
        vm.expectRevert(ITokenSwap.FeeTooHigh.selector);
        pool.setFee(301);
    }

    function test_Pause_Unpause() public {
        pool.pause();
        assertTrue(pool.paused());
        pool.unpause();
        assertFalse(pool.paused());
    }

    function test_TwoStepOwnership() public {
        pool.transferOwnership(alice);
        assertEq(pool.pendingOwner(), alice);
        vm.prank(alice);
        pool.acceptOwnership();
        assertEq(pool.owner(), alice);
    }

    function test_TransferOwnership_RevertZeroAddress() public {
        vm.expectRevert(ITokenSwap.ZeroAddress.selector);
        pool.transferOwnership(address(0));
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_SwapCeloForToken(uint256 celoIn) public {
        _addLiquidity();
        celoIn = bound(celoIn, 0.001 ether, 5 ether);
        vm.deal(alice, celoIn);
        vm.prank(alice);
        uint256 out = pool.swapCeloForToken{value: celoIn}(0);
        assertGt(out, 0);
    }

    function testFuzz_SwapTokenForCelo(uint256 tokenIn) public {
        _addLiquidity();
        tokenIn = bound(tokenIn, 1 ether, 1_000 ether);
        vm.prank(alice);
        tok.approve(address(pool), tokenIn);
        vm.prank(alice);
        uint256 out = pool.swapTokenForCelo(tokenIn, 0);
        assertGt(out, 0);
    }

    // ─── Invariant ─────────────────────────────────────────────────────────────

    function test_Invariant_KIncreasesAfterSwap() public {
        _addLiquidity();
        uint256 kBefore = address(pool).balance * tok.balanceOf(address(pool));
        vm.prank(alice);
        pool.swapCeloForToken{value: 1 ether}(0);
        uint256 kAfter = address(pool).balance * tok.balanceOf(address(pool));
        assertGe(kAfter, kBefore); // k never decreases (fees increase it)
    }

    receive() external payable {}
}
