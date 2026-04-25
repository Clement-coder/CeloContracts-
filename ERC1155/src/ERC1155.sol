// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC1155} from "./IERC1155.sol";

/// @title ERC1155
/// @notice Full ERC-1155 multi-token implementation with mint, burn, and URI management.
///         No external dependencies — self-contained for Celo deployment.
/// @dev    Implements EIP-1155 including safe-transfer receiver checks.
///         Owner can mint any token id to any address and update the base URI.
contract ERC1155 is IERC1155 {

    // ─── State ─────────────────────────────────────────────────────────────────

    /// @notice Contract owner — can mint tokens and update the base URI.
    address public owner;

    /// @notice Base URI for token metadata. Full URI = baseURI + id + ".json".
    string public baseURI;

    /// @notice account => tokenId => balance
    mapping(address => mapping(uint256 => uint256)) private _balances;

    /// @notice account => operator => isApproved for all tokens
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    /// @param _baseURI Base URI for token metadata (e.g. "ipfs://Qm.../").
    constructor(string memory _baseURI) {
        owner = msg.sender;
        baseURI = _baseURI;
    }

    // ─── ERC-1155 Core ─────────────────────────────────────────────────────────

    /// @notice Returns the balance of `account` for token `id`.
    function balanceOf(address account, uint256 id) public view override returns (uint256) {
        if (account == address(0)) revert ZeroAddress();
        return _balances[account][id];
    }

    /// @notice Returns balances for multiple (account, id) pairs.
    function balanceOfBatch(
        address[] calldata accounts,
        uint256[] calldata ids
    ) external view override returns (uint256[] memory balances) {
        if (accounts.length != ids.length) revert LengthMismatch();
        balances = new uint256[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) {
            balances[i] = balanceOf(accounts[i], ids[i]);
        }
    }

    /// @notice Grant or revoke operator approval for all tokens.
    function setApprovalForAll(address operator, bool approved) external override {
        if (operator == address(0)) revert ZeroAddress();
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    /// @notice Returns true if `operator` is approved to manage all of `account`'s tokens.
    function isApprovedForAll(address account, address operator) public view override returns (bool) {
        return _operatorApprovals[account][operator];
    }

    /// @notice Transfer `amount` of token `id` from `from` to `to`.
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external override {
        if (to == address(0)) revert ZeroAddress();
        if (from != msg.sender && !isApprovedForAll(from, msg.sender)) revert NotOwnerOrApproved();

        // Underflow reverts automatically — no explicit balance check needed
        _balances[from][id] -= amount;
        _balances[to][id]   += amount;

        emit TransferSingle(msg.sender, from, to, id, amount);
        _checkOnERC1155Received(msg.sender, from, to, id, amount, data);
    }

    /// @notice Batch transfer multiple token ids from `from` to `to`.
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external override {
        if (to == address(0)) revert ZeroAddress();
        if (ids.length != amounts.length) revert LengthMismatch();
        if (from != msg.sender && !isApprovedForAll(from, msg.sender)) revert NotOwnerOrApproved();

        for (uint256 i; i < ids.length; ++i) {
            _balances[from][ids[i]] -= amounts[i];
            _balances[to][ids[i]]   += amounts[i];
        }

        emit TransferBatch(msg.sender, from, to, ids, amounts);
        _checkOnERC1155BatchReceived(msg.sender, from, to, ids, amounts, data);
    }

    // ─── Mint / Burn ───────────────────────────────────────────────────────────

    /// @notice Mint `amount` of token `id` to `to`. Only owner.
    function mint(address to, uint256 id, uint256 amount, bytes calldata data) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        _balances[to][id] += amount;
        emit TransferSingle(msg.sender, address(0), to, id, amount);
        _checkOnERC1155Received(msg.sender, address(0), to, id, amount, data);
    }

    /// @notice Batch mint multiple token ids to `to`. Only owner.
    /// @dev    ids[i] and amounts[i] must correspond to the same token.
    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (ids.length != amounts.length) revert LengthMismatch();
        for (uint256 i; i < ids.length; ++i) {
            _balances[to][ids[i]] += amounts[i];
        }
        emit TransferBatch(msg.sender, address(0), to, ids, amounts);
        _checkOnERC1155BatchReceived(msg.sender, address(0), to, ids, amounts, data);
    }

    /// @notice Burn `amount` of token `id` from `from`. Caller must be owner or approved.
    function burn(address from, uint256 id, uint256 amount) external {
        if (from != msg.sender && !isApprovedForAll(from, msg.sender)) revert NotOwnerOrApproved();
        // Underflow reverts automatically on insufficient balance
        _balances[from][id] -= amount;
        emit TransferSingle(msg.sender, from, address(0), id, amount);
    }

    /// @notice Batch burn multiple token ids from `from`. Caller must be owner or approved.
    function burnBatch(address from, uint256[] calldata ids, uint256[] calldata amounts) external {
        if (from != msg.sender && !isApprovedForAll(from, msg.sender)) revert NotOwnerOrApproved();
        if (ids.length != amounts.length) revert LengthMismatch();
        for (uint256 i; i < ids.length; ++i) {
            _balances[from][ids[i]] -= amounts[i];
        }
        emit TransferBatch(msg.sender, from, address(0), ids, amounts);
    }

    // ─── URI ───────────────────────────────────────────────────────────────────

    /// @notice Returns the metadata URI for token `id`.
    function uri(uint256 id) external view returns (string memory) {
        return string(abi.encodePacked(baseURI, _toString(id), ".json"));
    }

    /// @notice Update the base URI. Only owner.
    function setBaseURI(string calldata newURI) external onlyOwner {
        baseURI = newURI;
    }

    // ─── ERC-165 ───────────────────────────────────────────────────────────────

    /// @notice Returns true for ERC-1155 and ERC-165 interface ids.
    /// @dev    Interface ids: ERC1155=0xd9b67a26, MetadataURI=0x0e89341c, ERC165=0x01ffc9a7.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0xd9b67a26 // ERC-1155
            || interfaceId == 0x0e89341c // ERC-1155 Metadata URI
            || interfaceId == 0x01ffc9a7; // ERC-165
    }

    // ─── Internal ──────────────────────────────────────────────────────────────

    /// @dev Check ERC1155Receiver on single transfer if `to` is a contract.
    ///      EOAs (code.length == 0) are skipped — no callback needed.
    function _checkOnERC1155Received(
        address operator,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) internal {
        if (to.code.length == 0) return;
        try IERC1155Receiver(to).onERC1155Received(operator, from, id, amount, data) returns (bytes4 retval) {
            if (retval != IERC1155Receiver.onERC1155Received.selector) revert UnsafeRecipient();
        } catch {
            revert UnsafeRecipient();
        }
    }

    /// @dev Check ERC1155Receiver on batch transfer if `to` is a contract.
    function _checkOnERC1155BatchReceived(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal {
        if (to.code.length == 0) return;
        try IERC1155Receiver(to).onERC1155BatchReceived(operator, from, ids, amounts, data) returns (bytes4 retval) {
            if (retval != IERC1155Receiver.onERC1155BatchReceived.selector) revert UnsafeRecipient();
        } catch {
            revert UnsafeRecipient();
        }
    }

    /// @dev Converts uint256 to decimal string for URI construction.
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }
}

/// @dev Minimal ERC1155Receiver interface for safe-transfer checks.
interface IERC1155Receiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4);
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) external returns (bytes4);
}
