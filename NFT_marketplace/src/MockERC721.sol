// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @dev Minimal ERC721 mock for testing. Not for production use.
contract MockERC721 {
    string public name = "MockNFT";
    string public symbol = "MNFT";

    mapping(uint256 => address) private _owners;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(uint256 => address) private _tokenApprovals;
    uint256 public nextTokenId = 1;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    function mint(address to) external returns (uint256 id) {
        id = nextTokenId++;
        _owners[id] = to;
        emit Transfer(address(0), to, id);
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = _owners[tokenId];
        require(o != address(0), "ERC721: invalid token");
        return o;
    }

    function approve(address to, uint256 tokenId) external {
        require(_owners[tokenId] == msg.sender, "ERC721: not owner");
        _tokenApprovals[tokenId] = to;
        emit Approval(msg.sender, to, tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address o, address operator) external view returns (bool) {
        return _operatorApprovals[o][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(_owners[tokenId] == from, "ERC721: wrong owner");
        require(
            msg.sender == from ||
            _tokenApprovals[tokenId] == msg.sender ||
            _operatorApprovals[from][msg.sender],
            "ERC721: not approved"
        );
        _tokenApprovals[tokenId] = address(0);
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }
}
