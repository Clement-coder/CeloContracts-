// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title AirdropToken
/// @notice Minimal ERC20 used as the airdrop reward token.
/// @dev    No dependencies — hand-rolled to keep the project self-contained.
contract AirdropToken {
    // ─── ERC20 State ───────────────────────────────────────────────────────────

    string public constant name     = "Airdrop Token";
    string public constant symbol   = "ADT";
    uint8  public constant decimals = 18;

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ─── Events ────────────────────────────────────────────────────────────────

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ─── Errors ────────────────────────────────────────────────────────────────

    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @notice Deploy the token and mint the full supply to the deployer.
    /// @param initialSupply Total tokens minted to deployer (in wei).
    constructor(uint256 initialSupply) {
        totalSupply = initialSupply;
        balanceOf[msg.sender] = initialSupply;
        emit Transfer(address(0), msg.sender, initialSupply);
    }

    // ─── ERC20 ─────────────────────────────────────────────────────────────────

    /// @notice Transfer tokens to another address.
    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Approve spender to transfer up to amount on behalf of caller.
    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Transfer tokens on behalf of from (requires prior approval).
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        uint256 allowed = allowance[from][msg.sender];
        // Skip decrement for max allowance (gas optimisation, matches OZ behaviour)
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
