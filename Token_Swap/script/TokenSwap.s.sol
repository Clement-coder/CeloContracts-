// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {TokenSwap} from "../src/TokenSwap.sol";

/// @notice Deploys the TokenSwap AMM to Celo mainnet.
/// @dev Run with:
///   forge script script/TokenSwap.s.sol:TokenSwapScript \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
contract TokenSwapScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address token = vm.envAddress("TOKEN_ADDRESS");
        vm.startBroadcast(deployerKey);
        // 30 bps = 0.3% swap fee
        new TokenSwap(token, 30);
        vm.stopBroadcast();
    }
}
