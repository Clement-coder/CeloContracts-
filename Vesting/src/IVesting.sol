// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IVesting
/// @notice Interface for the ERC20 token vesting contract with cliff and linear release.
interface IVesting {
    // ─── Errors ────────────────────────────────────────────────────────────────
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error Paused();
    error Reentrancy();
    error InvalidSchedule();
    error CliffTooLong();
    error DurationTooShort();
    error DurationTooLong();
    error AmountTooLow();
    error NothingToRelease();
    error AlreadyRevoked();
    error NotRevocable();
    error ScheduleNotFound();
    error TransferFailed();
    error BeneficiaryMismatch();

    // ─── Events ────────────────────────────────────────────────────────────────
    event ScheduleCreated(uint256 indexed id, address indexed beneficiary, address indexed token, uint256 amount, uint256 cliff, uint256 duration);
    event TokensReleased(uint256 indexed id, address indexed beneficiary, uint256 amount);
    event ScheduleRevoked(uint256 indexed id, address indexed revokedBy, uint256 unvestedReturned);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ─── Functions ─────────────────────────────────────────────────────────────
    function createSchedule(address beneficiary, address token, uint256 amount, uint256 cliffDuration, uint256 totalDuration, bool revocable) external returns (uint256);
    function release(uint256 id) external;
    function revoke(uint256 id) external;
    function releasable(uint256 id) external view returns (uint256);
    function getSchedule(uint256 id) external view returns (address beneficiary, address token, uint256 amount, uint256 start, uint256 cliff, uint256 duration, uint256 released, bool revocable, bool revoked);
    function pause() external;
    function unpause() external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
