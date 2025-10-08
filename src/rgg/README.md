Foundry project.

This is a private, random number guessing game build on TEN protocol.

the contract leverage TEN's private execution and their onchain, free random number generation.

On ethereum and other layer 2's, randomness is offchain and expensive, the solution? TEN Random Number Generation (rng).
This project showcases the capabilities of TEN network in the mids of their competition and ten multi use case.

How it works:
On contract deployment a new Random number is generated between 1 and 100:

```solidity
        /// Generate A Ten free and truly random number
    function _generateRandomNumber() private returns (uint256) {
        uint256 randomNumber = block.prevrandao;
        secretNumber = uint64((randomNumber % globalMaxGuess) + 1);
        return secretNumber;
    }
```

To play, player must first deposit the required fee in other to participate.
each deposit have 100 guesses, if the guesses reach 0 or there is a winner, player needs to make a new deposit in other to play the game again.

When a player guest the correct number, the secret number is revealed in an event

```solidity
        emit RoundReveal(currentRound, secretNumber, salt);
```

80% of the jackpot will be sent to the winner, 10% re-rolled into the next round and 10% goes to platform treasury.

Then a new Random Number is generated and a new round starts.

Force next round is added incase the game gets stuck for some time and there is no winner:

```solidity
        function forceNextRound() external {
        bool isOwner = msg.sender == owner();
        bool isTimeout = block.timestamp >=
            lastRoundTimestamp + MAX_ROUND_DURATION;

        if (!(isOwner || isTimeout)) {
            revert GuessingGame__OnlyOwnerOrTimeout();
        }
        _revealRound();
        _nextRound();
    }
```

this function kickstart a new game.

What makes it special is transparency: using TEN’s privacy primitives, guesses are private to players, but results are public and verifiable. That balance of privacy and fairness is only possible on TEN.
