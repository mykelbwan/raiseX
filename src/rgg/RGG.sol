// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ContractTransparencyConfig} from "../Interface/ContractTransparencyConfig.sol";

error GuessingGame__DepositRequired();
error GuessingGame__MaxGuessesReached();
error GuessingGame__FailSendJackpot();
error GuessingGame__ZeroAddress();
error GuessingGame__WithdrawalFailed();
error GuessingGame__GamePaused();
error GuessingGame__RefundFailed();
error GuessingGame__InvalidGuessRange();
error GuessingGame__Underpay();
error GuessingGame__OnlyOwnerOrTimeout();

contract RaiseXGuessingGame is
    ContractTransparencyConfig,
    Ownable,
    ReentrancyGuard,
    Pausable
{
    struct PlayerInfo {
        uint64 guesses;
        uint64 lastRound;
        bool hasDeposited;
    }

    struct GameState {
        uint256 prizePool;
        uint256 totalPayouts;
        uint256 gateFee;
        uint64 round;
        uint64 totalGuesses;
        uint64 totalWinnersCount;
        uint64 roundsPlayed;
    }

    struct FullState {
        GameState game;
        PlayerInfo player;
    }

    mapping(address => PlayerInfo) private players;

    uint256 private depositAmount = 0.0003 ether;
    uint256 private platformBalance; // accumulate platform fee
    uint256 private totalPayouts;
    uint256 private salt;
    uint256 public lastRoundTimestamp;
    uint256 public constant MAX_ROUND_DURATION = 1 days;
    bytes32 private currentCommit;

    uint64 private constant globalMaxGuess = 100_000;
    uint64 private secretNumber;
    uint64 private currentGlobalGuessCount;
    uint64 private currentRound;
    uint64 private constant playerMaxGuess = 100;
    uint64 private totalWinnersCount; // track winners count
    uint8 private constant PLATFORM_FEE = 10; // 10%
    uint8 private constant NEXT_ROUND_POOL = 10; // 10%

    event GuessMade(address indexed player, uint64 guess, bool correct);
    event JackpotWon(
        address indexed winner,
        uint256 amount,
        uint256 platformFee,
        uint256 nextRoundPool,
        uint64 secretNumber
    );
    event DepositReceived(address indexed player, uint256 amount);
    event PlatformWithdraw(address to, uint256 amount);

    event RoundAdvanced(uint64 round, uint256 carryOver, bytes32 newSecretHash);
    event RoundReveal(uint64 round, uint256 secretNumber, uint256 salt);

    constructor(address _initialOwner) Ownable(_initialOwner) {
        // initialize secret for round 1 and set commit
        uint256 scrt = _generateRandomNumber(); // sets secretNumber
        salt = uint256(
            keccak256(
                abi.encodePacked(
                    block.prevrandao,
                    block.timestamp,
                    address(this)
                )
            )
        );
        currentCommit = keccak256(abi.encode(scrt, salt));
        currentRound = 1;
        _startRoundInit();
    }

    /// Deposit into the game
    function deposit() public payable nonReentrant {
        if (paused()) revert GuessingGame__GamePaused();

        address player = msg.sender;
        uint256 amount = msg.value;

        if (amount < depositAmount) revert GuessingGame__Underpay();

        PlayerInfo storage info = players[player];

        // reset player info if new round
        if (info.lastRound < currentRound) {
            info.guesses = 0;
            info.lastRound = currentRound;
        }

        // refund change if any
        uint256 change = amount - depositAmount;
        if (change > 0) {
            (bool r, ) = payable(player).call{value: change}("");
            if (!r) revert GuessingGame__RefundFailed();
        }

        // Each new deposit = fresh guesses
        if (info.guesses != 0) info.guesses = 0;
        info.hasDeposited = true;

        emit DepositReceived(player, amount);
    }

    function guess(uint64 playerGuess) external nonReentrant {
        if (paused()) revert GuessingGame__GamePaused();

        address player = msg.sender;
        PlayerInfo storage info = players[player];

        // If player is from a past round, reset their state
        if (info.lastRound < currentRound) {
            info.guesses = 0;
            info.lastRound = currentRound;
            info.hasDeposited = false; // must re-deposit this round
        }

        if (!info.hasDeposited) revert GuessingGame__DepositRequired();
        if (info.guesses >= playerMaxGuess)
            revert GuessingGame__MaxGuessesReached();
        if (playerGuess <= 0 || playerGuess > globalMaxGuess)
            revert GuessingGame__InvalidGuessRange();

        info.guesses++;
        currentGlobalGuessCount++;

        bool isWinner = playerGuess == secretNumber;
        emit GuessMade(player, playerGuess, isWinner);

        if (isWinner) {
            totalWinnersCount++;
            _revealRound();
            _payoutWinner(player);
            _nextRound();
        } else if (currentGlobalGuessCount >= globalMaxGuess) {
            _nextRound();
        }
    }

    /// Generate A Ten free and truly random number
    function _generateRandomNumber() private returns (uint256) {
        uint256 randomNumber = block.prevrandao;
        secretNumber = uint64((randomNumber % globalMaxGuess) + 1);
        return secretNumber;
    }

    /// Deduct 10% platform fee and add it to platformBalance
    /// Deduct 10% carry over fee for the next round(this incentivize playing)
    /// Payout winner with remaining 80%
    function _payoutWinner(address player) private {
        uint256 pool = address(this).balance;

        if (platformBalance > 0) pool -= platformBalance;

        uint256 pFee = (pool * PLATFORM_FEE) / 100;
        uint256 carryOver = (pool * NEXT_ROUND_POOL) / 100;
        uint256 prize = pool - pFee - carryOver;

        platformBalance += pFee; // accumulate platform fee
        totalPayouts += prize;

        (bool sPrize, ) = payable(player).call{value: prize}("");
        if (!sPrize) revert GuessingGame__FailSendJackpot();

        emit JackpotWon(player, prize, pFee, carryOver, secretNumber);
    }

    /// Advance to next round
    function _nextRound() private {
        currentGlobalGuessCount = 0;
        currentRound++;
        uint256 scrtNum = _generateRandomNumber();

        salt = uint256(
            keccak256(
                abi.encodePacked(
                    block.prevrandao,
                    block.timestamp,
                    address(this)
                )
            )
        );
        currentCommit = keccak256(abi.encode(scrtNum, salt));

        uint256 pool = address(this).balance;
        if (platformBalance > 0) pool -= platformBalance;
        uint256 carryOver = (pool * NEXT_ROUND_POOL) / 100;

        emit RoundAdvanced(currentRound, carryOver, currentCommit);
        _startRoundInit();
    }

    function _revealRound() internal {
        emit RoundReveal(currentRound, secretNumber, salt);
    }

    /// @notice View the current prize pool (excludes accumulated platform fees & next round carry-over)
    /// @dev platformBalance contains previously accrued fees and is therefore excluded from playable pool
    function _prizePool() internal view returns (uint256) {
        uint256 pool = address(this).balance;

        // exclude already-accumulated platform fees
        if (platformBalance > 0) pool -= platformBalance;

        // Apply this round's fee rules
        uint256 platformFee = (pool * PLATFORM_FEE) / 100;
        uint256 carryOver = (pool * NEXT_ROUND_POOL) / 100;

        return pool - platformFee - carryOver;
    }

    /// @dev Returns the unique keccak256 hash of an event's signature string.
    /// Used to identify events in the EVM log system.
    /// Example: "DepositReceived(address,uint256)" → bytes32 hash
    function _hashEvent(
        string memory eventSignature
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(eventSignature));
    }

    function _startRoundInit() internal {
        lastRoundTimestamp = block.timestamp;
    }

    /// @notice Defines who can see each event in the contract.
    /// @dev
    /// - Sets visibility rules
    /// - Each event is linked to specific viewers
    /// - Returns PRIVATE contract mode with these event-based rules.
    function visibilityRules() external pure returns (VisibilityConfig memory) {
        // We are configuring visibility rules for X events in this contract.
        // -> The array size is set at creation time in memory.
        EventLogConfig[] memory eventLogConfigs = new EventLogConfig[](6);

        // Compute the keccak256 hash of the event signature.
        bytes32 guessMadeSig = _hashEvent("GuessMade(address,uint64,bool)");

        // Define who can view this event.
        // Here: only the player (first indexed param = topic1).
        Field[] memory relevantToGuessMade = new Field[](
            1
        ); /**specify the  array visibility size, in our case it's just 1 permission grated */
        // visible to the first address indexed in the event
        relevantToGuessMade[
            0 /**the index position in the array, here it's 0 */
        ] = Field.TOPIC1;
        // Save configuration into slot 0 of eventLogConfigs.
        eventLogConfigs[0] = EventLogConfig(guessMadeSig, relevantToGuessMade);

        bytes32 jackPotWonSig = _hashEvent(
            "JackpotWon(address,uint256,uint256,uint256,uint64)"
        );
        Field[] memory relevantToJackPot = new Field[](1);
        relevantToJackPot[0] = Field.EVERYONE;
        eventLogConfigs[1] = EventLogConfig(jackPotWonSig, relevantToJackPot);

        bytes32 depositReceivedSig = _hashEvent(
            "DepositReceived(address,uint256)"
        );
        Field[] memory relevantToDeposit = new Field[](1);
        relevantToDeposit[0] = Field.TOPIC1;
        eventLogConfigs[2] = EventLogConfig(
            depositReceivedSig,
            relevantToDeposit
        );

        bytes32 platformFeeWithdrawSig = _hashEvent(
            "PlatformWithdraw(address,uint256)"
        );
        Field[] memory relevantToPlatformFeeWith = new Field[](1);
        relevantToPlatformFeeWith[0] = Field.EVERYONE;
        eventLogConfigs[3] = EventLogConfig(
            platformFeeWithdrawSig,
            relevantToPlatformFeeWith
        );

        bytes32 roundAdvanceSig = _hashEvent(
            "RoundAdvanced(uint64,uint256,bytes32)"
        );
        Field[] memory relevantToRoundAdvance = new Field[](1);
        relevantToRoundAdvance[0] = Field.EVERYONE;
        eventLogConfigs[4] = EventLogConfig(
            roundAdvanceSig,
            relevantToRoundAdvance
        );

        bytes32 roundRevealSig = _hashEvent(
            "RoundReveal(uint64,uint256,uint256)"
        );
        Field[] memory relevantToRoundReveal = new Field[](1);
        relevantToRoundReveal[0] = Field.EVERYONE;
        eventLogConfigs[5] = EventLogConfig(
            roundRevealSig,
            relevantToRoundReveal
        );

        // ---------------------------------------------------------------------
        // Return global visibility rules
        // ---------------------------------------------------------------------

        // Contract is PRIVATE: storage is hidden, only events are visible
        // based on the rules we just configured above.
        return VisibilityConfig(ContractCfg.PRIVATE, eventLogConfigs);
    }

    function withdrawPlatformFee(address to) external onlyOwner {
        if (to == address(0)) revert GuessingGame__ZeroAddress();
        uint256 amount = platformBalance;
        platformBalance = 0;
        (bool s, ) = payable(to).call{value: amount}("");
        if (!s) revert GuessingGame__WithdrawalFailed();
        emit PlatformWithdraw(to, amount);
    }

    function setDepositAmount(uint256 _amount) external onlyOwner {
        depositAmount = _amount;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function forceNextRound() external {
        bool isOwner = msg.sender == owner();
        bool isTimeout = block.timestamp >=
            lastRoundTimestamp + MAX_ROUND_DURATION;

        if (!(isOwner || isTimeout)) {
            revert GuessingGame__OnlyOwnerOrTimeout();
        }
        _revealRound(); // reveal current round
        _nextRound();
    }

    /// External view function
    function getFullState(
        address player
    ) external view returns (FullState memory) {
        uint256 prizePool = _prizePool();

        GameState memory game = GameState({
            prizePool: prizePool,
            round: currentRound,
            totalGuesses: currentGlobalGuessCount,
            gateFee: depositAmount,
            totalWinnersCount: totalWinnersCount,
            roundsPlayed: currentRound,
            totalPayouts: totalPayouts
        });

        // player state
        PlayerInfo storage info = players[player];
        PlayerInfo memory playerState = PlayerInfo({
            guesses: info.guesses,
            hasDeposited: info.hasDeposited && info.lastRound == currentRound,
            lastRound: info.lastRound
        });

        return FullState({game: game, player: playerState});
    }

    //// accept any deposit as an entry to the game
    // extra will be auto refunded
    receive() external payable {
        deposit();
    }
}
