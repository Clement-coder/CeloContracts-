// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vesting} from "../src/Vesting.sol";
import {IVesting} from "../src/IVesting.sol";

/// @dev Minimal ERC20 mock for testing.
contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract VestingTest is Test {
    Vesting vesting;
    MockToken token;

    address owner = address(this);
    address alice = makeAddr("alice"); // beneficiary
    address bob   = makeAddr("bob");

    uint256 constant AMOUNT   = 1_000 ether;
    uint256 constant CLIFF    = 30 days;
    uint256 constant DURATION = 365 days;

    // Mirror events
    event ScheduleCreated(uint256 indexed id, address indexed beneficiary, address indexed token, uint256 amount, uint256 cliff, uint256 duration);
    event TokensReleased(uint256 indexed id, address indexed beneficiary, uint256 amount);
    event ScheduleRevoked(uint256 indexed id, address indexed revokedBy, uint256 unvestedReturned);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        vesting = new Vesting();
        token   = new MockToken();
        token.mint(owner, 100_000 ether);
        token.approve(address(vesting), type(uint256).max);
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────

    function _create(bool revocable) internal returns (uint256 id) {
        id = vesting.createSchedule(alice, address(token), AMOUNT, CLIFF, DURATION, revocable);
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsOwner() public view {
        assertEq(vesting.owner(), owner);
    }

    // ─── CreateSchedule ────────────────────────────────────────────────────────

    function test_Create_Success() public {
        uint256 id = _create(false);
        assertEq(id, 1);
        assertEq(vesting.scheduleCount(), 1);
        assertEq(token.balanceOf(address(vesting)), AMOUNT);
    }

    function test_Create_EmitsEvent() public {
        vm.expectEmit(true, true, true, false);
        emit ScheduleCreated(1, alice, address(token), AMOUNT, 0, DURATION);
        _create(false);
    }

    function test_Create_RevertZeroAddress_Beneficiary() public {
        vm.expectRevert(IVesting.ZeroAddress.selector);
        vesting.createSchedule(address(0), address(token), AMOUNT, CLIFF, DURATION, false);
    }

    function test_Create_RevertZeroAddress_Token() public {
        vm.expectRevert(IVesting.ZeroAddress.selector);
        vesting.createSchedule(alice, address(0), AMOUNT, CLIFF, DURATION, false);
    }

    function test_Create_RevertDurationTooShort() public {
        vm.expectRevert(IVesting.DurationTooShort.selector);
        vesting.createSchedule(alice, address(token), AMOUNT, 0, 1 hours, false);
    }

    function test_Create_RevertDurationTooLong() public {
        vm.expectRevert(IVesting.DurationTooLong.selector);
        vesting.createSchedule(alice, address(token), AMOUNT, 0, 5 * 365 days, false);
    }

    function test_Create_RevertCliffTooLong() public {
        vm.expectRevert(IVesting.CliffTooLong.selector);
        vesting.createSchedule(alice, address(token), AMOUNT, 3 * 365 days, 4 * 365 days, false);
    }

    function test_Create_RevertCliffExceedsDuration() public {
        vm.expectRevert(IVesting.InvalidSchedule.selector);
        vesting.createSchedule(alice, address(token), AMOUNT, 400 days, 365 days, false);
    }

    function test_Create_RevertWhenPaused() public {
        vesting.pause();
        vm.expectRevert(IVesting.Paused.selector);
        vesting.createSchedule(alice, address(token), AMOUNT, CLIFF, DURATION, false);
    }

    // ─── Release ───────────────────────────────────────────────────────────────

    function test_Release_AfterCliff() public {
        _create(false);
        skip(CLIFF + 1);
        uint256 releasableAmt = vesting.releasable(1);
        assertGt(releasableAmt, 0);
        vesting.release(1);
        assertEq(token.balanceOf(alice), releasableAmt);
    }

    function test_Release_FullyVested() public {
        _create(false);
        skip(DURATION + 1);
        vesting.release(1);
        assertEq(token.balanceOf(alice), AMOUNT);
    }

    function test_Release_EmitsEvent() public {
        _create(false);
        skip(DURATION + 1);
        vm.expectEmit(true, true, false, false);
        emit TokensReleased(1, alice, AMOUNT);
        vesting.release(1);
    }

    function test_Release_RevertBeforeCliff() public {
        _create(false);
        vm.expectRevert(IVesting.NothingToRelease.selector);
        vesting.release(1);
    }

    function test_Release_RevertNothingToRelease_AfterFull() public {
        _create(false);
        skip(DURATION + 1);
        vesting.release(1);
        vm.expectRevert(IVesting.NothingToRelease.selector);
        vesting.release(1);
    }

    function test_Release_RevertRevoked() public {
        _create(true);
        skip(CLIFF + 1);
        vesting.revoke(1);
        vm.expectRevert(IVesting.AlreadyRevoked.selector);
        vesting.release(1);
    }

    function test_Release_LinearVesting() public {
        _create(false);
        skip(DURATION / 2);
        uint256 r = vesting.releasable(1);
        // At halfway, roughly half should be vested
        assertApproxEqRel(r, AMOUNT / 2, 0.01e18); // within 1%
    }

    // ─── Revoke ────────────────────────────────────────────────────────────────

    function test_Revoke_Success() public {
        _create(true);
        skip(CLIFF + 1);
        uint256 vestedBefore = vesting.releasable(1);
        vesting.revoke(1);
        // Beneficiary got vested tokens
        assertEq(token.balanceOf(alice), vestedBefore);
        // Owner got unvested tokens back
        assertGt(token.balanceOf(owner), 0);
    }

    function test_Revoke_EmitsEvent() public {
        _create(true);
        vm.expectEmit(true, true, false, false);
        emit ScheduleRevoked(1, owner, AMOUNT);
        vesting.revoke(1);
    }

    function test_Revoke_RevertNotRevocable() public {
        _create(false);
        vm.expectRevert(IVesting.NotRevocable.selector);
        vesting.revoke(1);
    }

    function test_Revoke_RevertAlreadyRevoked() public {
        _create(true);
        vesting.revoke(1);
        vm.expectRevert(IVesting.AlreadyRevoked.selector);
        vesting.revoke(1);
    }

    function test_Revoke_RevertNotOwner() public {
        _create(true);
        vm.prank(alice);
        vm.expectRevert(IVesting.NotOwner.selector);
        vesting.revoke(1);
    }

    function test_Revoke_BeforeCliff_ReturnsAll() public {
        _create(true);
        // No cliff passed, all tokens unvested
        vesting.revoke(1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    // ─── Releasable ────────────────────────────────────────────────────────────

    function test_Releasable_ZeroBeforeCliff() public {
        _create(false);
        assertEq(vesting.releasable(1), 0);
    }

    function test_Releasable_FullAfterDuration() public {
        _create(false);
        skip(DURATION + 1);
        assertEq(vesting.releasable(1), AMOUNT);
    }

    function test_Releasable_ZeroAfterRevoke() public {
        _create(true);
        vesting.revoke(1);
        assertEq(vesting.releasable(1), 0);
    }

    function test_Releasable_RevertInvalidSchedule() public {
        vm.expectRevert(IVesting.ScheduleNotFound.selector);
        vesting.releasable(99);
    }

    // ─── Pause ─────────────────────────────────────────────────────────────────

    function test_Pause_Unpause() public {
        vesting.pause();
        assertTrue(vesting.paused());
        vesting.unpause();
        assertFalse(vesting.paused());
    }

    function test_Pause_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(IVesting.NotOwner.selector);
        vesting.pause();
    }

    // ─── Ownership ─────────────────────────────────────────────────────────────

    function test_TwoStepOwnership() public {
        vesting.transferOwnership(alice);
        assertEq(vesting.pendingOwner(), alice);
        vm.prank(alice);
        vesting.acceptOwnership();
        assertEq(vesting.owner(), alice);
        assertEq(vesting.pendingOwner(), address(0));
    }

    function test_TransferOwnership_RevertZeroAddress() public {
        vm.expectRevert(IVesting.ZeroAddress.selector);
        vesting.transferOwnership(address(0));
    }

    function test_AcceptOwnership_RevertNotPending() public {
        vesting.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(IVesting.NotPendingOwner.selector);
        vesting.acceptOwnership();
    }

    function test_TransferOwnership_EmitsEvents() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferStarted(owner, alice);
        vesting.transferOwnership(alice);
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, alice);
        vm.prank(alice);
        vesting.acceptOwnership();
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_LinearVesting(uint256 elapsed) public {
        _create(false);
        elapsed = bound(elapsed, CLIFF, DURATION);
        skip(elapsed);
        uint256 r = vesting.releasable(1);
        assertGt(r, 0);
        assertLe(r, AMOUNT);
    }

    function testFuzz_CreateSchedule(uint256 amount, uint256 cliff, uint256 dur) public {
        amount = bound(amount, 1, 10_000 ether);
        dur    = bound(dur, vesting.MIN_DURATION(), vesting.MAX_DURATION());
        cliff  = bound(cliff, 0, min(dur, vesting.MAX_CLIFF()));
        token.mint(owner, amount);
        token.approve(address(vesting), amount);
        uint256 id = vesting.createSchedule(alice, address(token), amount, cliff, dur, false);
        assertEq(id, vesting.scheduleCount());
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }

    // ─── Invariant ─────────────────────────────────────────────────────────────

    function test_Invariant_ContractBalanceEqualsUnreleased() public {
        _create(false);
        skip(DURATION / 2);
        uint256 released = vesting.releasable(1);
        vesting.release(1);
        (,,,,,, uint256 releasedStored,,) = vesting.getSchedule(1);
        assertEq(token.balanceOf(address(vesting)), AMOUNT - releasedStored);
    }

    receive() external payable {}
}
