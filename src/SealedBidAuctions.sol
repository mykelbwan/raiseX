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

error InvalidEndTime();
error InvalidReservePrice();
error InvalidTimeRange();
error AuctionNotSettled();
error AuctionCancel();
error PaymentFail();
error AlreadyClaimed();
error UnAuthorized();
error ContractPaused();
error AuctionNotStarted();
error AuctionEnded();
error AuctionAlreadySettled();
error BidsAlreadyPlaced();
error AuctionStillActive();
error BidTooLow();
error NotNftOwner();
error NotApprovedForTransfer();
error ZeroAddress();
error ErrorInvalidMsgValue();
error ErrorInvalidAmount();

contract SealedBidAuctions is
    Ownable,
    ReentrancyGuard,
    Pausable,
    ERC721Holder,
    ContractTransparencyConfig
{
    using SafeERC20 for IERC20;

    struct Auction {
        address owner;
        address nftAddress;
        address paymentToken;
        uint256 reservePrice;
        uint256 minBidUnit;
        uint256 startTime;
        uint256 commitEndTime;
        uint256 auctionId;
        uint256 tokenId;
        address highestBidder;
        uint256 highestBid;
        uint256 totalBids;
        bool settled;
        bool canceled;
    }

    struct Bids {
        uint256 bid;
        bool won;
    }
    struct PendingPayment {
        address token;
        address owner;
        uint256 amount;
        bool claimed;
    }

    struct AuctionRefund {
        address bidder;
        address token;
        uint256 amount;
        bool claimed;
    }

    struct AuctionView {
        address highestBidder;
        address aOwner;
        address nftAddress;
        address paymentToken;
        uint256 startTime;
        uint256 commitEndTime;
        uint256 tokenId;
        uint256 minBidUnit;
        uint256 highestBid;
        uint256 totalBids;
        uint32 platformFee;
        bool settled;
        bool cancelled;
    }

    struct BidderAuctionView {
        uint256 userBid;
        bool won; // true if bidder won the auction
        uint256 claimableRefund; // refund amount (0 if none)
        bool claimed; // true if refund already claimed
    }

    struct AuctionOwnerView {
        address owner;
        uint256 sellerProceeds;
        bool claimed;
    }

    mapping(uint256 aId => Auction) private auctions;
    mapping(uint256 aId => mapping(address bidder => Bids)) private bids;
    mapping(uint256 aId => mapping(address receiver => PendingPayment))
        private pendingPayment;
    mapping(uint256 aId => mapping(address bidder => AuctionRefund))
        private auctionRefunds;
    mapping(address bidder => uint256[]) private bidderAuctions;

    address private platformFeeRecipient;
    uint256 private auctionCounter;
    uint32 private constant PLATFORM_FEE = 5;

    event AuctionCreated(
        address indexed _nftAddress,
        uint256 _tokenId,
        uint256 _reservePrice,
        uint256 _minBid,
        uint256 _startDelayMinutes,
        uint256 _durationMinutes,
        uint256 _auctionId,
        address _paymentToken,
        address _owner
    );
    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 amount
    );
    event AuctionSettled(
        uint256 indexed auctionId,
        uint256 highestBid,
        address highestBidder
    );
    event Withdrawn(
        uint256 auctionId,
        address indexed recipient,
        uint256 amount
    );
    event AuctionCancelled(uint256 indexed auctionId);
    event Refund(uint256 indexed auctionId, uint256 amount);

    constructor(address _initialOwner) Ownable(_initialOwner) {
        if (_initialOwner == address(0)) revert ZeroAddress();
        platformFeeRecipient = _initialOwner;
    }

    function createAuction(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _reservePrice, // minimum acceptable bid to qualify as a winner
        uint256 _minBidUnit,
        uint256 _startDelayMinutes,
        uint256 _durationMinutes,
        address _paymentToken
    ) external nonReentrant {
        if (paused()) revert ContractPaused();
        if (_durationMinutes == 0) revert InvalidEndTime();
        if (_reservePrice == 0) revert InvalidReservePrice();

        uint256 startTime = block.timestamp + _minutes(_startDelayMinutes);
        uint256 endTime = startTime + _minutes(_durationMinutes);

        if (endTime <= startTime) revert InvalidTimeRange();

        address owner = msg.sender;

        // Ownership check
        if (IERC721(_nftAddress).ownerOf(_tokenId) != owner)
            revert NotNftOwner();
        // approval check
        if (IERC721(_nftAddress).getApproved(_tokenId) != address(this))
            revert NotApprovedForTransfer();

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
            minBidUnit: _minBidUnit,
            startTime: startTime,
            commitEndTime: endTime,
            highestBidder: address(0),
            highestBid: 0,
            totalBids: 0,
            settled: false,
            canceled: false,
            paymentToken: _paymentToken
        });

        emit AuctionCreated(
            _nftAddress,
            _tokenId,
            _reservePrice,
            _minBidUnit,
            startTime,
            endTime,
            auctionId,
            _paymentToken,
            owner
        );
    }

    function placeBid(
        uint256 _auctionId,
        uint256 _amount
    ) external payable nonReentrant {
        if (paused()) revert ContractPaused();
        Auction storage a = auctions[_auctionId];
        if (a.settled || a.canceled) revert AuctionAlreadySettled();
        if (block.timestamp < a.startTime) revert AuctionNotStarted();
        if (block.timestamp > a.commitEndTime) revert AuctionEnded();

        uint256 minRequiredBid = a.minBidUnit;
        uint256 amountIn;
        address bidder = msg.sender;
        uint256 amt = msg.value;

        // --- Handle ETH vs ERC20 ---
        if (a.paymentToken == address(0)) {
            if (amt == 0) revert ErrorInvalidAmount();
            amountIn = amt;
        } else {
            if (amt != 0) revert ErrorInvalidMsgValue();
            amountIn = _amount;
            if (amountIn == 0) revert ErrorInvalidAmount();
            IERC20(a.paymentToken).safeTransferFrom(
                bidder,
                address(this),
                amountIn
            );
        }

        if (amountIn < minRequiredBid) revert BidTooLow();

        a.totalBids += amountIn;
        // Update bidder's total bid
        Bids storage bid = bids[a.auctionId][bidder];
        bid.bid += amountIn;
        address prevHighest = a.highestBidder;
        AuctionRefund storage r = auctionRefunds[_auctionId][prevHighest];

        if (bids[_auctionId][bidder].bid == 0) {
            // first time this bidder joins this auction
            bidderAuctions[bidder].push(_auctionId);
        }

        // Handle previous highest bidder
        if (prevHighest != address(0) && prevHighest != bidder) {
            bids[a.auctionId][prevHighest].won = false;

            r.bidder = prevHighest;
            r.token = a.paymentToken;
            r.amount = bid.bid;
            r.claimed = false;
        }

        // Remove stale refund if current bidder is topping up as highest bidder
        if (bidder == prevHighest) {
            delete auctionRefunds[_auctionId][bidder];
        }

        // Check if bidder becomes highest
        if (bid.bid > a.highestBid && bid.bid >= a.reservePrice) {
            a.highestBid = bid.bid;
            a.highestBidder = bidder;
            bid.won = true;
        }

        // Record refund for losing bidder (anyone not highest)
        if (bidder != a.highestBidder) {
            r.bidder = bidder;
            r.token = a.paymentToken;
            r.amount = bid.bid;
            r.claimed = false;
        }

        emit BidPlaced(_auctionId, bidder, amountIn);
    }

    function settleAuction(uint256 _auctionId) external nonReentrant {
        if (paused()) revert ContractPaused();

        Auction storage a = auctions[_auctionId];

        if (a.settled || a.canceled) revert AuctionAlreadySettled();
        if (block.timestamp < a.commitEndTime) revert AuctionStillActive();

        a.settled = true;

        // No bids → return NFT to seller
        if (a.highestBidder == address(0)) {
            IERC721(a.nftAddress).safeTransferFrom(
                address(this),
                a.owner,
                a.tokenId
            );
            emit AuctionSettled(_auctionId, a.highestBid, a.highestBidder);
            return;
        }

        // 1) Transfer NFT to winner
        IERC721(a.nftAddress).safeTransferFrom(
            address(this),
            a.highestBidder,
            a.tokenId
        );

        // 2) Record pending payments
        uint256 amount = a.highestBid;
        uint256 fee = (amount * PLATFORM_FEE) / 100;
        uint256 sellerProceeds = amount - fee;

        // seller payment
        pendingPayment[_auctionId][a.owner] = PendingPayment({
            token: a.paymentToken,
            owner: a.owner,
            amount: sellerProceeds,
            claimed: false
        });

        // platform payment
        pendingPayment[_auctionId][platformFeeRecipient] = PendingPayment({
            token: a.paymentToken,
            owner: platformFeeRecipient,
            amount: fee,
            claimed: false
        });

        emit AuctionSettled(_auctionId, a.highestBid, a.highestBidder);
    }

    function withdraw(uint256 _auctionId) external nonReentrant {
        if (paused()) revert ContractPaused();
        Auction storage a = auctions[_auctionId];
        if (!a.settled) revert AuctionNotSettled();
        if (a.canceled) revert AuctionCancel();

        address owner = msg.sender;
        if (owner != a.owner || owner != platformFeeRecipient)
            revert UnAuthorized();
        PendingPayment storage p = pendingPayment[_auctionId][owner];

        if (p.amount == 0) revert PaymentFail();
        if (p.claimed) revert AlreadyClaimed();

        uint256 amount = p.amount;
        p.amount = 0;
        p.claimed = true;

        if (a.paymentToken == address(0)) {
            (bool ok, ) = payable(owner).call{value: amount}("");
            if (!ok) revert PaymentFail();
        } else {
            // ERC20
            IERC20 token = IERC20(p.token);
            token.safeTransfer(owner, amount);
        }

        emit Withdrawn(_auctionId, owner, amount);
    }

    function claimRefund(uint256 _auctionId) external nonReentrant {
        if (paused()) revert ContractPaused();
        Auction storage a = auctions[_auctionId];
        if (!a.settled) revert AuctionNotSettled();
        if (a.canceled) revert AuctionCancel();

        address bidder = msg.sender;
        AuctionRefund storage r = auctionRefunds[_auctionId][bidder];

        if (r.claimed) revert AlreadyClaimed();
        if (r.amount == 0) revert ErrorInvalidAmount();

        r.claimed = true;
        uint256 amount = r.amount;
        r.amount = 0;

        if (r.token == address(0)) {
            (bool ok, ) = payable(bidder).call{value: amount}("");
            if (!ok) revert PaymentFail();
        } else {
            // ERC20
            IERC20 token = IERC20(r.token);
            token.safeTransfer(bidder, amount);
        }
        emit Refund(a.auctionId, amount);
    }

    function cancelAuction(uint256 _auctionId) external nonReentrant {
        if (paused()) revert ContractPaused();

        Auction storage a = auctions[_auctionId];

        if (msg.sender != a.owner) revert UnAuthorized();
        if (a.settled || a.canceled) revert AuctionAlreadySettled();
        if (a.highestBidder != address(0)) revert BidsAlreadyPlaced();

        a.canceled = true;

        IERC721(a.nftAddress).safeTransferFrom(
            address(this),
            a.owner,
            a.tokenId
        );

        emit AuctionCancelled(_auctionId);
    }

    function _minutes(uint256 m) internal pure returns (uint256) {
        return m * 1 minutes;
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
        EventLogConfig[] memory eventLogConfigs = new EventLogConfig[](6);

        bytes32 auctionCreatedSig = _hashEvent(
            "AuctionCreated(address,uint256,uint256,uint256,uint256,uint256,uint256,address,address)"
        );
        Field[] memory relevantToAuctionCreated = new Field[](1);
        relevantToAuctionCreated[0] = Field.EVERYONE;
        eventLogConfigs[0] = EventLogConfig(
            auctionCreatedSig,
            relevantToAuctionCreated
        );

        bytes32 bidPlacedSig = _hashEvent(
            "BidPlaced(BidPlaced(uint256,address,uint256))"
        );
        Field[] memory relevantToBidPlaced = new Field[](1);
        relevantToBidPlaced[0] = Field.TOPIC2;
        eventLogConfigs[1] = EventLogConfig(bidPlacedSig, relevantToBidPlaced);

        bytes32 auctionSettledSig = _hashEvent(
            "AuctionSettled(AuctionSettled(uint256,uint256,address))"
        );
        Field[] memory relevantToAuctionSettled = new Field[](1);
        relevantToAuctionSettled[0] = Field.EVERYONE;
        eventLogConfigs[2] = EventLogConfig(
            auctionSettledSig,
            relevantToAuctionSettled
        );

        bytes32 withdrawnSig = _hashEvent("Withdrawn(uint256,address,uint256)");
        Field[] memory relevantToWithdrawn = new Field[](1);
        relevantToWithdrawn[0] = Field.EVERYONE;
        eventLogConfigs[3] = EventLogConfig(withdrawnSig, relevantToWithdrawn);

        bytes32 auctionCancelledSig = _hashEvent("AuctionCancelled(uint256)");
        Field[] memory relevantToAuctionCancelled = new Field[](1);
        relevantToAuctionCancelled[0] = Field.EVERYONE;
        eventLogConfigs[4] = EventLogConfig(
            auctionCancelledSig,
            relevantToAuctionCancelled
        );

        bytes32 refundSig = _hashEvent("Refund(uint256,uint256)");
        Field[] memory relevantToRefund = new Field[](1);
        relevantToRefund[0] = Field.SENDER;
        eventLogConfigs[5] = EventLogConfig(refundSig, relevantToRefund);

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
        Auction memory a = auctions[_auctionId];

        address highestBidder = address(0);
        uint256 highestBid = 0;
        uint256 totalBids = 0;

        if (a.settled) {
            highestBidder = a.highestBidder;
            highestBid = a.highestBid;
            totalBids = a.totalBids;
        }

        return
            AuctionView({
                highestBidder: highestBidder,
                aOwner: a.owner,
                nftAddress: a.nftAddress,
                paymentToken: a.paymentToken,
                startTime: a.startTime,
                commitEndTime: a.commitEndTime,
                tokenId: a.tokenId,
                minBidUnit: a.minBidUnit,
                highestBid: highestBid,
                totalBids: totalBids,
                settled: a.settled,
                cancelled: a.canceled,
                platformFee: PLATFORM_FEE
            });
    }

    function getAuctionOwnerView(
        uint256 _auctionId
    ) external view returns (AuctionOwnerView memory) {
        Auction memory a = auctions[_auctionId];

        // Default values if not settled
        uint256 proceeds = 0;
        bool claimed = false;

        if (a.settled && !a.canceled) {
            PendingPayment memory p = pendingPayment[_auctionId][a.owner];
            proceeds = p.amount;
            claimed = p.claimed;
        }

        return
            AuctionOwnerView({
                owner: a.owner,
                sellerProceeds: proceeds,
                claimed: claimed
            });
    }

    function getBidder(
        address bidder
    ) external view returns (BidderAuctionView[] memory) {
        uint256[] memory aIds = bidderAuctions[bidder];
        uint256 len = aIds.length;

        BidderAuctionView[] memory views = new BidderAuctionView[](len);

        for (uint256 i; i < len; i++) {
            uint256 aId = aIds[i];
            Auction memory a = auctions[aId];
            Bids memory b = bids[aId][bidder];

            uint256 refundAmount = 0;
            bool refundClaimed = false;

            if (a.settled && !b.won) {
                AuctionRefund memory r = auctionRefunds[aId][bidder];
                refundAmount = r.amount;
                refundClaimed = r.claimed;
            }

            views[i] = BidderAuctionView({
                userBid: b.bid,
                won: b.won,
                claimableRefund: refundAmount,
                claimed: refundClaimed
            });
        }
        return views;
    }

    function getFeeAddress() external view returns (address) {
        return platformFeeRecipient;
    }
}
