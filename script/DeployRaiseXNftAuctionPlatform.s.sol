// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {RaiseXNftAuctionPlatform} from "../src/RaiseXNftAuctionPlatform.sol";

contract DeployRaiseXAuctionPlatformScript is Script {
    function run() public returns (RaiseXNftAuctionPlatform) {
        address initialOwner = msg.sender;
       // address feeAddress = msg.sender;
        vm.startBroadcast();
        RaiseXNftAuctionPlatform newRaiseXNftAuctionPlatform = new RaiseXNftAuctionPlatform(
                initialOwner
            );
        vm.stopBroadcast();
        return newRaiseXNftAuctionPlatform;
    }
}
