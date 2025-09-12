// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ContractTransparencyConfig} from "./Interface/ContractTransparencyConfig.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

error InvalidTimeRange();
error ReserveMustBeGreaterThanZero();
error UnAuthorized();
error ContractPaused();
error AuctionNotStarted();
error AuctionEnded();
error AuctionAlreadySettled();
error BidsAlreadyPlaced();
error PaymentFail();
error AuctionStillActive();
error BidTooLow();
error EthMisMatch();
error AuctionTooShort();
error NotNftOwner();
error NotApprovedForTransfer();
error ZeroAddress();
error ErrorInvalidMsgValue();
error ErrorInvalidAmount();

contract RaiseXNftAuctionPlatform is
    Ownable,
    ReentrancyGuard,
    Pausable,
    ERC721Holder,
    ContractTransparencyConfig
{
    using SafeERC20 for IERC20;

    struct Auction {
        address owner;
        address highestBidder;
        address nftAddress;
        address paymentToken;
        uint256 highestBid;
        uint256 reservePrice;
        uint256 buyoutPrice;
        uint256 startTime;
        uint256 endTime;
        uint256 extensionWindow;
        uint256 minBidIncrement;
        uint256 auctionId;
        uint256 tokenId;
        bool settled;
    }
    struct AuctionView {
        uint256 reservePrice;
        uint256 minBidIncrement;
        uint256 buyoutPrice;
        uint256 startTime;
        uint256 endTime;
        uint256 highestBid;
        uint256 extensionWindow;
        address paymentToken;
        address nftAddress;
        uint256 auctionId;
        uint256 tokenId;
        bool settled;
    }

    struct PlatformView {
        uint32 platformFee;
    }

    mapping(uint256 auctionId => Auction) private auctions; // auctionId => Auction
    mapping(uint256 auctionId => mapping(address bidder => uint256 bid))
        private bids; // auctionId => bidder => amount

    uint256 private constant MIN_AUCTION_DURATION = 1 hours; // enforce minimum
    address private platformFeeRecipient;
    uint256 private auctionCounter;
    uint32 private constant PLATFORM_FEE = 3; //3%

    event AuctionCreated(
        address indexed _nftAddress,
        uint256 _tokenId,
        uint256 _reservePrice,
        uint256 _minBidIncrement,
        uint256 _buyoutPrice,
        uint256 _startTimeInHours,
        uint256 _endTimeInHours,
        uint256 _extensionWindow,
        address _paymentToken
    );
    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 amount
    );
    event BidRefunded(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 amount
    );
    event AuctionSettled(
        uint256 indexed auctionId,
        uint256 winningBid,
        address paymentToken
    );
    event AuctionCancelled(uint256 indexed auctionId);

    constructor(address _initialOwner) Ownable(_initialOwner) {
        if (_initialOwner == address(0)) revert ZeroAddress();
        platformFeeRecipient = _initialOwner;
    }

    function createAuction(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _reservePrice,
        uint256 _minBidIncrement,
        uint256 _buyoutPrice,
        uint256 _startTimeInHours,
        uint256 _endTimeInHours,
        uint256 _extensionWindow,
        address _paymentToken
    ) external nonReentrant {
        if (paused()) revert ContractPaused();
        if (_reservePrice == 0) revert ReserveMustBeGreaterThanZero();

        uint256 startTime = block.timestamp + _hours(_startTimeInHours);
        uint256 endTime = block.timestamp + _hours(_endTimeInHours);

        if (endTime <= startTime) revert InvalidTimeRange();
        if (endTime - startTime < MIN_AUCTION_DURATION)
            revert AuctionTooShort();

        address owner = msg.sender;

        // Ownership check
        if (IERC721(_nftAddress).ownerOf(_tokenId) != owner) {
            revert NotNftOwner();
        }

        if (
            IERC721(_nftAddress).getApproved(_tokenId) != address(this) &&
            !IERC721(_nftAddress).isApprovedForAll(owner, address(this))
        ) {
            revert NotApprovedForTransfer();
        }

        // Transfer NFT into escrow
        IERC721(_nftAddress).safeTransferFrom(owner, address(this), _tokenId);

        auctionCounter++;
        uint256 auctionId = auctionCounter;

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
        emit AuctionCreated(
            _nftAddress,
            _tokenId,
            _reservePrice,
            _minBidIncrement,
            _buyoutPrice,
            startTime,
            endTime,
            _extensionWindow,
            _paymentToken
        );
    }

    function placeBid(
        uint256 _auctionId,
        uint256 _amount
    ) external payable nonReentrant {
        if (paused()) revert ContractPaused();

        Auction storage auction = auctions[_auctionId];

        if (block.timestamp < auction.startTime) revert AuctionNotStarted();
        if (block.timestamp > auction.endTime) revert AuctionEnded();
        if (auction.settled) revert AuctionAlreadySettled();

        uint256 minRequiredBid = auction.highestBid == 0
            ? auction.reservePrice
            : auction.highestBid + auction.minBidIncrement;

        uint256 amountIn;
        address bidder = msg.sender;

        // --- Handle native ETH vs ERC20 ---
        if (auction.paymentToken == address(0)) {
            // Native: msg.value is the bid
            if (msg.value == 0) revert ErrorInvalidAmount();
            amountIn = msg.value;
        } else {
            // ERC20: caller must not send ETH
            if (msg.value != 0) revert ErrorInvalidMsgValue();
            amountIn = _amount;
            if (amountIn == 0) revert ErrorInvalidAmount();

            // Pull only the exact bid amount
            IERC20(auction.paymentToken).safeTransferFrom(
                bidder,
                address(this),
                amountIn
            );
        }

        if (amountIn < minRequiredBid) revert BidTooLow();

        // --- Checks-Effects-Interactions ---
        address prevBidder = auction.highestBidder;
        uint256 prevBid = auction.highestBid;

        // Update state BEFORE external calls
        auction.highestBidder = bidder;
        auction.highestBid = amountIn;

        // Refund previous bidder (if any)
        if (prevBidder != address(0)) {
            if (auction.paymentToken == address(0)) {
                (bool success, ) = payable(prevBidder).call{value: prevBid}("");
                if (!success) revert PaymentFail();
            } else {
                IERC20(auction.paymentToken).safeTransfer(prevBidder, prevBid);
            }
            emit BidRefunded(_auctionId, prevBidder, prevBid);
        }

        // Anti-sniping extension
        if (auction.endTime - block.timestamp <= auction.extensionWindow) {
            auction.endTime = block.timestamp + auction.extensionWindow;
        }

        emit BidPlaced(_auctionId, bidder, amountIn);

        // Instant buyout
        if (auction.buyoutPrice > 0 && amountIn >= auction.buyoutPrice) {
            _settleAuction(_auctionId);
        }
    }

    function settleAuction(uint256 _auctionId) external nonReentrant {
        if (paused()) revert ContractPaused();

        Auction storage auction = auctions[_auctionId];

        // Anyone can settle after the auction ends
        if (block.timestamp < auction.endTime) revert AuctionStillActive();
        if (auction.settled) revert AuctionAlreadySettled();

        _settleAuction(_auctionId);
    }

    function _hours(uint256 m) internal pure returns (uint256) {
        return m * 1 hours;
    }

    function _settleAuction(uint256 _auctionId) internal {
        Auction storage auction = auctions[_auctionId];

        // CEI: mark settled first
        auction.settled = true;

        // No bids → return NFT to seller
        if (auction.highestBidder == address(0)) {
            IERC721(auction.nftAddress).safeTransferFrom(
                address(this),
                auction.owner,
                auction.tokenId
            );
            emit AuctionSettled(
                _auctionId,
                auction.highestBid,
                auction.paymentToken
            );
            return;
        }

        // 1) Transfer NFT to winner
        IERC721(auction.nftAddress).safeTransferFrom(
            address(this),
            auction.highestBidder,
            auction.tokenId
        );

        // 2) Payouts (platform fee + seller proceeds)
        uint256 amount = auction.highestBid;
        uint256 fee = (amount * PLATFORM_FEE) / 100;
        uint256 sellerProceeds = amount - fee;

        if (auction.paymentToken == address(0)) {
            // ETH
            if (fee > 0) {
                (bool ok1, ) = payable(platformFeeRecipient).call{value: fee}(
                    ""
                );
                if (!ok1) revert PaymentFail();
            }
            (bool ok2, ) = payable(auction.owner).call{value: sellerProceeds}(
                ""
            );
            if (!ok2) revert PaymentFail();
        } else {
            // ERC20
            IERC20 token = IERC20(auction.paymentToken);
            if (fee > 0) token.safeTransfer(platformFeeRecipient, fee);
            token.safeTransfer(auction.owner, sellerProceeds);
        }

        emit AuctionSettled(
            _auctionId,
            auction.highestBid,
            auction.paymentToken
        );
    }

    function cancelAuction(uint256 _auctionId) external nonReentrant {
        if (paused()) revert ContractPaused();

        Auction storage auction = auctions[_auctionId];

        if (msg.sender != auction.owner) revert UnAuthorized();
        if (auction.settled) revert AuctionAlreadySettled();
        if (auction.highestBidder != address(0)) revert BidsAlreadyPlaced();

        // CEI: mark settled before transferring NFT out
        auction.settled = true;

        IERC721(auction.nftAddress).safeTransferFrom(
            address(this),
            auction.owner,
            auction.tokenId
        );

        emit AuctionCancelled(_auctionId);
    }

    /// @dev Returns the unique keccak256 hash of an event's signature string.
    /// Used to identify events in the EVM log system.
    /// Example: "DepositReceived(address,uint256)" → bytes32 hash
    function _hashEvent(
        string memory eventSignature
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(eventSignature));
    }

    function visibilityRules() external pure returns (VisibilityConfig memory) {
        EventLogConfig[] memory eventLogConfigs = new EventLogConfig[](5);

        bytes32 auctionCreatedSig = _hashEvent(
            "AuctionCreated(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,address)"
        );
        Field[] memory relevantToAuctionCreated = new Field[](1);
        relevantToAuctionCreated[0] = Field.EVERYONE;
        eventLogConfigs[0] = EventLogConfig(
            auctionCreatedSig,
            relevantToAuctionCreated
        );

        bytes32 bidPlacedSig = _hashEvent("BidPlaced(uint256,address,uint256)");
        Field[] memory relevantToBidPlaced = new Field[](1);
        relevantToBidPlaced[0] = Field.TOPIC2;
        eventLogConfigs[1] = EventLogConfig(bidPlacedSig, relevantToBidPlaced);

        bytes32 bidRefundedSig = _hashEvent(
            "BidRefunded(uint256,address,uint256)"
        );
        Field[] memory relevantToBidRefunded = new Field[](1);
        relevantToBidRefunded[0] = Field.TOPIC2;
        eventLogConfigs[2] = EventLogConfig(
            bidRefundedSig,
            relevantToBidRefunded
        );

        bytes32 auctionSettledSig = _hashEvent(
            "AuctionSettled(uint256,uint256,address)"
        );
        Field[] memory relevantToAuctionSettled = new Field[](1);
        relevantToAuctionSettled[0] = Field.EVERYONE;
        eventLogConfigs[3] = EventLogConfig(
            auctionSettledSig,
            relevantToAuctionSettled
        );

        bytes32 auctionCancelledSig = _hashEvent("AuctionCancelled(uint256)");
        Field[] memory relevantToAuctionCancelled = new Field[](1);
        relevantToAuctionCancelled[0] = Field.EVERYONE;
        eventLogConfigs[1] = EventLogConfig(
            auctionCancelledSig,
            relevantToAuctionCancelled
        );

        // Return global visibility rules
        return VisibilityConfig(ContractCfg.PRIVATE, eventLogConfigs);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setPlatformFeeAddress(address feeAddress) external onlyOwner {
        if (feeAddress == address(0)) revert ZeroAddress();
        platformFeeRecipient = feeAddress;
    }

    function getAuction(
        uint256 _auctionId
    ) external view returns (AuctionView memory) {
        Auction storage a = auctions[_auctionId];
        return
            AuctionView({
                auctionId: a.auctionId,
                nftAddress: a.nftAddress,
                tokenId: a.tokenId,
                reservePrice: a.reservePrice,
                minBidIncrement: a.minBidIncrement,
                buyoutPrice: a.buyoutPrice,
                startTime: a.startTime,
                endTime: a.endTime,
                extensionWindow: a.extensionWindow,
                highestBid: a.highestBid,
                settled: a.settled,
                paymentToken: a.paymentToken
            });
    }

    function getPlatformInfo() external pure returns (PlatformView memory) {
        return PlatformView({platformFee: PLATFORM_FEE});
    }
}
