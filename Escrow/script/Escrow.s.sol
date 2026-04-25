// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {Escrow} from "../src/Escrow.sol";

/// @notice Deploys the Escrow contract to Celo mainnet.
/// @dev Run with:
///   forge script script/Escrow.s.sol:EscrowScript \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
contract EscrowScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        // 100 bps = 1% platform fee
        new Escrow(100);
        vm.stopBroadcast();
    }
}
