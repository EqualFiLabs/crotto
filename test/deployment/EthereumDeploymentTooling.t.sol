// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    CrottoDeploymentConfig,
    CrottoDeploymentConfiguration,
    EthereumTarget
} from "../../script/CrottoDeploymentConfig.sol";
import {CrottoScriptBase} from "../../script/CrottoScriptBase.sol";
import {CrottoConstants} from "../../src/libraries/CrottoConstants.sol";
import {LibCrottoValidation} from "../../src/libraries/LibCrottoValidation.sol";

contract CrottoScriptBaseHarness is CrottoScriptBase {}

contract CrottoDeploymentConfigHarness is CrottoDeploymentConfig {
    function parseInt24(string memory json) external pure returns (int24) {
        return _int24(json, ".value");
    }

    function parseUint192(string memory json) external pure returns (uint192) {
        return _uint192(json, ".value", "operationsReserveCap");
    }
}

contract EthereumDeploymentToolingTest is Test {
    CrottoDeploymentConfig private configurationReader;
    CrottoDeploymentConfigHarness private configurationHarness;
    CrottoScriptBaseHarness private scriptBase;

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

    function setUp() public {
        configurationReader = new CrottoDeploymentConfig();
        configurationHarness = new CrottoDeploymentConfigHarness();
        scriptBase = new CrottoScriptBaseHarness();
    }

    function test_LoadsAndValidatesRequiredSepoliaRehearsalEconomics() public view {
        CrottoDeploymentConfiguration memory configuration = configurationReader.loadConfiguration(
            string.concat(vm.projectRoot(), "/script/config/sepolia-rehearsal.json")
        );
        configurationReader.validateEconomics(configuration);

        assertTrue(configuration.enforceRuntimeCodeHashes);
        assertEq(configuration.rewardNFTMaxSupply, 10_000);
        assertEq(configuration.round.winnerShareBps, 5_000);
        assertEq(configuration.round.nftShareBps, 3_000);
        assertEq(configuration.round.treasuryShareBps, 1_000);
        assertEq(configuration.round.buybackShareBps, 1_000);
        assertEq(configuration.round.operationsReserveCap, 1 ether);
        assertEq(configuration.round.vrfTimeoutBlocks, 30);
        assertEq(configuration.hook.inputFeeBps, 50);
        assertEq(configuration.hook.outputFeeBps, 50);
        assertEq(configuration.buyback.callerTipBps, 10);
        assertEq(configuration.buyback.maximumWethChunk, 0.1 ether);
    }

    function test_EthereumTargetsPinVerifiedDependencies() public view {
        EthereumTarget memory sepolia = configurationReader.ethereumTarget(11_155_111);
        assertEq(sepolia.weth, 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14);
        assertEq(sepolia.poolManager, 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
        assertEq(sepolia.vrfWrapper, 0x195f15F2d49d693cE265b4fB0fdDbE15b1850Cc1);
        assertEq(sepolia.create2Deployer, 0x4e59b44847b379578588920cA78FbF26c0B4956C);

        EthereumTarget memory mainnet = configurationReader.ethereumTarget(1);
        assertEq(mainnet.weth, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        assertEq(mainnet.poolManager, 0x000000000004444c5dc75cB358380D2e3dE08A90);
        assertEq(mainnet.vrfWrapper, 0x02aae1A04f9828517b3007f83f6181900CaD910c);
        assertEq(mainnet.create2Deployer, sepolia.create2Deployer);
    }

    function test_RejectsDisablingRuntimeCodeHashEnforcement() public {
        CrottoDeploymentConfiguration memory configuration = configurationReader.loadConfiguration(
            string.concat(vm.projectRoot(), "/script/config/sepolia-rehearsal.json")
        );
        configuration.enforceRuntimeCodeHashes = false;

        vm.expectRevert(CrottoDeploymentConfig.RuntimeCodeHashEnforcementRequired.selector);
        configurationReader.validateEconomics(configuration);
    }

    function test_RejectsSepoliaConfigurationWithVrfTimeoutBelowConfirmations() public {
        CrottoDeploymentConfiguration memory configuration = configurationReader.loadConfiguration(
            string.concat(vm.projectRoot(), "/script/config/sepolia-rehearsal.json")
        );
        configuration.round.vrfTimeoutBlocks = configuration.vrfRequestConfirmations + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                LibCrottoValidation.InvalidVrfTimeout.selector,
                configuration.round.vrfTimeoutBlocks,
                uint256(configuration.vrfRequestConfirmations) + 2,
                CrottoConstants.MAX_VRF_TIMEOUT_BLOCKS
            )
        );
        configurationReader.validateEconomics(configuration);
    }

    function test_Int24MinimumOverflowUsesNarrowValueError() public {
        string memory json = '{"value":-57896044618658097711785492504343953926634992332820282019728792003956564819968}';

        vm.expectRevert(
            abi.encodeWithSelector(
                CrottoDeploymentConfig.NarrowValueOverflow.selector, bytes32("canonicalTickSpacing"), uint256(1) << 255
            )
        );
        configurationHarness.parseInt24(json);
    }

    function test_OperationsReserveCapRejectsUint192Overflow() public {
        string memory json = '{"value":6277101735386680763835789423207666416102355444464034512896}';

        vm.expectRevert(
            abi.encodeWithSelector(
                CrottoDeploymentConfig.NarrowValueOverflow.selector,
                bytes32("operationsReserveCap"),
                uint256(type(uint192).max) + 1
            )
        );
        configurationHarness.parseUint192(json);
    }

    function test_CompleteDeploymentFacetManifestHasNoSelectorCollisions() public view {
        bytes4[] memory seen = new bytes4[](128);
        uint256 seenCount;

        for (uint256 i; i < facetNames.length; ++i) {
            bytes4[] memory selectors = scriptBase.facetSelectors(facetNames[i]);
            assertGt(selectors.length, 0, facetNames[i]);
            for (uint256 j; j < selectors.length; ++j) {
                bytes4 selector = selectors[j];
                for (uint256 k; k < seenCount; ++k) {
                    assertTrue(selector != seen[k], "facet selector collision");
                }
                seen[seenCount++] = selector;
            }
        }

        assertEq(seenCount, 91);
    }
}
