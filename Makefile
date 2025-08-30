-include .env

build:; forge build # we use (:;) syntax to write the command on the same line
compile:; forge compile
format:; forge fmt
anvil:; anvil
coverage:; forge coverage


ten-deploy:
	forge script script/DeployRandomGuessingGame.s.sol:DeployRNGGScript --rpc-url $(TEN_RPC_URL) --private-key $(TESTNET_PRIVATE_KEY) --broadcast 
#	--verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv

anvil-deploy:
	forge script script/DeployRandomGuessingGame.s.sol:DeployRNGGScript --rpc-url $(ANVIL_RPC_URL) --private-key $(DEFAULT_ANVIL_KEY) --broadcast