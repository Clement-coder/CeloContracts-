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

    uint256 constant FEE       = 30;        // 0.3%
    uint256 constant CELO_LIQ  = 10 ether;
    uint256 constant TOKEN_LIQ = 10_000 ether;

    event LiquidityAdded(address indexed provider, uint256 celoAmount, uint256 tokenAmount, uint256 lpMinted);
    event LiquidityRemoved(address indexed provider, uint256 celoAmount, uint256 tokenAmount, uint256 lpBurned);
    event SwappedCeloForToken(address indexed user, uint256 celoIn, uint256 tokenOut);
    event SwappedTokenForCelo(address indexed user, uint256 tokenIn, uint256 celoOut);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event BlacklistUpdated(address indexed account, bool blacklisted);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);
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

    function test_Constructor_ZeroFeeAllowed() public {
        TokenSwap p = new TokenSwap(address(tok), 0);
        assertEq(p.feeBps(), 0);
    }

    function test_Constructor_MaxFeeAllowed() public {
        TokenSwap p = new TokenSwap(address(tok), 300);
        assertEq(p.feeBps(), 300);
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

    function test_AddLiquidity_SecondDeposit_IncreasesLP() public {
        uint256 lp1 = _addLiquidity();
        vm.prank(alice);
        tok.approve(address(pool), type(uint256).max);
        uint256 lp2 = pool.addLiquidity{value: 1 ether}(1_000 ether, 0);
        assertEq(pool.totalLP(), lp1 + lp2);
    }

    function test_AddLiquidity_RevertZeroValue() public {
        vm.expectRevert(ITokenSwap.ZeroAmount.selector);
        pool.addLiquidity{value: 0}(TOKEN_LIQ, 0);
    }

    function test_AddLiquidity_RevertZeroTokenAmount() public {
        vm.expectRevert(ITokenSwap.ZeroAmount.selector);
        pool.addLiquidity{value: CELO_LIQ}(0, 0);
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

    function test_AddLiquidity_RevertBlacklisted() public {
        pool.addToBlacklist(alice);
        vm.prank(alice);
        tok.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(ITokenSwap.Blacklisted.selector);
        pool.addLiquidity{value: 1 ether}(1_000 ether, 0);
    }

    function test_AddLiquidity_FirstDeposit_GeometricMean() public {
        uint256 lp = _addLiquidity();
        // sqrt(10e18 * 10000e18) = sqrt(1e23) ≈ 316227766016837933
        uint256 expected = _sqrt(CELO_LIQ * TOKEN_LIQ);
        assertEq(lp, expected);
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

    function test_RemoveLiquidity_Partial() public {
        uint256 lp = _addLiquidity();
        pool.removeLiquidity(lp / 2, 0, 0);
        assertEq(pool.totalLP(), lp - lp / 2);
        assertEq(pool.lpBalances(owner), lp - lp / 2);
    }

    function test_RemoveLiquidity_RevertZeroAmount() public {
        _addLiquidity();
        vm.expectRevert(ITokenSwap.ZeroAmount.selector);
        pool.removeLiquidity(0, 0, 0);
    }

    function test_RemoveLiquidity_RevertInsufficientLP() public {
        _addLiquidity();
        vm.prank(alice);
        vm.expectRevert(ITokenSwap.InsufficientLPTokens.selector);
        pool.removeLiquidity(1, 0, 0);
    }

    function test_RemoveLiquidity_RevertSlippageCelo() public {
        uint256 lp = _addLiquidity();
        vm.expectRevert(ITokenSwap.SlippageExceeded.selector);
        pool.removeLiquidity(lp, type(uint256).max, 0);
    }

    function test_RemoveLiquidity_RevertSlippageToken() public {
        uint256 lp = _addLiquidity();
        vm.expectRevert(ITokenSwap.SlippageExceeded.selector);
        pool.removeLiquidity(lp, 0, type(uint256).max);
    }

    function test_RemoveLiquidity_RevertBlacklisted() public {
        uint256 lp = _addLiquidity();
        pool.addToBlacklist(owner);
        vm.expectRevert(ITokenSwap.Blacklisted.selector);
        pool.removeLiquidity(lp, 0, 0);
    }

    function test_RemoveLiquidity_ProportionalAmounts() public {
        uint256 lp = _addLiquidity();
        (uint256 celoOut, uint256 tokenOut) = pool.removeLiquidity(lp, 0, 0);
        assertEq(celoOut, CELO_LIQ);
        assertEq(tokenOut, TOKEN_LIQ);
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

    function test_SwapCeloForToken_RevertZeroValue() public {
        _addLiquidity();
        vm.prank(alice);
        vm.expectRevert(ITokenSwap.ZeroAmount.selector);
        pool.swapCeloForToken{value: 0}(0);
    }

    function test_SwapCeloForToken_RevertBlacklisted() public {
        _addLiquidity();
        pool.addToBlacklist(alice);
        vm.prank(alice);
        vm.expectRevert(ITokenSwap.Blacklisted.selector);
        pool.swapCeloForToken{value: 1 ether}(0);
    }

    function test_SwapCeloForToken_IncreasesTokenReserve() public {
        _addLiquidity();
        uint256 tokReserveBefore = tok.balanceOf(address(pool));
        vm.prank(alice);
        uint256 out = pool.swapCeloForToken{value: 1 ether}(0);
        assertEq(tok.balanceOf(address(pool)), tokReserveBefore - out);
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

    function test_SwapTokenForCelo_RevertNoLiquidity() public {
        vm.prank(alice);
        tok.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(ITokenSwap.InsufficientLiquidity.selector);
        pool.swapTokenForCelo(100 ether, 0);
    }

    function test_SwapTokenForCelo_RevertZeroAmount() public {
        _addLiquidity();
        vm.prank(alice);
        vm.expectRevert(ITokenSwap.ZeroAmount.selector);
        pool.swapTokenForCelo(0, 0);
    }

    function test_SwapTokenForCelo_RevertBlacklisted() public {
        _addLiquidity();
        pool.addToBlacklist(alice);
        vm.prank(alice);
        tok.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(ITokenSwap.Blacklisted.selector);
        pool.swapTokenForCelo(100 ether, 0);
    }

    function test_SwapTokenForCelo_RevertWhenPaused() public {
        _addLiquidity();
        pool.pause();
        vm.prank(alice);
        tok.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(ITokenSwap.Paused.selector);
        pool.swapTokenForCelo(100 ether, 0);
    }

    // ─── GetAmountOut ──────────────────────────────────────────────────────────

    function test_GetAmountOut_ConstantProduct() public {
        _addLiquidity();
        uint256 out = pool.getAmountOut(1 ether, CELO_LIQ, TOKEN_LIQ);
        assertGt(out, 0);
        assertLt(out, TOKEN_LIQ);
    }

    function test_GetAmountOut_RevertZeroInput() public {
        vm.expectRevert(ITokenSwap.ZeroAmount.selector);
        pool.getAmountOut(0, 10 ether, 10 ether);
    }

    function test_GetAmountOut_RevertZeroReserveIn() public {
        vm.expectRevert(ITokenSwap.InsufficientLiquidity.selector);
        pool.getAmountOut(1 ether, 0, 10 ether);
    }

    function test_GetAmountOut_RevertZeroReserveOut() public {
        vm.expectRevert(ITokenSwap.InsufficientLiquidity.selector);
        pool.getAmountOut(1 ether, 10 ether, 0);
    }

    function test_GetAmountOut_ZeroFee_FullConstantProduct() public {
        TokenSwap p = new TokenSwap(address(tok), 0);
        // With 0 fee: out = amountIn * reserveOut / (reserveIn + amountIn)
        uint256 out = p.getAmountOut(1 ether, 10 ether, 10 ether);
        assertEq(out, (1 ether * 10 ether) / (10 ether + 1 ether));
    }

    function test_GetAmountOut_HigherFee_LessOutput() public {
        uint256 outLow  = pool.getAmountOut(1 ether, 10 ether, 10 ether); // 0.3% fee
        TokenSwap p2 = new TokenSwap(address(tok), 300);
        uint256 outHigh = p2.getAmountOut(1 ether, 10 ether, 10 ether);   // 3% fee
        assertGt(outLow, outHigh);
    }

    // ─── Blacklist ─────────────────────────────────────────────────────────────

    function test_AddToBlacklist_Success() public {
        pool.addToBlacklist(alice);
        assertTrue(pool.blacklisted(alice));
    }

    function test_AddToBlacklist_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit BlacklistUpdated(alice, true);
        pool.addToBlacklist(alice);
    }

    function test_AddToBlacklist_RevertZeroAddress() public {
        vm.expectRevert(ITokenSwap.ZeroAddress.selector);
        pool.addToBlacklist(address(0));
    }

    function test_AddToBlacklist_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ITokenSwap.NotOwner.selector);
        pool.addToBlacklist(bob);
    }

    function test_RemoveFromBlacklist_Success() public {
        pool.addToBlacklist(alice);
        pool.removeFromBlacklist(alice);
        assertFalse(pool.blacklisted(alice));
    }

    function test_RemoveFromBlacklist_EmitsEvent() public {
        pool.addToBlacklist(alice);
        vm.expectEmit(true, false, false, true);
        emit BlacklistUpdated(alice, false);
        pool.removeFromBlacklist(alice);
    }

    function test_RemoveFromBlacklist_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ITokenSwap.NotOwner.selector);
        pool.removeFromBlacklist(bob);
    }

    function test_Blacklist_RemovedCanSwapAgain() public {
        _addLiquidity();
        pool.addToBlacklist(alice);
        pool.removeFromBlacklist(alice);
        vm.prank(alice);
        uint256 out = pool.swapCeloForToken{value: 1 ether}(0);
        assertGt(out, 0);
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

    function test_SetFee_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ITokenSwap.NotOwner.selector);
        pool.setFee(10);
    }

    function test_SetFee_ZeroAllowed() public {
        pool.setFee(0);
        assertEq(pool.feeBps(), 0);
    }

    function test_SetFee_MaxAllowed() public {
        pool.setFee(300);
        assertEq(pool.feeBps(), 300);
    }

    function test_Pause_Unpause() public {
        pool.pause();
        assertTrue(pool.paused());
        pool.unpause();
        assertFalse(pool.paused());
    }

    function test_Pause_EmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit ContractPaused(owner);
        pool.pause();
    }

    function test_Unpause_EmitsEvent() public {
        pool.pause();
        vm.expectEmit(true, false, false, false);
        emit ContractUnpaused(owner);
        pool.unpause();
    }

    function test_Pause_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ITokenSwap.NotOwner.selector);
        pool.pause();
    }

    function test_TwoStepOwnership() public {
        pool.transferOwnership(alice);
        assertEq(pool.pendingOwner(), alice);
        vm.prank(alice);
        pool.acceptOwnership();
        assertEq(pool.owner(), alice);
        assertEq(pool.pendingOwner(), address(0));
    }

    function test_TransferOwnership_EmitsEvents() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferStarted(owner, alice);
        pool.transferOwnership(alice);
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, alice);
        vm.prank(alice);
        pool.acceptOwnership();
    }

    function test_TransferOwnership_RevertZeroAddress() public {
        vm.expectRevert(ITokenSwap.ZeroAddress.selector);
        pool.transferOwnership(address(0));
    }

    function test_AcceptOwnership_RevertNotPending() public {
        pool.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(ITokenSwap.NotPendingOwner.selector);
        pool.acceptOwnership();
    }

    function test_TransferOwnership_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(ITokenSwap.NotOwner.selector);
        pool.transferOwnership(bob);
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

    function testFuzz_GetAmountOut(uint256 amountIn, uint256 rIn, uint256 rOut) public view {
        amountIn = bound(amountIn, 1, 1e30);
        rIn      = bound(rIn, 1, 1e30);
        rOut     = bound(rOut, 1, 1e30);
        uint256 out = pool.getAmountOut(amountIn, rIn, rOut);
        assertLt(out, rOut); // cannot drain reserve
    }

    function testFuzz_AddRemoveLiquidity(uint256 celoAmt, uint256 tokAmt) public {
        celoAmt = bound(celoAmt, 0.001 ether, 50 ether);
        tokAmt  = bound(tokAmt, 1 ether, 50_000 ether);
        tok.mint(owner, tokAmt);
        tok.approve(address(pool), tokAmt);
        vm.deal(owner, celoAmt);
        uint256 lp = pool.addLiquidity{value: celoAmt}(tokAmt, 0);
        assertGt(lp, 0);
        pool.removeLiquidity(lp, 0, 0);
        assertEq(pool.totalLP(), 0);
    }

    // ─── Invariant ─────────────────────────────────────────────────────────────

    function test_Invariant_KIncreasesAfterSwap() public {
        _addLiquidity();
        uint256 kBefore = address(pool).balance * tok.balanceOf(address(pool));
        vm.prank(alice);
        pool.swapCeloForToken{value: 1 ether}(0);
        uint256 kAfter = address(pool).balance * tok.balanceOf(address(pool));
        assertGe(kAfter, kBefore);
    }

    function test_Invariant_KIncreasesAfterTokenSwap() public {
        _addLiquidity();
        uint256 kBefore = address(pool).balance * tok.balanceOf(address(pool));
        vm.prank(alice);
        tok.approve(address(pool), 100 ether);
        vm.prank(alice);
        pool.swapTokenForCelo(100 ether, 0);
        uint256 kAfter = address(pool).balance * tok.balanceOf(address(pool));
        assertGe(kAfter, kBefore);
    }

    function test_Invariant_TotalLPZeroAfterFullRemoval() public {
        uint256 lp = _addLiquidity();
        pool.removeLiquidity(lp, 0, 0);
        assertEq(pool.totalLP(), 0);
        assertEq(pool.lpBalances(owner), 0);
    }

    function test_Invariant_OutputLessThanReserve() public {
        _addLiquidity();
        vm.prank(alice);
        uint256 out = pool.swapCeloForToken{value: 1 ether}(0);
        assertLt(out, TOKEN_LIQ);
    }

    // ─── Internal helper ───────────────────────────────────────────────────────

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) { z = y; uint256 x = y / 2 + 1; while (x < z) { z = x; x = (y / x + x) / 2; } }
        else if (y != 0) { z = 1; }
    }

    receive() external payable {}
}
