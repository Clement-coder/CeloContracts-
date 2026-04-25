// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ITokenSwap} from "./ITokenSwap.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title TokenSwap
/// @notice Constant-product AMM (x*y=k) for CELO ↔ ERC20 token swaps.
///         Liquidity providers deposit CELO + token and receive LP tokens.
///         Swappers pay a fee (in bps) that accrues to liquidity providers.
/// @dev    Production-grade: reentrancy guard, pause, two-step ownership,
///         slippage protection, custom errors, full NatSpec.
contract TokenSwap is ITokenSwap {

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Maximum swap fee: 3% (300 bps).
    uint256 public constant MAX_FEE_BPS = 300;

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice ERC20 token paired with CELO.
    address public immutable token;

    /// @notice Current contract owner.
    address public owner;

    /// @notice Pending owner in two-step transfer.
    address public pendingOwner;

    /// @notice Whether the contract is paused.
    bool public paused;

    /// @notice Reentrancy lock.
    bool private _locked;

    /// @notice Swap fee in basis points (e.g. 30 = 0.3%).
    uint256 public feeBps;

    /// @notice Total LP tokens in circulation.
    uint256 public totalLP;

    /// @notice LP token balances per provider.
    mapping(address => uint256) public lpBalances;

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

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @notice Deploy the AMM pool.
    /// @param _token  ERC20 token address to pair with CELO.
    /// @param _feeBps Swap fee in basis points. Must be <= MAX_FEE_BPS.
    constructor(address _token, uint256 _feeBps) {
        if (_token == address(0)) revert ZeroAddress();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        token = _token;
        feeBps = _feeBps;
        owner = msg.sender;
    }

    // ─── Liquidity ─────────────────────────────────────────────────────────────

    /// @notice Add liquidity to the pool. Receive LP tokens proportional to share.
    /// @param tokenAmount Amount of ERC20 tokens to deposit.
    /// @param minLpOut    Minimum LP tokens to receive (slippage protection).
    /// @return lpMinted   LP tokens minted to caller.
    /// @dev   First liquidity provider sets the initial price ratio.
    ///        Caller must approve this contract for tokenAmount. Emits {LiquidityAdded}.
    function addLiquidity(uint256 tokenAmount, uint256 minLpOut)
        external payable override whenNotPaused nonReentrant returns (uint256 lpMinted)
    {
        if (msg.value == 0 || tokenAmount == 0) revert ZeroAmount();

        uint256 celoReserve = address(this).balance - msg.value;
        uint256 tokenReserve = IERC20(token).balanceOf(address(this));

        if (totalLP == 0) {
            // First deposit: LP = sqrt(celo * token) simplified to geometric mean
            lpMinted = _sqrt(msg.value * tokenAmount);
        } else {
            // Proportional to existing reserves
            uint256 lpByCelo  = (msg.value * totalLP) / celoReserve;
            uint256 lpByToken = (tokenAmount * totalLP) / tokenReserve;
            lpMinted = lpByCelo < lpByToken ? lpByCelo : lpByToken;
        }

        if (lpMinted < minLpOut) revert SlippageExceeded();
        if (lpMinted == 0) revert InsufficientLiquidity();

        totalLP += lpMinted;
        lpBalances[msg.sender] += lpMinted;

        emit LiquidityAdded(msg.sender, msg.value, tokenAmount, lpMinted);

        bool ok = IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);
        if (!ok) revert TransferFailed();
    }

    /// @notice Remove liquidity from the pool. Burn LP tokens, receive CELO + token.
    /// @param lpAmount  LP tokens to burn.
    /// @param minCelo   Minimum CELO to receive (slippage protection).
    /// @param minToken  Minimum tokens to receive (slippage protection).
    /// @return celoOut  CELO returned.
    /// @return tokenOut Tokens returned.
    /// @dev Emits {LiquidityRemoved}.
    function removeLiquidity(uint256 lpAmount, uint256 minCelo, uint256 minToken)
        external override nonReentrant returns (uint256 celoOut, uint256 tokenOut)
    {
        if (lpAmount == 0) revert ZeroAmount();
        if (lpBalances[msg.sender] < lpAmount) revert InsufficientLPTokens();

        uint256 celoReserve  = address(this).balance;
        uint256 tokenReserve = IERC20(token).balanceOf(address(this));

        celoOut  = (lpAmount * celoReserve)  / totalLP;
        tokenOut = (lpAmount * tokenReserve) / totalLP;

        if (celoOut < minCelo)   revert SlippageExceeded();
        if (tokenOut < minToken) revert SlippageExceeded();

        totalLP -= lpAmount;
        lpBalances[msg.sender] -= lpAmount;

        emit LiquidityRemoved(msg.sender, celoOut, tokenOut, lpAmount);

        (bool ok,) = msg.sender.call{value: celoOut}("");
        if (!ok) revert TransferFailed();

        bool tok = IERC20(token).transfer(msg.sender, tokenOut);
        if (!tok) revert TransferFailed();
    }

    // ─── Swaps ─────────────────────────────────────────────────────────────────

    /// @notice Swap CELO for ERC20 tokens.
    /// @param minTokenOut Minimum tokens to receive (slippage protection).
    /// @return tokenOut   Tokens received.
    /// @dev Emits {SwappedCeloForToken}.
    function swapCeloForToken(uint256 minTokenOut)
        external payable override whenNotPaused nonReentrant returns (uint256 tokenOut)
    {
        if (msg.value == 0) revert ZeroAmount();

        uint256 celoReserve  = address(this).balance - msg.value;
        uint256 tokenReserve = IERC20(token).balanceOf(address(this));

        if (celoReserve == 0 || tokenReserve == 0) revert InsufficientLiquidity();

        tokenOut = getAmountOut(msg.value, celoReserve, tokenReserve);
        if (tokenOut < minTokenOut) revert SlippageExceeded();

        emit SwappedCeloForToken(msg.sender, msg.value, tokenOut);

        bool ok = IERC20(token).transfer(msg.sender, tokenOut);
        if (!ok) revert TransferFailed();
    }

    /// @notice Swap ERC20 tokens for CELO.
    /// @param tokenIn    Amount of tokens to swap.
    /// @param minCeloOut Minimum CELO to receive (slippage protection).
    /// @return celoOut   CELO received.
    /// @dev Emits {SwappedTokenForCelo}.
    function swapTokenForCelo(uint256 tokenIn, uint256 minCeloOut)
        external override whenNotPaused nonReentrant returns (uint256 celoOut)
    {
        if (tokenIn == 0) revert ZeroAmount();

        uint256 celoReserve  = address(this).balance;
        uint256 tokenReserve = IERC20(token).balanceOf(address(this));

        if (celoReserve == 0 || tokenReserve == 0) revert InsufficientLiquidity();

        celoOut = getAmountOut(tokenIn, tokenReserve, celoReserve);
        if (celoOut < minCeloOut) revert SlippageExceeded();

        emit SwappedTokenForCelo(msg.sender, tokenIn, celoOut);

        bool tok = IERC20(token).transferFrom(msg.sender, address(this), tokenIn);
        if (!tok) revert TransferFailed();

        (bool ok,) = msg.sender.call{value: celoOut}("");
        if (!ok) revert TransferFailed();
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Calculate output amount using constant-product formula with fee.
    /// @param amountIn   Input amount.
    /// @param reserveIn  Reserve of input token.
    /// @param reserveOut Reserve of output token.
    /// @return Amount of output token received.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public view override returns (uint256)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 amountInWithFee = amountIn * (10_000 - feeBps);
        return (amountInWithFee * reserveOut) / (reserveIn * 10_000 + amountInWithFee);
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Update the swap fee.
    /// @param newFeeBps New fee in basis points. Must be <= MAX_FEE_BPS.
    function setFee(uint256 newFeeBps) external override onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        emit FeeUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    /// @notice Pause the contract.
    function pause() external override onlyOwner {
        paused = true;
        emit ContractPaused(msg.sender);
    }

    /// @notice Unpause the contract.
    function unpause() external override onlyOwner {
        paused = false;
        emit ContractUnpaused(msg.sender);
    }

    /// @notice Initiate two-step ownership transfer.
    function transferOwnership(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Accept ownership.
    function acceptOwnership() external override {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    // ─── Internal ──────────────────────────────────────────────────────────────

    /// @dev Integer square root (Babylonian method).
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2; }
        } else if (y != 0) {
            z = 1;
        }
    }
}
