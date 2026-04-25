// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {ERC721NFT} from "../src/ERC721NFT.sol";

/// @notice Deploys the ERC721NFT collection to Celo mainnet.
/// @dev Run with:
///   forge script script/ERC721NFT.s.sol:ERC721NFTScript \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
contract ERC721NFTScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        new ERC721NFT("CeloNFT", "CNFT", 10_000);
        vm.stopBroadcast();
    }
}
