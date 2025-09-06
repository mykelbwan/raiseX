// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {RaiseXTokenSalePlatform} from "../src/RaiseXTokenSalePlatform.sol";

contract DeployRaiseXTokenSalePlatformScript is Script {
    function run() public returns (RaiseXTokenSalePlatform) {
        address initialOwner = msg.sender;
        address feeAddress = msg.sender;
        vm.startBroadcast();
        RaiseXTokenSalePlatform newRaiseX = new RaiseXTokenSalePlatform(
            initialOwner,
            feeAddress
        );
        vm.stopBroadcast();
        return newRaiseX;
    }
}
