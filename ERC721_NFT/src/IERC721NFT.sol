// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IERC721NFT
/// @notice Interface for the Celo ERC721 NFT contract.
interface IERC721NFT {
    // ─── Errors ────────────────────────────────────────────────────────────────
    error ZeroAddress();
    error ZeroAmount();
    error NotOwner();
    error NotPendingOwner();
    error Paused();
    error Reentrancy();
    error NotTokenOwner();
    error NotApproved();
    error TokenNotFound();
    error AlreadyMinted();
    error CapExceeded();
    error InvalidRecipient();

    // ─── Events ────────────────────────────────────────────────────────────────
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event Minted(address indexed to, uint256 indexed tokenId, string tokenURI);
    event Burned(address indexed from, uint256 indexed tokenId);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ─── ERC721 ────────────────────────────────────────────────────────────────
    function balanceOf(address owner) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;
    function getApproved(uint256 tokenId) external view returns (address);
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function tokenURI(uint256 tokenId) external view returns (string memory);

    // ─── Mint / Burn ───────────────────────────────────────────────────────────
    function mint(address to, string calldata uri) external returns (uint256 tokenId);
    function burn(uint256 tokenId) external;

    // ─── Admin ─────────────────────────────────────────────────────────────────
    function pause() external;
    function unpause() external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
