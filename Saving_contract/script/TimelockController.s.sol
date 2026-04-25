// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "../src/TimelockController.sol";
import {Savings} from "../src/Savings.sol";

/// @notice Deploys TimelockController and transfers Savings ownership to it.
/// @dev Run with:
///   forge script script/TimelockController.s.sol:TimelockScript \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
///
///   Required env vars:
///     PRIVATE_KEY        - deployer private key
///     SAVINGS_ADDRESS    - already-deployed Savings contract address
///     PROPOSER_ADDRESS   - address to grant proposer role (defaults to deployer)
///     EXECUTOR_ADDRESS   - address to grant executor role (defaults to deployer)
contract TimelockScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address savingsAddr = vm.envAddress("SAVINGS_ADDRESS");

        // Default proposer/executor to deployer if not set
        address proposer = vm.envOr("PROPOSER_ADDRESS", deployer);
        address executor = vm.envOr("EXECUTOR_ADDRESS", deployer);

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;

        address[] memory executors = new address[](1);
        executors[0] = executor;

        vm.startBroadcast(deployerKey);

        // Deploy timelock with 2-day delay
        TimelockController timelock = new TimelockController(2 days, proposers, executors);

        // Transfer Savings ownership to the timelock
        Savings savings = Savings(payable(savingsAddr));
        savings.transferOwnership(address(timelock));

        vm.stopBroadcast();

        // Log addresses
        console2.log("TimelockController:", address(timelock));
        console2.log("Savings (ownership pending):", savingsAddr);
    }
}
