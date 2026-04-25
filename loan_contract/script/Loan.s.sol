// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {Loan} from "../src/Loan.sol";

contract LoanScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        // 1000 bps = 10% annual interest
        new Loan(1000);
        vm.stopBroadcast();
    }
}
