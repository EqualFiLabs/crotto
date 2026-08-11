// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {CrottoDiamond} from "../../src/diamond/CrottoDiamond.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {LotteryViewFacet} from "../../src/diamond/facets/LotteryViewFacet.sol";
import {CrottoTimelock} from "../../src/governance/CrottoTimelock.sol";
import {ICrotto} from "../../src/interfaces/ICrotto.sol";
import {ICrottoFinalImmutability} from "../../src/interfaces/ICrottoFinalImmutability.sol";
import {ICrottoGovernance} from "../../src/interfaces/ICrottoGovernance.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/diamond/IERC173.sol";
import {LibCrottoReleaseManifest} from "../../src/diamond/libraries/LibCrottoReleaseManifest.sol";
import {LibDiamond} from "../../src/diamond/libraries/LibDiamond.sol";

contract ReleaseManifestProbe {
    function ping() external pure returns (bool) {
        return true;
    }
}

contract ReleaseManifestHarness {
    function finalSelectorCount() external pure returns (uint256) {
        return LibCrottoReleaseManifest.FINAL_SELECTOR_COUNT;
    }

    function finalSelectorSetHash() external pure returns (bytes32) {
        return LibCrottoReleaseManifest.FINAL_SELECTOR_SET_HASH;
    }
}

contract FinalImmutabilityTest is Test {
    string[16] private facetNames = [
        "DiamondCutFacet",
        "DiamondLoupeFacet",
        "OwnershipFacet",
        "GovernanceFacet",
        "BuilderFeesFacet",
        "LotteryTicketFacet",
        "LotteryVRFFacet",
        "LotteryFinalizationFacet",
        "LotteryViewFacet",
        "OperationsFacet",
        "RewardActivationFacet",
        "RewardClaimsFacet",
        "RewardAccountingFacet",
        "NFTVaultFacet",
        "POLInitializationFacet",
        "BuybackSettlementFacet"
    ];

    CrottoDiamond private diamond;
    IDiamondLoupe private loupe;

    function setUp() public {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](facetNames.length);
        for (uint256 i; i < facetNames.length; ++i) {
            address facet = vm.deployCode(string.concat(facetNames[i], ".sol:", facetNames[i]));
            cuts[i] = IDiamondCut.FacetCut({
                facetAddress: facet,
                action: IDiamondCut.FacetCutAction.Add,
                functionSelectors: _artifactSelectors(facetNames[i])
            });
        }
        diamond = new CrottoDiamond(address(this), cuts, address(0), bytes(""));
        loupe = IDiamondLoupe(address(diamond));
    }

    function test_FinalizationAtomicallyEnforcesCanonicalReleaseManifest() public {
        bytes32 expectedPreFinalManifestHash = _manifestHash();
        address ownerBefore = IERC173(address(diamond)).owner();

        ICrottoFinalImmutability(address(diamond)).finalizeImmutability(expectedPreFinalManifestHash);

        assertEq(loupe.facetAddress(IDiamondCut.diamondCut.selector), address(0));
        assertEq(loupe.facetAddress(IERC173.transferOwnership.selector), address(0));
        assertEq(loupe.facetAddress(ICrottoFinalImmutability.finalizeImmutability.selector), address(0));
        assertNotEq(loupe.facetAddress(IERC173.owner.selector), address(0));
        assertNotEq(loupe.facetAddress(ICrotto.buyTickets.selector), address(0));
        assertNotEq(loupe.facetAddress(ICrotto.claimWinnings.selector), address(0));
        assertNotEq(loupe.facetAddress(ICrottoGovernance.setRoundConfiguration.selector), address(0));
        assertNotEq(loupe.facetAddress(ICrottoGovernance.addPOL.selector), address(0));
        assertNotEq(loupe.facetAddress(ICrottoGovernance.pauseActions.selector), address(0));
        assertEq(IERC173(address(diamond)).owner(), ownerBefore);

        IDiamondCut.FacetCut[] memory restoreCut = new IDiamondCut.FacetCut[](0);
        vm.expectRevert(
            abi.encodeWithSelector(CrottoDiamond.FunctionNotFound.selector, IDiamondCut.diamondCut.selector)
        );
        IDiamondCut(address(diamond)).diamondCut(restoreCut, address(0), bytes(""));

        ReleaseManifestHarness manifest = new ReleaseManifestHarness();
        (bytes32 actualHash, uint256 actualCount) = _selectorSetHash();
        assertEq(actualHash, manifest.finalSelectorSetHash());
        assertEq(actualCount, manifest.finalSelectorCount());
    }

    function test_OpenExecutorExecutesCommittedFinalizationThroughTimelock() public {
        address proposer = makeAddr("proposer");
        address executor = makeAddr("executor");
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        CrottoTimelock timelock = new CrottoTimelock(proposers, executors, address(this));
        IERC173(address(diamond)).transferOwnership(address(timelock));

        bytes32 expectedPreFinalManifestHash = _manifestHash();
        bytes memory payload =
            abi.encodeCall(ICrottoFinalImmutability.finalizeImmutability, (expectedPreFinalManifestHash));
        bytes32 salt = keccak256("final-immutability");
        uint256 delay = timelock.getMinDelay();
        vm.prank(proposer);
        timelock.schedule(address(diamond), 0, payload, bytes32(0), salt, delay);
        vm.warp(block.timestamp + delay);

        vm.prank(executor);
        timelock.execute(address(diamond), 0, payload, bytes32(0), salt);

        assertEq(loupe.facetAddress(IDiamondCut.diamondCut.selector), address(0));
        assertEq(loupe.facetAddress(IERC173.transferOwnership.selector), address(0));
        assertEq(loupe.facetAddress(ICrottoFinalImmutability.finalizeImmutability.selector), address(0));
        assertEq(IERC173(address(diamond)).owner(), address(timelock));
    }

    function test_RevertWhen_ManifestChangesAfterCommitment() public {
        bytes32 staleManifestHash = _manifestHash();
        LotteryViewFacet replacement = new LotteryViewFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = LotteryViewFacet.currentRoundId.selector;
        _cut(address(replacement), IDiamondCut.FacetCutAction.Replace, selectors);

        vm.expectPartialRevert(DiamondCutFacet.UnexpectedPreFinalManifest.selector);
        ICrottoFinalImmutability(address(diamond)).finalizeImmutability(staleManifestHash);

        assertNotEq(loupe.facetAddress(IDiamondCut.diamondCut.selector), address(0));
        assertNotEq(loupe.facetAddress(IERC173.transferOwnership.selector), address(0));
        assertNotEq(loupe.facetAddress(ICrottoFinalImmutability.finalizeImmutability.selector), address(0));
    }

    function test_RevertAtomicallyWhen_PostFinalSelectorSetIsIncomplete() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ICrotto.buyTickets.selector;
        _cut(address(0), IDiamondCut.FacetCutAction.Remove, selectors);

        bytes32 currentManifestHash = _manifestHash();
        vm.expectPartialRevert(DiamondCutFacet.UnexpectedFinalSelectorSet.selector);
        ICrottoFinalImmutability(address(diamond)).finalizeImmutability(currentManifestHash);

        assertNotEq(loupe.facetAddress(IDiamondCut.diamondCut.selector), address(0));
        assertNotEq(loupe.facetAddress(IERC173.transferOwnership.selector), address(0));
        assertNotEq(loupe.facetAddress(ICrottoFinalImmutability.finalizeImmutability.selector), address(0));
    }

    function test_RevertAtomicallyWhen_PostFinalSelectorSetHasUnexpectedSelector() public {
        ReleaseManifestProbe probe = new ReleaseManifestProbe();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ReleaseManifestProbe.ping.selector;
        _cut(address(probe), IDiamondCut.FacetCutAction.Add, selectors);

        bytes32 currentManifestHash = _manifestHash();
        vm.expectPartialRevert(DiamondCutFacet.UnexpectedFinalSelectorSet.selector);
        ICrottoFinalImmutability(address(diamond)).finalizeImmutability(currentManifestHash);

        assertNotEq(loupe.facetAddress(IDiamondCut.diamondCut.selector), address(0));
        assertNotEq(loupe.facetAddress(IERC173.transferOwnership.selector), address(0));
        assertNotEq(loupe.facetAddress(ICrottoFinalImmutability.finalizeImmutability.selector), address(0));
    }

    function test_RevertWhen_CallerIsNotOwner() public {
        address stranger = makeAddr("stranger");
        bytes32 currentManifestHash = _manifestHash();
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, stranger, address(this)));
        vm.prank(stranger);
        ICrottoFinalImmutability(address(diamond)).finalizeImmutability(currentManifestHash);
    }

    function _cut(address facet, IDiamondCut.FacetCutAction action, bytes4[] memory selectors) private {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({facetAddress: facet, action: action, functionSelectors: selectors});
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), bytes(""));
    }

    function _artifactSelectors(string memory facet) private view returns (bytes4[] memory selectors) {
        string memory artifactPath = string.concat(vm.projectRoot(), "/out/", facet, ".sol/", facet, ".json");
        // Facet names come only from the fixed production manifest above, and this reads generated Foundry output.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory artifactJson = vm.readFile(artifactPath);
        string[] memory signatures = vm.parseJsonKeys(artifactJson, ".methodIdentifiers");
        selectors = new bytes4[](signatures.length);
        for (uint256 i; i < signatures.length; ++i) {
            selectors[i] = bytes4(keccak256(bytes(signatures[i])));
        }
    }

    function _manifestHash() private view returns (bytes32) {
        return keccak256(abi.encode(loupe.facets()));
    }

    function _selectorSetHash() private view returns (bytes32 hash, uint256 count) {
        IDiamondLoupe.Facet[] memory facets_ = loupe.facets();
        for (uint256 i; i < facets_.length; ++i) {
            count += facets_[i].functionSelectors.length;
        }
        bytes4[] memory selectors = new bytes4[](count);
        uint256 cursor;
        for (uint256 i; i < facets_.length; ++i) {
            for (uint256 j; j < facets_[i].functionSelectors.length; ++j) {
                selectors[cursor++] = facets_[i].functionSelectors[j];
            }
        }
        _sortSelectors(selectors);
        hash = keccak256(abi.encode(selectors));
    }

    function _sortSelectors(bytes4[] memory selectors) private pure {
        for (uint256 i = 1; i < selectors.length; ++i) {
            bytes4 value = selectors[i];
            uint256 j = i;
            while (j != 0 && uint32(selectors[j - 1]) > uint32(value)) {
                selectors[j] = selectors[j - 1];
                --j;
            }
            selectors[j] = value;
        }
    }
}
