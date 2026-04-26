// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title ITokenSwap
/// @notice Interface for the CELO ↔ ERC20 constant-product AMM.
interface ITokenSwap {
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error Paused();
    error Reentrancy();
    error InsufficientLiquidity();
    error InsufficientInput();
    error SlippageExceeded();
    error InsufficientLPTokens();
    error ZeroAmount();
    error TransferFailed();
    error FeeTooHigh();
    error Blacklisted();

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

    function addLiquidity(uint256 tokenAmount, uint256 minLpOut) external payable returns (uint256 lpMinted);
    function removeLiquidity(uint256 lpAmount, uint256 minCelo, uint256 minToken) external returns (uint256 celoOut, uint256 tokenOut);
    function swapCeloForToken(uint256 minTokenOut) external payable returns (uint256 tokenOut);
    function swapTokenForCelo(uint256 tokenIn, uint256 minCeloOut) external returns (uint256 celoOut);
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external view returns (uint256);
    function setFee(uint256 newFeeBps) external;
    function pause() external;
    function unpause() external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
