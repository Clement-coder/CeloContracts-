// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IFlashLoan
/// @notice Interface for the CELO flash loan pool.
interface IFlashLoan {
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error Paused();
    error Reentrancy();
    error AmountTooLow();
    error InsufficientLiquidity();
    error RepaymentFailed();
    error FeeTooHigh();
    error TransferFailed();
    error InvalidReceiver();
    error AmountTooHigh();
    error DailyLimitExceeded();
    error NotPaused();

    event FlashLoan(address indexed receiver, uint256 amount, uint256 fee);
    event PoolFunded(address indexed funder, uint256 amount);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event EmergencyWithdrawal(address indexed to, uint256 amount);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event LimitsUpdated(uint256 oldMaxLoan, uint256 newMaxLoan, uint256 oldMaxDaily, uint256 newMaxDaily);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function flashLoan(address receiver, uint256 amount, bytes calldata data) external;
    function fundPool() external payable;
    function withdrawFees() external;
    function setFee(uint256 newFeeBps) external;
    function availableLiquidity() external view returns (uint256);
    function pause() external;
    function unpause() external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

/// @title IFlashLoanReceiver
/// @notice Callback interface that borrowers must implement.
interface IFlashLoanReceiver {
    /// @notice Called by the flash loan pool during a loan.
    /// @param amount   Amount borrowed in wei.
    /// @param fee      Fee owed in wei.
    /// @param data     Arbitrary data passed by the borrower.
    function executeOperation(uint256 amount, uint256 fee, bytes calldata data) external payable;
}
