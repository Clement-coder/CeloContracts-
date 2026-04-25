// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IDutchAuction} from "./IDutchAuction.sol";

/// @title DutchAuction
/// @notice Dutch auction where price starts high and drops linearly to a floor.
///         Seller deposits the item value (CELO) upfront. First buyer to pay the
///         current price wins. Overpayment is refunded. Unsold auctions can be
///         reclaimed by the seller after expiry.
/// @dev    Production-grade: reentrancy guard, pause, two-step ownership,
///         custom errors, full NatSpec, locked pragma, optimizer config.
contract DutchAuction is IDutchAuction {

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Maximum platform fee: 5% (500 bps).
    uint256 public constant MAX_FEE_BPS = 500;

    /// @notice Minimum auction duration: 1 hour.
    uint256 public constant MIN_DURATION = 1 hours;

    /// @notice Maximum auction duration: 30 days.
    uint256 public constant MAX_DURATION = 30 days;

    /// @notice Minimum start price: 0.001 CELO.
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

    /// @notice Platform fee in basis points.
    uint256 public feeBps;

    /// @notice Accumulated platform fees.
    uint256 public accruedFees;

    /// @notice Total auctions created.
    uint256 public auctionCount;

    /// @dev Auction record.
    struct Auction {
        /// @dev Seller address.
        address seller;
        /// @dev Starting price in wei.
        uint256 startPrice;
        /// @dev Floor price in wei (price at end of auction).
        uint256 endPrice;
        /// @dev Timestamp when auction started.
        uint256 startTime;
        /// @dev Timestamp when auction ends.
        uint256 endTime;
        /// @dev CELO value of the item being auctioned (deposited by seller).
        uint256 itemValue;
        /// @dev Whether the auction has been sold.
        bool sold;
        /// @dev Whether the auction was cancelled.
        bool cancelled;
    }

    /// @notice Auctions by ID (1-indexed).
    mapping(uint256 => Auction) public auctions;

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

    modifier auctionExists(uint256 id) {
        if (id == 0 || id > auctionCount) revert AuctionNotFound();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @notice Deploy the Dutch auction contract.
    /// @param _feeBps Platform fee in basis points. Must be <= MAX_FEE_BPS.
    constructor(uint256 _feeBps) {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        owner = msg.sender;
        feeBps = _feeBps;
    }

    // ─── Core ──────────────────────────────────────────────────────────────────

    /// @notice Create a new Dutch auction. Seller deposits the item value upfront.
    /// @param startPrice Starting price in wei. Must be > endPrice >= MIN_PRICE.
    /// @param endPrice   Floor price in wei. Price never drops below this.
    /// @param duration   Auction duration in seconds.
    /// @return id        The new auction ID.
    /// @dev   msg.value = item value being auctioned. Emits {AuctionCreated}.
    function createAuction(uint256 startPrice, uint256 endPrice, uint256 duration)
        external payable override whenNotPaused nonReentrant returns (uint256)
    {
        if (endPrice < MIN_PRICE) revert InvalidPrice();
        if (startPrice <= endPrice) revert InvalidPrice();
        if (msg.value == 0) revert InvalidPrice();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidDuration();

        uint256 id = ++auctionCount;
        uint256 end = block.timestamp + duration;

        auctions[id] = Auction({
            seller: msg.sender,
            startPrice: startPrice,
            endPrice: endPrice,
            startTime: block.timestamp,
            endTime: end,
            itemValue: msg.value,
            sold: false,
            cancelled: false
        });

        emit AuctionCreated(id, msg.sender, startPrice, endPrice, end);
        return id;
    }

    /// @notice Buy the auctioned item at the current price.
    /// @param id Auction ID to buy.
    /// @dev   Send at least currentPrice(id) as msg.value. Overpayment refunded.
    ///        Buyer receives the item value (CELO) deposited by seller.
    ///        Seller receives the sale price minus fee. Emits {AuctionSold}.
    function buy(uint256 id)
        external payable override whenNotPaused nonReentrant auctionExists(id)
    {
        Auction storage a = auctions[id];
        if (a.sold) revert AuctionAlreadySold();
        if (a.cancelled) revert AuctionNotActive();
        if (block.timestamp >= a.endTime) revert AuctionExpired();

        uint256 price = _currentPrice(a);
        if (msg.value < price) revert InsufficientPayment();

        a.sold = true;

        // Platform fee on sale price
        uint256 fee = (price * feeBps) / 10_000;
        uint256 sellerProceeds = price - fee;
        accruedFees += fee;

        // Refund overpayment
        if (msg.value > price) {
            (bool refund,) = msg.sender.call{value: msg.value - price}("");
            if (!refund) revert TransferFailed();
        }

        emit AuctionSold(id, msg.sender, price);

        // Send item value to buyer
        (bool toBuyer,) = msg.sender.call{value: a.itemValue}("");
        if (!toBuyer) revert TransferFailed();

        // Send sale proceeds to seller
        (bool toSeller,) = a.seller.call{value: sellerProceeds}("");
        if (!toSeller) revert TransferFailed();
    }

    /// @notice Seller cancels an active auction and reclaims item value.
    /// @param id Auction ID to cancel.
    /// @dev   Only callable before auction ends and before sold. Emits {AuctionCancelled}.
    function cancel(uint256 id)
        external override nonReentrant auctionExists(id)
    {
        Auction storage a = auctions[id];
        if (msg.sender != a.seller) revert NotSeller();
        if (a.sold) revert AuctionAlreadySold();
        if (a.cancelled) revert AuctionNotActive();
        if (block.timestamp >= a.endTime) revert AuctionExpired();

        a.cancelled = true;
        uint256 value = a.itemValue;
        a.itemValue = 0;

        emit AuctionCancelled(id, msg.sender);

        (bool ok,) = a.seller.call{value: value}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Seller reclaims item value from an expired unsold auction.
    /// @param id Auction ID to reclaim.
    /// @dev   Only callable after auction ends without a sale. Emits {AuctionExpiredReclaimed}.
    function reclaimExpired(uint256 id)
        external override nonReentrant auctionExists(id)
    {
        Auction storage a = auctions[id];
        if (msg.sender != a.seller) revert NotSeller();
        if (a.sold) revert AuctionAlreadySold();
        if (a.cancelled) revert AuctionNotActive();
        if (block.timestamp < a.endTime) revert AuctionNotExpired();

        a.cancelled = true;
        uint256 value = a.itemValue;
        a.itemValue = 0;

        emit AuctionExpiredReclaimed(id, msg.sender);

        (bool ok,) = a.seller.call{value: value}("");
        if (!ok) revert TransferFailed();
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Returns the current price of an auction at this moment.
    /// @param id Auction ID to query.
    /// @return Current price in wei. Returns endPrice if auction has expired.
    function currentPrice(uint256 id)
        external view override auctionExists(id) returns (uint256)
    {
        return _currentPrice(auctions[id]);
    }

    /// @notice Returns full details of an auction.
    /// @param id Auction ID to query.
    function getAuction(uint256 id)
        external view override auctionExists(id)
        returns (address seller, uint256 startPrice, uint256 endPrice, uint256 startTime, uint256 endTime, uint256 itemValue, bool sold, bool cancelled)
    {
        Auction storage a = auctions[id];
        return (a.seller, a.startPrice, a.endPrice, a.startTime, a.endTime, a.itemValue, a.sold, a.cancelled);
    }

    // ─── Internal ──────────────────────────────────────────────────────────────

    /// @dev Linear price decay: price = startPrice - (startPrice - endPrice) * elapsed / duration
    function _currentPrice(Auction storage a) internal view returns (uint256) {
        if (block.timestamp >= a.endTime) return a.endPrice;
        uint256 elapsed = block.timestamp - a.startTime;
        uint256 duration = a.endTime - a.startTime;
        uint256 drop = ((a.startPrice - a.endPrice) * elapsed) / duration;
        return a.startPrice - drop;
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Owner withdraws accumulated platform fees.
    function withdrawFees() external override onlyOwner nonReentrant {
        uint256 amount = accruedFees;
        if (amount == 0) revert InvalidPrice();
        accruedFees = 0;
        emit FeeWithdrawn(owner, amount);
        (bool ok,) = owner.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Update the platform fee.
    /// @param newFeeBps New fee in basis points. Must be <= MAX_FEE_BPS.
    function setFee(uint256 newFeeBps) external override onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = newFeeBps;
    }

    /// @notice Pause the contract.
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
    function transferOwnership(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Accept ownership.
    function acceptOwnership() external override {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}
