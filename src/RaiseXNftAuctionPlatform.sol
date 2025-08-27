// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

error InvalidTimeRange();
error ReserveMustBeGreaterThanZero();
error UnAuthorized();

contract RaiseXNft is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Auction {
        // Identification
        uint256 auctionId;
        address owner; // Seller
        address nftAddress; // NFT contract
        uint256 tokenId; // NFT being auctioned
        // Auction Rules
        uint256 reservePrice; // Minimum acceptable price (auction won't settle below this)
        uint256 minBidIncrement; // Minimum increment for next bids
        uint256 buyoutPrice; // Optional instant purchase price (0 if disabled)
        // Timing
        uint256 startTime; // When bidding starts
        uint256 endTime; // When bidding ends
        uint256 extensionWindow; // Auto-extend window (anti-sniping)
        // Current State
        address highestBidder;
        uint256 highestBid;
        bool settled; // Auction finalized
        // Funds Handling
        address paymentToken; // ERC20 token address (or address(0) for native ETH)
    }

    uint256 private auctionCounter;
    mapping(uint256 => Auction) private auctions; // auctionId => Auction
    mapping(uint256 => mapping(address => uint256)) private bids; // auctionId => bidder => amount

    constructor(address _initialOwner) Ownable(_initialOwner) {}

    function createAuction(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _reservePrice,
        uint256 _minBidIncrement,
        uint256 _buyoutPrice,
        uint256 _startTimeInMinutes,
        uint256 _endTimeInMinutes,
        uint256 _extensionWindow,
        address _paymentToken
    ) external nonReentrant returns (uint256) {
        uint256 startTime = block.timestamp + _minutes(_startTimeInMinutes);
        uint256 endTime = block.timestamp + _minutes(_endTimeInMinutes);

        if (endTime < startTime) revert InvalidTimeRange();
        if (_reservePrice < 0) revert ReserveMustBeGreaterThanZero();

        address owner = msg.sender;

        auctionCounter++;
        uint256 auctionId = auctionCounter;

        // Transfer NFT into escrow
        IERC721(_nftAddress).transferFrom(owner, address(this), _tokenId);

        auctions[auctionId] = Auction({
            auctionId: auctionId,
            owner: owner,
            nftAddress: _nftAddress,
            tokenId: _tokenId,
            reservePrice: _reservePrice,
            minBidIncrement: _minBidIncrement,
            buyoutPrice: _buyoutPrice,
            startTime: startTime,
            endTime: endTime,
            extensionWindow: _extensionWindow,
            highestBidder: address(0),
            highestBid: 0,
            settled: false,
            paymentToken: _paymentToken
        });

        return auctionId;
    }

    function placeBid(
        uint256 _auctionId,
        uint256 _amount
    ) external payable nonReentrant {
        Auction storage auction = auctions[_auctionId];
        require(block.timestamp >= auction.startTime, "Auction not started");
        require(block.timestamp < auction.endTime, "Auction ended");
        require(!auction.settled, "Auction settled");

        uint256 minRequiredBid = auction.highestBid == 0
            ? auction.reservePrice
            : auction.highestBid + auction.minBidIncrement;
        require(_amount >= minRequiredBid, "Bid too low");

        // Handle ERC20 or ETH
        if (auction.paymentToken == address(0)) {
            require(msg.value == _amount, "ETH mismatch");
        } else {
            IERC20(auction.paymentToken).safeTransferFrom(
                msg.sender,
                address(this),
                _amount
            );
        }

        // Refund previous highest bidder
        if (auction.highestBidder != address(0)) {
            if (auction.paymentToken == address(0)) {
                payable(auction.highestBidder).transfer(auction.highestBid);
            } else {
                IERC20(auction.paymentToken).safeTransfer(
                    auction.highestBidder,
                    auction.highestBid
                );
            }
        }

        // Record new highest bid
        auction.highestBidder = msg.sender;
        auction.highestBid = _amount;

        // Anti-sniping: extend if bid placed near end
        if (auction.endTime - block.timestamp <= auction.extensionWindow) {
            auction.endTime = block.timestamp + auction.extensionWindow;
        }

        // Instant buyout
        if (auction.buyoutPrice > 0 && _amount >= auction.buyoutPrice) {
            _settleAuction(_auctionId);
        }
    }

    function settleAuction(uint256 _auctionId) external nonReentrant {
        Auction storage auction = auctions[_auctionId];
        require(
            block.timestamp >= auction.endTime || msg.sender == auction.owner,
            "Auction still active"
        );
        require(!auction.settled, "Already settled");

        _settleAuction(_auctionId);
    }

    function _settleAuction(uint256 _auctionId) internal {
        Auction storage auction = auctions[_auctionId];
        auction.settled = true;

        if (auction.highestBidder != address(0)) {
            // Transfer NFT to winner
            IERC721(auction.nftAddress).transferFrom(
                address(this),
                auction.highestBidder,
                auction.tokenId
            );

            // Transfer funds to seller
            if (auction.paymentToken == address(0)) {
                payable(auction.owner).transfer(auction.highestBid);
            } else {
                IERC20(auction.paymentToken).safeTransfer(
                    auction.owner,
                    auction.highestBid
                );
            }
        } else {
            // No bids: return NFT to seller
            IERC721(auction.nftAddress).transferFrom(
                address(this),
                auction.owner,
                auction.tokenId
            );
        }
    }

    function cancelAuction(uint256 _auctionId) external nonReentrant {
        Auction storage auction = auctions[_auctionId];
        if (msg.sender != auction.owner) revert UnAuthorized();
        require(!auction.settled, "Already settled");
        require(auction.highestBidder == address(0), "Bids already placed");

        auction.settled = true;
        IERC721(auction.nftAddress).transferFrom(
            address(this),
            auction.owner,
            auction.tokenId
        );
    }

    // minutes -> seconds helper (optional)
    function _minutes(uint256 m) internal pure returns (uint256) {
        return m * 1 minutes; // same as m * 60
    }
}
