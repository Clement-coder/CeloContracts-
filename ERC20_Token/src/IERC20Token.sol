// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IERC20Token
/// @notice Interface for the Celo ERC20 token with mint/burn and two-step ownership.
interface IERC20Token {
    // ─── Errors ────────────────────────────────────────────────────────────────
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error InsufficientAllowance();
    error NotOwner();
    error NotPendingOwner();
    error Paused();
    error Reentrancy();
    error CapExceeded();

    // ─── Events ────────────────────────────────────────────────────────────────
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ─── ERC20 ─────────────────────────────────────────────────────────────────
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);

    // ─── Mint / Burn ───────────────────────────────────────────────────────────
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;

    // ─── Admin ─────────────────────────────────────────────────────────────────
    function pause() external;
    function unpause() external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function totalSupply() external view returns (uint256);
    function CAP() external view returns (uint256);
    function decimals() external view returns (uint8);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}
