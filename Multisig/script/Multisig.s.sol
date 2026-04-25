// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {Multisig} from "../src/Multisig.sol";

/// @notice Deploys the Multisig wallet to Celo mainnet.
/// @dev Run with:
///   forge script script/Multisig.s.sol:MultisigScript \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
contract MultisigScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        vm.startBroadcast(deployerKey);

        address[] memory owners = new address[](1);
        owners[0] = deployer;
        // 1-of-1 to start — add more owners via multisig after deploy
        new Multisig(owners, 1);

        vm.stopBroadcast();
    }
}
