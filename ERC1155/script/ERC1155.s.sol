// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1155} from "../src/ERC1155.sol";

/// @notice Deploys the ERC1155 contract.
/// @dev Run with:
///   forge script script/ERC1155.s.sol:ERC1155Script \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
///
///   Required env vars:
///     PRIVATE_KEY - deployer private key
///     BASE_URI    - base URI for token metadata (e.g. "ipfs://Qm.../")
contract ERC1155Script is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        string memory baseURI = vm.envString("BASE_URI");

        vm.startBroadcast(deployerKey);
        ERC1155 token = new ERC1155(baseURI);
        vm.stopBroadcast();

        console2.log("ERC1155:", address(token));
    }
}
