// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {DAOGovernance} from "../src/DAOGovernance.sol";

/// @notice Deploys the DAOGovernance contract to Celo mainnet.
/// @dev Run with:
///   forge script script/DAOGovernance.s.sol:DAOGovernanceScript \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
contract DAOGovernanceScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        // Replace TOKEN_ADDRESS with your governance token
        address token = vm.envAddress("GOVERNANCE_TOKEN");
        // 1000 tokens quorum, 3 day voting period
        new DAOGovernance(token, 1_000 ether, 3 days);
        vm.stopBroadcast();
    }
}
