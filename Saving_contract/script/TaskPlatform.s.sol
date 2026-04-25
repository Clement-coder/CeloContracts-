// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {TaskPlatform} from "../src/TaskPlatform.sol";

contract TaskPlatformScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        new TaskPlatform();
        vm.stopBroadcast();
    }
}
