// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {TaskPlatform} from "../src/TaskPlatform.sol";

/// @notice Deploys the TaskPlatform contract to Celo mainnet.
/// @dev Run with:
///   forge script script/TaskPlatform.s.sol:TaskPlatformScript \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
contract TaskPlatformScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        new TaskPlatform();
        vm.stopBroadcast();
    }
}
