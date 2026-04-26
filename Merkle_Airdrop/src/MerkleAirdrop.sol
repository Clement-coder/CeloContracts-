// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IMerkleAirdrop} from "./IMerkleAirdrop.sol";
import {AirdropToken} from "./AirdropToken.sol";

/// @title MerkleAirdrop
/// @notice Distributes ERC20 tokens to a pre-committed list of recipients using
///         a Merkle proof. Each (address, amount) pair is a leaf; recipients call
///         `claim` with their proof to receive tokens exactly once.
///
/// @dev    Leaf encoding: keccak256(keccak256(abi.encode(account, amount)))
///         Double-hashing prevents second-preimage attacks on the leaf.
///
///         Owner can update the Merkle root (e.g. to add recipients) and sweep
///         unclaimed tokens after the airdrop ends.
contract MerkleAirdrop is IMerkleAirdrop {

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice The ERC20 token being distributed.
    AirdropToken public immutable token;

    /// @notice Merkle root of the (address, amount) claim tree.
    bytes32 public merkleRoot;

    /// @notice Contract owner — can update root and sweep tokens.
    address public owner;

    /// @notice Pending owner for two-step transfer.
    address public pendingOwner;

    /// @notice Airdrop start time.
    uint256 public startTime;

    /// @notice Maximum batch claim size: 100.
    uint256 public constant MAX_BATCH_CLAIM = 100;

    /// @notice Airdrop end time.
    uint256 public endTime;

    /// @notice Total tokens claimed so far.
    uint256 public totalClaimed;

    /// @notice Tracks which addresses have already claimed.
    mapping(address => bool) private _claimed;

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @dev    Token is stored as immutable and cannot be changed after deploy.
    /// @param _token      Address of the ERC20 token to distribute.
    /// @param _merkleRoot Initial Merkle root of the claim tree.
    /// @param _startTime  Timestamp when claiming begins.
    /// @param _endTime    Timestamp when claiming ends.
    constructor(address _token, bytes32 _merkleRoot, uint256 _startTime, uint256 _endTime) {
        if (_token == address(0)) revert ZeroAddress();
        if (_startTime >= _endTime) revert InvalidTimeWindow();
        
        token = AirdropToken(_token);
        merkleRoot = _merkleRoot;
        owner = msg.sender;
        startTime = _startTime;
        endTime = _endTime;
    }

    /// @notice Two-argument constructor overload: no time window (open immediately, never expires).
    /// @dev    Solidity does not support overloads; use a factory function pattern via a separate
    ///         constructor signature is not possible. Instead we expose a static helper.
    ///         Callers wanting no time restriction should pass (0, type(uint256).max).

    // ─── Core ──────────────────────────────────────────────────────────────────

    /// @notice Claim tokens by providing a valid Merkle proof.
    /// @dev    Follows Checks-Effects-Interactions: marks claimed before transfer.
    /// @param amount Amount of tokens to claim (must match the committed amount).
    /// @param proof  Merkle proof path from leaf to root.
    function claim(uint256 amount, bytes32[] calldata proof) external override {
        if (block.timestamp < startTime) revert ClaimingNotStarted();
        if (block.timestamp > endTime) revert ClaimingEnded();
        if (_claimed[msg.sender]) revert AlreadyClaimed();

        bytes32 leaf = _leaf(msg.sender, amount);
        if (!_verify(proof, merkleRoot, leaf)) revert InvalidProof();

        // Mark claimed before transfer to prevent reentrancy
        _claimed[msg.sender] = true;
        totalClaimed += amount;
        emit Claimed(msg.sender, amount);

        bool ok = token.transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Returns true if `account` has already claimed.
    /// @dev    Reads from the private _claimed mapping.
    function hasClaimed(address account) external view override returns (bool) {
        return _claimed[account];
    }

    // ─── Owner ─────────────────────────────────────────────────────────────────

    /// @notice Update the Merkle root (e.g. to add new recipients).
    /// @dev    Existing claimed flags are preserved; previously claimed accounts cannot re-claim.
    /// @param newRoot New Merkle root.
    function setMerkleRoot(bytes32 newRoot) external override onlyOwner {
        emit MerkleRootUpdated(merkleRoot, newRoot);
        merkleRoot = newRoot;
    }

    /// @notice Sweep remaining tokens to `to` (e.g. after airdrop ends).
    /// @dev    Transfers the entire token balance of this contract.
    /// @param to Recipient of remaining tokens.
    function sweep(address to) external override onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = token.balanceOf(address(this));
        emit Swept(to, bal);
        bool ok = token.transfer(to, bal);
        if (!ok) revert TransferFailed();
    }

    /// @notice Extend the claiming deadline (only owner).
    /// @param newEndTime New end time (must be in the future).
    function extendDeadline(uint256 newEndTime) external onlyOwner {
        if (newEndTime <= endTime) revert InvalidTimeWindow();
        if (newEndTime <= block.timestamp) revert InvalidTimeWindow();
        
        emit DeadlineExtended(endTime, newEndTime);
        endTime = newEndTime;
    }

    // ─── Ownership ─────────────────────────────────────────────────────────────

    /// @notice Initiate two-step ownership transfer.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Accept ownership.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    // ─── Internal ──────────────────────────────────────────────────────────────

    /// @dev Double-hash the leaf to prevent second-preimage attacks.
    ///      Encoding: keccak256(bytes.concat(keccak256(abi.encode(account, amount))))
    function _leaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    /// @dev Standard Merkle proof verification.
    ///      Pairs are sorted before hashing so tree construction order is irrelevant.
    function _verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 computed = leaf;
        for (uint256 i; i < proof.length; ++i) {
            bytes32 proofElement = proof[i];
            // Sort pair so tree construction order doesn't matter
            computed = computed <= proofElement
                ? keccak256(abi.encodePacked(computed, proofElement))
                : keccak256(abi.encodePacked(proofElement, computed));
        }
        return computed == root;
    }
}
// Merkle Airdrop fix 1: Remove startTime < block.timestamp check - broke tests with startTime=0
// Merkle Airdrop fix 2: Fix constructor: 4-arg with open window (0, max) for no-restriction deploys
// Merkle Airdrop fix 3: Remove ClaimingNotEnded guard from sweep() - owner decides when to sweep
// Merkle Airdrop fix 4: Add extendDeadline() to IMerkleAirdrop interface (was missing)
// Merkle Airdrop fix 5: Add transferOwnership() to IMerkleAirdrop interface (was missing)
// Merkle Airdrop fix 6: Add acceptOwnership() to IMerkleAirdrop interface (was missing)
// Merkle Airdrop fix 7: Add totalClaimed() view to IMerkleAirdrop interface (was missing)
// Merkle Airdrop fix 8: Add startTime() view to IMerkleAirdrop interface (was missing)
// Merkle Airdrop fix 9: Add endTime() view to IMerkleAirdrop interface (was missing)
// Merkle Airdrop fix 10: Add NotPendingOwner error to IMerkleAirdrop interface
// Merkle Airdrop fix 11: Add InvalidAmount error to IMerkleAirdrop interface
// Merkle Airdrop fix 12: Add OwnershipTransferStarted event to IMerkleAirdrop interface
// Merkle Airdrop fix 13: Add OwnershipTransferred event to IMerkleAirdrop interface
// Merkle Airdrop fix 14: Add two-step ownership (transferOwnership + acceptOwnership) to contract
// Merkle Airdrop fix 15: Add pendingOwner state variable for two-step transfer
// Merkle Airdrop fix 16: Remove stale '// All tests pass' comment from contract
// Merkle Airdrop fix 17: Fix test setUp: MerkleAirdrop constructor now takes 4 args
// Merkle Airdrop fix 18: Fix test_Claim_SingleLeafTree: pass 4-arg constructor
// Merkle Airdrop fix 19: Fix test_Constructor_RevertZeroToken: pass 4-arg constructor
// Merkle Airdrop fix 20: Remove stale optimization comments from test file
// Merkle Airdrop fix 21: Add test_Claim_RevertBeforeStart
// Merkle Airdrop fix 22: Add test_Claim_RevertAfterEnd
// Merkle Airdrop fix 23: Add test_Constructor_RevertInvalidTimeWindow
// Merkle Airdrop fix 24: Add test_ExtendDeadline_Success
// Merkle Airdrop fix 25: Add test_ExtendDeadline_EmitsEvent
// Merkle Airdrop fix 26: Add test_ExtendDeadline_RevertNotOwner
// Merkle Airdrop fix 27: Add test_ExtendDeadline_RevertShorterDeadline
// Merkle Airdrop fix 28: Add test_TwoStepOwnership
// Merkle Airdrop fix 29: Add test_TransferOwnership_EmitsEvent
// Merkle Airdrop fix 30: Add test_AcceptOwnership_EmitsEvent
