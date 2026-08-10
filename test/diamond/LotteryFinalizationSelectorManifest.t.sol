// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {LotteryFinalizationFacet} from "../../src/diamond/facets/LotteryFinalizationFacet.sol";

contract LotteryFinalizationSelectorManifestTest is Test {
    function test_LotteryFinalizationSelectorManifestIsExact() public pure {
        bytes4 finalizeSelector = LotteryFinalizationFacet.finalizeLottery.selector;
        bytes4 winningsSelector = LotteryFinalizationFacet.claimWinnings.selector;
        bytes4 rewardsSelector = LotteryFinalizationFacet.claimPlayerRewards.selector;

        assertEq(finalizeSelector, bytes4(keccak256("finalizeLottery(uint256)")));
        assertEq(winningsSelector, bytes4(keccak256("claimWinnings(uint256,address)")));
        assertEq(rewardsSelector, bytes4(keccak256("claimPlayerRewards(uint256,address)")));
        assertTrue(
            finalizeSelector != winningsSelector && finalizeSelector != rewardsSelector
                && winningsSelector != rewardsSelector
        );
    }
}
