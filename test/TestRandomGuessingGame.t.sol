// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {DeployRNGGScript} from "../script/DeployRandomGuessingGame.s.sol";
import {RaiseXGuessingGame} from "../src/RGG.sol";

contract TestRaiseXRNGG is Test {
    RaiseXGuessingGame public rngg;

    uint256 overDepLimit = 1 ether;
    uint256 underDepLimit = 0.00029 ether;
    uint256 correctAmount = 0.0003 ether;

    function setUp() public {
        DeployRNGGScript deployRNGGScript = new DeployRNGGScript();
        rngg = deployRNGGScript.run();
    }

    function testGuessWithoutPaying_expectRevert() public {
        vm.expectRevert();
        rngg.guess(50);
    }

    function testGuessingGamePayingOverAndUnderTheFixedAmount_expectRevert()
        public
    {
        vm.expectRevert();
        (bool ok, ) = payable(address(rngg)).call{value: overDepLimit}("");

        vm.expectRevert();
        (ok, ) = payable(address(rngg)).call{value: underDepLimit}("");

        /// to silence the warning of un-used variable(which is very annoying)
        if (ok) {}
    }

    function testDepCorrectAmountAmdGuess_success() public {
        (bool ok, ) = payable(address(rngg)).call{value: correctAmount}("");

        /// to silence the warning of un-used variable(which is very annoying)
        if (ok) {}

        rngg.guess(50);
    }
}
