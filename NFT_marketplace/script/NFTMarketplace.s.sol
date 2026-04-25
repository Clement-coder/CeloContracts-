// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {NFTMarketplace} from "../src/NFTMarketplace.sol";

/// @notice Deploys the NFTMarketplace to Celo mainnet.
/// @dev Run with:
///   forge script script/NFTMarketplace.s.sol:NFTMarketplaceScript \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
contract NFTMarketplaceScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        // 250 bps = 2.5% platform fee
        new NFTMarketplace(250);
        vm.stopBroadcast();
    }
}
