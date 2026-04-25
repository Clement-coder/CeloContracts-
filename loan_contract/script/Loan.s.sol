// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {Loan} from "../src/Loan.sol";

/// @notice Deploys the Loan contract to Celo mainnet.
/// @dev Run with:
///   forge script script/Loan.s.sol:LoanScript \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
contract LoanScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        // 1000 bps = 10% annual interest
        new Loan(1_000);
        vm.stopBroadcast();
    }
}
