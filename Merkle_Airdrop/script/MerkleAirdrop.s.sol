// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {AirdropToken} from "../src/AirdropToken.sol";
import {MerkleAirdrop} from "../src/MerkleAirdrop.sol";

/// @notice Deploys AirdropToken + MerkleAirdrop and funds the airdrop contract.
/// @dev Run with:
///   forge script script/MerkleAirdrop.s.sol:MerkleAirdropScript \
///     --rpc-url celo --private-key $PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $CELOSCAN_API_KEY -vvv
///
///   Required env vars:
///     PRIVATE_KEY    - deployer private key
///     MERKLE_ROOT    - bytes32 root of the claim tree
///     AIRDROP_SUPPLY - total tokens to mint and fund into the airdrop (in wei)
contract MerkleAirdropScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        bytes32 merkleRoot  = vm.envBytes32("MERKLE_ROOT");
        uint256 supply      = vm.envUint("AIRDROP_SUPPLY");

        vm.startBroadcast(deployerKey);

        // 1. Deploy token — full supply to deployer
        AirdropToken token = new AirdropToken(supply);

        // 2. Deploy airdrop contract
        MerkleAirdrop airdrop = new MerkleAirdrop(address(token), merkleRoot);

        // 3. Fund the airdrop contract with the full supply
        token.transfer(address(airdrop), supply);

        vm.stopBroadcast();

        console2.log("AirdropToken :", address(token));
        console2.log("MerkleAirdrop:", address(airdrop));
    }
}
