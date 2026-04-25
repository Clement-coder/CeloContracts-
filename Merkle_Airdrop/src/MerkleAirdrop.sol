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

    /// @notice Tracks which addresses have already claimed.
    mapping(address => bool) private _claimed;

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @param _token      Address of the ERC20 token to distribute.
    /// @param _merkleRoot Initial Merkle root of the claim tree.
    constructor(address _token, bytes32 _merkleRoot) {
        if (_token == address(0)) revert ZeroAddress();
        token = AirdropToken(_token);
        merkleRoot = _merkleRoot;
        owner = msg.sender;
    }

    // ─── Core ──────────────────────────────────────────────────────────────────

    /// @notice Claim tokens by providing a valid Merkle proof.
    /// @param amount Amount of tokens to claim (must match the committed amount).
    /// @param proof  Merkle proof path from leaf to root.
    function claim(uint256 amount, bytes32[] calldata proof) external override {
        if (_claimed[msg.sender]) revert AlreadyClaimed();

        bytes32 leaf = _leaf(msg.sender, amount);
        if (!_verify(proof, merkleRoot, leaf)) revert InvalidProof();

        _claimed[msg.sender] = true;
        emit Claimed(msg.sender, amount);

        bool ok = token.transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();
    }

    // ─── Views ─────────────────────────────────────────────────────────────────

    /// @notice Returns true if `account` has already claimed.
    function hasClaimed(address account) external view override returns (bool) {
        return _claimed[account];
    }

    // ─── Owner ─────────────────────────────────────────────────────────────────

    /// @notice Update the Merkle root (e.g. to add new recipients).
    /// @param newRoot New Merkle root.
    function setMerkleRoot(bytes32 newRoot) external override onlyOwner {
        emit MerkleRootUpdated(merkleRoot, newRoot);
        merkleRoot = newRoot;
    }

    /// @notice Sweep remaining tokens to `to` (e.g. after airdrop ends).
    /// @param to Recipient of remaining tokens.
    function sweep(address to) external override onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = token.balanceOf(address(this));
        emit Swept(to, bal);
        bool ok = token.transfer(to, bal);
        if (!ok) revert TransferFailed();
    }

    // ─── Internal ──────────────────────────────────────────────────────────────

    /// @dev Double-hash the leaf to prevent second-preimage attacks.
    ///      Encoding: keccak256(bytes.concat(keccak256(abi.encode(account, amount))))
    function _leaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    /// @dev Standard Merkle proof verification.
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
