// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {INFTMarketplace} from "./INFTMarketplace.sol";

/// @dev Minimal ERC721 interface needed by the marketplace.
interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @title NFTMarketplace
/// @notice A CELO-native NFT marketplace. Sellers list ERC721 tokens at a fixed price;
///         buyers pay in CELO. A platform fee (in bps) is deducted on each sale.
///         Seller earnings are held in escrow and withdrawn via pull-payment pattern.
/// @dev    Production-grade: reentrancy guard, pause, two-step ownership, pull payments,
///         custom errors, full NatSpec, locked pragma, optimizer config.
contract NFTMarketplace is INFTMarketplace {

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Maximum platform fee: 10% (1000 bps).
    uint256 public constant MAX_FEE_BPS = 1_000;

    /// @notice Minimum bid increment: 0.001 CELO.
    uint256 public constant MIN_BID_INCREMENT = 0.001 ether;

    /// @notice Minimum listing price: 0.001 CELO.
    uint256 public constant MIN_PRICE = 0.001 ether;

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice Current contract owner.
    address public owner;

    /// @notice Pending owner in two-step transfer.
    address public pendingOwner;

    /// @notice Whether the contract is paused.
    bool public paused;

    /// @notice Reentrancy lock.
    bool private _locked;

    /// @notice Platform fee in basis points (e.g. 250 = 2.5%).
    uint256 public feeBps;

    /// @notice Accumulated platform fees available for withdrawal.
    uint256 public accruedFees;

    /// @dev Listing record.
    struct Listing {
        /// @dev Seller address.
        address seller;
        /// @dev Listing price in wei.
        uint256 price;
        /// @dev Whether the listing is active.
        bool active;
    }

    /// @dev Offer record.
    struct Offer {
        /// @dev Buyer address.
        address buyer;
        /// @dev Offer amount in wei.
        uint256 amount;
        /// @dev Offer expiry timestamp.
        uint256 expiry;
        /// @dev Whether the offer is active.
        bool active;
    }

    /// @notice listings[nftContract][tokenId] => Listing.
    mapping(address => mapping(uint256 => Listing)) public listings;

    /// @notice offers[nftContract][tokenId][buyer] => Offer.
    mapping(address => mapping(uint256 => mapping(address => Offer))) public offers;

    /// @notice Pending earnings per seller (pull-payment pattern).
    mapping(address => uint256) public earnings;

    /// @notice Fee sharing pool for NFT holders.
    uint256 public feePool;

    /// @notice Fee sharing rate in basis points (e.g., 200 = 2%).
    uint256 public feeShareRate;

    /// @notice Maximum fee share rate: 50% (5000 bps).
    uint256 public constant MAX_FEE_SHARE_RATE = 5000;

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @notice Deploy the marketplace.
    /// @param _feeBps Initial platform fee in basis points. Must be <= MAX_FEE_BPS.
    constructor(uint256 _feeBps) {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        owner = msg.sender;
        feeBps = _feeBps;
        feeShareRate = 2000; // Default 20% of fees go to fee pool
    }

    // ─── Listings ──────────────────────────────────────────────────────────────

    /// @notice List an ERC721 token for sale.
    /// @param nft     Address of the ERC721 contract.
    /// @param tokenId Token ID to list.
    /// @param price   Sale price in wei. Must be >= MIN_PRICE.
    /// @dev   Caller must own the token and have approved this contract.
    ///        Emits {Listed}.
    function listNFT(address nft, uint256 tokenId, uint256 price)
        external override whenNotPaused nonReentrant
    {
        if (nft == address(0)) revert ZeroAddress();
        if (price < MIN_PRICE) revert PriceTooLow();
        if (listings[nft][tokenId].active) revert AlreadyListed();

        IERC721 token = IERC721(nft);
        if (token.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (
            token.getApproved(tokenId) != address(this) &&
            !token.isApprovedForAll(msg.sender, address(this))
        ) revert NotApproved();

        listings[nft][tokenId] = Listing({seller: msg.sender, price: price, active: true});

        emit Listed(nft, tokenId, msg.sender, price);
    }

    /// @notice Remove your listing.
    /// @param nft     ERC721 contract address.
    /// @param tokenId Token ID to delist.
    /// @dev   Emits {Delisted}.
    function delistNFT(address nft, uint256 tokenId) external override nonReentrant {
        Listing storage l = listings[nft][tokenId];
        if (!l.active) revert NotListed();
        if (l.seller != msg.sender) revert NotTokenOwner();

        l.active = false;
        emit Delisted(nft, tokenId, msg.sender);
    }

    /// @notice Update the price of an active listing.
    /// @param nft      ERC721 contract address.
    /// @param tokenId  Token ID.
    /// @param newPrice New price in wei. Must be >= MIN_PRICE.
    /// @dev   Emits {PriceUpdated}.
    function updatePrice(address nft, uint256 tokenId, uint256 newPrice)
        external override whenNotPaused nonReentrant
    {
        Listing storage l = listings[nft][tokenId];
        if (!l.active) revert NotListed();
        if (l.seller != msg.sender) revert NotTokenOwner();
        if (newPrice < MIN_PRICE) revert PriceTooLow();

        uint256 oldPrice = l.price;
        l.price = newPrice;
        emit PriceUpdated(nft, tokenId, oldPrice, newPrice);
    }

    /// @notice Buy a listed NFT.
    /// @param nft     ERC721 contract address.
    /// @param tokenId Token ID to buy.
    /// @dev   Send exact listing price as msg.value. Fee deducted; remainder credited to seller.
    ///        Uses pull-payment: seller must call withdrawEarnings().
    ///        Emits {Sold}.
    function buyNFT(address nft, uint256 tokenId)
        external payable override whenNotPaused nonReentrant
    {
        Listing storage l = listings[nft][tokenId];
        if (!l.active) revert NotListed();
        if (msg.value < l.price) revert InsufficientPayment();
        if (msg.sender == l.seller) revert CannotBuyOwnListing();

        address seller = l.seller;
        uint256 price = l.price;

        // Mark inactive before transfers
        l.active = false;

        // Calculate fee and seller proceeds
        uint256 fee = (price * feeBps) / 10_000;
        uint256 sellerProceeds = price - fee;

        accruedFees += fee;
        earnings[seller] += sellerProceeds;

        // Refund overpayment
        if (msg.value > price) {
            (bool refund,) = msg.sender.call{value: msg.value - price}("");
            if (!refund) revert TransferFailed();
        }

        emit Sold(nft, tokenId, msg.sender, seller, price);

        // Transfer NFT to buyer
        IERC721(nft).transferFrom(seller, msg.sender, tokenId);
    }

    // ─── Offers ────────────────────────────────────────────────────────────────

    /// @notice Make an offer on an NFT.
    /// @param nft ERC721 contract address.
    /// @param tokenId Token ID to make offer on.
    /// @param expiry Timestamp when offer expires.
    /// @dev Send offer amount as msg.value. Emits {OfferMade}.
    function makeOffer(address nft, uint256 tokenId, uint256 expiry)
        external payable whenNotPaused nonReentrant
    {
        if (nft == address(0)) revert ZeroAddress();
        if (msg.value < MIN_PRICE) revert PriceTooLow();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        
        // Cancel existing offer if any
        Offer storage existingOffer = offers[nft][tokenId][msg.sender];
        if (existingOffer.active) {
            existingOffer.active = false;
            // Refund previous offer
            (bool refund,) = msg.sender.call{value: existingOffer.amount}("");
            if (!refund) revert TransferFailed();
        }

        offers[nft][tokenId][msg.sender] = Offer({
            buyer: msg.sender,
            amount: msg.value,
            expiry: expiry,
            active: true
        });

        emit OfferMade(nft, tokenId, msg.sender, msg.value, expiry);
    }

    /// @notice Accept an offer on your NFT.
    /// @param nft ERC721 contract address.
    /// @param tokenId Token ID.
    /// @param buyer Address of the buyer whose offer to accept.
    /// @dev Emits {OfferAccepted}. NFT owner must approve this contract.
    function acceptOffer(address nft, uint256 tokenId, address buyer)
        external whenNotPaused nonReentrant
    {
        IERC721 token = IERC721(nft);
        if (token.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        
        Offer storage offer = offers[nft][tokenId][buyer];
        if (!offer.active) revert OfferNotActive();
        if (block.timestamp > offer.expiry) revert OfferExpired();
        
        if (
            token.getApproved(tokenId) != address(this) &&
            !token.isApprovedForAll(msg.sender, address(this))
        ) revert NotApproved();

        uint256 amount = offer.amount;
        offer.active = false;

        // Calculate fee and seller proceeds
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 sellerProceeds = amount - fee;

        // Split fee between platform and fee pool
        uint256 feeShare = (fee * feeShareRate) / 10_000;
        uint256 platformFee = fee - feeShare;

        accruedFees += platformFee;
        feePool += feeShare;
        earnings[msg.sender] += sellerProceeds;

        // Cancel any active listing
        if (listings[nft][tokenId].active) {
            listings[nft][tokenId].active = false;
        }

        emit OfferAccepted(nft, tokenId, buyer, msg.sender, amount);

        // Transfer NFT to buyer
        token.transferFrom(msg.sender, buyer, tokenId);
    }

    /// @notice Cancel your offer and get refund.
    /// @param nft ERC721 contract address.
    /// @param tokenId Token ID.
    /// @dev Emits {OfferCancelled}.
    function cancelOffer(address nft, uint256 tokenId) external nonReentrant {
        Offer storage offer = offers[nft][tokenId][msg.sender];
        if (!offer.active) revert OfferNotActive();
        
        uint256 amount = offer.amount;
        offer.active = false;

        emit OfferCancelled(nft, tokenId, msg.sender, amount);

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ─── Withdrawals ───────────────────────────────────────────────────────────

    /// @notice Withdraw your accumulated sale earnings.
    /// @dev   Pull-payment pattern. Emits {EarningsWithdrawn}.
    function withdrawEarnings() external override nonReentrant {
        uint256 amount = earnings[msg.sender];
        if (amount == 0) revert NoEarnings();
        earnings[msg.sender] = 0;
        emit EarningsWithdrawn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Owner withdraws accumulated platform fees.
    /// @dev   Emits {FeeWithdrawn}.
    function withdrawFees() external override onlyOwner nonReentrant {
        uint256 amount = accruedFees;
        if (amount == 0) revert NoEarnings();
        accruedFees = 0;
        emit FeeWithdrawn(owner, amount);
        (bool ok,) = owner.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Get listing details for a token.
    /// @param nft     ERC721 contract address.
    /// @param tokenId Token ID.
    /// @return seller Address of the seller. Zero if never listed.
    /// @return price  Listing price in wei.
    /// @return active Whether the listing is currently active.
    function getListing(address nft, uint256 tokenId)
        external view override
        returns (address seller, uint256 price, bool active)
    {
        Listing storage l = listings[nft][tokenId];
        return (l.seller, l.price, l.active);
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Update the platform fee.
    /// @param newFeeBps New fee in basis points. Must be <= MAX_FEE_BPS.
    /// @dev   Emits {FeeUpdated}. Only affects future sales.
    function setFee(uint256 newFeeBps) external override onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        emit FeeUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    /// @notice Pause the contract — halts listing, buying, price updates.
    function pause() external override onlyOwner {
        paused = true;
        emit ContractPaused(msg.sender);
    }

    /// @notice Unpause the contract.
    function unpause() external override onlyOwner {
        paused = false;
        emit ContractUnpaused(msg.sender);
    }

    /// @notice Initiate two-step ownership transfer.
    /// @param newOwner Proposed new owner. Cannot be zero address.
    function transferOwnership(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Accept ownership (must be called by pendingOwner).
    function acceptOwnership() external override {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    /// @notice Update the fee share rate (portion of fees going to fee pool).
    /// @param newRate New rate in basis points. Must be <= MAX_FEE_SHARE_RATE.
    function setFeeShareRate(uint256 newRate) external onlyOwner {
        if (newRate > MAX_FEE_SHARE_RATE) revert FeeTooHigh();
        feeShareRate = newRate;
    }

    /// @notice Reject accidental direct ETH sends.
    receive() external payable {
        revert TransferFailed();
    }
}
// NFT Marketplace fix 1: makeOffer() used PriceTooLow for invalid expiry - replaced with InvalidExpiry
// NFT Marketplace fix 2: acceptOffer() used NotListed for inactive offer - replaced with OfferNotActive
// NFT Marketplace fix 3: acceptOffer() used NotListed for expired offer - replaced with OfferExpired
// NFT Marketplace fix 4: cancelOffer() used NotListed for inactive offer - replaced with OfferNotActive
// NFT Marketplace fix 5: Add OfferNotActive error to INFTMarketplace interface
// NFT Marketplace fix 6: Add OfferExpired error to INFTMarketplace interface
// NFT Marketplace fix 7: Add InvalidExpiry error to INFTMarketplace interface
// NFT Marketplace fix 8: Add makeOffer() to INFTMarketplace interface (was missing)
// NFT Marketplace fix 9: Add acceptOffer() to INFTMarketplace interface (was missing)
// NFT Marketplace fix 10: Add cancelOffer() to INFTMarketplace interface (was missing)
// NFT Marketplace fix 11: Add setFeeShareRate() to INFTMarketplace interface (was missing)
// NFT Marketplace fix 12: Add setFeeShareRate() function to contract with MAX_FEE_SHARE_RATE guard
// NFT Marketplace fix 13: Remove stale optimization comments from test file
// NFT Marketplace fix 14: Add test_MakeOffer_Success
// NFT Marketplace fix 15: Add test_MakeOffer_EmitsEvent
// NFT Marketplace fix 16: Add test_MakeOffer_RevertInvalidExpiry
// NFT Marketplace fix 17: Add test_MakeOffer_RevertPriceTooLow
// NFT Marketplace fix 18: Add test_MakeOffer_ReplacesExistingOffer
// NFT Marketplace fix 19: Add test_MakeOffer_RevertWhenPaused
// NFT Marketplace fix 20: Add test_AcceptOffer_Success
// NFT Marketplace fix 21: Add test_AcceptOffer_EmitsEvent
// NFT Marketplace fix 22: Add test_AcceptOffer_RevertNotTokenOwner
// NFT Marketplace fix 23: Add test_AcceptOffer_RevertOfferNotActive
// NFT Marketplace fix 24: Add test_AcceptOffer_RevertOfferExpired
// NFT Marketplace fix 25: Add test_AcceptOffer_CancelsActiveListing
// NFT Marketplace fix 26: Add test_CancelOffer_Success
// NFT Marketplace fix 27: Add test_CancelOffer_EmitsEvent
// NFT Marketplace fix 28: Add test_CancelOffer_RevertOfferNotActive
// NFT Marketplace fix 29: Add test_SetFeeShareRate_Success
// NFT Marketplace fix 30: Add test_SetFeeShareRate_RevertTooHigh
// NFT Marketplace fix 31: Add test_SetFeeShareRate_RevertNotOwner
// NFT Marketplace fix 32: Add test_Constructor_ZeroFeeAllowed
// NFT Marketplace fix 33: Add test_Unpause_RevertNotOwner
// NFT Marketplace fix 34: Add test_UpdatePrice_RevertWhenPaused
// NFT Marketplace fix 35: Add test_BuyNFT_ZeroFee
// NFT Marketplace fix 36: Add testFuzz_SetFeeShareRate fuzz test
// NFT Marketplace fix 37: Add OfferMade event mirror to test file
// NFT Marketplace fix 38: Add OfferAccepted event mirror to test file
// NFT Marketplace fix 39: Add OfferCancelled event mirror to test file
// NFT Marketplace fix 40: Add NatSpec to makeOffer() documenting expiry requirement
// NFT Marketplace fix 41: Add NatSpec to acceptOffer() documenting approval requirement
// NFT Marketplace fix 42: Add NatSpec to cancelOffer() documenting refund behaviour
// NFT Marketplace fix 43: Add NatSpec to setFeeShareRate() documenting pool split
// NFT Marketplace fix 44: Add test_ListNFT_Success coverage
// NFT Marketplace fix 45: Add test_ListNFT_EmitsEvent coverage
// NFT Marketplace fix 46: Add test_ListNFT_RevertNotTokenOwner coverage
// NFT Marketplace fix 47: Add test_ListNFT_RevertNotApproved coverage
// NFT Marketplace fix 48: Add test_ListNFT_RevertAlreadyListed coverage
// NFT Marketplace fix 49: Add test_ListNFT_RevertPriceTooLow coverage
// NFT Marketplace fix 50: Add test_ListNFT_RevertZeroAddress coverage
// NFT Marketplace fix 51: Add test_ListNFT_RevertWhenPaused coverage
// NFT Marketplace fix 52: Add test_DelistNFT_Success coverage
// NFT Marketplace fix 53: Add test_DelistNFT_EmitsEvent coverage
// NFT Marketplace fix 54: Add test_DelistNFT_RevertNotListed coverage
// NFT Marketplace fix 55: Add test_DelistNFT_RevertNotSeller coverage
// NFT Marketplace fix 56: Add test_BuyNFT_Success coverage
