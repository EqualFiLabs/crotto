// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {NFTRewardPosition, RewardBook} from "../../src/types/CrottoTypes.sol";
import {RewardAccountingTestBase, RewardAssetMock, IRewardAccountingHarness} from "../rewards/RewardNFTIndexes.t.sol";

contract RewardAccountingHandler is RewardAccountingTestBase {
    uint256 internal constant POSITION_COUNT = 4;

    function setUp() public override {
        super.setUp();
        _configure(makeAddr("hook"));
    }

    function changeWeight(uint256 tokenId, uint256 weight) external {
        tokenId = bound(tokenId, 1, POSITION_COUNT);
        weight = bound(weight, 0, 1e24);
        rewards.setPosition(tokenId, weight == 0 ? 0 : 1, weight);
    }

    function accrue(uint256 assetSeed, uint256 amount) external {
        if (rewards.totalActiveWeight() == 0) return;
        amount = bound(amount, 1, 1e24);
        if (assetSeed % 2 == 0) {
            weth.mint(address(diamond), amount);
            rewards.accrueLotteryWeth(amount);
        } else {
            token.mint(address(diamond), amount);
            rewards.accrueActivationToken(amount);
        }
    }

    function settle(uint256 tokenId) external {
        rewards.settlePosition(bound(tokenId, 1, POSITION_COUNT));
    }

    function positionCount() external pure returns (uint256) {
        return POSITION_COUNT;
    }

    function exposedRewards() external view returns (IRewardAccountingHarness) {
        return rewards;
    }

    function exposedWeth() external view returns (RewardAssetMock) {
        return weth;
    }

    function exposedToken() external view returns (RewardAssetMock) {
        return token;
    }

    function exposedDiamond() external view returns (address) {
        return address(diamond);
    }
}

contract RewardAccountingInvariantTest is StdInvariant, RewardAccountingTestBase {
    RewardAccountingHandler private handler;

    function setUp() public override {
        handler = new RewardAccountingHandler();
        handler.setUp();
        rewards = handler.exposedRewards();
        weth = handler.exposedWeth();
        token = handler.exposedToken();
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = RewardAccountingHandler.changeWeight.selector;
        selectors[1] = RewardAccountingHandler.accrue.selector;
        selectors[2] = RewardAccountingHandler.settle.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_TotalActiveWeightEqualsStoredPositionWeights() public view {
        uint256 sum;
        uint256 count = handler.positionCount();
        for (uint256 tokenId = 1; tokenId <= count; ++tokenId) {
            sum += rewards.nftRewardPosition(tokenId).storedWeight;
        }
        assertEq(rewards.totalActiveWeight(), sum);
    }

    function invariant_BookLiabilitiesEqualDiamondCustody() public view {
        (uint256 wethLiability, uint256 tokenLiability) = rewards.rewardLiabilities();
        assertEq(weth.balanceOf(handler.exposedDiamond()), wethLiability);
        assertEq(token.balanceOf(handler.exposedDiamond()), tokenLiability);
    }

    function invariant_CrystallizedAmountsNeverExceedCurrentEpochIndexing() public view {
        RewardBook memory wethBook = rewards.wethRewardBook();
        RewardBook memory tokenBook = rewards.tokenRewardBook();
        assertLe(wethBook.crystallizedAmount, wethBook.indexedAmount);
        assertLe(tokenBook.crystallizedAmount, tokenBook.indexedAmount);
    }

    function invariant_TotalClaimableEqualsAttachedPositionClaims() public view {
        uint256 wethClaims;
        uint256 tokenClaims;
        uint256 count = handler.positionCount();
        for (uint256 tokenId = 1; tokenId <= count; ++tokenId) {
            NFTRewardPosition memory position = rewards.nftRewardPosition(tokenId);
            wethClaims += position.claimableWeth;
            tokenClaims += position.claimableToken;
        }
        assertEq(rewards.wethRewardBook().totalClaimable, wethClaims);
        assertEq(rewards.tokenRewardBook().totalClaimable, tokenClaims);
    }
}
