// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {ERC20Token} from "../src/ERC20Token.sol";

/// @notice Deploys the ERC20Token to Celo mainnet.
/// @dev Run with:
///   forge script script/ERC20Token.s.sol:ERC20TokenScript \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
contract ERC20TokenScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        new ERC20Token("CeloToken", "CTK", 1_000_000_000 ether);
        vm.stopBroadcast();
    }
}
