// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title Savings
/// @notice A simple savings contract where each user can deposit, lock funds until a deadline, and withdraw.
contract Savings {
    struct Account {
        uint256 balance;
        uint256 unlockTime; // 0 means no lock
    }

    mapping(address => Account) public accounts;

    event Deposited(address indexed user, uint256 amount, uint256 unlockTime);
    event Withdrawn(address indexed user, uint256 amount);

    /// @notice Deposit CELO into your savings account.
    /// @param lockDuration Seconds to lock the funds (0 for no lock).
    function deposit(uint256 lockDuration) external payable {
        require(msg.value > 0, "No value sent");
        Account storage acc = accounts[msg.sender];
        acc.balance += msg.value;
        if (lockDuration > 0) {
            uint256 newUnlock = block.timestamp + lockDuration;
            if (newUnlock > acc.unlockTime) acc.unlockTime = newUnlock;
        }
        emit Deposited(msg.sender, msg.value, acc.unlockTime);
    }

    /// @notice Withdraw all funds (only after lock expires).
    function withdraw() external {
        Account storage acc = accounts[msg.sender];
        require(acc.balance > 0, "Nothing to withdraw");
        require(block.timestamp >= acc.unlockTime, "Funds are locked");
        uint256 amount = acc.balance;
        acc.balance = 0;
        acc.unlockTime = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "Transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Returns the caller's balance and unlock timestamp.
    function getAccount() external view returns (uint256 balance, uint256 unlockTime) {
        Account storage acc = accounts[msg.sender];
        return (acc.balance, acc.unlockTime);
    }
}
