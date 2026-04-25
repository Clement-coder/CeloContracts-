// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {Vesting} from "../src/Vesting.sol";

/// @notice Deploys the Vesting contract to Celo mainnet.
/// @dev Run with:
///   forge script script/Vesting.s.sol:VestingScript \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
contract VestingScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        new Vesting();
        vm.stopBroadcast();
    }
}
