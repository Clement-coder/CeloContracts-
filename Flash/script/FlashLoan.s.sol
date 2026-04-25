// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {FlashLoanPool} from "../src/FlashLoan.sol";

/// @notice Deploys the FlashLoan pool to Celo mainnet.
/// @dev Run with:
///   forge script script/FlashLoan.s.sol:FlashLoanScript \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
contract FlashLoanScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        // 9 bps = 0.09% fee
        new FlashLoanPool(9);
        vm.stopBroadcast();
    }
}
