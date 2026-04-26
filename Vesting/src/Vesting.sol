// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IVesting} from "./IVesting.sol";

/// @dev Minimal ERC20 interface needed by the vesting contract.
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title Vesting
/// @notice ERC20 token vesting with cliff and linear release schedule.
///         Owner creates schedules for beneficiaries. After the cliff, tokens
///         vest linearly until the end of the duration. Revocable schedules
///         allow the owner to cancel and reclaim unvested tokens.
/// @dev    Production-grade: reentrancy guard, pause, two-step ownership,
///         custom errors, full NatSpec, locked pragma, optimizer config.
contract Vesting is IVesting {

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Minimum vesting amount: 1 token unit (1e-18).
    uint256 public constant MIN_AMOUNT = 1;

    /// @notice Minimum total vesting duration: 1 day.
    uint256 public constant MIN_DURATION = 1 days;

    /// @notice Maximum total vesting duration: 4 years.
    uint256 public constant MAX_DURATION = 4 * 365 days;

    /// @notice Maximum cliff duration: 2 years.
    uint256 public constant MAX_CLIFF_DURATION = 2 * 365 days;

    /// @notice Maximum cliff: 2 years.
    uint256 public constant MAX_CLIFF = 2 * 365 days;

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice Current contract owner.
    address public owner;

    /// @notice Pending owner in two-step transfer.
    address public pendingOwner;

    /// @notice Whether the contract is paused.
    bool public paused;

    /// @notice Reentrancy lock.
    bool private _locked;

    /// @notice Total number of vesting schedules created.
    uint256 public scheduleCount;

    /// @dev Vesting schedule record.
    struct Schedule {
        /// @dev Token beneficiary address.
        address beneficiary;
        /// @dev ERC20 token being vested.
        address token;
        /// @dev Total tokens to vest.
        uint256 amount;
        /// @dev Timestamp when vesting starts.
        uint256 start;
        /// @dev Timestamp when cliff ends (tokens first become releasable).
        uint256 cliff;
        /// @dev Total vesting duration in seconds from start.
        uint256 duration;
        /// @dev Tokens already released.
        uint256 released;
        /// @dev Whether the owner can revoke this schedule.
        bool revocable;
        /// @dev Whether the schedule has been revoked.
        bool revoked;
    }

    /// @notice Vesting schedules by ID (1-indexed).
    mapping(uint256 => Schedule) public schedules;

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    modifier scheduleExists(uint256 id) {
        if (id == 0 || id > scheduleCount) revert ScheduleNotFound();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @notice Deploy the vesting contract. Deployer becomes owner.
    constructor() {
        owner = msg.sender;
    }

    // ─── Core ──────────────────────────────────────────────────────────────────

    /// @notice Create a new vesting schedule. Transfers tokens from caller to this contract.
    /// @param beneficiary    Address that will receive vested tokens.
    /// @param token          ERC20 token address to vest.
    /// @param amount         Total tokens to vest. Must be >= MIN_AMOUNT.
    /// @param cliffDuration  Seconds from now until first tokens vest. Must be <= MAX_CLIFF.
    /// @param totalDuration  Total vesting duration in seconds. Must be between MIN_DURATION and MAX_DURATION.
    /// @param revocable      Whether the owner can revoke this schedule.
    /// @return id            The new schedule ID.
    /// @dev Caller must have approved this contract for `amount` tokens.
    ///      Emits {ScheduleCreated}.
    function createSchedule(
        address beneficiary,
        address token,
        uint256 amount,
        uint256 cliffDuration,
        uint256 totalDuration,
        bool revocable
    ) external override whenNotPaused nonReentrant returns (uint256) {
        if (beneficiary == address(0) || token == address(0)) revert ZeroAddress();
        if (amount < MIN_AMOUNT) revert AmountTooLow();
        if (totalDuration < MIN_DURATION) revert DurationTooShort();
        if (totalDuration > MAX_DURATION) revert DurationTooLong();
        if (cliffDuration > MAX_CLIFF) revert CliffTooLong();
        if (cliffDuration > totalDuration) revert InvalidSchedule();

        uint256 id = ++scheduleCount;
        uint256 start = block.timestamp;
        uint256 cliff = start + cliffDuration;

        schedules[id] = Schedule({
            beneficiary: beneficiary,
            token: token,
            amount: amount,
            start: start,
            cliff: cliff,
            duration: totalDuration,
            released: 0,
            revocable: revocable,
            revoked: false
        });

        emit ScheduleCreated(id, beneficiary, token, amount, cliff, totalDuration);

        bool ok = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        return id;
    }

    /// @notice Release vested tokens to the beneficiary.
    /// @param id Schedule ID to release from.
    /// @dev   Anyone can call this on behalf of the beneficiary.
    ///        Emits {TokensReleased}.
    function release(uint256 id)
        external override nonReentrant scheduleExists(id)
    {
        Schedule storage s = schedules[id];
        if (s.revoked) revert AlreadyRevoked();

        uint256 amount = _releasable(s);
        if (amount == 0) revert NothingToRelease();

        s.released += amount;

        emit TokensReleased(id, s.beneficiary, amount);

        bool ok = IERC20(s.token).transfer(s.beneficiary, amount);
        if (!ok) revert TransferFailed();
    }

    /// @notice Release vested tokens from multiple schedules in one transaction.
    /// @param ids Array of schedule IDs to release from.
    /// @dev   Skips schedules with no releasable tokens. Emits {TokensReleased} for each.
    function batchRelease(uint256[] calldata ids) external nonReentrant {
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            if (id == 0 || id > scheduleCount) continue; // Skip invalid IDs
            
            Schedule storage s = schedules[id];
            if (s.revoked) continue; // Skip revoked schedules
            
            uint256 amount = _releasable(s);
            if (amount == 0) continue; // Skip if nothing to release
            
            s.released += amount;
            
            emit TokensReleased(id, s.beneficiary, amount);
            
            bool ok = IERC20(s.token).transfer(s.beneficiary, amount);
            if (!ok) revert TransferFailed();
        }
    }

    /// @notice Owner revokes a revocable schedule. Unvested tokens returned to owner.
    /// @param id Schedule ID to revoke.
    /// @dev   Emits {ScheduleRevoked}. Already-vested tokens remain claimable by beneficiary.
    function revoke(uint256 id)
        external override onlyOwner nonReentrant scheduleExists(id)
    {
        Schedule storage s = schedules[id];
        if (!s.revocable) revert NotRevocable();
        if (s.revoked) revert AlreadyRevoked();

        // Release any vested-but-unreleased tokens to beneficiary first
        uint256 vestedUnreleased = _releasable(s);
        if (vestedUnreleased > 0) {
            s.released += vestedUnreleased;
            bool ok1 = IERC20(s.token).transfer(s.beneficiary, vestedUnreleased);
            if (!ok1) revert TransferFailed();
        }

        // Return unvested tokens to owner
        uint256 unvested = s.amount - s.released;
        s.revoked = true;

        emit ScheduleRevoked(id, msg.sender, unvested);

        if (unvested > 0) {
            bool ok2 = IERC20(s.token).transfer(owner, unvested);
            if (!ok2) revert TransferFailed();
        }
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Returns the amount of tokens currently releasable for a schedule.
    /// @param id Schedule ID to query.
    /// @return Amount of tokens that can be released right now.
    function releasable(uint256 id)
        external view override scheduleExists(id) returns (uint256)
    {
        return _releasable(schedules[id]);
    }

    /// @notice Returns full details of a vesting schedule.
    /// @param id Schedule ID to query.
    /// @return beneficiary Address receiving vested tokens.
    /// @return token       ERC20 token being vested.
    /// @return amount      Total tokens in schedule.
    /// @return start       Vesting start timestamp.
    /// @return cliff       Cliff end timestamp.
    /// @return duration    Total vesting duration in seconds.
    /// @return released    Tokens already released.
    /// @return revocable   Whether owner can revoke.
    /// @return revoked     Whether schedule has been revoked.
    function getSchedule(uint256 id)
        external view override scheduleExists(id)
        returns (address beneficiary, address token, uint256 amount, uint256 start, uint256 cliff, uint256 duration, uint256 released, bool revocable, bool revoked)
    {
        Schedule storage s = schedules[id];
        return (s.beneficiary, s.token, s.amount, s.start, s.cliff, s.duration, s.released, s.revocable, s.revoked);
    }

    // ─── Internal ──────────────────────────────────────────────────────────────

    /// @dev Calculates releasable tokens for a schedule at current timestamp.
    ///      Returns 0 before cliff. After cliff, linear vesting until end.
    function _releasable(Schedule storage s) internal view returns (uint256) {
        if (s.revoked) return 0;
        uint256 vested = _vestedAmount(s);
        return vested - s.released;
    }

    /// @dev Calculates total vested amount at current timestamp.
    function _vestedAmount(Schedule storage s) internal view returns (uint256) {
        uint256 end = s.start + s.duration;
        if (block.timestamp < s.cliff) return 0;
        if (block.timestamp >= end) return s.amount;
        // Linear vesting between cliff and end
        return (s.amount * (block.timestamp - s.start)) / s.duration;
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Pause the contract — halts schedule creation.
    /// @dev Emits {ContractPaused}.
    function pause() external override onlyOwner {
        paused = true;
        emit ContractPaused(msg.sender);
    }

    /// @notice Unpause the contract.
    /// @dev Emits {ContractUnpaused}.
    function unpause() external override onlyOwner {
        paused = false;
        emit ContractUnpaused(msg.sender);
    }

    /// @notice Initiate two-step ownership transfer.
    /// @param newOwner Proposed new owner. Cannot be zero address.
    function transferOwnership(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Accept ownership (must be called by pendingOwner).
    function acceptOwnership() external override {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}
