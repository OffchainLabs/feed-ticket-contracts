// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Tickets} from "../src/Tickets.sol";

contract TicketsHarness is Tickets {
    function fakeExponential(uint256 factor, uint256 numerator, uint256 denominator) external pure returns (uint256) {
        return _fakeExponential(factor, numerator, denominator);
    }
}

contract FakeExponentialTest is Test {
    TicketsHarness harness;

    struct Case {
        uint256 factor;
        uint256 numerator;
        uint256 denominator;
        uint256 expected;
    }

    function setUp() public {
        harness = new TicketsHarness();
    }

    // https://github.com/ethereum/go-ethereum/blob/1d29e3ec0ed0afc7c2cc7ebe2b4b694cc5485b9a/consensus/misc/eip4844/eip4844_test.go#L153
    function test_fakeExponential_gethVectors() public view {
        Case[15] memory cases = [
            Case(1, 0, 1, 1),
            Case(38493, 0, 1000, 38493),
            Case(0, 1234, 2345, 0),
            Case(1, 2, 1, 6),
            Case(1, 4, 2, 6),
            Case(1, 3, 1, 16),
            Case(1, 6, 2, 18),
            Case(1, 4, 1, 49),
            Case(1, 8, 2, 50),
            Case(10, 8, 2, 542),
            Case(11, 8, 2, 596),
            Case(1, 5, 1, 136),
            Case(1, 5, 2, 11),
            Case(2, 5, 2, 23),
            Case(1, 50000000, 2225652, 5709098764)
        ];

        for (uint256 i = 0; i < cases.length; i++) {
            Case memory c = cases[i];
            assertEq(
                harness.fakeExponential(c.factor, c.numerator, c.denominator),
                c.expected,
                string.concat("case ", vm.toString(i))
            );
        }
    }
}
