// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ContractTransparencyConfig} from "./Interface/ContractTransparencyConfig.sol";

error ErrorMissingParam();
error ErrorInvalidPresaleId();
error ErrorPresaleFilled();
error ErrorInvalidAmount();
error ErrorInvalidMsgValue();
error ErrorRefundExcessFilled();
error ErrorPresaleNotActive();
error ErrorExceedsWalletMax();
error ErrorInvalidCap();
error ErrorInvalidStart();
error ErrorInvalidTimeRange();
error ErrorInvalidPresaleType();
error ErrorUnAuthorized();
error ErrorNoLeftover();
error ErrorFeeTooHigh(uint8);
error ErrorAddressCannotBeZeroAddress();
error ErrorPresaleNotFinalized();
error ErrorFundsAlreadyWithdrawn();
error ErrorPresaleStillActive();
error ErrorPresaleFailed();
error ErrorWithdrawFailed();
error ErrorAlreadyFinalized();
error ErrorPresaleNotFailed();
error ErrorRefundFailed();
error ErrorSoftCapReached();
error ErrorCannotSellPresaleTokenInSameToken();
error ErrorNotCancelledPresale();
error ErrorNotWhitelistSale();
error ErrorWhitelistNotActive();
error ErrorNotWhitelisted();
error ErrorPresaleNotStarted();
error ErrorInvalidWlSale();
error ErrorBatchExceedsMaxAllowed(uint256);
error ErrorInvalidNumber(uint16);
error ErrorFunctionalityIsPaused();

contract RaiseXTokenSalePlatform is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    enum PresaleType {
        Fixed,
        Dynamic
    }

    struct Presale {
        PresaleType presaleType;
        uint256 presaleId;
        // Sale params
        uint256 tokensForSale;
        uint256 tokensSold; // @notice reflects fixed-type sales only
        uint256 softCap;
        uint256 hardCap;
        uint256 minContribution;
        uint256 maxContribution;
        uint256 startTime;
        uint256 endTime;
        uint256 amountRaised;
        // Whitelist
        uint256 whiteListSaleStartTime;
        uint256 whitelistSaleEndTime;
        // Token info
        address token; // token being sold
        address raiseToken; // ETH/BNB or ERC20 used to raise
        address owner;
        // Status flags
        bool presaleFilled;
        bool finalized;
        bool cancelled;
        bool presaleFundsWithdrawn;
        bool leftOverTokensWithdrawn;
        // Whitelist
        bool whiteListSale; // @notice applies only for fixed sales
    }

    mapping(uint256 presaleId => Presale) private presale;
    mapping(uint256 presaleId => mapping(address contributor => uint256 contribution))
        private contributed; // funds
    mapping(uint256 presaleId => mapping(address contributor => uint256 amount))
        private claimable; // amount in fixed presale. tokens are computed on contributing
    mapping(uint256 => mapping(address => bool)) private isWhitelisted;
    mapping(address token => uint256 amount) private totalRaisedByToken;
    mapping(uint256 => bool) presaleCounted; // track which presaleIDs have already been counted

    uint256 public totalProjectsRaised; // track total number of projects that have raised on the platform
    uint256 private presaleCounter; // incremented at each presale creation
    address private feeAddress;
    uint16 private maxWhitelistBatch = 100; // default 100, can be updated by owner
    uint8 private platformFee = 2; //@notice fee can be updated up to 10%
    uint8 private constant PRESALE_PULL_OUT_PENALTY_FEE = 2; // @notice fee cannot be changed

    event PresaleCreated(
        address indexed presaleOwner,
        PresaleType presaleType,
        bool whitelistSale,
        uint256 whitelistStartTime,
        uint256 whitelistEndTime,
        uint256 minContribution,
        uint256 maxContribution,
        uint256 startTime,
        uint256 endTime,
        uint256 tokensForSale,
        uint256 hardCap,
        uint256 presaleId
    );
    event ParticipatedInFixedPresale(
        address indexed contributor,
        uint256 presaleId,
        uint256 contribution
    );
    event ParticipatedInDynamicPresale(
        address indexed contributor,
        uint256 presaleId,
        uint256 contribution
    );
    event TokenClaim(
        address indexed contributor,
        uint256 presaleId,
        uint256 tokensClaimed,
        PresaleType presaleType
    );
    event PresaleFinalized(
        uint256 presaleId,
        address indexed owner,
        uint256 tokensSold,
        uint256 amountRaised
    );
    event LeftoverTokensWithdrawn(
        uint256 presaleId,
        address indexed owner,
        uint256 payout,
        uint256 fee
    );
    event Refunded(
        uint256 presaleId,
        address indexed contributor,
        uint256 contributedAmount
    );
    event PresaleFundsWithdrawn(
        uint256 indexed presaleId,
        address indexed owner,
        uint256 payout,
        uint256 fee
    );
    event ContributionWithdrawn(
        address indexed sender,
        uint256 presaleId,
        uint256 contribution
    );
    event PresaleFailed(uint256 presaleId);
    event CancelledPresaleTokensWithdrawn(
        uint256 presaleId,
        address indexed owner,
        uint256 amount
    );
    event WhitelistedAddressesAdded(uint256 presaleId);
    event WhitelistedAddressesRemoved(uint256 presaleId);

    constructor(
        address _initialOwner,
        address _feeAddress
    ) Ownable(_initialOwner) {
        if (_feeAddress == address(0))
            revert ErrorAddressCannotBeZeroAddress();
        feeAddress = _feeAddress;
    }

    function createPresale(
        PresaleType presaleType,
        address tokenAddress,
        address raiseToken,
        uint256 tokensForSale,
        uint256 softCap,
        uint256 hardCap,
        uint256 minContribution,
        uint256 maxContribution,
        uint256 startTimeInMinutes,
        uint256 endTimeInMinutes,
        bool whiteListSale,
        uint256 wlSaleStartTimeInMinutes,
        uint256 wlSaleEndTimeInMinutes
    ) external nonReentrant {
        /// pause incase of emergency
        if (paused()) revert ErrorFunctionalityIsPaused();

        // Convert minutes offset into absolute timestamps
        uint256 startTime = block.timestamp + _minutes(startTimeInMinutes);
        uint256 endTime = block.timestamp + _minutes(endTimeInMinutes);

        // Basic sanity checks
        if (tokenAddress == address(0) || tokensForSale == 0)
            revert ErrorMissingParam();

        if (endTimeInMinutes == 0) revert ErrorInvalidTimeRange();

        if (tokenAddress == raiseToken)
            revert ErrorCannotSellPresaleTokenInSameToken();

        // Validate time range
        if (startTime < block.timestamp) revert ErrorInvalidStart();
        if (endTime <= startTime) revert ErrorInvalidTimeRange();

        // Contribution range validation
        if (minContribution > maxContribution)
            revert ErrorInvalidAmount();

        // Validate presale type and cap logic
        if (presaleType == PresaleType.Fixed) {
            if (softCap > hardCap) revert ErrorInvalidCap();
            if (hardCap == 0) revert ErrorInvalidCap();
        } else if (presaleType == PresaleType.Dynamic) {
            if (softCap == 0) revert ErrorInvalidCap();
            if (hardCap == 0) {
                hardCap = type(uint256).max;
            }
        } else revert ErrorInvalidPresaleType();

        // --- Whitelist sale validation ---
        uint256 wlStart = 0;
        uint256 wlEnd = 0;

        if (whiteListSale) {
            if (presaleType != PresaleType.Fixed) {
                revert ErrorInvalidWlSale();
            }

            wlStart = block.timestamp + _minutes(wlSaleStartTimeInMinutes);
            wlEnd = block.timestamp + _minutes(wlSaleEndTimeInMinutes);

            if (wlStart < startTime) revert ErrorInvalidWlSale();
            if (wlEnd > endTime) revert ErrorInvalidWlSale();
            if (wlEnd <= wlStart) revert ErrorInvalidWlSale();
        }

        // Increment presale counter
        unchecked {
            presaleCounter++;
        }

        uint256 presaleID = presaleCounter;
        address presaleOwner = msg.sender;

        // Initialize presale struct
        Presale storage newPresale = presale[presaleID];
        newPresale.presaleType = presaleType;
        newPresale.token = tokenAddress;
        newPresale.raiseToken = raiseToken;
        newPresale.owner = presaleOwner;
        newPresale.presaleId = presaleID;
        newPresale.tokensForSale = tokensForSale;
        newPresale.tokensSold = 0;
        newPresale.softCap = softCap;
        newPresale.hardCap = hardCap;
        newPresale.minContribution = minContribution;
        newPresale.maxContribution = maxContribution;
        newPresale.startTime = startTime;
        newPresale.endTime = endTime;
        newPresale.amountRaised = 0;
        newPresale.finalized = false;
        newPresale.cancelled = false;
        newPresale.presaleFundsWithdrawn = false;
        newPresale.presaleFilled = false;
        newPresale.leftOverTokensWithdrawn = false;
        newPresale.whiteListSale = whiteListSale;
        newPresale.whiteListSaleStartTime = wlStart;
        newPresale.whitelistSaleEndTime = wlEnd;

        // Transfer presale tokens from owner to contract
        IERC20(tokenAddress).safeTransferFrom(
            presaleOwner,
            address(this),
            tokensForSale
        );

        emit PresaleCreated(
            presaleOwner,
            presaleType,
            whiteListSale,
            wlSaleStartTimeInMinutes,
            wlSaleEndTimeInMinutes,
            minContribution,
            maxContribution,
            startTime,
            endTime,
            tokensForSale,
            hardCap,
            presaleID
        );
    }

    function participateInPresale(
        uint256 presaleId,
        uint256 contribution
    ) external payable nonReentrant {
        /// pause incase of emergency
        if (paused()) revert ErrorFunctionalityIsPaused();

        Presale storage p = presale[presaleId];
        address contributor = msg.sender;

        if (p.owner == address(0)) revert ErrorInvalidPresaleId();

        // Presale active window
        if (block.timestamp < p.startTime || block.timestamp > p.endTime)
            revert ErrorPresaleNotActive();

        uint256 amountIn;
        if (p.raiseToken == address(0)) {
            // Native presale: value must be provided in msg.value
            if (msg.value == 0) revert ErrorInvalidAmount();
            amountIn = msg.value;
        } else {
            // ERC20 presale: caller must not send native value by mistake
            if (msg.value != 0) revert ErrorInvalidMsgValue();
            amountIn = contribution;
            if (amountIn == 0) revert ErrorInvalidAmount();
        }

        // Branch by presale type
        if (p.presaleType == PresaleType.Fixed) {
            // Fixed presale: enforce hardCap and allocate claimable tokens

            // Whitelist enforcement for fixed presales
            if (p.whiteListSale) {
                // Too early: presale not open for anyone yet
                if (block.timestamp < p.whiteListSaleStartTime) {
                    revert ErrorPresaleNotStarted();
                }

                // Within whitelist window: must be whitelisted
                if (
                    block.timestamp >= p.whiteListSaleStartTime &&
                    block.timestamp <= p.whitelistSaleEndTime
                ) {
                    if (!isWhitelisted[presaleId][contributor]) {
                        revert ErrorNotWhitelisted();
                    }
                }

                // After whitelistSaleEndTime: open to everyone, no restriction
            }

            // check if presale already marked as filled
            if (p.presaleFilled) revert ErrorPresaleFilled();

            // Check if presale already full
            if (p.amountRaised >= p.hardCap)
                revert ErrorPresaleFilled();

            // Per-tx minimum
            if (amountIn < p.minContribution)
                revert ErrorInvalidAmount();

            // Per-wallet max check (based on what they'd have after this tx, using requested amount)
            uint256 userTotal = contributed[presaleId][contributor] + amountIn;
            if (userTotal > p.maxContribution)
                revert ErrorExceedsWalletMax();

            // Compute how much we can actually accept (cap remaining)
            uint256 available = p.hardCap - p.amountRaised;
            uint256 take = amountIn > available ? available : amountIn; // accepted amount

            // Transfer funds in for ERC20 only (transfer only the accepted 'take')
            if (p.raiseToken != address(0)) {
                // Pull only the accepted amount; avoids needing to refund ERC20
                IERC20(p.raiseToken).safeTransferFrom(
                    contributor,
                    address(this),
                    take
                );
            }

            // Compute token allocation for the accepted amount
            uint256 tokenAmount = _calculateFixedPresaleAmount(
                take,
                p.tokensForSale,
                p.hardCap
            );

            // Safety cap: ensure tokensSold doesn't exceed tokensForSale
            uint256 newTokensSold = p.tokensSold + tokenAmount;
            if (newTokensSold > p.tokensForSale) {
                // reduce tokenAmount to remaining tokens
                tokenAmount = p.tokensForSale - p.tokensSold;
                newTokensSold = p.tokensForSale;
            }

            // Update state BEFORE performing native refunds or any further external actions
            p.amountRaised += take;
            p.tokensSold = newTokensSold;
            contributed[presaleId][contributor] += take;
            claimable[presaleId][contributor] += tokenAmount;

            // Mark presale filled if we've reached the hard cap
            if (p.amountRaised >= p.hardCap) p.presaleFilled = true;

            // Handle native refund (if any excess sent)
            if (p.raiseToken == address(0) && take < amountIn) {
                uint256 refund = amountIn - take;
                (bool ok, ) = payable(contributor).call{value: refund}("");
                if (!ok) revert ErrorRefundExcessFilled();
            }

            emit ParticipatedInFixedPresale(contributor, presaleId, take);
        } else if (p.presaleType == PresaleType.Dynamic) {
            // Dynamic presale: accept contributions; allocations occur at finalization

            if (amountIn < p.minContribution)
                revert ErrorInvalidAmount();

            uint256 userTotal = contributed[presaleId][contributor] + amountIn;
            if (userTotal > p.maxContribution)
                revert ErrorExceedsWalletMax();

            // For ERC20, pull the full amountIn now
            if (p.raiseToken != address(0)) {
                IERC20(p.raiseToken).safeTransferFrom(
                    contributor,
                    address(this),
                    amountIn
                );
            }

            // Update contributor + global raise
            contributed[presaleId][contributor] = userTotal;
            p.amountRaised += amountIn;

            emit ParticipatedInDynamicPresale(contributor, presaleId, amountIn);
        } else {
            revert ErrorInvalidPresaleType();
        }
    }

    function pullOut(uint256 presaleId) external nonReentrant {
        /// pause encase of emergency
        if (paused()) revert ErrorFunctionalityIsPaused();

        Presale storage p = presale[presaleId];
        address sender = msg.sender;

        if (p.owner == address(0)) revert ErrorInvalidPresaleId();

        // Ensure presale is still active
        if (block.timestamp > p.endTime) revert ErrorPresaleNotActive();

        // Disallow pull-out if softCap already reached
        if (p.amountRaised >= p.softCap) revert ErrorSoftCapReached();

        uint256 contribution = contributed[presaleId][sender];

        // Verify contributor has a valid contribution
        if (contribution == 0) revert ErrorInvalidAmount();

        // Reset contributor's state before transfers (reentrancy safe)
        contributed[presaleId][sender] = 0;

        // For Fixed presales, reset claimable tokens too
        if (p.presaleType == PresaleType.Fixed) {
            claimable[presaleId][sender] = 0;
        }

        // Reduce total raised amount
        p.amountRaised -= contribution;

        // Calculate penalty & refund
        uint256 fee = (contribution * PRESALE_PULL_OUT_PENALTY_FEE) / 100;
        uint256 refund = contribution - fee;

        if (p.raiseToken == address(0)) {
            // Refund native token (ETH/BNB/etc.)
            (bool ok, ) = payable(feeAddress).call{value: fee}(
                ""
            );
            if (!ok) revert ErrorRefundFailed();

            (ok, ) = payable(sender).call{value: refund}("");
            if (!ok) revert ErrorRefundFailed();
        } else {
            // Refund ERC20 token
            IERC20(p.raiseToken).safeTransfer(feeAddress, fee);
            IERC20(p.raiseToken).safeTransfer(sender, refund);
        }
        // Emit contribution withdrawal details
        emit ContributionWithdrawn(sender, presaleId, refund);
    }

    function claimRefund(uint256 presaleId) external nonReentrant {
        /// pause incase of emergency
        if (paused()) revert ErrorFunctionalityIsPaused();

        Presale storage p = presale[presaleId];
        address contributor = msg.sender;

        if (p.owner == address(0)) revert ErrorInvalidPresaleId();

        // Presale must have failed (cancelled by finalize logic)
        if (!p.cancelled) revert ErrorPresaleNotFailed();

        uint256 contributedAmount = contributed[presaleId][contributor];
        // Check that the caller has a refundable contribution
        if (contributedAmount == 0) revert ErrorInvalidAmount();

        // Reset contributed amount before transferring to prevent reentrancy
        contributed[presaleId][contributor] = 0;

        if (p.raiseToken == address(0)) {
            // Refund native token (e.g. ETH/BNB)
            (bool ok, ) = payable(contributor).call{value: contributedAmount}(
                ""
            );
            if (!ok) revert ErrorRefundFailed();
        } else {
            // Refund ERC20 token
            IERC20(p.raiseToken).safeTransfer(contributor, contributedAmount);
        }
        // Log refund details
        emit Refunded(presaleId, contributor, contributedAmount);
    }

    function claimTokens(uint256 presaleId) external nonReentrant {
        /// pause incase of emergency
        if (paused()) revert ErrorFunctionalityIsPaused();

        Presale storage p = presale[presaleId];
        address sender = msg.sender;

        if (p.owner == address(0)) revert ErrorInvalidPresaleId();

        // Presale must be successfully finalized
        if (!p.finalized) revert ErrorPresaleNotFinalized();
        if (p.cancelled) revert ErrorPresaleFailed();

        if (p.presaleType == PresaleType.Fixed) {
            // --- Fixed Presale Allocation ---

            // Get pre-computed owed tokens
            uint256 amount = claimable[presaleId][sender];

            if (amount == 0) revert ErrorInvalidAmount();

            // Reset balances before transfer
            claimable[presaleId][sender] = 0;
            contributed[presaleId][sender] = 0;

            // Transfer owed tokens
            IERC20(p.token).safeTransfer(sender, amount);

            emit TokenClaim(sender, presaleId, amount, p.presaleType);
        } else if (p.presaleType == PresaleType.Dynamic) {
            // --- Dynamic Presale Allocation ---

            uint256 contribution = contributed[presaleId][sender];

            if (contribution == 0) revert ErrorInvalidAmount();

            // Reset contribution before calculation
            contributed[presaleId][sender] = 0;

            // Calculate proportional token allocation
            uint256 amount = _calculateDynamicAllocation(
                contribution,
                p.amountRaised,
                p.tokensForSale
            );
            if (amount == 0) revert ErrorInvalidAmount();

            // Safety check: ensure not exceeding total tokens for sale
            if (p.tokensSold + amount > p.tokensForSale) {
                amount = p.tokensForSale - p.tokensSold;
            }

            // Transfer allocated tokens
            IERC20(p.token).safeTransfer(sender, amount);

            emit TokenClaim(sender, presaleId, amount, p.presaleType);
        } else revert ErrorInvalidPresaleType();
    }

    function withdrawTokensOnCancelledPresale(
        uint256 presaleId
    ) external nonReentrant {
        /// pause incase of emergency
        if (paused()) revert ErrorFunctionalityIsPaused();

        Presale storage p = presale[presaleId];
        address owner = msg.sender;

        if (p.owner == address(0)) revert ErrorInvalidPresaleId();

        // Must be a cancelled presale (failed)
        if (!p.cancelled) revert ErrorNotCancelledPresale();

        // Only the presale owner can recover the tokens
        if (owner != p.owner) revert ErrorUnAuthorized();

        // Amount to withdraw is the full escrowed sale allocation
        uint256 amount = p.tokensForSale;
        if (amount == 0) revert ErrorInvalidAmount();

        // Mark-before-interaction for idempotency & reentrancy posture
        p.tokensForSale = 0;

        // Transfer tokens back to the owner
        IERC20(p.token).safeTransfer(owner, amount);

        emit CancelledPresaleTokensWithdrawn(presaleId, owner, amount);
    }

    function finalizePresale(uint256 presaleId) external nonReentrant {
        /// pause incase of emergency
        if (paused()) revert ErrorFunctionalityIsPaused();

        Presale storage p = presale[presaleId];
        address caller = msg.sender;

        if (p.owner == address(0)) revert ErrorInvalidPresaleId();

        // Cannot finalize while presale is still running
        if (block.timestamp <= p.endTime) {
            revert ErrorPresaleStillActive();
        }

        // Prevent re-finalization or double cancellation
        if (p.finalized || p.cancelled) {
            revert ErrorAlreadyFinalized();
        }

        // Case 1: Presale successful + within 24hr grace period
        if (
            block.timestamp > p.endTime &&
            p.amountRaised >= p.softCap && // successful presale
            block.timestamp - p.endTime <= 1 days && // within 24hr window
            p.owner == caller // only owner can finalize in this period
        ) {
            /// presale is successful and time passed after presale is not upto 24hrs
            /// in this case only dev can finalize the presale in the giving time frame
            p.finalized = true;
            emit PresaleFinalized(
                p.presaleId,
                p.owner,
                p.tokensSold,
                p.amountRaised
            );
        }
        // Case 2: Presale successful + after 24hr grace period
        else if (
            block.timestamp > p.endTime &&
            p.amountRaised >= p.softCap && // successful presale
            block.timestamp - p.endTime > 1 days // 24hrs passed
        ) {
            // Now anyone can finalize
            p.finalized = true;
            emit PresaleFinalized(
                p.presaleId,
                p.owner,
                p.tokensSold,
                p.amountRaised
            );
        }
        // Case 3: Presale failed (softCap not reached)
        else if (block.timestamp > p.endTime && p.amountRaised < p.softCap) {
            // Mark as cancelled, contributors will later withdraw refunds
            p.cancelled = true;
            emit PresaleFailed(p.presaleId);
        }
        // Fallback: Any unauthorized attempt
        else revert ErrorUnAuthorized();
    }

    function withdrawPresaleFunds(uint256 presaleId) external nonReentrant {
        /// pause incase of emergency
        if (paused()) revert ErrorFunctionalityIsPaused();

        Presale storage p = presale[presaleId];

        if (p.owner == address(0)) revert ErrorInvalidPresaleId();

        // Ensure presale has been finalized before withdrawal
        if (!p.finalized) revert ErrorPresaleNotFinalized();

        // Prevent multiple withdrawals
        if (p.presaleFundsWithdrawn)
            revert ErrorFundsAlreadyWithdrawn();

        // Only presale owner can withdraw
        if (msg.sender != p.owner) revert ErrorUnAuthorized();

        // Mark as withdrawn before transfer to prevent reentrancy
        p.presaleFundsWithdrawn = true;

        // Calculate amounts
        uint256 amount = p.amountRaised;

        // record total raised in currency
        totalRaisedByToken[p.raiseToken] += amount;

        uint256 fee = (amount * platformFee) / 100; // platform fee %
        uint256 payout = amount - fee; // remaining amount to owner

        // prevent double counting
        if (!presaleCounted[presaleId]) {
            /// count total number of projects that have raise on the platform
            totalProjectsRaised++;
            presaleCounted[presaleId] = true;
        }

        if (p.raiseToken == address(0)) {
            // Native token withdrawal (e.g. ETH/BNB)
            (bool ok1, ) = payable(feeAddress).call{value: fee}("");
            if (!ok1) revert ErrorWithdrawFailed();
            (bool ok2, ) = payable(p.owner).call{value: payout}("");
            if (!ok2) revert ErrorWithdrawFailed();
        } else {
            // ERC20 token withdrawal
            IERC20(p.raiseToken).safeTransfer(feeAddress, fee);
            IERC20(p.raiseToken).safeTransfer(p.owner, payout);
        }

        // Log withdrawal details
        emit PresaleFundsWithdrawn(p.presaleId, p.owner, payout, fee);
    }

    function withdrawLeftOverTokens(uint256 presaleId) external nonReentrant {
        /// pause incase of emergency
        if (paused()) revert ErrorFunctionalityIsPaused();

        Presale storage p = presale[presaleId];

        if (p.owner == address(0)) revert ErrorInvalidPresaleId();

        // Validate conditions
        if (
            block.timestamp <= p.endTime || // presale must be over
            p.tokensSold >= p.tokensForSale || // no leftovers
            !p.finalized || // must be finalized
            p.presaleType != PresaleType.Fixed || // only fixed presale supported
            p.leftOverTokensWithdrawn // cannot withdraw twice
        ) revert ErrorUnAuthorized();

        // Calculate leftovers
        uint256 leftover = p.tokensForSale - p.tokensSold;
        if (leftover == 0) revert ErrorNoLeftover();

        // Mark before transfers (reentrancy-safe)
        p.leftOverTokensWithdrawn = true;

        // Split leftover: platform fee + owner payout
        uint256 fee = (leftover * platformFee) / 100;
        uint256 payout = leftover - fee;

        // Transfer tokens
        IERC20(p.token).safeTransfer(feeAddress, fee);
        IERC20(p.token).safeTransfer(p.owner, payout);

        emit LeftoverTokensWithdrawn(p.presaleId, p.owner, payout, fee);
    }

    function _calculateFixedPresaleAmount(
        uint256 contribution,
        uint256 tokensForSale,
        uint256 hardCap
    ) internal pure returns (uint256) {
        return (contribution * tokensForSale) / hardCap;
    }

    function _calculateDynamicAllocation(
        uint256 userContribution,
        uint256 totalRaised,
        uint256 tokensForSale
    ) internal pure returns (uint256) {
        if (totalRaised == 0) return 0;
        return (userContribution * tokensForSale) / totalRaised;
    }

    function _minutes(uint256 m) internal pure returns (uint256) {
        return m * 1 minutes; // same as m * 60
    }

    function setPlatformFee(uint8 newPlatformFee) external onlyOwner {
        if (newPlatformFee > 10) revert ErrorFeeTooHigh(newPlatformFee);
        platformFee = newPlatformFee;
    }

    function setFeeAddress(address newFeeAddress) external onlyOwner {
        if (newFeeAddress == address(0))
            revert ErrorAddressCannotBeZeroAddress();
        feeAddress = newFeeAddress;
    }

    function setMaxWhitelistBatch(uint16 newMax) external onlyOwner {
        if (newMax == 0) revert ErrorInvalidNumber(newMax);
        maxWhitelistBatch = newMax;
    }

    function addToWhitelist(
        uint256 presaleId,
        address[] calldata whitelistedAddresses
    ) external {
        Presale storage p = presale[presaleId];

        if (msg.sender != p.owner) revert ErrorUnAuthorized();
        if (!p.whiteListSale) revert ErrorNotWhitelistSale();

        if (block.timestamp > p.whitelistSaleEndTime)
            revert ErrorWhitelistNotActive();

        uint256 addressLength = whitelistedAddresses.length;

        if (addressLength > maxWhitelistBatch)
            revert ErrorBatchExceedsMaxAllowed(maxWhitelistBatch);

        // Push new addresses
        for (uint256 i = 0; i < addressLength; i++) {
            address user = whitelistedAddresses[i];
            if (user == address(0)) continue; // skip invalid

            // Avoid duplicates if using array
            if (!isWhitelisted[presaleId][user]) {
                isWhitelisted[presaleId][user] = true;
            }
        }

        emit WhitelistedAddressesAdded(presaleId);
    }

    function removeFromWhitelist(
        uint256 presaleId,
        address[] calldata addressesToRemove
    ) external {
        Presale storage p = presale[presaleId];

        if (msg.sender != p.owner) revert ErrorUnAuthorized();
        if (!p.whiteListSale) revert ErrorNotWhitelistSale();
        if (block.timestamp > p.whitelistSaleEndTime)
            revert ErrorWhitelistNotActive();

        uint256 length = addressesToRemove.length;
        if (length > maxWhitelistBatch)
            revert ErrorBatchExceedsMaxAllowed(maxWhitelistBatch);

        for (uint256 i = 0; i < length; i++) {
            address user = addressesToRemove[i];
            if (user == address(0)) continue; // skip invalid

            if (isWhitelisted[presaleId][user]) {
                isWhitelisted[presaleId][user] = false;
            }
        }

        emit WhitelistedAddressesRemoved(presaleId);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
