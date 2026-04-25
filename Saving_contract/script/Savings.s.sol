// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {Savings} from "../src/Savings.sol";

/// @notice Deploys the Savings contract to Celo mainnet.
/// @dev Run with:
///   forge script script/Savings.s.sol:SavingsScript \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
contract SavingsScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        new Savings();
        vm.stopBroadcast();
    }
}
