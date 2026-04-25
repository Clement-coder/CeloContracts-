// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20Token} from "./IERC20Token.sol";

/// @title ERC20Token
/// @notice A standard ERC20 token with mint/burn, supply cap, pause,
///         and two-step ownership — deployed on Celo.
/// @dev    Custom errors, full NatSpec, reentrancy guard.
contract ERC20Token is IERC20Token {

    // ─── Metadata ──────────────────────────────────────────────────────────────

    /// @notice Token name.
    string public name;

    /// @notice Token symbol.
    string public symbol;

    /// @notice Token decimals (18).
    uint8 public constant decimals = 18;

    // ─── Supply ────────────────────────────────────────────────────────────────

    /// @notice Maximum token supply.
    uint256 public immutable CAP;

    /// @notice Current total supply.
    uint256 public totalSupply;

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice Current owner.
    address public owner;

    /// @notice Pending owner in two-step transfer.
    address public pendingOwner;

    /// @notice Whether the contract is paused.
    bool public paused;

    /// @notice Reentrancy lock.
    bool private _locked;

    /// @notice Token balances.
    mapping(address => uint256) private _balances;

    /// @notice Spending allowances.
    mapping(address => mapping(address => uint256)) private _allowances;

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

    /// @notice Deploy the token.
    /// @param _name   Token name.
    /// @param _symbol Token symbol.
    /// @param _cap    Maximum supply (in wei). Must be > 0.
    constructor(string memory _name, string memory _symbol, uint256 _cap) {
        if (_cap == 0) revert ZeroAmount();
        name = _name;
        symbol = _symbol;
        CAP = _cap;
        owner = msg.sender;
    }

    // ─── ERC20 ─────────────────────────────────────────────────────────────────

    /// @notice Returns the balance of `account`.
    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    /// @notice Returns the allowance `spender` has over `owner`'s tokens.
    function allowance(address _owner, address spender) external view override returns (uint256) {
        return _allowances[_owner][spender];
    }

    /// @notice Transfer `amount` tokens to `to`.
    function transfer(address to, uint256 amount) external override whenNotPaused nonReentrant returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Approve `spender` to spend `amount` of caller's tokens.
    function approve(address spender, uint256 amount) external override returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Transfer `amount` tokens from `from` to `to` using allowance.
    function transferFrom(address from, address to, uint256 amount)
        external override whenNotPaused nonReentrant returns (bool)
    {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance();
        if (allowed != type(uint256).max) _allowances[from][msg.sender] -= amount;
        _transfer(from, to, amount);
        return true;
    }

    // ─── Mint / Burn ───────────────────────────────────────────────────────────

    /// @notice Mint `amount` tokens to `to`. Only owner.
    /// @dev Reverts if supply would exceed CAP. Emits {Minted} and {Transfer}.
    function mint(address to, uint256 amount) external override onlyOwner whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (totalSupply + amount > CAP) revert CapExceeded();
        totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
        emit Minted(to, amount);
    }

    /// @notice Burn `amount` of caller's tokens.
    /// @dev Emits {Burned} and {Transfer}.
    function burn(uint256 amount) external override whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (_balances[msg.sender] < amount) revert InsufficientBalance();
        _balances[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
        emit Burned(msg.sender, amount);
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Pause the contract — halts transfers, mints, and burns.
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

    /// @notice Accept ownership (must be called by pendingOwner).
    function acceptOwnership() external override {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    // ─── Internal ──────────────────────────────────────────────────────────────

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (_balances[from] < amount) revert InsufficientBalance();
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }
}
