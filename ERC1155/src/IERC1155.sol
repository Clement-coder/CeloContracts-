// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title IERC1155
/// @notice Minimal ERC-1155 interface (EIP-1155).
interface IERC1155 {
    // ─── Errors ────────────────────────────────────────────────────────────────
    error NotOwnerOrApproved(); // caller is not token owner or approved operator
    error ZeroAddress();
    error LengthMismatch();       // ids and amounts arrays have different lengths
    error InsufficientBalance();
    error UnsafeRecipient();      // contract recipient did not return correct ERC1155Receiver selector
    error NotOwner();
    error ExceedsMaxSupply();

    // ─── Events ────────────────────────────────────────────────────────────────
    /// @dev Emitted on single-token transfer or mint/burn.
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);
    /// @dev Emitted on batch transfer or batch mint/burn.
    event TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values);
    /// @dev Emitted when an operator is approved or revoked for all tokens.
    event ApprovalForAll(address indexed account, address indexed operator, bool approved);
    event URI(string value, uint256 indexed id);
    event MaxSupplySet(uint256 indexed id, uint256 maxSupply);

    // ─── Functions ─────────────────────────────────────────────────────────────
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids) external view returns (uint256[] memory);
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address account, address operator) external view returns (bool);
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
    function safeBatchTransferFrom(address from, address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data) external;
}
