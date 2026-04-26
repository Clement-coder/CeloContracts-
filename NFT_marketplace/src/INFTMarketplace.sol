// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title INFTMarketplace
/// @notice Interface for the CELO NFT Marketplace.
interface INFTMarketplace {
    // ─── Errors ────────────────────────────────────────────────────────────────
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error Paused();
    error Reentrancy();
    error NotTokenOwner();
    error NotApproved();
    error AlreadyListed();
    error NotListed();
    error PriceTooLow();
    error InsufficientPayment();
    error TransferFailed();
    error FeeTooHigh();
    error InvalidToken();
    error CannotBuyOwnListing();
    error NoEarnings();
    error OfferNotActive();
    error OfferExpired();
    error InvalidExpiry();

    // ─── Events ────────────────────────────────────────────────────────────────
    event Listed(address indexed nft, uint256 indexed tokenId, address indexed seller, uint256 price);
    event Delisted(address indexed nft, uint256 indexed tokenId, address indexed seller);
    event Sold(address indexed nft, uint256 indexed tokenId, address indexed buyer, address seller, uint256 price);
    event PriceUpdated(address indexed nft, uint256 indexed tokenId, uint256 oldPrice, uint256 newPrice);
    event OfferMade(address indexed nft, uint256 indexed tokenId, address indexed buyer, uint256 amount, uint256 expiry);
    event OfferAccepted(address indexed nft, uint256 indexed tokenId, address indexed buyer, address seller, uint256 amount);
    event OfferCancelled(address indexed nft, uint256 indexed tokenId, address indexed buyer, uint256 amount);
    event EarningsWithdrawn(address indexed seller, uint256 amount);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeWithdrawn(address indexed to, uint256 amount);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ─── Functions ─────────────────────────────────────────────────────────────
    function listNFT(address nft, uint256 tokenId, uint256 price) external;
    function delistNFT(address nft, uint256 tokenId) external;
    function updatePrice(address nft, uint256 tokenId, uint256 newPrice) external;
    function buyNFT(address nft, uint256 tokenId) external payable;
    function withdrawEarnings() external;
    function withdrawFees() external;
    function setFee(uint256 newFeeBps) external;
    function getListing(address nft, uint256 tokenId) external view returns (address seller, uint256 price, bool active);
    function pause() external;
    function unpause() external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function makeOffer(address nft, uint256 tokenId, uint256 expiry) external payable;
    function acceptOffer(address nft, uint256 tokenId, address buyer) external;
    function cancelOffer(address nft, uint256 tokenId) external;
    function setFeeShareRate(uint256 newRate) external;
}
