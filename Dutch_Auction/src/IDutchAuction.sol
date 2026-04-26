// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IDutchAuction
/// @notice Interface for the Dutch Auction contract.
interface IDutchAuction {
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error Paused();
    error Reentrancy();
    error AuctionNotFound();
    error AuctionNotActive();
    error AuctionAlreadySold();
    error AuctionExpired();
    error AuctionNotExpired();
    error InsufficientPayment();
    error TransferFailed();
    error InvalidPrice();
    error InvalidDuration();
    error FeeTooHigh();
    error NotSeller();

    event AuctionCreated(uint256 indexed id, address indexed seller, uint256 startPrice, uint256 endPrice, uint256 endTime);
    event AuctionSold(uint256 indexed id, address indexed buyer, uint256 price);
    event AuctionCancelled(uint256 indexed id, address indexed seller);
    event AuctionExpiredReclaimed(uint256 indexed id, address indexed seller);
    event FeeWithdrawn(address indexed to, uint256 amount);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function createAuction(uint256 startPrice, uint256 endPrice, uint256 reservePrice, uint256 duration) external payable returns (uint256);
    function buy(uint256 id) external payable;
    function cancel(uint256 id) external;
    function reclaimExpired(uint256 id) external;
    function currentPrice(uint256 id) external view returns (uint256);
    function getAuction(uint256 id) external view returns (address seller, uint256 startPrice, uint256 endPrice, uint256 reservePrice, uint256 startTime, uint256 endTime, uint256 itemValue, bool sold, bool cancelled);
    function withdrawFees() external;
    function setFee(uint256 newFeeBps) external;
    function pause() external;
    function unpause() external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
