// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {DutchAuction} from "../src/DutchAuction.sol";

/// @notice Deploys the DutchAuction contract to Celo mainnet.
/// @dev Run with:
///   forge script script/DutchAuction.s.sol:DutchAuctionScript \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
contract DutchAuctionScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        // 250 bps = 2.5% platform fee
        new DutchAuction(250);
        vm.stopBroadcast();
    }
}
