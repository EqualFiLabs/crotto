// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {LotteryVRFFacet} from "../../src/diamond/facets/LotteryVRFFacet.sol";

contract LotteryVRFSelectorManifestTest is Test {
    function test_LotteryVrfSelectorManifestIsExact() public pure {
        bytes4 requestSelector = LotteryVRFFacet.requestRandomness.selector;
        bytes4 retrySelector = LotteryVRFFacet.retryRandomness.selector;
        bytes4 callbackSelector = LotteryVRFFacet.rawFulfillRandomWords.selector;

        assertEq(requestSelector, bytes4(keccak256("requestRandomness(uint256)")));
        assertEq(retrySelector, bytes4(keccak256("retryRandomness(uint256)")));
        assertEq(callbackSelector, bytes4(keccak256("rawFulfillRandomWords(uint256,uint256[])")));
        assertTrue(
            requestSelector != retrySelector && requestSelector != callbackSelector && retrySelector != callbackSelector
        );
    }
}
