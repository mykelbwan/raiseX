// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

error RaiseX__ErrorMissingParam();
error RaiseX__ErrorInvalidPresaleId();
error RaiseX__ErrorPresaleFilled();
error RaiseX__ErrorInvalidAmount();
error RaiseX__ErrorInvalidMsgValue();
error RaiseX__ErrorRefundExcessFilled();
error RaiseX__ErrorPresaleNotActive();
error RaiseX__ErrorExceedsWalletMax();
error RaiseX__ErrorInvalidCap();
error RaiseX__ErrorInvalidStart();
error RaiseX__ErrorInvalidTimeRange();
error RaiseX__ErrorInvalidPresaleType();
error RaiseX__ErrorUnAuthorized();
error RaiseX__ErrorNotAFixedPresale();
error ErrorNoLeftover();
error RaiseX__ErrorFeeTooHigh(uint8);
error RaiseX__ErrorAddressCannotBeZeroAddress();
error RaiseX__ErrorPresaleNotFinalized();
error RaiseX__ErrorFundsAlreadyWithdrawn();
error RaiseX__ErrorPresaleStillActive();
error RaiseX__ErrorPresaleFailed();
error RaiseX__ErrorWithdrawFailed();
error RaiseX__ErrorAlreadyFinalized();
error RaiseX__ErrorPresaleNotFailed();
error RaiseX__ErrorRundFailed();
error RaiseX__ErrorSoftCapReached();
error RaiseX__ErrorCannotSellPresaleTokenInSameToken();
error RaiseX__ErrorNotCancelledPresale();

contract RaiseX is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum PresaleType {
        Fixed,
        Dynamic
    }

    struct Presale {
        PresaleType presaleType;
        address token; // token being sold
        address raiseToken; // ETH/BNB or ERC20 used to raise
        address owner;
        uint256 presaleId;
        // Sale params
        uint256 tokensForSale;
        uint256 tokensSold;
        uint256 softCap;
        uint256 hardCap;
        uint256 minContribution;
        uint256 maxContribution;
        uint256 startTime;
        uint256 endTime;
        uint256 amountRaised;
        // Status
        bool presaleFilled;
        bool finalized;
        bool cancelled;
        bool presaleFundsWithdrawn;
        bool leftOverTokensWithdrawn;
    }

    mapping(uint256 presaleId => Presale) private presale;
    mapping(uint256 presaleId => mapping(address contributor => uint256 contribution))
        private contributed; // funds
    mapping(uint256 presaleId => mapping(address contributor => uint256 claimedAmountInFixedPresaleCauseTokensAreComputedOnTheSpot))
        private claimable; // tokens

    event PresaleCreated(
        address indexed presaleOwner,
        PresaleType presaleType,
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

    address private feeAddress;
    address private pullOutPenaltyFeeAddress;
    uint256 private presaleCounter;
    uint8 private platformFee = 2; //@notice fee can be updated up to 10%
    uint8 private constant PRESALE_PULL_OUT_PENALTY_FEE = 2; // @notice fee cannot be changed

    constructor(
        address _initialOwner,
        address _feeAddress,
        address _pullOutPenaltyAddress
    ) Ownable(_initialOwner) {
        if (_feeAddress == address(0) || _pullOutPenaltyAddress == address(0))
            revert RaiseX__ErrorAddressCannotBeZeroAddress();
        feeAddress = _feeAddress;
        pullOutPenaltyFeeAddress = _pullOutPenaltyAddress;
    }

    /**
     * @notice Creates a new presale with specified parameters.
     * @dev
     * - Supports both Fixed and Dynamic presale types.
     * - Tokens to be sold are transferred from the presale owner to the contract at creation.
     * - Uses `_minutes()` helper to convert relative start/end times (in minutes) to absolute timestamps.
     *
     * @param presaleType The type of presale:
     *        - Fixed: Allocation is proportional to the contribution relative to hardCap.
     *        - Dynamic: Allocation is proportional to the total raise (no fixed cap needed).
     * @param tokenAddress The ERC20 token address being sold in the presale.
     * @param raiseToken The token accepted for contributions.
     *        - `address(0)` for native ETH/BNB/etc.
     *        - ERC20 address otherwise.
     * @param tokensForSale Total number of tokens deposited into the contract for the presale.
     * @param softCap Minimum raise threshold required for presale to succeed.
     * @param hardCap Maximum raise limit. For Fixed presale this is mandatory > 0. For Dynamic, can be zero (treated as uncapped).
     * @param minContribution Minimum contribution per wallet.
     * @param maxContribution Maximum contribution per wallet.
     * @param startTimeInMinutes Delay in minutes from current block timestamp until presale starts.
     * @param endTimeInMinutes Delay in minutes from current block timestamp until presale ends.
     *
     * Emits a {PresaleCreated} event after successful creation.
     */
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
        uint256 endTimeInMinutes
    ) external nonReentrant {
        // Convert minutes offset into absolute timestamps
        uint256 startTime = block.timestamp + _minutes(startTimeInMinutes);
        uint256 endTime = block.timestamp + _minutes(endTimeInMinutes);

        // Basic sanity checks
        if (tokenAddress == address(0) || tokensForSale == 0)
            revert RaiseX__ErrorMissingParam();
        if (endTimeInMinutes == 0) revert RaiseX__ErrorInvalidTimeRange();
        if (tokenAddress == raiseToken)
            revert RaiseX__ErrorCannotSellPresaleTokenInSameToken();

        // Validate time range
        if (startTime < block.timestamp) revert RaiseX__ErrorInvalidStart();
        if (endTime <= startTime) revert RaiseX__ErrorInvalidTimeRange();

        // Contribution range validation
        if (minContribution > maxContribution)
            revert RaiseX__ErrorInvalidAmount();

        // Validate presale type and cap logic
        if (presaleType == PresaleType.Fixed) {
            // HardCap must exist and must be >= softCap
            if (softCap > hardCap) revert RaiseX__ErrorInvalidCap();
            if (hardCap == 0) revert RaiseX__ErrorInvalidCap();
        } else if (presaleType == PresaleType.Dynamic) {
            // Dynamic presale must have a softCap
            if (softCap == 0) revert RaiseX__ErrorInvalidCap();
            // If hardCap not set, default to max uint256 (uncapped)
            if (hardCap == 0) {
                hardCap = type(uint256).max;
            }
        } else revert RaiseX__ErrorInvalidPresaleType();

        // Increment presale counter and assign new ID
        presaleCounter++;
        uint256 presaleID = presaleCounter;
        address presaleOwner = msg.sender;

        // Initialize presale struct
        Presale memory newPresale = Presale({
            presaleType: presaleType,
            token: tokenAddress,
            raiseToken: raiseToken,
            owner: presaleOwner,
            presaleId: presaleID,
            tokensForSale: tokensForSale,
            tokensSold: 0,
            softCap: softCap,
            hardCap: hardCap,
            minContribution: minContribution,
            maxContribution: maxContribution,
            startTime: startTime,
            endTime: endTime,
            amountRaised: 0,
            finalized: false,
            cancelled: false,
            presaleFundsWithdrawn: false,
            presaleFilled: false,
            leftOverTokensWithdrawn: false
        });

        // Transfer presale tokens from owner into contract for escrow
        IERC20(tokenAddress).safeTransferFrom(
            presaleOwner,
            address(this),
            tokensForSale
        );

        // Store presale
        presale[presaleID] = newPresale;

        // Emit creation event
        emit PresaleCreated(
            presaleOwner,
            presaleType,
            tokensForSale,
            hardCap,
            presaleID
        );
    }

    /**
     * @notice Participate in an active presale by contributing funds (native token or ERC20).
     *
     * @dev Behaviour summary:
     *  - Accepts either native token (msg.value) if `p.raiseToken == address(0)` OR an ERC20 `contribution`
     *    when `p.raiseToken != address(0)`. Mixing is not allowed (msg.value must be 0 for ERC20 presales).
     *  - Enforces per-tx `minContribution` and per-wallet `maxContribution`.
     *  - Fixed presale:
     *      - Enforces a global `hardCap`. Only `take = min(amountIn, hardCap - amountRaised)` is accepted.
     *      - For ERC20 presales we pull `take` from the caller (no refund needed).
     *      - For native presales, the caller must send `msg.value`; any excess (`amountIn - take`)
     *        is refunded immediately.
     *      - Token allocation is computed as: `(take * tokensForSale) / hardCap` and added to `claimable`.
     *      - `tokensSold` is updated and cannot exceed `tokensForSale`.
     *      - If `amountRaised` reaches `hardCap`, `p.presaleFilled` is set to true.
     *  - Dynamic presale:
     *      - Only tracks contributions (`contributed`) and `amountRaised`. Allocation happens later.
     *
     * Security & checks:
     *  - Presale must be active: `startTime <= block.timestamp <= endTime`
     *  - Caller must respect min/max contribution rules
     *  - For ERC20: we perform `safeTransferFrom` only for the accepted amount (take)
     *  - Function is marked `nonReentrant` already (caller must ensure modifier is present)
     *
     * @param presaleId The presale identifier.
     * @param contribution For ERC20 presales: amount to contribute. Ignored for native presales (use msg.value).
     *
     * Emits:
     *  - `ParticipatedInFixedPresale(contributor, presaleId, acceptedAmount)` for Fixed
     *  - `ParticipatedInDynamicPresale(contributor, presaleId, amountIn)` for Dynamic
     */
    function participateInPresale(
        uint256 presaleId,
        uint256 contribution
    ) external payable nonReentrant {
        Presale storage p = presale[presaleId];
        address contributor = msg.sender;

        if (p.owner == address(0)) revert RaiseX__ErrorInvalidPresaleId();

        // ---------- 1) Presale active window ----------
        if (block.timestamp < p.startTime || block.timestamp > p.endTime)
            revert RaiseX__ErrorPresaleNotActive();

        // ---------- 2) Normalize input amounts & basic validation ----------
        uint256 amountIn;
        if (p.raiseToken == address(0)) {
            // Native presale: value must be provided in msg.value
            if (msg.value == 0) revert RaiseX__ErrorInvalidAmount();
            amountIn = msg.value;
        } else {
            // ERC20 presale: caller must not send native value by mistake
            if (msg.value != 0) revert RaiseX__ErrorInvalidMsgValue();
            amountIn = contribution;
            if (amountIn == 0) revert RaiseX__ErrorInvalidAmount();
        }

        // ---------- 3) Branch by presale type ----------
        if (p.presaleType == PresaleType.Fixed) {
            // --- Fixed presale: enforce hardCap and allocate claimable tokens ---

            // check if presale already marked as filled
            if (p.presaleFilled) revert RaiseX__ErrorPresaleFilled();

            // Check if presale already full
            if (p.amountRaised >= p.hardCap)
                revert RaiseX__ErrorPresaleFilled();

            // Per-tx minimum
            if (amountIn < p.minContribution)
                revert RaiseX__ErrorInvalidAmount();

            // Per-wallet max check (based on what they'd have after this tx, using requested amount)
            uint256 userTotal = contributed[presaleId][contributor] + amountIn;
            if (userTotal > p.maxContribution)
                revert RaiseX__ErrorExceedsWalletMax();

            // Compute how much we can actually accept (cap remaining)
            uint256 available = p.hardCap - p.amountRaised;
            uint256 take = amountIn > available ? available : amountIn; // accepted amount

            // --- Transfer funds in for ERC20 only (transfer only the accepted 'take') ---
            if (p.raiseToken != address(0)) {
                // Pull only the accepted amount; avoids needing to refund ERC20
                IERC20(p.raiseToken).safeTransferFrom(
                    contributor,
                    address(this),
                    take
                );
            }

            // --- Compute token allocation for the accepted amount ---
            uint256 tokenAmount = calculateFixedPresaleAmount(
                take,
                p.tokensForSale,
                p.hardCap
            );

            // Safety cap: ensure tokensSold doesn't exceed tokensForSale (handle rounding)
            uint256 newTokensSold = p.tokensSold + tokenAmount;
            if (newTokensSold > p.tokensForSale) {
                // reduce tokenAmount to remaining tokens (defensive)
                tokenAmount = p.tokensForSale - p.tokensSold;
                newTokensSold = p.tokensForSale;
            }

            // ---------- 4) Update state BEFORE performing native refunds or any further external actions ----------
            p.amountRaised += take;
            p.tokensSold = newTokensSold;
            contributed[presaleId][contributor] += take;
            claimable[presaleId][contributor] += tokenAmount;

            // Mark presale filled if we've reached the hard cap
            if (p.amountRaised >= p.hardCap) p.presaleFilled = true;

            // ---------- 5) Handle native refund (if any excess sent) ----------
            if (p.raiseToken == address(0) && take < amountIn) {
                uint256 refund = amountIn - take;
                (bool ok, ) = payable(contributor).call{value: refund}("");
                if (!ok) revert RaiseX__ErrorRefundExcessFilled();
            }

            emit ParticipatedInFixedPresale(contributor, presaleId, take);
        } else if (p.presaleType == PresaleType.Dynamic) {
            // --- Dynamic presale: accept contributions; allocations occur at finalization ---

            if (amountIn < p.minContribution)
                revert RaiseX__ErrorInvalidAmount();

            uint256 userTotal = contributed[presaleId][contributor] + amountIn;
            if (userTotal > p.maxContribution)
                revert RaiseX__ErrorExceedsWalletMax();

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
            revert RaiseX__ErrorInvalidPresaleType();
        }
    }

    /**
     * @notice Allows contributors to withdraw (pull out) their contribution
     *         before the presale ends *and* before the softCap is reached.
     *
     * Rules:
     * - Can only be called while presale is active (`block.timestamp < endTime`).
     * - Not allowed once the softCap is reached or exceeded.
     * - Caller must have a non-zero contribution.
     * - Contribution balance is reset to 0 before transfer to prevent reentrancy.
     *
     * Behavior:
     * - Deducts a penalty fee (percentage of contribution).
     *      this is intentional to discourage people from over using it
     * - Refunds remaining contribution (`contribution - fee`) back to contributor.
     * - Penalty fee is sent to `pullOutPenaltyFeeAddress`.
     * - In `Fixed` presale type, resets claimable token allocation to zero.
     * - Updates `amountRaised` by subtracting the contributor’s amount.
     *
     * Supports:
     * - Native token refunds (via `.call`).
     * - ERC20 refunds (via `safeTransfer`).
     *
     * Emits:
     * - `ContributionWithdrawn(contributor, presaleId, refund)` after successful pull-out.
     */

    function pullOut(uint256 presaleId) external nonReentrant {
        Presale storage p = presale[presaleId];
        address sender = msg.sender;

        if (p.owner == address(0)) revert RaiseX__ErrorInvalidPresaleId();

        // Ensure presale is still active
        if (block.timestamp > p.endTime) revert RaiseX__ErrorPresaleNotActive();

        // Disallow pull-out if softCap already reached
        if (p.amountRaised >= p.softCap) revert RaiseX__ErrorSoftCapReached();

        uint256 contribution = contributed[presaleId][sender];

        // Verify contributor has a valid contribution
        if (contribution == 0) revert RaiseX__ErrorInvalidAmount();

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
            (bool ok, ) = payable(pullOutPenaltyFeeAddress).call{value: fee}(
                ""
            );
            (ok, ) = payable(sender).call{value: refund}("");
            if (!ok) revert RaiseX__ErrorRundFailed();
        } else {
            // Refund ERC20 token
            IERC20(p.raiseToken).safeTransfer(pullOutPenaltyFeeAddress, fee);
            IERC20(p.raiseToken).safeTransfer(sender, refund);
        }
        // Emit contribution withdrawal details
        emit ContributionWithdrawn(sender, presaleId, refund);
    }

    /**
     * @notice Allows contributors to claim a refund if the presale failed.
     *
     * Rules:
     * - Presale must have been marked as failed (`p.cancelled == true`).
     * - Caller must have contributed a non-zero amount.
     * - Refund can only be claimed once per contributor (contribution is reset to 0).
     *
     * Behavior:
     * - Refunds the exact contributed amount (either in native token or ERC20).
     * - Uses `.call` for native tokens (e.g. ETH/BNB).
     * - Uses `safeTransfer` for ERC20 tokens.
     *
     * Security:
     * - Contribution balance is set to zero *before* transfer to prevent reentrancy.
     *
     * Emits:
     * - `Refunded(presaleId, contributor, amount)` when refund is successful.
     */

    function claimRefund(uint256 presaleId) external nonReentrant {
        Presale storage p = presale[presaleId];
        address contributor = msg.sender;

        if (p.owner == address(0)) revert RaiseX__ErrorInvalidPresaleId();

        // Presale must have failed (cancelled by finalize logic)
        if (!p.cancelled) revert RaiseX__ErrorPresaleNotFailed();

        uint256 contributedAmount = contributed[presaleId][contributor];
        // Check that the caller has a refundable contribution
        if (contributedAmount == 0) revert RaiseX__ErrorInvalidAmount();

        // Reset contributed amount before transferring to prevent reentrancy
        contributed[presaleId][contributor] = 0;

        if (p.raiseToken == address(0)) {
            // Refund native token (e.g. ETH/BNB)
            (bool ok, ) = payable(contributor).call{value: contributedAmount}(
                ""
            );
            if (!ok) revert RaiseX__ErrorRundFailed();
        } else {
            // Refund ERC20 token
            IERC20(p.raiseToken).safeTransfer(contributor, contributedAmount);
        }
        // Log refund details
        emit Refunded(presaleId, contributor, contributedAmount);
    }

    /**
     * @notice Allows contributors to claim their purchased tokens after a successful presale.
     *
     * Rules:
     * - Presale must be finalized.
     * - Presale must not be cancelled (i.e. it must have succeeded).
     * - Claimable tokens are determined by presale type:
     *
     *   Fixed Presale:
     *     - Each contributor has a pre-computed allocation stored in `claimable`.
     *     - Tokens are transferred directly from this claimable balance.
     *
     *   Dynamic Presale:
     *     - Allocation is calculated based on the contributor’s share of the total raise
     *       (`contribution / amountRaised * tokensForSale`).
     *     - Ensures no more than `tokensForSale` are distributed.
     *
     * Security:
     * - Contributor balances are reset before transfers to prevent reentrancy.
     *
     * Emits:
     * - `TokenClaim(contributor, presaleId, amount, presaleType)` upon successful claim.
     */

    function claimTokens(uint256 presaleId) external nonReentrant {
        Presale storage p = presale[presaleId];
        address sender = msg.sender;

        if (p.owner == address(0)) revert RaiseX__ErrorInvalidPresaleId();

        // Presale must be successfully finalized
        if (!p.finalized) revert RaiseX__ErrorPresaleNotFinalized();
        if (p.cancelled) revert RaiseX__ErrorPresaleFailed();

        if (p.presaleType == PresaleType.Fixed) {
            // --- Fixed Presale Allocation ---

            // Get pre-computed owed tokens
            uint256 amount = claimable[presaleId][sender];

            if (amount == 0) revert RaiseX__ErrorInvalidAmount();

            // Reset balances before transfer
            claimable[presaleId][sender] = 0;
            contributed[presaleId][sender] = 0;

            // Transfer owed tokens
            IERC20(p.token).safeTransfer(sender, amount);

            emit TokenClaim(sender, presaleId, amount, p.presaleType);
        } else if (p.presaleType == PresaleType.Dynamic) {
            // --- Dynamic Presale Allocation ---

            uint256 contribution = contributed[presaleId][sender];

            if (contribution == 0) revert RaiseX__ErrorInvalidAmount();

            // Reset contribution before calculation
            contributed[presaleId][sender] = 0;

            // Calculate proportional token allocation
            uint256 amount = calculateDynamicAllocation(
                contribution,
                p.amountRaised,
                p.tokensForSale
            );
            if (amount == 0) revert RaiseX__ErrorInvalidAmount();

            // Safety check: ensure not exceeding total tokens for sale
            if (p.tokensSold + amount > p.tokensForSale) {
                amount = p.tokensForSale - p.tokensSold;
            }

            // Transfer allocated tokens
            IERC20(p.token).safeTransfer(sender, amount);

            emit TokenClaim(sender, presaleId, amount, p.presaleType);
        } else revert RaiseX__ErrorInvalidPresaleType();
    }

    /**
     * @notice Allows the presale owner to recover all escrowed sale tokens
     *         after the presale has been cancelled (i.e., it failed).
     *
     * @dev Rules & behavior
     * - Preconditions:
     *   - The presale must be marked as cancelled (`p.cancelled == true`).
     *   - The presale window must have ended (`block.timestamp >= p.endTime`).
     *   - Only the presale owner may call this function.
     *
     * - Amount:
     *   - Returns the full `tokensForSale` that were deposited at creation time.
     *   - In a cancelled presale, no tokens are distributed to contributors,
     *     so the contract should still hold the entire sale allocation.
     *
     * - Security:
     *   - Marks state **before** external token transfers (`p.tokensForSale = 0`)
     *     to make the function idempotent and to prevent reentrancy surprises.
     *   - The function is `nonReentrant` and uses `safeTransfer`.
     *
     * - Accounting note:
     *   - We intentionally do **not** subtract `tokensSold` here. In a failed/cancelled
     *     presale, contributors claim refunds of the raise token and never receive sale tokens.
     *     Therefore, the entire sale allocation is returned to the owner.
     *
     * Emits:
     * - `CancelledPresaleTokensWithdrawn(presaleId, owner, amount)` upon success.
     */
    function withdrawTokensOnCancelledPresale(
        uint256 presaleId
    ) external nonReentrant {
        Presale storage p = presale[presaleId];
        address owner = msg.sender;

        if (p.owner == address(0)) revert RaiseX__ErrorInvalidPresaleId();

        // Must be a cancelled presale (failed)
        if (!p.cancelled) revert RaiseX__ErrorNotCancelledPresale();

        // Only the presale owner can recover the tokens
        if (owner != p.owner) revert RaiseX__ErrorUnAuthorized();

        // Amount to withdraw is the full escrowed sale allocation
        uint256 amount = p.tokensForSale;
        if (amount == 0) revert RaiseX__ErrorInvalidAmount();

        // Mark-before-interaction for idempotency & reentrancy posture
        p.tokensForSale = 0;

        // Transfer tokens back to the owner
        IERC20(p.token).safeTransfer(owner, amount);

        emit CancelledPresaleTokensWithdrawn(presaleId, owner, amount);
    }

    /**
     * @notice Finalize a presale after it has ended.
     *
     * Rules:
     * - Only executable after the presale end time has passed.
     * - If the presale is successful (amountRaised >= softCap):
     *    - Presale owner has a 24hr grace period to finalize it.
     *    - After 24hrs, anyone can finalize on behalf of the owner.
     * - If the presale fails (amountRaised < softCap):
     *    - Anyone can cancel the presale, allowing contributors to claim refunds.
     *
     * Important:
     * - Raised funds are *always* only claimable by the presale owner.
     * - A presale can only be finalized or cancelled once.
     */

    function finalizePresale(uint256 presaleId) external nonReentrant {
        Presale storage p = presale[presaleId];
        address caller = msg.sender;

        if (p.owner == address(0)) revert RaiseX__ErrorInvalidPresaleId();

        // Cannot finalize while presale is still running
        if (block.timestamp <= p.endTime) {
            revert RaiseX__ErrorPresaleStillActive();
        }

        // Prevent re-finalization or double cancellation
        if (p.finalized || p.cancelled) {
            revert RaiseX__ErrorAlreadyFinalized();
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
        else revert RaiseX__ErrorUnAuthorized();
    }

    /**
     * @notice Allows the presale owner to withdraw raised funds after presale finalization.
     *
     * Rules:
     * - Presale must be finalized before funds can be withdrawn.
     * - Only the presale owner can call this function.
     * - Funds can only be withdrawn once.
     * - Platform fee is deducted and sent to `feeAddress`.
     * - Remaining funds are transferred to the presale owner.
     *
     * Supports:
     * - Native token (e.g. ETH/BNB): sent using `.call`.
     * - ERC20 tokens: sent using `safeTransfer`.
     *
     * Emits:
     * - `PresaleFundsWithdrawn(presaleId, owner, payout, fee)`
     */

    function withdrawPresaleFunds(uint256 presaleId) external nonReentrant {
        Presale storage p = presale[presaleId];

        if (p.owner == address(0)) revert RaiseX__ErrorInvalidPresaleId();

        // Ensure presale has been finalized before withdrawal
        if (!p.finalized) revert RaiseX__ErrorPresaleNotFinalized();

        // Prevent multiple withdrawals
        if (p.presaleFundsWithdrawn)
            revert RaiseX__ErrorFundsAlreadyWithdrawn();

        // Only presale owner can withdraw
        if (msg.sender != p.owner) revert RaiseX__ErrorUnAuthorized();

        // Mark as withdrawn before transfer to prevent reentrancy
        p.presaleFundsWithdrawn = true;

        // Calculate amounts
        uint256 amount = p.amountRaised;
        uint256 fee = (amount * platformFee) / 100; // platform fee %
        uint256 payout = amount - fee; // remaining amount to owner

        if (p.raiseToken == address(0)) {
            // Native token withdrawal (e.g. ETH/BNB)
            (bool ok1, ) = payable(feeAddress).call{value: fee}("");
            (bool ok2, ) = payable(p.owner).call{value: payout}("");
            if (!ok1 || !ok2) revert RaiseX__ErrorWithdrawFailed();
        } else {
            // ERC20 token withdrawal
            IERC20(p.raiseToken).safeTransfer(feeAddress, fee);
            IERC20(p.raiseToken).safeTransfer(p.owner, payout);
        }
        // Log withdrawal details
        emit PresaleFundsWithdrawn(p.presaleId, p.owner, payout, fee);
    }

    /**
     * @notice Allows the presale owner to withdraw leftover (unsold) tokens
     *         after a successful Fixed presale has ended and been finalized.
     *
     * Rules:
     * - Presale must have ended (`block.timestamp > endTime`).
     * - Presale must be finalized.
     * - Only applies to `Fixed` presales (not `Dynamic`).
     * - Can only be executed once (prevent double withdrawals).
     * - There must be unsold tokens (`tokensForSale > tokensSold`).
     *
     * Behavior:
     * - Calculates leftover tokens (`tokensForSale - tokensSold`).
     * - Deducts platform fee from leftovers.
     * - Transfers fee portion to `feeAddress`.
     * - Transfers remainder to the presale owner.
     *
     * Security:
     * - Marks `leftOverTokensWithdrawn = true` before external transfers
     *   to prevent reentrancy or double-withdrawal exploits.
     */

    function withdrawLeftOverTokens(uint256 presaleId) external nonReentrant {
        Presale storage p = presale[presaleId];

        if (p.owner == address(0)) revert RaiseX__ErrorInvalidPresaleId();

        // Validate conditions
        if (
            block.timestamp <= p.endTime || // presale must be over
            p.tokensSold >= p.tokensForSale || // no leftovers
            !p.finalized || // must be finalized
            p.presaleType != PresaleType.Fixed || // only fixed presale supported
            p.leftOverTokensWithdrawn // cannot withdraw twice
        ) revert RaiseX__ErrorUnAuthorized();

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

    /**
     * @notice Calculates the token allocation for a contributor in a Fixed presale.
     *
     * @dev Allocation is proportional to the contributor’s share of the total hard cap.
     *      Formula:
     *          allocation = (contribution * tokensForSale) / hardCap
     *
     * Example:
     * - tokensForSale = 1,000,000
     * - hardCap = 100 ETH
     * - contribution = 5 ETH
     *   => allocation = (5 * 1,000,000) / 100 = 50,000 tokens
     *
     * @param contribution The contributor’s contribution amount (in raise token).
     * @param tokensForSale Total number of tokens allocated for the presale.
     * @param hardCap The maximum raise target of the presale.
     *
     * @return The number of tokens the contributor is entitled to.
     */
    function calculateFixedPresaleAmount(
        uint256 contribution,
        uint256 tokensForSale,
        uint256 hardCap
    ) internal pure returns (uint256) {
        return (contribution * tokensForSale) / hardCap;
    }

    /**
     * @notice Calculates the token allocation for a contributor in a Dynamic presale.
     *
     * @dev Allocation is proportional to the user’s share of the total funds raised.
     *      Formula:
     *          allocation = (userContribution * tokensForSale) / totalRaised
     *
     * If no funds were raised (`totalRaised == 0`), the function returns 0
     * to avoid division by zero.
     *
     * Example:
     * - tokensForSale = 1,000,000
     * - totalRaised = 200 ETH
     * - userContribution = 10 ETH
     *   => allocation = (10 * 1,000,000) / 200 = 50,000 tokens
     *
     * @param userContribution The contribution amount made by the user (in raise token).
     * @param totalRaised The total amount of funds raised in the presale.
     * @param tokensForSale Total number of tokens available for sale in the presale.
     *
     * @return The number of tokens allocated to the contributor.
     */
    function calculateDynamicAllocation(
        uint256 userContribution,
        uint256 totalRaised,
        uint256 tokensForSale
    ) internal pure returns (uint256) {
        if (totalRaised == 0) return 0;
        return (userContribution * tokensForSale) / totalRaised;
    }

    /**
     * @notice Updates the platform fee percentage taken from presales.
     *
     * @dev
     * - Only callable by the contract owner.
     * - Platform fee is expressed as a percentage (`0 - 100`).
     * - A hard limit of `10%` is enforced to protect presale owners from excessive fees.
     * - The fee is later applied in functions such as `withdrawPresaleFunds`
     *   and `withdrawLeftOverTokens`.
     *
     * @param newPlatformFee The new platform fee percentage (must be <= 10).
     *
     * Reverts:
     * - `RaiseX__ErrorFeeTooHigh(newPlatformFee)` if the fee exceeds 10%.
     */
    function setPlatformFee(uint8 newPlatformFee) external onlyOwner {
        if (newPlatformFee > 10) revert RaiseX__ErrorFeeTooHigh(newPlatformFee);
        platformFee = newPlatformFee;
    }

    /**
     * @notice Updates the address that receives platform fees.
     *
     * @dev
     * - Only callable by the contract owner.
     * - The new fee address cannot be the zero address.
     * - This address receives:
     *    - Platform fees deducted from presale funds (`withdrawPresaleFunds`).
     *    - Platform fees deducted from leftover tokens (`withdrawLeftOverTokens`).
     *    - Penalty fees from contributor pull-outs (`pullOut`).
     *
     * @param newFeeAddress The new address that will receive all platform-related fees.
     *
     * Reverts:
     * - `RaiseX__ErrorAddressCannotBeZeroAddress()` if the provided address is zero.
     */
    function setFeeAddress(address newFeeAddress) external onlyOwner {
        if (newFeeAddress == address(0))
            revert RaiseX__ErrorAddressCannotBeZeroAddress();
        feeAddress = newFeeAddress;
    }

    /**
     * @notice Updates the address that receives penalty fees when contributors pull out of a presale.
     *
     * @dev
     * - Only callable by the contract owner.
     * - The new penalty fee address cannot be the zero address.
     * - This address specifically receives the penalty portion deducted
     *   when contributors withdraw contributions early via `pullOut`.
     *
     * @param newPullOutFeeAddress The new address that will receive penalty fees.
     *
     * Reverts:
     * - `RaiseX__ErrorAddressCannotBeZeroAddress()` if the provided address is zero.
     */
    function setPullOutPenaltyFeeAddress(
        address newPullOutFeeAddress
    ) external onlyOwner {
        if (newPullOutFeeAddress == address(0))
            revert RaiseX__ErrorAddressCannotBeZeroAddress();
        pullOutPenaltyFeeAddress = newPullOutFeeAddress;
    }

    /**
     * @notice Utility function to convert minutes into seconds.
     *
     * @dev Multiplies the input by Solidity’s built-in `1 minutes` time unit
     *      (equivalent to `60` seconds). Useful for readability when
     *      working with time-based presale parameters.
     *
     * Example:
     * - `_minutes(5)` → returns `300` (5 minutes in seconds).
     *
     * @param m The number of minutes to convert.
     * @return The equivalent duration in seconds.
     */
    function _minutes(uint256 m) internal pure returns (uint256) {
        return m * 1 minutes; // same as m * 60
    }
}
