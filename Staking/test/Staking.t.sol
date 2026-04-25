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

    uint256 constant RATE   = 1_000; // 10% APR
    uint256 constant STAKE  = 1 ether;
    uint256 constant POOL   = 10 ether;

    event Staked(address indexed user, uint256 amount, uint256 lockUntil);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 reward);
    event RewardPoolFunded(address indexed funder, uint256 amount);
    event RateUpdated(uint256 oldRate, uint256 newRate);
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

    // ─── Unstake ───────────────────────────────────────────────────────────────

    function test_Unstake_NoLock() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        uint256 before = alice.balance;
        vm.prank(alice);
        staking.unstake();
        assertGe(alice.balance, before + STAKE); // principal + any reward
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

    // ─── ClaimReward ───────────────────────────────────────────────────────────

    function test_ClaimReward_Success() public {
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

    function test_ClaimReward_EmitsEvent() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        skip(365 days);
        uint256 reward = staking.pendingReward(alice);
        vm.expectEmit(true, false, false, true);
        emit RewardClaimed(alice, reward);
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
        staking.claimReward(); // no time elapsed
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
        // 10% of 1 ether = 0.1 ether
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
        assertLe(reward, STAKE); // at 100% max APR, reward <= principal in 1 year
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

    function test_Invariant_BalanceEqualsTotalStakedPlusPool() public {
        vm.prank(alice);
        staking.stake{value: STAKE}(0);
        vm.prank(bob);
        staking.stake{value: STAKE}(0);
        assertEq(address(staking).balance, staking.totalStaked() + staking.rewardPool());
    }

    receive() external payable {}
}
