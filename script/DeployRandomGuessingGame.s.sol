// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {RaiseXGuessingGame} from "../src/RGG.sol";

contract DeployRNGGScript is Script {
    function run() public returns (RaiseXGuessingGame) {
        address initialOwner = msg.sender;
        address feeAddress = msg.sender;

        vm.startBroadcast();
        RaiseXGuessingGame newRaiseXGuessingGame = new RaiseXGuessingGame(
            initialOwner,
            feeAddress
        );
        vm.stopBroadcast();
        return newRaiseXGuessingGame;
    }
}
