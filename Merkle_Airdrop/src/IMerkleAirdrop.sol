// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IMerkleAirdrop
/// @notice Interface for the Merkle-proof-based ERC20 airdrop contract.
interface IMerkleAirdrop {
    // ─── Errors ────────────────────────────────────────────────────────────────
    error AlreadyClaimed();  // account has already claimed their tokens
    error InvalidProof();     // Merkle proof does not verify against root
    error ZeroAddress();
    error AirdropEnded();     // airdrop window has closed
    error NotOwner();
    error TransferFailed();   // ERC20 transfer returned false
    error ClaimingNotStarted();
    error ClaimingEnded();
    error ClaimingNotEnded();
    error InvalidTimeWindow();

    // ─── Events ────────────────────────────────────────────────────────────────
    /// @dev Emitted when a recipient successfully claims their tokens.
    event Claimed(address indexed account, uint256 amount);
    /// @dev Emitted when the owner updates the Merkle root.
    event MerkleRootUpdated(bytes32 oldRoot, bytes32 newRoot);
    /// @dev Emitted when the owner sweeps remaining tokens after the airdrop.
    event Swept(address indexed to, uint256 amount);
    event DeadlineExtended(uint256 oldDeadline, uint256 newDeadline);

    // ─── Functions ─────────────────────────────────────────────────────────────
    function claim(uint256 amount, bytes32[] calldata proof) external;
    function hasClaimed(address account) external view returns (bool);
    function setMerkleRoot(bytes32 newRoot) external;
    function sweep(address to) external;
}
