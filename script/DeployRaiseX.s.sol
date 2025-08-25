// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {RaiseX} from "../src/RaiseX.sol";

contract DeployRaiseXScript is Script {
    function run() public returns (RaiseX) {
        address initialOwner = msg.sender;
        address feeAddress = msg.sender;
        vm.startBroadcast();
        RaiseX newRaiseX = new RaiseX(initialOwner, feeAddress);
        vm.stopBroadcast();
        return newRaiseX;
    }
}
