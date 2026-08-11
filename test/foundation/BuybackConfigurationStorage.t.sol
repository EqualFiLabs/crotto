// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {LibGovernanceStorage} from "../../src/libraries/storage/LibGovernanceStorage.sol";
import {BuybackConfiguration} from "../../src/types/CrottoTypes.sol";

contract BuybackConfigurationStorageHarness {
    function seedRemovedFields(uint16 legacySlippageBps, uint32 legacyTwapWindowSeconds) external {
        LibGovernanceStorage.StoredBuybackConfiguration storage configuration =
        LibGovernanceStorage.layout().buybackConfiguration;
        configuration.legacySlippageBps = legacySlippageBps;
        configuration.legacyTwapWindowSeconds = legacyTwapWindowSeconds;
    }

    function store(BuybackConfiguration calldata configuration) external {
        LibGovernanceStorage.Layout storage state = LibGovernanceStorage.layout();
        LibGovernanceStorage.storeBuybackConfiguration(state, configuration);
    }

    function load() external view returns (BuybackConfiguration memory) {
        LibGovernanceStorage.Layout storage state = LibGovernanceStorage.layout();
        return LibGovernanceStorage.loadBuybackConfiguration(state);
    }

    function storedFields() external view returns (uint16, uint16, uint32, uint128) {
        LibGovernanceStorage.StoredBuybackConfiguration storage configuration =
        LibGovernanceStorage.layout().buybackConfiguration;
        return (
            configuration.legacySlippageBps,
            configuration.callerTipBps,
            configuration.legacyTwapWindowSeconds,
            configuration.maximumWethChunk
        );
    }
}

contract BuybackConfigurationStorageTest is Test {
    BuybackConfigurationStorageHarness private harness;

    function setUp() public {
        harness = new BuybackConfigurationStorageHarness();
    }

    function test_ActiveConfigurationDoesNotReinterpretOrOverwriteRemovedFields() public {
        harness.seedRemovedFields(500, 30 minutes);
        harness.store(BuybackConfiguration({callerTipBps: 25, maximumWethChunk: 0.2 ether}));

        BuybackConfiguration memory active = harness.load();
        assertEq(active.callerTipBps, 25);
        assertEq(active.maximumWethChunk, 0.2 ether);

        (uint16 legacySlippage, uint16 storedTip, uint32 legacyWindow, uint128 storedChunk) = harness.storedFields();
        assertEq(legacySlippage, 500);
        assertEq(storedTip, 25);
        assertEq(legacyWindow, 30 minutes);
        assertEq(storedChunk, 0.2 ether);
    }
}
