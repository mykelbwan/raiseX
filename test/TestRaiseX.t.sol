// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {DeployRaiseXScript} from "../script/DeployRaiseX.s.sol";

contract RaiseXTest is Test {
    RaiseX public raiseX;

    function setUp() public {
        DeployRaiseXScript deployRaiseX = new DeployRaiseXScript();
        raiseX = deployRaiseX.run();
    }
}
