// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {CrottoDiamond} from "../../src/diamond/CrottoDiamond.sol";
import {CrottoFacet} from "../../src/diamond/CrottoFacet.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {CrottoDiamondInit} from "../../src/diamond/initializers/CrottoDiamondInit.sol";
import {LibDiamond} from "../../src/diamond/libraries/LibDiamond.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/diamond/IERC173.sol";
import {LibCrottoGuard} from "../../src/libraries/LibCrottoGuard.sol";
import {LibGovernanceStorage} from "../../src/libraries/storage/LibGovernanceStorage.sol";
import {LibLotteryStorage} from "../../src/libraries/storage/LibLotteryStorage.sol";
import {LibPOLStorage} from "../../src/libraries/storage/LibPOLStorage.sol";
import {LibRewardsStorage} from "../../src/libraries/storage/LibRewardsStorage.sol";
import {LibTreasuryStorage} from "../../src/libraries/storage/LibTreasuryStorage.sol";
import {LibVaultStorage} from "../../src/libraries/storage/LibVaultStorage.sol";

interface IGuardHarness {
    function guardedIncrement() external;

    function reenterGuardedIncrement() external;

    function onRewardNFTTransfer(address from, address to, uint256 tokenId) external;

    function scopedCallback(
        address expectedFrom,
        address expectedTo,
        uint256 expectedTokenId,
        address callbackFrom,
        address callbackTo,
        uint256 callbackTokenId,
        bool callTwice
    ) external;

    function callbackInsideGuardWithoutScope(address from, address to, uint256 tokenId) external;

    function scopedWithoutCallback(address from, address to, uint256 tokenId) external;

    function callbackCount() external view returns (uint256);
}

library GuardHarnessStorage {
    bytes32 internal constant SLOT = keccak256("crotto.test.storage.GuardHarness");

    struct Layout {
        uint256 callbackCount;
        uint256 guardedCount;
    }

    function layout() internal pure returns (Layout storage state) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            state.slot := slot
        }
    }
}

contract MockRewardNFTCallbackCaller {
    function invoke(address diamond, address from, address to, uint256 tokenId) public {
        IGuardHarness(diamond).onRewardNFTTransfer(from, to, tokenId);
    }
}

contract StorageHarnessFacet {
    function configureRewardNFT(address rewardNFT) external {
        // Synthetic setup for isolated storage and callback-boundary tests.
        LibGovernanceStorage.layout().immutableConfiguration.rewardNFT = rewardNFT;
    }

    function writeSentinels(uint256 seed) external {
        LibGovernanceStorage.layout().pausedActions = seed + 1;
        LibLotteryStorage.layout().currentRoundId = seed + 2;
        LibRewardsStorage.layout().totalActiveWeight = seed + 3;
        LibVaultStorage.layout().tokenBacking = seed + 4;
        LibTreasuryStorage.layout().operationsReserveEth = seed + 5;
        LibPOLStorage.layout().bootstrapWeth = seed + 6;
    }

    function sentinels() external view returns (uint256[6] memory values) {
        values[0] = LibGovernanceStorage.layout().pausedActions;
        values[1] = LibLotteryStorage.layout().currentRoundId;
        values[2] = LibRewardsStorage.layout().totalActiveWeight;
        values[3] = LibVaultStorage.layout().tokenBacking;
        values[4] = LibTreasuryStorage.layout().operationsReserveEth;
        values[5] = LibPOLStorage.layout().bootstrapWeth;
    }

    function storageSlots() external pure returns (bytes32[8] memory slots) {
        slots[0] = LibDiamond.diamondStorageSlot();
        slots[1] = LibGovernanceStorage.storageSlot();
        slots[2] = LibLotteryStorage.storageSlot();
        slots[3] = LibRewardsStorage.storageSlot();
        slots[4] = LibVaultStorage.storageSlot();
        slots[5] = LibTreasuryStorage.storageSlot();
        slots[6] = LibPOLStorage.storageSlot();
        slots[7] = LibCrottoGuard.storageSlot();
    }
}

contract GuardHarnessFacet is CrottoFacet, IGuardHarness {
    function guardedIncrement() external nonReentrant {
        ++GuardHarnessStorage.layout().guardedCount;
    }

    function reenterGuardedIncrement() external nonReentrant {
        IGuardHarness(address(this)).guardedIncrement();
    }

    function onRewardNFTTransfer(address from, address to, uint256 tokenId)
        external
        onlyRewardNFTTransferCallback(from, to, tokenId)
    {
        ++GuardHarnessStorage.layout().callbackCount;
    }

    function scopedCallback(
        address expectedFrom,
        address expectedTo,
        uint256 expectedTokenId,
        address callbackFrom,
        address callbackTo,
        uint256 callbackTokenId,
        bool callTwice
    ) external nonReentrant {
        _beginRewardNFTTransfer(expectedFrom, expectedTo, expectedTokenId);
        MockRewardNFTCallbackCaller rewardNFT = _rewardNFT();
        rewardNFT.invoke(address(this), callbackFrom, callbackTo, callbackTokenId);
        if (callTwice) rewardNFT.invoke(address(this), callbackFrom, callbackTo, callbackTokenId);
        _finishRewardNFTTransfer();
    }

    function callbackInsideGuardWithoutScope(address from, address to, uint256 tokenId) external nonReentrant {
        _rewardNFT().invoke(address(this), from, to, tokenId);
    }

    function scopedWithoutCallback(address from, address to, uint256 tokenId) external nonReentrant {
        _beginRewardNFTTransfer(from, to, tokenId);
        _finishRewardNFTTransfer();
    }

    function callbackCount() external view returns (uint256) {
        return GuardHarnessStorage.layout().callbackCount;
    }

    function _rewardNFT() private view returns (MockRewardNFTCallbackCaller) {
        return MockRewardNFTCallbackCaller(LibGovernanceStorage.layout().immutableConfiguration.rewardNFT);
    }
}

contract DiamondStorageAndGuardTest is Test {
    address private owner = makeAddr("owner");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    DiamondCutFacet private cutFacet;
    DiamondLoupeFacet private loupeFacet;
    OwnershipFacet private ownershipFacet;
    CrottoDiamondInit private initializer;
    StorageHarnessFacet private storageFacet;
    GuardHarnessFacet private guardFacet;
    MockRewardNFTCallbackCaller private rewardNFT;
    CrottoDiamond private diamond;

    function setUp() public {
        cutFacet = new DiamondCutFacet();
        loupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        initializer = new CrottoDiamondInit();
        storageFacet = new StorageHarnessFacet();
        guardFacet = new GuardHarnessFacet();
        rewardNFT = new MockRewardNFTCallbackCaller();

        diamond = _deployCoreDiamond();
        _installHarnessFacets();
        StorageHarnessFacet(address(diamond)).configureRewardNFT(address(rewardNFT));
    }

    function test_ProtocolStorageNamespacesAreUniqueAndAligned() public view {
        bytes32[8] memory slots = StorageHarnessFacet(address(diamond)).storageSlots();
        for (uint256 i; i < slots.length; ++i) {
            assertEq(uint256(slots[i]) & 0xff, 0, "ERC-7201 slot must be 256-byte aligned");
            for (uint256 j = i + 1; j < slots.length; ++j) {
                assertNotEq(slots[i], slots[j], "storage namespaces must not collide");
            }
        }
    }

    function test_ProtocolStorageWritesRemainIsolatedFromDiamondOwnership() public {
        StorageHarnessFacet(address(diamond)).writeSentinels(100);
        uint256[6] memory values = StorageHarnessFacet(address(diamond)).sentinels();
        for (uint256 i; i < values.length; ++i) {
            assertEq(values[i], 101 + i);
        }
        assertEq(IERC173(address(diamond)).owner(), owner);
    }

    function test_CrossFacetReentrancyRevertsAndGuardRecovers() public {
        vm.expectRevert(LibCrottoGuard.ReentrantCall.selector);
        IGuardHarness(address(diamond)).reenterGuardedIncrement();

        IGuardHarness(address(diamond)).guardedIncrement();
    }

    function test_TrustedRewardNFTCanCallBackWhileGuardIsIdle() public {
        rewardNFT.invoke(address(diamond), alice, bob, 7);
        assertEq(IGuardHarness(address(diamond)).callbackCount(), 1);
    }

    function test_RevertWhen_UntrustedCallerInvokesRewardNFTCallback() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LibCrottoGuard.UnauthorizedRewardNFTCallback.selector, address(this), address(rewardNFT)
            )
        );
        IGuardHarness(address(diamond)).onRewardNFTTransfer(alice, bob, 7);
    }

    function test_ScopedRewardNFTCallbackConsumesExactContext() public {
        IGuardHarness(address(diamond)).scopedCallback(alice, bob, 7, alice, bob, 7, false);
        assertEq(IGuardHarness(address(diamond)).callbackCount(), 1);
    }

    function test_RevertWhen_ScopedRewardNFTCallbackDoesNotMatchContext() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LibCrottoGuard.UnexpectedRewardNFTTransferCallback.selector, bob, alice, 8, alice, bob, 7
            )
        );
        IGuardHarness(address(diamond)).scopedCallback(alice, bob, 7, bob, alice, 8, false);
        assertEq(IGuardHarness(address(diamond)).callbackCount(), 0);
    }

    function test_RevertWhen_ScopedRewardNFTCallbackIsRepeated() public {
        vm.expectRevert(LibCrottoGuard.RewardNFTTransferContextNotActive.selector);
        IGuardHarness(address(diamond)).scopedCallback(alice, bob, 7, alice, bob, 7, true);
        assertEq(IGuardHarness(address(diamond)).callbackCount(), 0);
    }

    function test_RevertWhen_CallbackOccursInsideGuardWithoutScope() public {
        vm.expectRevert(LibCrottoGuard.RewardNFTTransferContextNotActive.selector);
        IGuardHarness(address(diamond)).callbackInsideGuardWithoutScope(alice, bob, 7);
    }

    function test_RevertWhen_ScopedTransferDoesNotCallBack() public {
        vm.expectRevert(LibCrottoGuard.RewardNFTTransferCallbackNotConsumed.selector);
        IGuardHarness(address(diamond)).scopedWithoutCallback(alice, bob, 7);
    }

    function _deployCoreDiamond() private returns (CrottoDiamond deployed) {
        IDiamondCut.FacetCut[] memory initialCut = new IDiamondCut.FacetCut[](3);
        initialCut[0] = IDiamondCut.FacetCut({
            facetAddress: address(cutFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: _cutSelectors()
        });
        initialCut[1] = IDiamondCut.FacetCut({
            facetAddress: address(loupeFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _loupeSelectors()
        });
        initialCut[2] = IDiamondCut.FacetCut({
            facetAddress: address(ownershipFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _ownershipSelectors()
        });
        deployed = new CrottoDiamond(
            owner, initialCut, address(initializer), abi.encodeCall(CrottoDiamondInit.initialize, ())
        );
    }

    function _installHarnessFacets() private {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(storageFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _storageHarnessSelectors()
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(guardFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _guardHarnessSelectors()
        });
        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
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
        selectors[4] = IERC165.supportsInterface.selector;
    }

    function _ownershipSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IERC173.owner.selector;
        selectors[1] = IERC173.transferOwnership.selector;
    }

    function _storageHarnessSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = StorageHarnessFacet.configureRewardNFT.selector;
        selectors[1] = StorageHarnessFacet.writeSentinels.selector;
        selectors[2] = StorageHarnessFacet.sentinels.selector;
        selectors[3] = StorageHarnessFacet.storageSlots.selector;
    }

    function _guardHarnessSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = IGuardHarness.guardedIncrement.selector;
        selectors[1] = IGuardHarness.reenterGuardedIncrement.selector;
        selectors[2] = IGuardHarness.onRewardNFTTransfer.selector;
        selectors[3] = IGuardHarness.scopedCallback.selector;
        selectors[4] = IGuardHarness.callbackInsideGuardWithoutScope.selector;
        selectors[5] = IGuardHarness.scopedWithoutCallback.selector;
        selectors[6] = IGuardHarness.callbackCount.selector;
    }
}
