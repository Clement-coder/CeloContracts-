// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title ILottery
/// @notice Interface for the CELO lottery contract.
interface ILottery {
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error Paused();
    error Reentrancy();
    error LotteryNotOpen();
    error LotteryNotEnded();
    error LotteryAlreadyDrawn();
    error TicketPriceMismatch();
    error NoTickets();
    error TransferFailed();
    error InvalidTicketPrice();
    error InvalidDuration();
    error InvalidFee();
    error RoundNotFound();
    error InvalidAmount();
    error ZeroRecipient();

    event RoundStarted(uint256 indexed round, uint256 ticketPrice, uint256 endTime);
    event TicketBought(uint256 indexed round, address indexed buyer, uint256 tickets, uint256 totalPot);
    event WinnerDrawn(uint256 indexed round, address indexed winner, uint256 prize);
    event NoWinner(uint256 indexed round);
    event FeeWithdrawn(address indexed to, uint256 amount);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event FeeUpdated(uint256 oldFee, uint256 newFee);

    function buyTickets(uint256 count) external payable;
    function drawWinner() external;
    function startRound(uint256 ticketPrice, uint256 duration) external;
    function withdrawFees() external;
    function getRound(uint256 round) external view returns (uint256 ticketPrice, uint256 endTime, uint256 pot, uint256 totalTickets, address winner, bool drawn);
    function getTickets(uint256 round, address player) external view returns (uint256);
    function pause() external;
    function unpause() external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function setFee(uint256 newFeeBps) external;
    function buyTicketsForMultiple(address[] calldata recipients, uint256[] calldata counts) external payable;
}
