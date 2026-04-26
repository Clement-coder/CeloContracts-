// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ILottery} from "./ILottery.sol";

/// @title Lottery
/// @notice CELO lottery. Owner starts rounds with a ticket price and duration.
///         Players buy tickets. After the round ends, anyone can trigger the draw.
///         Winner is selected pseudo-randomly from all ticket entries.
///         A platform fee (in bps) is deducted from the pot.
/// @dev    Production-grade: reentrancy guard, pause, two-step ownership,
///         custom errors, full NatSpec, locked pragma, optimizer config.
contract Lottery is ILottery {

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Maximum platform fee: 10% (1000 bps).
    uint256 public constant MAX_FEE_BPS = 1_000;

    /// @notice Minimum ticket price: 0.001 CELO.
    uint256 public constant MIN_TICKET_PRICE = 0.001 ether;

    /// @notice Minimum round duration: 1 hour.
    uint256 public constant MIN_DURATION = 1 hours;

    /// @notice Maximum round duration: 30 days.
    uint256 public constant MAX_DURATION = 30 days;

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

    /// @notice Current round number (1-indexed, 0 = no round started).
    uint256 public currentRound;

    /// @dev Lottery round record.
    struct Round {
        /// @dev Ticket price in wei.
        uint256 ticketPrice;
        /// @dev Timestamp when the round ends.
        uint256 endTime;
        /// @dev Total CELO in the pot (after fees).
        uint256 pot;
        /// @dev All ticket holders (one entry per ticket bought).
        address[] entries;
        /// @dev Winner address (zero if not drawn yet).
        address winner;
        /// @dev Whether the winner has been drawn.
        bool drawn;
    }

    /// @notice Rounds by round number.
    mapping(uint256 => Round) public rounds;

    /// @notice tickets[round][player] = number of tickets bought.
    mapping(uint256 => mapping(address => uint256)) public tickets;

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

    /// @notice Deploy the lottery contract.
    /// @param _feeBps Platform fee in basis points. Must be <= MAX_FEE_BPS.
    constructor(uint256 _feeBps) {
        if (_feeBps > MAX_FEE_BPS) revert InvalidFee();
        owner = msg.sender;
        feeBps = _feeBps;
    }

    // ─── Owner Actions ─────────────────────────────────────────────────────────

    /// @notice Start a new lottery round.
    /// @param ticketPrice Price per ticket in wei. Must be >= MIN_TICKET_PRICE.
    /// @param duration    Round duration in seconds.
    /// @dev   Previous round must be drawn before starting a new one. Emits {RoundStarted}.
    function startRound(uint256 ticketPrice, uint256 duration)
        external override onlyOwner whenNotPaused
    {
        if (ticketPrice < MIN_TICKET_PRICE) revert InvalidTicketPrice();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidDuration();
        if (currentRound > 0 && !rounds[currentRound].drawn) revert LotteryNotEnded();

        currentRound++;
        rounds[currentRound].ticketPrice = ticketPrice;
        rounds[currentRound].endTime = block.timestamp + duration;

        emit RoundStarted(currentRound, ticketPrice, rounds[currentRound].endTime);
    }

    // ─── Player Actions ────────────────────────────────────────────────────────

    /// @notice Buy one or more tickets for the current round.
    /// @param count Number of tickets to buy. Must be >= 1.
    /// @dev   Send exactly ticketPrice * count as msg.value. Emits {TicketBought}.
    function buyTickets(uint256 count)
        external payable override whenNotPaused nonReentrant
    {
        if (currentRound == 0) revert LotteryNotOpen();
        Round storage r = rounds[currentRound];
        if (r.drawn) revert LotteryNotOpen();
        if (block.timestamp >= r.endTime) revert LotteryNotOpen();
        if (count == 0) revert NoTickets();
        if (msg.value != r.ticketPrice * count) revert TicketPriceMismatch();

        // Deduct fee, add remainder to pot
        uint256 fee = (msg.value * feeBps) / 10_000;
        uint256 net = msg.value - fee;
        accruedFees += fee;
        r.pot += net;

        tickets[currentRound][msg.sender] += count;
        for (uint256 i; i < count; i++) {
            r.entries.push(msg.sender);
        }

        emit TicketBought(currentRound, msg.sender, count, r.pot);
    }

    /// @notice Buy tickets for multiple players in one transaction (gift tickets).
    /// @param recipients Array of addresses to receive tickets.
    /// @param counts Array of ticket counts for each recipient.
    /// @dev   Arrays must be same length. Total cost = sum(ticketPrice * counts[i]).
    function buyTicketsForMultiple(address[] calldata recipients, uint256[] calldata counts)
        external payable whenNotPaused nonReentrant
    {
        if (currentRound == 0) revert LotteryNotOpen();
        if (recipients.length != counts.length) revert InvalidTicketPrice();
        if (recipients.length == 0) revert NoTickets();
        
        Round storage r = rounds[currentRound];
        if (r.drawn) revert LotteryNotOpen();
        if (block.timestamp >= r.endTime) revert LotteryNotOpen();

        uint256 totalTickets = 0;
        for (uint256 i = 0; i < counts.length; i++) {
            if (counts[i] == 0) revert NoTickets();
            totalTickets += counts[i];
        }

        if (msg.value != r.ticketPrice * totalTickets) revert TicketPriceMismatch();

        // Deduct fee, add remainder to pot
        uint256 fee = (msg.value * feeBps) / 10_000;
        uint256 net = msg.value - fee;
        accruedFees += fee;
        r.pot += net;

        // Add tickets for each recipient
        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            uint256 count = counts[i];
            
            tickets[currentRound][recipient] += count;
            for (uint256 j = 0; j < count; j++) {
                r.entries.push(recipient);
            }
            
            emit TicketBought(currentRound, recipient, count, r.pot);
        }
    }

    /// @notice Draw the winner for the current round. Callable by anyone after round ends.
    /// @dev   Uses block-based pseudo-randomness. Emits {WinnerDrawn} or {NoWinner}.
    function drawWinner() external override nonReentrant {
        if (currentRound == 0) revert LotteryNotOpen();
        Round storage r = rounds[currentRound];
        if (block.timestamp < r.endTime) revert LotteryNotEnded();
        if (r.drawn) revert LotteryAlreadyDrawn();

        r.drawn = true;

        if (r.entries.length == 0) {
            emit NoWinner(currentRound);
            return;
        }

        // Pseudo-random winner selection
        uint256 idx = uint256(keccak256(abi.encodePacked(
            block.timestamp, block.prevrandao, r.entries.length, currentRound
        ))) % r.entries.length;

        address winner = r.entries[idx];
        r.winner = winner;
        uint256 prize = r.pot;
        r.pot = 0;

        emit WinnerDrawn(currentRound, winner, prize);

        (bool ok,) = winner.call{value: prize}("");
        if (!ok) revert TransferFailed();
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Owner withdraws accumulated platform fees.
    function withdrawFees() external override onlyOwner nonReentrant {
        uint256 amount = accruedFees;
        if (amount == 0) revert NoTickets();
        accruedFees = 0;
        emit FeeWithdrawn(owner, amount);
        (bool ok,) = owner.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Update platform fee (only owner).
    /// @param newFeeBps New fee in basis points (max 1000 = 10%).
    function setFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert InvalidFee();
        emit FeeUpdated(feeBps, newFeeBps);
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

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Returns details of a lottery round.
    /// @param round Round number to query.
    /// @return ticketPrice  Price per ticket in wei.
    /// @return endTime      Round end timestamp.
    /// @return pot          Current pot size in wei.
    /// @return totalTickets Total tickets sold.
    /// @return winner       Winner address (zero if not drawn).
    /// @return drawn        Whether winner has been drawn.
    function getRound(uint256 round)
        external view override
        returns (uint256 ticketPrice, uint256 endTime, uint256 pot, uint256 totalTickets, address winner, bool drawn)
    {
        if (round == 0 || round > currentRound) revert RoundNotFound();
        Round storage r = rounds[round];
        return (r.ticketPrice, r.endTime, r.pot, r.entries.length, r.winner, r.drawn);
    }

    /// @notice Returns number of tickets a player bought in a round.
    function getTickets(uint256 round, address player)
        external view override returns (uint256)
    {
        return tickets[round][player];
    }
}
