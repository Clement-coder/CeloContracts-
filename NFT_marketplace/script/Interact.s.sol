// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console} from "forge-std/Script.sol";

interface IMarket {
    function listNFT(address nft, uint256 tokenId, uint256 price) external;
    function delistNFT(address nft, uint256 tokenId) external;
    function updatePrice(address nft, uint256 tokenId, uint256 newPrice) external;
    function buyNFT(address nft, uint256 tokenId) external payable;
    function withdrawEarnings() external;
    function setFee(uint256 newFeeBps) external;
    function getListing(address nft, uint256 tokenId) external view returns (address, uint256, bool);
    function earnings(address) external view returns (uint256);
}

/// @dev Minimal NFT deployable inline.
contract NFT {
    mapping(uint256 => address) public owners;
    mapping(address => mapping(address => bool)) public operatorApprovals;
    uint256 public next = 1;

    function mint(address to) external returns (uint256 id) {
        id = next++;
        owners[id] = to;
    }
    function ownerOf(uint256 id) external view returns (address) { return owners[id]; }
    function getApproved(uint256) external pure returns (address) { return address(0); }
    function isApprovedForAll(address o, address op) external view returns (bool) { return operatorApprovals[o][op]; }
    function setApprovalForAll(address op, bool v) external { operatorApprovals[msg.sender][op] = v; }
    function transferFrom(address, address to, uint256 id) external { owners[id] = to; }
}

/// @dev Acts as buyer — holds ETH and buys NFTs on behalf of the script.
contract Buyer {
    address immutable market;
    constructor(address _market) payable { market = _market; }
    function buy(address nft, uint256 id, uint256 price) external {
        IMarket(market).buyNFT{value: price}(nft, id);
    }
    function withdraw() external { payable(msg.sender).transfer(address(this).balance); }
    receive() external payable {}
}

/// @notice 78 mainnet interactions against NFTMarketplace at 0xafa8232cf9a6415e8ffaf642d62f57e05b544abf
/// @dev forge script script/Interact.s.sol:InteractScript \
///        --rpc-url celo --private-key $PRIVATE_KEY --broadcast --legacy -vvv
contract InteractScript is Script {
    address constant MARKET = 0xafA8232cF9a6415E8ffAf642d62F57e05b544AbF;
    uint256 constant PRICE  = 0.001 ether;

    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(key);
        vm.startBroadcast(key);

        // tx 1: deploy NFT
        NFT nft = new NFT();
        console.log("NFT:", address(nft));

        // tx 2: deploy Buyer with 0.015 CELO (enough to buy 15 NFTs at 0.001 each)
        Buyer buyer = new Buyer{value: 0.015 ether}(MARKET);
        console.log("Buyer:", address(buyer));

        // txs 3-22: mint 20 NFTs to deployer
        uint256[] memory ids = new uint256[](20);
        for (uint256 i; i < 20; i++) ids[i] = nft.mint(me);
        console.log("Minted 20 NFTs, first id:", ids[0]);

        // tx 23: approve marketplace for all
        nft.setApprovalForAll(MARKET, true);

        // txs 24-38: list 15 NFTs at 0.001 CELO each
        for (uint256 i; i < 15; i++)
            IMarket(MARKET).listNFT(address(nft), ids[i], PRICE);
        console.log("Listed 15 NFTs");

        // txs 39-48: update price on first 10 listings
        for (uint256 i; i < 10; i++)
            IMarket(MARKET).updatePrice(address(nft), ids[i], PRICE);
        console.log("Updated 10 prices");

        // txs 49-53: delist last 5 of the 15 listed
        for (uint256 i = 10; i < 15; i++)
            IMarket(MARKET).delistNFT(address(nft), ids[i]);
        console.log("Delisted 5");

        // txs 54-58: re-list those 5
        for (uint256 i = 10; i < 15; i++)
            IMarket(MARKET).listNFT(address(nft), ids[i], PRICE);
        console.log("Re-listed 5");

        // txs 59-73: buyer buys all 15 listed NFTs (15 txs)
        for (uint256 i; i < 15; i++)
            buyer.buy(address(nft), ids[i], PRICE);
        console.log("Buyer bought 15 NFTs");

        // tx 74: deployer withdraws earnings
        IMarket(MARKET).withdrawEarnings();
        console.log("Withdrew earnings");

        // txs 75-79: setFee 5 times (owner only)
        IMarket(MARKET).setFee(100);
        IMarket(MARKET).setFee(200);
        IMarket(MARKET).setFee(300);
        IMarket(MARKET).setFee(200);
        IMarket(MARKET).setFee(250);
        console.log("Set fee 5 times");

        // tx 80: buyer withdraws leftover ETH back to deployer
        buyer.withdraw();

        vm.stopBroadcast();
        console.log("=== 80 interactions complete ===");
    }
}
