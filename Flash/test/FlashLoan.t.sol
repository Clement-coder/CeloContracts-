// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {FlashLoanPool} from "../src/FlashLoan.sol";
import {IFlashLoan, IFlashLoanReceiver} from "../src/IFlashLoan.sol";

/// @dev Honest borrower: repays principal + fee.
contract HonestBorrower is IFlashLoanReceiver {
    FlashLoanPool pool;
    constructor(address _pool) payable { pool = FlashLoanPool(payable(_pool)); }
    function executeOperation(uint256 amount, uint256 fee, bytes calldata) external payable override {
        // Repay principal + fee
        (bool ok,) = address(pool).call{value: amount + fee}("");
        require(ok);
    }
    receive() external payable {}
}

/// @dev Dishonest borrower: keeps the money.
contract ThiefBorrower is IFlashLoanReceiver {
    function executeOperation(uint256, uint256, bytes calldata) external payable override {}
    receive() external payable {}
}

/// @dev Partial repayer: only repays principal, not fee.
contract PartialBorrower is IFlashLoanReceiver {
    FlashLoanPool pool;
    constructor(address _pool) payable { pool = FlashLoanPool(payable(_pool)); }
    function executeOperation(uint256 amount, uint256, bytes calldata) external payable override {
        (bool ok,) = address(pool).call{value: amount}("");
        require(ok);
    }
    receive() external payable {}
}

contract FlashLoanTest is Test {
    FlashLoanPool pool;
    address owner = address(this);
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    uint256 constant FEE      = 9;    // 0.09%
    uint256 constant LIQUIDITY = 10 ether;
    uint256 constant LOAN     = 1 ether;

    event FlashLoan(address indexed receiver, uint256 amount, uint256 fee);
    event PoolFunded(address indexed funder, uint256 amount);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        pool = new FlashLoanPool(FEE);
        pool.fundPool{value: LIQUIDITY}();
        vm.deal(alice, 5 ether);
        vm.deal(bob,   5 ether);
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsParams() public view {
        assertEq(pool.owner(), owner);
        assertEq(pool.feeBps(), FEE);
    }

    function test_Constructor_RevertFeeTooHigh() public {
        vm.expectRevert(IFlashLoan.FeeTooHigh.selector);
        new FlashLoanPool(101);
    }

    // ─── FundPool ──────────────────────────────────────────────────────────────

    function test_FundPool_Success() public {
        uint256 before = pool.availableLiquidity();
        pool.fundPool{value: 1 ether}();
        assertEq(pool.availableLiquidity(), before + 1 ether);
    }

    function test_FundPool_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit PoolFunded(owner, 1 ether);
        pool.fundPool{value: 1 ether}();
    }

    function test_FundPool_RevertZero() public {
        vm.expectRevert(IFlashLoan.AmountTooLow.selector);
        pool.fundPool{value: 0}();
    }

    function test_FundPool_ViaReceive() public {
        uint256 before = pool.availableLiquidity();
        (bool ok,) = address(pool).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(pool.availableLiquidity(), before + 1 ether);
    }

    // ─── FlashLoan ─────────────────────────────────────────────────────────────

    function test_FlashLoan_HonestBorrower() public {
        uint256 fee = (LOAN * FEE) / 10_000;
        HonestBorrower borrower = new HonestBorrower{value: fee + 0.1 ether}(address(pool));
        uint256 liquidityBefore = pool.availableLiquidity();
        pool.flashLoan(address(borrower), LOAN, "");
        // Liquidity unchanged (principal returned), fees accrued
        assertEq(pool.availableLiquidity(), liquidityBefore);
        assertEq(pool.accruedFees(), fee);
    }

    function test_FlashLoan_EmitsEvent() public {
        uint256 fee = (LOAN * FEE) / 10_000;
        HonestBorrower borrower = new HonestBorrower{value: fee + 0.1 ether}(address(pool));
        vm.expectEmit(true, false, false, true);
        emit FlashLoan(address(borrower), LOAN, fee);
        pool.flashLoan(address(borrower), LOAN, "");
    }

    function test_FlashLoan_RevertThief() public {
        ThiefBorrower thief = new ThiefBorrower();
        vm.expectRevert(IFlashLoan.RepaymentFailed.selector);
        pool.flashLoan(address(thief), LOAN, "");
    }

    function test_FlashLoan_RevertPartialRepay() public {
        PartialBorrower cheater = new PartialBorrower{value: 0.1 ether}(address(pool));
        vm.expectRevert(IFlashLoan.RepaymentFailed.selector);
        pool.flashLoan(address(cheater), LOAN, "");
    }

    function test_FlashLoan_RevertInsufficientLiquidity() public {
        HonestBorrower borrower = new HonestBorrower{value: 1 ether}(address(pool));
        vm.expectRevert(IFlashLoan.InsufficientLiquidity.selector);
        pool.flashLoan(address(borrower), 100 ether, "");
    }

    function test_FlashLoan_RevertAmountTooLow() public {
        HonestBorrower borrower = new HonestBorrower{value: 1 ether}(address(pool));
        vm.expectRevert(IFlashLoan.AmountTooLow.selector);
        pool.flashLoan(address(borrower), 1, "");
    }

    function test_FlashLoan_RevertZeroReceiver() public {
        vm.expectRevert(IFlashLoan.InvalidReceiver.selector);
        pool.flashLoan(address(0), LOAN, "");
    }

    function test_FlashLoan_RevertWhenPaused() public {
        pool.pause();
        HonestBorrower borrower = new HonestBorrower{value: 1 ether}(address(pool));
        vm.expectRevert(IFlashLoan.Paused.selector);
        pool.flashLoan(address(borrower), LOAN, "");
    }

    function test_FlashLoan_LiquidityRestoredAfterLoan() public {
        uint256 fee = (LOAN * FEE) / 10_000;
        HonestBorrower borrower = new HonestBorrower{value: fee + 0.1 ether}(address(pool));
        uint256 before = address(pool).balance;
        pool.flashLoan(address(borrower), LOAN, "");
        assertEq(address(pool).balance, before + fee);
    }

    // ─── WithdrawFees ──────────────────────────────────────────────────────────

    function test_WithdrawFees_Success() public {
        uint256 fee = (LOAN * FEE) / 10_000;
        HonestBorrower borrower = new HonestBorrower{value: fee + 0.1 ether}(address(pool));
        pool.flashLoan(address(borrower), LOAN, "");
        uint256 before = owner.balance;
        pool.withdrawFees();
        assertEq(owner.balance, before + fee);
        assertEq(pool.accruedFees(), 0);
    }

    function test_WithdrawFees_EmitsEvent() public {
        uint256 fee = (LOAN * FEE) / 10_000;
        HonestBorrower borrower = new HonestBorrower{value: fee + 0.1 ether}(address(pool));
        pool.flashLoan(address(borrower), LOAN, "");
        vm.expectEmit(true, false, false, true);
        emit FeesWithdrawn(owner, fee);
        pool.withdrawFees();
    }

    function test_WithdrawFees_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(IFlashLoan.NotOwner.selector);
        pool.withdrawFees();
    }

    // ─── AvailableLiquidity ────────────────────────────────────────────────────

    function test_AvailableLiquidity_ExcludesFees() public {
        uint256 fee = (LOAN * FEE) / 10_000;
        HonestBorrower borrower = new HonestBorrower{value: fee + 0.1 ether}(address(pool));
        pool.flashLoan(address(borrower), LOAN, "");
        assertEq(pool.availableLiquidity(), address(pool).balance - pool.accruedFees());
    }

    // ─── SetFee ────────────────────────────────────────────────────────────────

    function test_SetFee_Success() public {
        vm.expectEmit(false, false, false, true);
        emit FeeUpdated(FEE, 50);
        pool.setFee(50);
        assertEq(pool.feeBps(), 50);
    }

    function test_SetFee_RevertFeeTooHigh() public {
        vm.expectRevert(IFlashLoan.FeeTooHigh.selector);
        pool.setFee(101);
    }

    // ─── Pause / Ownership ─────────────────────────────────────────────────────

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
        vm.expectRevert(IFlashLoan.ZeroAddress.selector);
        pool.transferOwnership(address(0));
    }

    function test_AcceptOwnership_RevertNotPending() public {
        pool.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(IFlashLoan.NotPendingOwner.selector);
        pool.acceptOwnership();
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_FlashLoan(uint256 amount) public {
        amount = bound(amount, pool.MIN_AMOUNT(), LIQUIDITY);
        uint256 fee = (amount * FEE) / 10_000;
        HonestBorrower borrower = new HonestBorrower{value: fee + 0.1 ether}(address(pool));
        pool.flashLoan(address(borrower), amount, "");
        assertEq(pool.accruedFees(), fee);
    }

    // ─── Invariant ─────────────────────────────────────────────────────────────

    function test_Invariant_BalanceEqualsLiquidityPlusFees() public {
        uint256 fee = (LOAN * FEE) / 10_000;
        HonestBorrower borrower = new HonestBorrower{value: fee + 0.1 ether}(address(pool));
        pool.flashLoan(address(borrower), LOAN, "");
        assertEq(address(pool).balance, pool.availableLiquidity() + pool.accruedFees());
    }

    receive() external payable {}
}
// Commit 12 optimization
