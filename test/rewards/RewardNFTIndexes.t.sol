// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CrottoDiamond} from "../../src/diamond/CrottoDiamond.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {RewardAccountingFacet} from "../../src/diamond/facets/RewardAccountingFacet.sol";
import {CrottoDiamondInit} from "../../src/diamond/initializers/CrottoDiamondInit.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/diamond/IERC173.sol";
import {ICrottoRewards} from "../../src/interfaces/ICrottoRewards.sol";
import {LibRewardAccounting} from "../../src/libraries/LibRewardAccounting.sol";
import {LibGovernanceStorage} from "../../src/libraries/storage/LibGovernanceStorage.sol";
import {LibRewardsStorage} from "../../src/libraries/storage/LibRewardsStorage.sol";
import {RewardBook} from "../../src/types/CrottoTypes.sol";

contract RewardAssetMock is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

contract TransferRejectingRewardAsset is RewardAssetMock {
    error RejectedReceiver(address receiver);

    address public rejectedReceiver;

    constructor() RewardAssetMock("Rejecting Reward", "REJECT") {}

    function setRejectedReceiver(address receiver) external {
        rejectedReceiver = receiver;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to == rejectedReceiver) revert RejectedReceiver(to);
        super._update(from, to, value);
    }
}

interface IRewardAccountingHarness is ICrottoRewards {
    function configureRewards(address weth, address token, address hook, address treasury) external;

    function accrueLotteryWeth(uint256 amount) external;

    function accrueActivationToken(uint256 amount) external;

    function settlePosition(uint256 tokenId) external returns (uint256 wethAmount, uint256 tokenAmount);

    function setPosition(uint256 tokenId, uint256 tier, uint256 weight) external returns (uint256 previousWeight);

    function checkpointPosition(uint256 tokenId) external;

    function rewardLiabilities() external view returns (uint256 wethLiability, uint256 tokenLiability);
}

contract RewardAccountingHarnessFacet is RewardAccountingFacet {
    error TierOverflow(uint256 tier);

    function configureRewards(address weth, address token, address hook, address treasury) external {
        LibGovernanceStorage.Layout storage state = LibGovernanceStorage.layout();
        state.immutableConfiguration.weth = weth;
        state.immutableConfiguration.activationToken = token;
        state.immutableConfiguration.canonicalHook = hook;
        state.treasuryReceiver = treasury;
        state.immutableConfigurationInitialized = true;
    }

    function accrueLotteryWeth(uint256 amount) external {
        _accrueNftWethRewards(amount);
    }

    function accrueActivationToken(uint256 amount) external {
        _accrueNftTokenRewards(amount);
    }

    function settlePosition(uint256 tokenId) external returns (uint256 wethAmount, uint256 tokenAmount) {
        return _settleNftRewards(tokenId);
    }

    function setPosition(uint256 tokenId, uint256 tier, uint256 weight)
        external
        nonReentrant
        returns (uint256 previousWeight)
    {
        if (tier > type(uint8).max) revert TierOverflow(tier);
        // The explicit bound above makes this narrowing safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        return _setNftRewardWeight(tokenId, uint8(tier), weight);
    }

    function checkpointPosition(uint256 tokenId) external {
        _checkpointNftRewards(tokenId);
    }

    function rewardLiabilities() external view returns (uint256 wethLiability, uint256 tokenLiability) {
        LibRewardsStorage.Layout storage state = LibRewardsStorage.layout();
        return (LibRewardAccounting.outstanding(state.wethBook), LibRewardAccounting.outstanding(state.tokenBook));
    }
}

abstract contract RewardAccountingTestBase is Test {
    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");

    CrottoDiamond internal diamond;
    IRewardAccountingHarness internal rewards;
    RewardAssetMock internal weth;
    RewardAssetMock internal token;

    function setUp() public virtual {
        weth = new RewardAssetMock("Wrapped Ether", "WETH");
        token = new RewardAssetMock("Activation Token", "TOKEN");
        diamond = _deployDiamond();
        rewards = IRewardAccountingHarness(address(diamond));
    }

    function _configure(address hook) internal {
        rewards.configureRewards(address(weth), address(token), hook, treasury);
    }

    function _fundAndAccrue(uint256 wethAmount, uint256 tokenAmount) internal {
        if (wethAmount != 0) {
            weth.mint(address(diamond), wethAmount);
            rewards.accrueLotteryWeth(wethAmount);
        }
        if (tokenAmount != 0) {
            token.mint(address(diamond), tokenAmount);
            rewards.accrueActivationToken(tokenAmount);
        }
    }

    function _deployDiamond() private returns (CrottoDiamond deployed) {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        RewardAccountingHarnessFacet rewardFacet = new RewardAccountingHarnessFacet();
        CrottoDiamondInit initializer = new CrottoDiamondInit();

        IDiamondCut.FacetCut[] memory initialCut = new IDiamondCut.FacetCut[](4);
        initialCut[0] = _facetCut(address(cutFacet), _cutSelectors());
        initialCut[1] = _facetCut(address(loupeFacet), _loupeSelectors());
        initialCut[2] = _facetCut(address(ownershipFacet), _ownershipSelectors());
        initialCut[3] = _facetCut(address(rewardFacet), _rewardSelectors());
        deployed = new CrottoDiamond(
            owner, initialCut, address(initializer), abi.encodeCall(CrottoDiamondInit.initialize, ())
        );
    }

    function _facetCut(address facet, bytes4[] memory selectors) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
    }

    function _cutSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;
    }

    function _loupeSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IDiamondLoupe.facets.selector;
        selectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        selectors[2] = IDiamondLoupe.facetAddresses.selector;
        selectors[3] = IDiamondLoupe.facetAddress.selector;
        selectors[4] = bytes4(keccak256("supportsInterface(bytes4)"));
    }

    function _ownershipSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IERC173.owner.selector;
        selectors[1] = IERC173.transferOwnership.selector;
    }

    function _rewardSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](13);
        selectors[0] = RewardAccountingFacet.routeHookRevenue.selector;
        selectors[1] = RewardAccountingFacet.totalActiveWeight.selector;
        selectors[2] = RewardAccountingFacet.wethRewardBook.selector;
        selectors[3] = RewardAccountingFacet.tokenRewardBook.selector;
        selectors[4] = RewardAccountingFacet.nftRewardPosition.selector;
        selectors[5] = RewardAccountingFacet.pendingNFTRewards.selector;
        selectors[6] = IRewardAccountingHarness.configureRewards.selector;
        selectors[7] = IRewardAccountingHarness.accrueLotteryWeth.selector;
        selectors[8] = IRewardAccountingHarness.accrueActivationToken.selector;
        selectors[9] = IRewardAccountingHarness.settlePosition.selector;
        selectors[10] = IRewardAccountingHarness.setPosition.selector;
        selectors[11] = IRewardAccountingHarness.checkpointPosition.selector;
        selectors[12] = IRewardAccountingHarness.rewardLiabilities.selector;
    }
}

contract RewardNFTIndexesTest is RewardAccountingTestBase {
    function setUp() public override {
        super.setUp();
        _configure(makeAddr("hook"));
    }

    function test_MixedBooksDistributeProportionallyAndSettleIdempotently() public {
        rewards.setPosition(1, 1, 2);
        rewards.setPosition(2, 1, 3);
        _fundAndAccrue(50 ether, 100 ether);

        (uint256 wethOne, uint256 tokenOne) = rewards.pendingNFTRewards(1);
        (uint256 wethTwo, uint256 tokenTwo) = rewards.pendingNFTRewards(2);
        assertEq(wethOne, 20 ether);
        assertEq(tokenOne, 40 ether);
        assertEq(wethTwo, 30 ether);
        assertEq(tokenTwo, 60 ether);

        rewards.settlePosition(1);
        RewardBook memory wethBook = rewards.wethRewardBook();
        RewardBook memory tokenBook = rewards.tokenRewardBook();
        assertEq(wethBook.crystallizedAmount, 20 ether);
        assertEq(wethBook.totalClaimable, 20 ether);
        assertEq(tokenBook.crystallizedAmount, 40 ether);
        assertEq(tokenBook.totalClaimable, 40 ether);

        (uint256 wethSettledAgain, uint256 tokenSettledAgain) = rewards.settlePosition(1);
        assertEq(wethSettledAgain, 0);
        assertEq(tokenSettledAgain, 0);
        (uint256 wethLiability, uint256 tokenLiability) = rewards.rewardLiabilities();
        assertEq(wethLiability, 50 ether);
        assertEq(tokenLiability, 100 ether);
    }

    function test_NewWeightCannotReceiveHistoricalIndexGrowth() public {
        rewards.setPosition(1, 1, 1);
        _fundAndAccrue(20 ether, 40 ether);
        rewards.setPosition(2, 1, 1);

        (uint256 priorWeth, uint256 priorToken) = rewards.pendingNFTRewards(2);
        assertEq(priorWeth, 0);
        assertEq(priorToken, 0);

        _fundAndAccrue(10 ether, 14 ether);
        (uint256 newWeth, uint256 newToken) = rewards.pendingNFTRewards(2);
        assertEq(newWeth, 5 ether);
        assertEq(newToken, 7 ether);
    }

    function test_DenominatorChangeClearsFractionalCarryWithoutDroppingIndexedValue() public {
        rewards.setPosition(1, 1, 3);
        _fundAndAccrue(1, 1);
        assertGt(rewards.wethRewardBook().indexRemainder, 0);
        assertGt(rewards.tokenRewardBook().indexRemainder, 0);

        rewards.setPosition(2, 1, 2);
        RewardBook memory wethBook = rewards.wethRewardBook();
        RewardBook memory tokenBook = rewards.tokenRewardBook();
        assertEq(wethBook.indexRemainder, 0);
        assertEq(tokenBook.indexRemainder, 0);
        assertEq(wethBook.indexedAmount, 1);
        assertEq(tokenBook.indexedAmount, 1);
    }

    function test_ZeroDenominatorAccrualReverts() public {
        vm.expectRevert(LibRewardAccounting.NoActiveRewardWeight.selector);
        rewards.accrueLotteryWeth(1);
        vm.expectRevert(LibRewardAccounting.NoActiveRewardWeight.selector);
        rewards.accrueActivationToken(1);
    }

    function test_ZeroAmountAccrualIsNoOp() public {
        rewards.accrueLotteryWeth(0);
        rewards.accrueActivationToken(0);
        assertEq(rewards.wethRewardBook().indexedAmount, 0);
        assertEq(rewards.tokenRewardBook().indexedAmount, 0);
    }

    function test_RevertWhen_CheckpointWouldDiscardActiveEntitlement() public {
        rewards.setPosition(1, 1, 1);
        _fundAndAccrue(1 ether, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(LibRewardAccounting.ActivePositionCheckpoint.selector, 1));
        rewards.checkpointPosition(1);

        (uint256 pendingWeth, uint256 pendingToken) = rewards.pendingNFTRewards(1);
        assertEq(pendingWeth, 1 ether);
        assertEq(pendingToken, 1 ether);
    }

    function test_LastWeightRemovalRoutesOnlyDustAndPreservesClaims() public {
        rewards.setPosition(1, 1, 1);
        rewards.setPosition(2, 1, 2);
        _fundAndAccrue(10, 10);

        rewards.setPosition(1, 0, 0);
        rewards.setPosition(2, 0, 0);

        assertEq(weth.balanceOf(treasury), 1);
        assertEq(token.balanceOf(treasury), 1);
        assertEq(weth.balanceOf(address(diamond)), 9);
        assertEq(token.balanceOf(address(diamond)), 9);

        RewardBook memory wethBook = rewards.wethRewardBook();
        RewardBook memory tokenBook = rewards.tokenRewardBook();
        assertEq(wethBook.indexRay, 0);
        assertEq(wethBook.indexedAmount, 0);
        assertEq(wethBook.crystallizedAmount, 0);
        assertEq(wethBook.totalClaimable, 9);
        assertEq(tokenBook.totalClaimable, 9);

        (uint256 wethOne, uint256 tokenOne) = rewards.pendingNFTRewards(1);
        (uint256 wethTwo, uint256 tokenTwo) = rewards.pendingNFTRewards(2);
        assertEq(wethOne + wethTwo, 9);
        assertEq(tokenOne + tokenTwo, 9);

        (uint256 wethLiability, uint256 tokenLiability) = rewards.rewardLiabilities();
        assertEq(wethLiability, 9);
        assertEq(tokenLiability, 9);
    }

    function test_RevertOnDustTransferRestoresWeightAndBooks() public {
        TransferRejectingRewardAsset rejectingWeth = new TransferRejectingRewardAsset();
        rewards.configureRewards(address(rejectingWeth), address(token), makeAddr("hook"), treasury);
        rewards.setPosition(1, 1, 3);
        rejectingWeth.mint(address(diamond), 1);
        rewards.accrueLotteryWeth(1);
        rejectingWeth.setRejectedReceiver(treasury);

        vm.expectRevert(abi.encodeWithSelector(TransferRejectingRewardAsset.RejectedReceiver.selector, treasury));
        rewards.setPosition(1, 0, 0);

        assertEq(rewards.totalActiveWeight(), 3);
        assertEq(rewards.nftRewardPosition(1).storedWeight, 3);
        assertEq(rewards.wethRewardBook().indexedAmount, 1);
    }

    function testFuzz_BookLiabilityAlwaysMatchesIndexedAndCrystallizedFormula(
        uint256 firstWeight,
        uint256 secondWeight,
        uint256 amount
    ) public {
        firstWeight = bound(firstWeight, 1, 1e24);
        secondWeight = bound(secondWeight, 1, 1e24);
        amount = bound(amount, 1, 1e30);
        rewards.setPosition(1, 1, firstWeight);
        rewards.setPosition(2, 1, secondWeight);
        _fundAndAccrue(amount, amount);
        rewards.settlePosition(1);

        RewardBook memory wethBook = rewards.wethRewardBook();
        (uint256 wethLiability, uint256 tokenLiability) = rewards.rewardLiabilities();
        assertEq(wethLiability, wethBook.indexedAmount - wethBook.crystallizedAmount + wethBook.totalClaimable);
        assertEq(tokenLiability, amount);
        assertLe(wethBook.crystallizedAmount, wethBook.indexedAmount);
    }
}
