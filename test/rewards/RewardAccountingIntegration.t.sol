// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICrottoRewards} from "../../src/interfaces/ICrottoRewards.sol";
import {LibCrottoGuard} from "../../src/libraries/LibCrottoGuard.sol";
import {LibRewardAccounting} from "../../src/libraries/LibRewardAccounting.sol";
import {LibAssetTransfer} from "../../src/libraries/LibAssetTransfer.sol";
import {RewardAccountingFacet} from "../../src/diamond/facets/RewardAccountingFacet.sol";
import {RewardAccountingTestBase, RewardAssetMock} from "./RewardNFTIndexes.t.sol";

contract CanonicalHookRewardProbe {
    function route(address diamond, IERC20 asset, uint256 rewardAmount, uint256 treasuryAmount) external {
        asset.approve(diamond, rewardAmount);
        ICrottoRewards(diamond).routeHookRevenue(address(asset), rewardAmount, treasuryAmount);
    }
}

contract FeeChargingRewardAsset is RewardAssetMock {
    uint256 private constant FEE_BPS = 100;

    constructor() RewardAssetMock("Fee Reward", "FEE") {}

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = value * FEE_BPS / 10_000;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

contract RewardAccountingIntegrationTest is RewardAccountingTestBase {
    CanonicalHookRewardProbe private hook;

    function setUp() public override {
        super.setUp();
        hook = new CanonicalHookRewardProbe();
        _configure(address(hook));
    }

    function test_CanonicalHookPullsAndIndexesEachConfiguredAssetExactly() public {
        rewards.setPosition(1, 1, 4);
        weth.mint(address(hook), 12 ether);
        token.mint(address(hook), 20 ether);

        hook.route(address(diamond), IERC20(address(weth)), 12 ether, 3 ether);
        hook.route(address(diamond), IERC20(address(token)), 20 ether, 5 ether);

        assertEq(weth.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(weth.balanceOf(address(diamond)), 12 ether);
        assertEq(token.balanceOf(address(diamond)), 20 ether);
        assertEq(weth.allowance(address(hook), address(diamond)), 0);
        assertEq(token.allowance(address(hook), address(diamond)), 0);
        assertEq(rewards.wethRewardBook().indexedAmount, 12 ether);
        assertEq(rewards.tokenRewardBook().indexedAmount, 20 ether);

        (uint256 pendingWeth, uint256 pendingToken) = rewards.pendingNFTRewards(1);
        assertEq(pendingWeth, 12 ether);
        assertEq(pendingToken, 20 ether);
        assertEq(weth.balanceOf(treasury), 0, "hook handles its treasury leg directly");
        assertEq(token.balanceOf(treasury), 0, "hook handles its treasury leg directly");
    }

    function test_ZeroRewardHookRouteNeedsNoAllowanceOrActiveWeight() public {
        hook.route(address(diamond), IERC20(address(weth)), 0, 9 ether);
        assertEq(rewards.wethRewardBook().indexedAmount, 0);
    }

    function test_RevertWhen_CallerIsNotCanonicalHook() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LibCrottoGuard.UnauthorizedCanonicalHookCallback.selector, address(this), address(hook)
            )
        );
        rewards.routeHookRevenue(address(weth), 0, 0);
    }

    function test_RevertWhen_HookRoutesUnsupportedAsset() public {
        RewardAssetMock unsupported = new RewardAssetMock("Unsupported", "NOPE");
        vm.expectRevert(abi.encodeWithSelector(RewardAccountingFacet.InvalidRewardAsset.selector, address(unsupported)));
        hook.route(address(diamond), IERC20(address(unsupported)), 0, 0);
    }

    function test_RevertWhen_HookRoutesRewardsWithoutActiveWeight() public {
        weth.mint(address(hook), 1 ether);
        vm.expectRevert(LibRewardAccounting.NoActiveRewardWeight.selector);
        hook.route(address(diamond), IERC20(address(weth)), 1 ether, 0);
        assertEq(weth.balanceOf(address(hook)), 1 ether);
        assertEq(weth.balanceOf(address(diamond)), 0);
    }

    function test_RevertWhen_RewardAssetDoesNotDeliverExactAmount() public {
        FeeChargingRewardAsset feeAsset = new FeeChargingRewardAsset();
        rewards.configureRewards(address(feeAsset), address(token), address(hook), treasury);
        rewards.setPosition(1, 1, 1);
        feeAsset.mint(address(hook), 100);

        vm.expectRevert(
            abi.encodeWithSelector(
                LibAssetTransfer.UnexpectedTokenReceipt.selector, address(feeAsset), address(diamond), 100, 99
            )
        );
        hook.route(address(diamond), IERC20(address(feeAsset)), 100, 0);

        assertEq(feeAsset.balanceOf(address(hook)), 100);
        assertEq(feeAsset.balanceOf(address(diamond)), 0);
        assertEq(rewards.wethRewardBook().indexedAmount, 0);
    }
}
