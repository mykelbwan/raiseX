// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";

contract TESTNft is Ownable, ERC721Enumerable, ERC721URIStorage {
    uint256 private constant MAX_TOKENS = 6000;
    uint256 public constant WALLET_MAX = 500;
    uint256 private numTokens;
    uint256 public mintPrice;
    string private baseTokenURI;

    constructor(
        uint256 _price,
        address owner,
        string memory _baseTokenURI
    ) ERC721("TEST NFT", "TEN") Ownable(owner) {
        mintPrice = _price;
        baseTokenURI = _baseTokenURI;
    }

    function mint(uint256 count) external payable {
        if (msg.sender != owner()) {
            require(count * mintPrice == msg.value, "Invalid payment amount");
            (bool success, ) = payable(owner()).call{value: msg.value}("");
            require(success, "Failed to send payment");
        }

        for (uint256 i = 0; i < count; i++) {
            numTokens++;
            uint256 nftId = numTokens;
            _safeMint(msg.sender, nftId);
        }
    }

    function mintableCount(address addr) external view returns (uint256) {
        if (numTokens < MAX_TOKENS) {
            uint256 maxMints = (addr == owner())
                ? MAX_TOKENS - numTokens
                : WALLET_MAX - balanceOf(addr);
            return
                (maxMints + numTokens > MAX_TOKENS)
                    ? (MAX_TOKENS - numTokens)
                    : maxMints;
        }
        return 0;
    }

    function tokenURI(
        uint256 tokenId
    )
        public
        view
        virtual
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        require(tokenId <= numTokens, "Non-existent token");
        return string.concat(_baseURI(), "metadata.json");
    }

    function setBaseURI(string memory baseURI) external onlyOwner {
        baseTokenURI = baseURI;
    }

    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        virtual
        override(ERC721Enumerable, ERC721URIStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _update(
        address dest,
        uint256 nftId,
        address auth
    ) internal virtual override(ERC721Enumerable, ERC721) returns (address) {
        if (
            dest != address(owner()) &&
            dest != address(0) &&
            numTokens < MAX_TOKENS
        ) {
            require(
                WALLET_MAX >= balanceOf(dest) + 1,
                "Wallet limit would be exceeded"
            );
        }

        return super._update(dest, nftId, auth);
    }

    function _increaseBalance(
        address account,
        uint128 value
    ) internal virtual override(ERC721Enumerable, ERC721) {
        super._increaseBalance(account, value);
    }

    function _baseURI() internal view override returns (string memory) {
        return baseTokenURI;
    }
}
