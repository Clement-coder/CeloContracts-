// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {Staking} from "../src/Staking.sol";
import {IStaking} from "../src/IStaking.sol";

contract StakingTest is Test {
    Staking staking;
    address owner = address(this);
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    uint256 constant RATE  = 1_000; // 10% APR
    uint256 constant STAKE = 1 ether;
    uint256 constant POOL  = 10 ether;

    event Staked(address indexed user, uint256 amount, uint256 lockUntil);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 reward);
    event RewardCompounded(address indexed user, uint256 reward, uint256 newStakeAmount);
    event RewardPoolFunded(address indexed funder, uint256 amount);
    event RateUpdated(uint256 oldRate, uint256 newRate);
    event ProtocolFeeAccrued(uint256 amount);
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    event ProtocolFeesWithdrawn(address indexed to, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        staking = new Staking(RATE);
        staking.fundRewardPool{value: POOL}();
        vm.deal(alice, 10 ether);
        vm.deal(bob,   10 ether);
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    function test_Constructor_SetsParams() public view {
        assertEq(staking.owner(), owner);
        assertEq(staking.rewardRateBps(), RATE);
    }

    function test_Constructor_RevertZeroRate() public {
        vm.expectRevert(IStaking.InvalidRate.selector);
        new Staking(0);
    }

    function test_Constructor_RevertRateTooHigh() public {
        vm.expectRevert(IStaking.InvalidRate.selector);
        new Staking(10_001);
    }

    // ─── FundRewardPool ────────────────────────────────────────────────────────

    function test_FundRewardPool_Success() public {
        uint256 before = staking.rewardPool();
        staking.fundRewardPool{value: 1 ether}();
        assertEq(staking.rewardPool(), before + 1 ether);
    }

    function test_FundRewardPool_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit RewardPoolFunded(owner, 1 ether);
        staking.fundRewardPool{value: 1 ether}();
    }

    function test_FundRewardPool_RevertZero() public {
        vm.expectRevert(IStaking.AmountTooLow.selector);
        staking.fundRewardPool{value: 0}();
    }

    // ─── Stake ─────────────────────────────────────────────────────────────────

    function test_Stake_NoLock() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        (uint256 amount, uint256 lockUntil,) = staking.getStake(alice);
        assertEq(amount, STAKE);
        assertEq(lockUntil, 0);
        assertEq(staking.totalStaked(), STAKE);
    }

    function test_Stake_WithLock() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(30 days);
        (, uint256 lockUntil,) = staking.getStake(alice);
        assertApproxEqAbs(lockUntil, block.timestamp + 30 days, 1);
    }

    function test_Stake_EmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit Staked(alice, STAKE, 0);
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
    }

    function test_Stake_TopUp() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        (uint256 amount,,) = staking.getStake(alice);
        assertEq(amount, STAKE * 2);
    }

    function test_Stake_RevertBelowMin() public {
        vm.prank(alice);
        vm.expectRevert(IStaking.AmountTooLow.selector);
        staking.stake{value: 1}(0);
    }

    function test_Stake_RevertLockTooLong() public {
        uint256 tooLong = staking.MAX_LOCK() + 1 days;
        vm.prank(alice);
        vm.expectRevert(IStaking.LockTooLong.selector);
        staking.stake{value: STAKE}(tooLong);
    }

    function test_Stake_RevertWhenPaused() public {
        staking.pause();
        vm.prank(alice);
        vm.expectRevert(IStaking.Paused.selector);
        staking.stake{value: STAKE}(0);
    }

    function test_Stake_RevertExceedsMaxPerUser() public {
        uint256 max = staking.MAX_STAKE_PER_USER();
        vm.deal(alice, max + 1 ether);
        vm.prank(alice);
        staking.stake{value: max}(0);
        vm.prank(alice);
        vm.expectRevert(IStaking.StakeExceedsMax.selector);
        staking.stake{value: 1 ether}(0);
    }

    // ─── Unstake ───────────────────────────────────────────────────────────────

    function test_Unstake_NoLock() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        uint256 before = alice.balance;
        vm.prank(alice);
        staking.unstake();
        assertGe(alice.balance, before + STAKE);
        assertEq(staking.totalStaked(), 0);
    }

    function test_Unstake_AfterLock() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(7 days);
        skip(7 days + 1);
        vm.prank(alice);
        staking.unstake();
        (uint256 amount,,) = staking.getStake(alice);
        assertEq(amount, 0);
    }

    function test_Unstake_EmitsEvent() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        vm.expectEmit(true, false, false, true);
        emit Unstaked(alice, STAKE);
        vm.prank(alice);
        staking.unstake();
    }

    function test_Unstake_RevertNothingStaked() public {
        vm.prank(alice);
        vm.expectRevert(IStaking.NothingStaked.selector);
        staking.unstake();
    }

    function test_Unstake_RevertLockNotExpired() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(7 days);
        vm.prank(alice);
        vm.expectRevert(IStaking.LockNotExpired.selector);
        staking.unstake();
    }

    function test_Unstake_ClearsStake() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        vm.prank(alice);
        staking.unstake();
        (uint256 amount, uint256 lockUntil, uint256 stakedAt) = staking.getStake(alice);
        assertEq(amount, 0);
        assertEq(lockUntil, 0);
        assertEq(stakedAt, 0);
    }

    function test_Unstake_DeductsProtocolFeeFromReward() public {
        staking.setProtocolFee(100); // 1%
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        skip(365 days);
        uint256 grossReward = staking.pendingReward(alice);
        uint256 expectedFee = grossReward / 100;
        uint256 before = alice.balance;
        vm.prank(alice);
        staking.unstake();
        // principal + net reward
        assertApproxEqAbs(alice.balance, before + STAKE + grossReward - expectedFee, 1);
    }

    // ─── ClaimReward ───────────────────────────────────────────────────────────

    function test_ClaimReward_Success() public {
        staking.setProtocolFee(0); // zero fee for clean assertion
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        skip(365 days);
        uint256 reward = staking.pendingReward(alice);
        assertGt(reward, 0);
        uint256 before = alice.balance;
        vm.prank(alice);
        staking.claimReward();
        assertEq(alice.balance, before + reward);
    }

    function test_ClaimReward_NetAfterProtocolFee() public {
        staking.setProtocolFee(100); // 1%
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        skip(365 days);
        uint256 grossReward = staking.pendingReward(alice);
        uint256 expectedFee = grossReward / 100;
        uint256 before = alice.balance;
        vm.prank(alice);
        staking.claimReward();
        assertEq(alice.balance, before + grossReward - expectedFee);
    }

    function test_ClaimReward_EmitsEvent() public {
        staking.setProtocolFee(0);
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        skip(365 days);
        uint256 reward = staking.pendingReward(alice);
        vm.expectEmit(true, false, false, true);
        emit RewardClaimed(alice, reward);
        vm.prank(alice);
        staking.claimReward();
    }

    function test_ClaimReward_EmitsProtocolFeeAccrued() public {
        staking.setProtocolFee(100);
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        skip(365 days);
        uint256 grossReward = staking.pendingReward(alice);
        vm.expectEmit(false, false, false, true);
        emit ProtocolFeeAccrued(grossReward / 100);
        vm.prank(alice);
        staking.claimReward();
    }

    function test_ClaimReward_ResetsTimer() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        skip(365 days);
        vm.prank(alice);
        staking.claimReward();
        assertEq(staking.pendingReward(alice), 0);
    }

    function test_ClaimReward_RevertNothingStaked() public {
        vm.prank(alice);
        vm.expectRevert(IStaking.NothingStaked.selector);
        staking.claimReward();
    }

    function test_ClaimReward_RevertNothingToWithdraw() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        vm.prank(alice);
        vm.expectRevert(IStaking.NothingToWithdraw.selector);
        staking.claimReward();
    }

    // ─── CompoundReward ────────────────────────────────────────────────────────

    function test_CompoundReward_IncreasesStake() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        skip(365 days);
        uint256 reward = staking.pendingReward(alice);
        vm.prank(alice);
        staking.compoundReward();
        (uint256 amount,,) = staking.getStake(alice);
        assertEq(amount, STAKE + reward);
    }

    function test_CompoundReward_IncreasesTotalStaked() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        skip(365 days);
        uint256 reward = staking.pendingReward(alice);
        vm.prank(alice);
        staking.compoundReward();
        assertEq(staking.totalStaked(), STAKE + reward);
    }

    function test_CompoundReward_EmitsEvent() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        skip(365 days);
        uint256 reward = staking.pendingReward(alice);
        vm.expectEmit(true, false, false, true);
        emit RewardCompounded(alice, reward, STAKE + reward);
        vm.prank(alice);
        staking.compoundReward();
    }

    function test_CompoundReward_ResetsTimer() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        skip(365 days);
        vm.prank(alice);
        staking.compoundReward();
        assertEq(staking.pendingReward(alice), 0);
    }

    function test_CompoundReward_RevertNothingStaked() public {
        vm.prank(alice);
        vm.expectRevert(IStaking.NothingStaked.selector);
        staking.compoundReward();
    }

    function test_CompoundReward_RevertNothingToWithdraw() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        vm.prank(alice);
        vm.expectRevert(IStaking.NothingToWithdraw.selector);
        staking.compoundReward();
    }

    // ─── SetProtocolFee ────────────────────────────────────────────────────────

    function test_SetProtocolFee_Success() public {
        staking.setProtocolFee(200);
        assertEq(staking.protocolFeeBps(), 200);
    }

    function test_SetProtocolFee_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit ProtocolFeeUpdated(100, 200);
        staking.setProtocolFee(200);
    }

    function test_SetProtocolFee_RevertTooHigh() public {
        vm.expectRevert(IStaking.InvalidProtocolFee.selector);
        staking.setProtocolFee(1001);
    }

    function test_SetProtocolFee_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(IStaking.NotOwner.selector);
        staking.setProtocolFee(100);
    }

    function test_SetProtocolFee_MaxBoundary() public {
        staking.setProtocolFee(1000); // exactly 10% — should succeed
        assertEq(staking.protocolFeeBps(), 1000);
    }

    // ─── WithdrawProtocolFees ──────────────────────────────────────────────────

    function test_WithdrawProtocolFees_Success() public {
        staking.setProtocolFee(100);
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        skip(365 days);
        vm.prank(alice);
        staking.claimReward();
        uint256 accrued = staking.accruedProtocolFees();
        assertGt(accrued, 0);
        uint256 before = owner.balance;
        staking.withdrawProtocolFees();
        assertEq(owner.balance, before + accrued);
        assertEq(staking.accruedProtocolFees(), 0);
    }

    function test_WithdrawProtocolFees_EmitsEvent() public {
        staking.setProtocolFee(100);
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        skip(365 days);
        vm.prank(alice);
        staking.claimReward();
        uint256 accrued = staking.accruedProtocolFees();
        vm.expectEmit(true, false, false, true);
        emit ProtocolFeesWithdrawn(owner, accrued);
        staking.withdrawProtocolFees();
    }

    function test_WithdrawProtocolFees_RevertNothingToWithdraw() public {
        vm.expectRevert(IStaking.NothingToWithdraw.selector);
        staking.withdrawProtocolFees();
    }

    function test_WithdrawProtocolFees_RevertNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(IStaking.NotOwner.selector);
        staking.withdrawProtocolFees();
    }

    // ─── PendingReward ─────────────────────────────────────────────────────────

    function test_PendingReward_ZeroIfNoStake() public view {
        assertEq(staking.pendingReward(alice), 0);
    }

    function test_PendingReward_AccruesOverTime() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        uint256 r1 = staking.pendingReward(alice);
        skip(30 days);
        uint256 r2 = staking.pendingReward(alice);
        assertGt(r2, r1);
    }

    function test_PendingReward_At10PctAPR_1Year() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        skip(365 days);
        uint256 reward = staking.pendingReward(alice);
        assertApproxEqRel(reward, 0.1 ether, 0.01e18);
    }

    // ─── SetRewardRate ─────────────────────────────────────────────────────────

    function test_SetRewardRate_Success() public {
        vm.expectEmit(false, false, false, true);
        emit RateUpdated(RATE, 500);
        staking.setRewardRate(500);
        assertEq(staking.rewardRateBps(), 500);
    }

    function test_SetRewardRate_RevertZero() public {
        vm.expectRevert(IStaking.InvalidRate.selector);
        staking.setRewardRate(0);
    }

    function test_SetRewardRate_RevertTooHigh() public {
        vm.expectRevert(IStaking.InvalidRate.selector);
        staking.setRewardRate(10_001);
    }

    // ─── Pause / Ownership ─────────────────────────────────────────────────────

    function test_Pause_Unpause() public {
        staking.pause();
        assertTrue(staking.paused());
        staking.unpause();
        assertFalse(staking.paused());
    }

    function test_TwoStepOwnership() public {
        staking.transferOwnership(alice);
        assertEq(staking.pendingOwner(), alice);
        vm.prank(alice);
        staking.acceptOwnership();
        assertEq(staking.owner(), alice);
    }

    function test_TransferOwnership_RevertZeroAddress() public {
        vm.expectRevert(IStaking.ZeroAddress.selector);
        staking.transferOwnership(address(0));
    }

    function test_AcceptOwnership_RevertNotPending() public {
        staking.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(IStaking.NotPendingOwner.selector);
        staking.acceptOwnership();
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_StakeAndReward(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, 365 days);
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        skip(elapsed);
        uint256 reward = staking.pendingReward(alice);
        assertGt(reward, 0);
        assertLe(reward, STAKE);
    }

    function testFuzz_StakeAmount(uint256 amount) public {
        amount = bound(amount, staking.MIN_STAKE(), 5 ether);
        vm.deal(alice, amount);
        vm.prank(alice);
        staking.stake{value: amount}(0);
        (uint256 staked,,) = staking.getStake(alice);
        assertEq(staked, amount);
    }

    // ─── Invariant ─────────────────────────────────────────────────────────────

    function test_Invariant_BalanceEqualsTotalStakedPlusPoolPlusFees() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        vm.prank(bob);
        staking.stake{value: STAKE}(0);
        assertEq(
            address(staking).balance,
            staking.totalStaked() + staking.rewardPool() + staking.accruedProtocolFees()
        );
    }

    receive() external payable {}
}
