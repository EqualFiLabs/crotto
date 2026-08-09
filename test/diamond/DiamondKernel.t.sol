// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {CrottoDiamond} from "../../src/diamond/CrottoDiamond.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {CrottoDiamondInit} from "../../src/diamond/initializers/CrottoDiamondInit.sol";
import {LibDiamond} from "../../src/diamond/libraries/LibDiamond.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/diamond/IERC173.sol";

interface IUnknownDiamondFunction {
    function unknown() external;
}

library KernelTestStorage {
    bytes32 internal constant SLOT = keccak256("crotto.test.storage.Kernel");

    struct Layout {
        uint256 value;
    }

    function layout() internal pure returns (Layout storage state) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            state.slot := slot
        }
    }

    function storageSlot() internal pure returns (bytes32) {
        return SLOT;
    }
}

contract KernelFacetV1 {
    error KernelFailure(uint256 code);

    function setValue(uint256 newValue) external {
        KernelTestStorage.layout().value = newValue;
    }

    function value() external view returns (uint256) {
        return KernelTestStorage.layout().value;
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function fail(uint256 code) external pure {
        revert KernelFailure(code);
    }
}

contract KernelFacetV2 {
    function setValue(uint256 newValue) external {
        KernelTestStorage.layout().value = newValue * 2;
    }

    function value() external view returns (uint256) {
        return KernelTestStorage.layout().value;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract KernelInitializer {
    error InitializationReverted(uint256 value);

    function setValue(uint256 value) external {
        KernelTestStorage.layout().value = value;
    }

    function setValueThenRevert(uint256 value) external {
        KernelTestStorage.layout().value = value;
        revert InitializationReverted(value);
    }
}

contract DiamondKernelTest is Test {
    address private owner = makeAddr("owner");
    address private nextOwner = makeAddr("nextOwner");

    DiamondCutFacet private cutFacet;
    DiamondLoupeFacet private loupeFacet;
    OwnershipFacet private ownershipFacet;
    CrottoDiamondInit private coreInitializer;
    CrottoDiamond private diamond;

    function setUp() public {
        cutFacet = new DiamondCutFacet();
        loupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        coreInitializer = new CrottoDiamondInit();
        diamond = _deployCoreDiamond();
    }

    function test_ConstructorAtomicallyInstallsCoreFacetsAndInterfaces() public view {
        IDiamondLoupe loupe = IDiamondLoupe(address(diamond));
        assertEq(loupe.facetAddresses().length, 3);
        assertEq(loupe.facetAddress(IDiamondCut.diamondCut.selector), address(cutFacet));
        assertEq(loupe.facetAddress(IDiamondLoupe.facets.selector), address(loupeFacet));
        assertEq(loupe.facetAddress(IERC173.owner.selector), address(ownershipFacet));
        assertEq(IERC173(address(diamond)).owner(), owner);

        assertTrue(IERC165(address(diamond)).supportsInterface(type(IERC165).interfaceId));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IDiamondCut).interfaceId));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IDiamondLoupe).interfaceId));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IERC173).interfaceId));
        assertFalse(IERC165(address(diamond)).supportsInterface(0xffffffff));
    }

    function test_ReceiveAcceptsNativeEth() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(diamond).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(diamond).balance, 1 ether);
    }

    function test_RevertWhen_SelectorIsUnknown() public {
        bytes4 selector = IUnknownDiamondFunction.unknown.selector;
        vm.expectRevert(abi.encodeWithSelector(CrottoDiamond.FunctionNotFound.selector, selector));
        IUnknownDiamondFunction(address(diamond)).unknown();
    }

    function test_AddReplaceAndRemovePreserveRoutingAndStorage() public {
        KernelFacetV1 facetV1 = new KernelFacetV1();
        KernelFacetV2 facetV2 = new KernelFacetV2();
        bytes4[] memory selectors = _kernelSelectors();

        _cut(address(facetV1), IDiamondCut.FacetCutAction.Add, selectors, address(0), "");
        KernelFacetV1(address(diamond)).setValue(21);
        assertEq(KernelFacetV1(address(diamond)).value(), 21);
        assertEq(KernelFacetV1(address(diamond)).version(), 1);

        _cut(address(facetV2), IDiamondCut.FacetCutAction.Replace, selectors, address(0), "");
        assertEq(KernelFacetV2(address(diamond)).value(), 21);
        assertEq(KernelFacetV2(address(diamond)).version(), 2);
        KernelFacetV2(address(diamond)).setValue(21);
        assertEq(KernelFacetV2(address(diamond)).value(), 42);

        _cut(address(0), IDiamondCut.FacetCutAction.Remove, selectors, address(0), "");
        assertEq(IDiamondLoupe(address(diamond)).facetFunctionSelectors(address(facetV2)).length, 0);
        assertEq(IDiamondLoupe(address(diamond)).facetAddress(KernelFacetV2.version.selector), address(0));
    }

    function test_FallbackBubblesFacetRevertData() public {
        KernelFacetV1 facet = new KernelFacetV1();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = KernelFacetV1.fail.selector;
        _cut(address(facet), IDiamondCut.FacetCutAction.Add, selectors, address(0), "");

        vm.expectRevert(abi.encodeWithSelector(KernelFacetV1.KernelFailure.selector, 7));
        KernelFacetV1(address(diamond)).fail(7);
    }

    function test_DiamondCutInitializerWritesInDiamondStorage() public {
        KernelFacetV1 facet = new KernelFacetV1();
        KernelInitializer initializer = new KernelInitializer();
        bytes4[] memory selectors = _kernelSelectors();

        _cut(
            address(facet),
            IDiamondCut.FacetCutAction.Add,
            selectors,
            address(initializer),
            abi.encodeCall(KernelInitializer.setValue, (55))
        );

        assertEq(KernelFacetV1(address(diamond)).value(), 55);
    }

    function test_RevertingInitializerRollsBackCutAndStorage() public {
        KernelFacetV1 facet = new KernelFacetV1();
        KernelInitializer initializer = new KernelInitializer();
        bytes4[] memory selectors = _kernelSelectors();

        vm.expectRevert(abi.encodeWithSelector(KernelInitializer.InitializationReverted.selector, 55));
        _cut(
            address(facet),
            IDiamondCut.FacetCutAction.Add,
            selectors,
            address(initializer),
            abi.encodeCall(KernelInitializer.setValueThenRevert, (55))
        );

        assertEq(IDiamondLoupe(address(diamond)).facetAddress(KernelFacetV1.value.selector), address(0));
        assertEq(uint256(vm.load(address(diamond), KernelTestStorage.storageSlot())), 0);
    }

    function test_OnlyOwnerCanCutAndTransferOwnership() public {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](0);

        vm.prank(nextOwner);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, nextOwner, owner));
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        vm.prank(nextOwner);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, nextOwner, owner));
        IERC173(address(diamond)).transferOwnership(nextOwner);

        vm.prank(owner);
        IERC173(address(diamond)).transferOwnership(nextOwner);
        assertEq(IERC173(address(diamond)).owner(), nextOwner);
    }

    function test_RevertWhen_OwnershipTransferredToZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(LibDiamond.ZeroAddress.selector);
        IERC173(address(diamond)).transferOwnership(address(0));
    }

    function test_RevertWhen_AddingExistingSelector() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;

        vm.expectRevert(abi.encodeWithSelector(LibDiamond.SelectorAlreadyExists.selector, selectors[0]));
        _cut(address(cutFacet), IDiamondCut.FacetCutAction.Add, selectors, address(0), "");
    }

    function test_RevertWhen_ReplacingSelectorWithSameFacet() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;

        vm.expectRevert(
            abi.encodeWithSelector(
                LibDiamond.CannotReplaceSelectorWithSameFacet.selector, selectors[0], address(cutFacet)
            )
        );
        _cut(address(cutFacet), IDiamondCut.FacetCutAction.Replace, selectors, address(0), "");
    }

    function test_RevertWhen_ReplacingOrRemovingMissingSelector() public {
        KernelFacetV1 facet = new KernelFacetV1();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = KernelFacetV1.value.selector;

        vm.expectRevert(abi.encodeWithSelector(LibDiamond.SelectorDoesNotExist.selector, selectors[0]));
        _cut(address(facet), IDiamondCut.FacetCutAction.Replace, selectors, address(0), "");

        vm.expectRevert(abi.encodeWithSelector(LibDiamond.SelectorDoesNotExist.selector, selectors[0]));
        _cut(address(0), IDiamondCut.FacetCutAction.Remove, selectors, address(0), "");
    }

    function test_RevertWhen_RemoveFacetAddressIsNonzero() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;

        vm.expectRevert(abi.encodeWithSelector(LibDiamond.RemoveFacetAddressMustBeZero.selector, address(cutFacet)));
        _cut(address(cutFacet), IDiamondCut.FacetCutAction.Remove, selectors, address(0), "");
    }

    function test_RevertWhen_FacetHasNoCodeOrCutIsEmpty() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = KernelFacetV1.value.selector;

        vm.expectRevert(abi.encodeWithSelector(LibDiamond.FacetHasNoCode.selector, nextOwner));
        _cut(nextOwner, IDiamondCut.FacetCutAction.Add, selectors, address(0), "");

        selectors = new bytes4[](0);
        vm.expectRevert(LibDiamond.EmptyFacetCut.selector);
        _cut(address(cutFacet), IDiamondCut.FacetCutAction.Add, selectors, address(0), "");
    }

    function test_RevertWhen_InitializerPairIsMalformed() public {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](0);

        vm.prank(owner);
        vm.expectRevert(LibDiamond.InitAddressIsZeroButCalldataIsNotEmpty.selector);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), hex"01");

        KernelInitializer initializer = new KernelInitializer();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.InitCalldataIsEmpty.selector, address(initializer)));
        IDiamondCut(address(diamond)).diamondCut(cuts, address(initializer), "");
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
            owner, initialCut, address(coreInitializer), abi.encodeCall(CrottoDiamondInit.initialize, ())
        );
    }

    function _cut(
        address facet,
        IDiamondCut.FacetCutAction action,
        bytes4[] memory selectors,
        address init,
        bytes memory initCalldata
    ) private {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({facetAddress: facet, action: action, functionSelectors: selectors});
        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(cuts, init, initCalldata);
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

    function _kernelSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = KernelFacetV1.setValue.selector;
        selectors[1] = KernelFacetV1.value.selector;
        selectors[2] = KernelFacetV1.version.selector;
    }
}
