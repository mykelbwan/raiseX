// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

error GuessingGame__InvalidDeposit();
error GuessingGame__DepositRequired();
error GuessingGame__MaxGuessesReached();
error GuessingGame__FailSendJackpot();

contract RaiseXGuessingGame is Ownable, ReentrancyGuard {
    struct PlayerInfo {
        uint256 guesses;
        uint256 lastRound;
        bool hasDeposited;
    }
    struct PlayerState {
        uint256 guesses;
        bool hasDeposited;
        uint256 lastRound;
    }

    struct GameState {
        uint256 prizePool;
        uint256 round;
        uint256 totalGuesses;
    }

    struct FullState {
        GameState game;
        PlayerState player;
    }

    mapping(address => PlayerInfo) private players;

    uint256 private secretNumber;
    uint256 private currentGlobalGuessCount;
    uint256 private currentRound;

    uint256 private constant globalMaxGuess = 1_000_000;
    uint256 private constant playerMaxGuess = 100;
    uint256 private depositAmount = 0.0003 ether;

    address private feeAddress;
    uint8 private constant PLATFORM_FEE = 10; // 10%
    uint8 private constant NEXT_ROUND_POOL = 10; // 10%

    event GuessMade(address indexed player, uint256 guess, bool correct);
    event JackpotWon(
        address indexed winner,
        uint256 amount,
        uint256 platformFee,
        uint256 nextRoundPool,
        uint256 winningNumber
    );
    event DepositReceived(address indexed player, uint256 amount);

    constructor(
        address _initialOwner,
        address _feeAddress
    ) Ownable(_initialOwner) {
        feeAddress = _feeAddress;
        _generateRandomNumber();
        currentRound = 1;
    }

    /// Deposit into the game
    function deposit() external payable nonReentrant {
        address player = msg.sender;
        uint256 amount = msg.value;

        PlayerInfo storage info = players[player];

        // reset player info if new round
        if (info.lastRound < currentRound) {
            info.guesses = 0;
            info.lastRound = currentRound;
        }

        if (amount != depositAmount) revert GuessingGame__InvalidDeposit();

        // Each new deposit = fresh guesses
        if (info.guesses != 0) info.guesses = 0;
        info.hasDeposited = true;

        emit DepositReceived(player, amount);
    }

    function guess(uint256 playerGuess) external nonReentrant {
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

        info.guesses++;
        currentGlobalGuessCount++;

        bool isWinner = playerGuess == secretNumber;
        emit GuessMade(player, playerGuess, isWinner);

        if (isWinner) {
            _payoutWinner(player, secretNumber);
            _nextRound();
        } else if (currentGlobalGuessCount >= globalMaxGuess) {
            _nextRound();
        }
    }

    /// Generate random number using TEN protocol
    function _generateRandomNumber() internal returns (uint256) {
        // Replace with TEN Protocol RNG call
        uint256 randomNumber = block.prevrandao;
        secretNumber = (randomNumber % globalMaxGuess) + 1;
        return secretNumber;
    }

    /// Payout winner with fees and leftover pool
    function _payoutWinner(address player, uint256 _winningNumber) internal {
        uint256 pool = address(this).balance;

        uint256 pFee = (pool * PLATFORM_FEE) / 100;
        uint256 carryOver = (pool * NEXT_ROUND_POOL) / 100;
        uint256 prize = pool - pFee - carryOver;

        (bool sentPrize, ) = payable(player).call{value: prize}("");
        if (!sentPrize) revert GuessingGame__FailSendJackpot();

        (bool sentFee, ) = payable(feeAddress).call{value: pFee}("");
        if (!sentFee) revert GuessingGame__FailSendJackpot();

        emit JackpotWon(player, prize, pFee, carryOver, _winningNumber);
    }

    /// Advance to next round
    function _nextRound() internal {
        currentGlobalGuessCount = 0;
        currentRound++;
        _generateRandomNumber();
    }

    /// External view functions
    function getFullState(
        address player
    ) external view returns (FullState memory) {
        // --- global state ---
        uint256 pool = address(this).balance;
        uint256 platformFee = (pool * PLATFORM_FEE) / 100;
        uint256 carryOver = (pool * NEXT_ROUND_POOL) / 100;
        uint256 prizePool = pool - platformFee - carryOver;

        GameState memory game = GameState({
            prizePool: prizePool,
            round: currentRound,
            totalGuesses: currentGlobalGuessCount
        });

        // --- player state ---
        PlayerInfo storage info = players[player];
        PlayerState memory playerState = PlayerState({
            guesses: info.guesses,
            hasDeposited: info.hasDeposited && info.lastRound == currentRound,
            lastRound: info.lastRound
        });

        return FullState({game: game, player: playerState});
    }

    /// external Set Functions
    function setDepositAmount(uint256 _amount) external onlyOwner {
        depositAmount = _amount;
    }

    function setFeeAddress(address _feeAddress) external onlyOwner {
        feeAddress = _feeAddress;
    }
}
