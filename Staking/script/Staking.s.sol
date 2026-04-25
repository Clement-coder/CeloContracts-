// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {Staking} from "../src/Staking.sol";

/// @notice Deploys the Staking contract to Celo mainnet.
/// @dev Run with:
///   forge script script/Staking.s.sol:StakingScript \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
contract StakingScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        // 1000 bps = 10% APR
        new Staking(1_000);
        vm.stopBroadcast();
    }
}
