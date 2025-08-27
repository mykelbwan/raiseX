// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {DeployRaiseXTokenSalePlatformScript} from "../script/DeployRaiseXTokenSalePlatform.s.sol";
import {RaiseXTokenSalePlatform} from "../src/RaiseXTokenSalePlatform.sol";

contract RaiseXTest is Test {
    RaiseXTokenSalePlatform public raiseX;

    function setUp() public {
        DeployRaiseXTokenSalePlatformScript deployRaiseX = new DeployRaiseXTokenSalePlatformScript();
        raiseX = deployRaiseX.run();
    }
}
