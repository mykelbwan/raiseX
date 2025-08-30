// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {RaiseXNftAuctionPlatform} from "../src/RaiseXNftAuctionPlatform.sol";
import {DeployRaiseXAuctionPlatformScript} from "../script/DeployRaiseXNftAuctionPlatform.s.sol";

contract TestRaiseXNftAuction is Test {
    RaiseXNftAuctionPlatform public raiseXNft;

    function setUp() public {
        DeployRaiseXAuctionPlatformScript deployRaiseXNftAuctionPlatform = new DeployRaiseXAuctionPlatformScript();
        raiseXNft = deployRaiseXNftAuctionPlatform.run();
    }
}
