// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import { WBondToken } from "../src/WBondToken.sol";

contract Deploy is Script {
    function run() public {
        address stakingACM = 0xfAc510D5dB8cadfF323D4b979D898dc38F3FB6dF;
        address treasuryAddress = 0xcBA04A89d8875f2eD85C91c8e856bE675e7BDA8c;
        uint256 yield = 1234; // in BPS
        uint256 endOfBondingPeriod = 1756684799;
        uint256 maturityTimestamp = 1819756799;

        WBondToken bondToken = new WBondToken(
            "WHB20270831",
            "WHB20270831",
            endOfBondingPeriod,
            maturityTimestamp,
            yield,
            stakingACM,
            treasuryAddress
        );

        console.log("WHB20270831 deployed at:", address(bondToken));
    }
}