// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {Subscription} from "../src/Subscription.sol";

/// @notice Deploys the Subscription contract to Celo mainnet.
/// @dev Run with:
///   forge script script/Subscription.s.sol:SubscriptionScript \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
contract SubscriptionScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        new Subscription();
        vm.stopBroadcast();
    }
}
