// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {Crowdfunding} from "../src/Crowdfunding.sol";

/// @notice Deploys the Crowdfunding contract to Celo mainnet.
/// @dev Run with:
///   forge script script/Crowdfunding.s.sol:CrowdfundingScript \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
contract CrowdfundingScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        new Crowdfunding();
        vm.stopBroadcast();
    }
}
