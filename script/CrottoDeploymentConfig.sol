// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {LibCrottoValidation} from "../src/libraries/LibCrottoValidation.sol";
import {
    ActivationConfiguration,
    BuybackConfiguration,
    HookConfiguration,
    RoundConfiguration
} from "../src/types/CrottoTypes.sol";

struct EthereumTarget {
    address weth;
    address poolManager;
    address vrfWrapper;
    address create2Deployer;
    bytes32 wethRuntimeCodeHash;
    bytes32 poolManagerRuntimeCodeHash;
    bytes32 vrfWrapperRuntimeCodeHash;
    bytes32 create2DeployerRuntimeCodeHash;
}

struct CrottoDeploymentConfiguration {
    address treasuryReceiver;
    address guardian;
    address[] proposers;
    bool enforceRuntimeCodeHashes;
    uint256 rewardNFTMaxSupply;
    uint256 vaultPrice;
    uint256 requiredBootstrapWeth;
    uint256 initialTokenPerWethWad;
    uint16 maxCombinedHookFeeBps;
    int24 canonicalTickSpacing;
    uint32 vrfCallbackGasLimit;
    uint16 vrfRequestConfirmations;
    RoundConfiguration round;
    ActivationConfiguration activation;
    HookConfiguration hook;
    BuybackConfiguration buyback;
}

/// @notice Ethereum chain targets and strict JSON configuration loading shared by deployment scripts.
contract CrottoDeploymentConfig is Script {
    uint256 internal constant ETHEREUM_MAINNET_CHAIN_ID = 1;
    uint256 internal constant ETHEREUM_SEPOLIA_CHAIN_ID = 11_155_111;

    error UnsupportedEthereumChain(uint256 chainId);
    error MissingConfigurationAddress(bytes32 field);
    error MissingProposer();
    error RuntimeCodeHashEnforcementRequired();
    error InvalidRuntimeCode(address target, bytes32 expected, bytes32 actual);
    error NarrowValueOverflow(bytes32 field, uint256 value);

    function ethereumTarget(uint256 chainId) public pure returns (EthereumTarget memory target) {
        if (chainId == ETHEREUM_SEPOLIA_CHAIN_ID) {
            return EthereumTarget({
                weth: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14,
                poolManager: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543,
                vrfWrapper: 0x195f15F2d49d693cE265b4fB0fdDbE15b1850Cc1,
                create2Deployer: 0x4e59b44847b379578588920cA78FbF26c0B4956C,
                wethRuntimeCodeHash: 0xc864e10689f2da18833652a3b075d43106e87f0f90d95ee64f6f0b33bc026083,
                poolManagerRuntimeCodeHash: 0x09930125a49f5b95caf8052991cc14d1240dca8b43f42b899115b86867e4bce1,
                vrfWrapperRuntimeCodeHash: 0x079cd722dd7b8789bdb5f313d032e4f8fe66bb75e93f07acd6ec33b50d1dc42b,
                create2DeployerRuntimeCodeHash: 0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989
            });
        }
        if (chainId == ETHEREUM_MAINNET_CHAIN_ID) {
            return EthereumTarget({
                weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                poolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90,
                vrfWrapper: 0x02aae1A04f9828517b3007f83f6181900CaD910c,
                create2Deployer: 0x4e59b44847b379578588920cA78FbF26c0B4956C,
                wethRuntimeCodeHash: 0xd0a06b12ac47863b5c7be4185c2deaad1c61557033f56c7d4ea74429cbb25e23,
                poolManagerRuntimeCodeHash: 0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293,
                vrfWrapperRuntimeCodeHash: 0x79dd04a1a325740433d8ffbbc0a9217c5d88992d6f58c58daad0982d41f639bc,
                create2DeployerRuntimeCodeHash: 0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989
            });
        }
        revert UnsupportedEthereumChain(chainId);
    }

    function loadConfiguration(string memory path)
        public
        view
        returns (CrottoDeploymentConfiguration memory configuration)
    {
        string memory json = vm.readFile(path);
        configuration.treasuryReceiver = vm.parseJsonAddress(json, ".treasuryReceiver");
        configuration.guardian = vm.parseJsonAddress(json, ".guardian");
        configuration.proposers = vm.parseJsonAddressArray(json, ".proposers");
        configuration.enforceRuntimeCodeHashes = vm.parseJsonBool(json, ".enforceRuntimeCodeHashes");
        configuration.rewardNFTMaxSupply = vm.parseJsonUint(json, ".immutable.rewardNFTMaxSupply");
        configuration.vaultPrice = vm.parseJsonUint(json, ".immutable.vaultPrice");
        configuration.requiredBootstrapWeth = vm.parseJsonUint(json, ".immutable.requiredBootstrapWeth");
        configuration.initialTokenPerWethWad = vm.parseJsonUint(json, ".immutable.initialTokenPerWethWad");
        configuration.maxCombinedHookFeeBps = _uint16(json, ".immutable.maxCombinedHookFeeBps", "maxCombinedHookFeeBps");
        configuration.canonicalTickSpacing = _int24(json, ".immutable.canonicalTickSpacing");
        configuration.vrfCallbackGasLimit = _uint32(json, ".immutable.vrfCallbackGasLimit", "vrfCallbackGasLimit");
        configuration.vrfRequestConfirmations =
            _uint16(json, ".immutable.vrfRequestConfirmations", "vrfRequestConfirmations");

        configuration.round = RoundConfiguration({
            ticketPrice: vm.parseJsonUint(json, ".round.ticketPrice"),
            ticketOperationsFee: vm.parseJsonUint(json, ".round.ticketOperationsFee"),
            playerRewardRate: vm.parseJsonUint(json, ".round.playerRewardRate"),
            ticketTarget: vm.parseJsonUint(json, ".round.ticketTarget"),
            maxVrfCost: vm.parseJsonUint(json, ".round.maxVrfCost"),
            vrfTimeoutBlocks: vm.parseJsonUint(json, ".round.vrfTimeoutBlocks"),
            requestCallerReward: vm.parseJsonUint(json, ".round.requestCallerReward"),
            finalizationCallerReward: vm.parseJsonUint(json, ".round.finalizationCallerReward"),
            winnerShareBps: _uint16(json, ".round.winnerShareBps", "winnerShareBps"),
            nftShareBps: _uint16(json, ".round.nftShareBps", "nftShareBps"),
            treasuryShareBps: _uint16(json, ".round.treasuryShareBps", "treasuryShareBps"),
            buybackShareBps: _uint16(json, ".round.buybackShareBps", "buybackShareBps"),
            operationsReserveCap: _uint192(json, ".round.operationsReserveCap", "operationsReserveCap")
        });

        uint256[] memory costs = vm.parseJsonUintArray(json, ".activation.costs");
        uint256[] memory weights = vm.parseJsonUintArray(json, ".activation.destinationWeights");
        if (costs.length != 3 || weights.length != 3) {
            revert NarrowValueOverflow("activationArrayLength", costs.length);
        }
        configuration.activation.costs = [costs[0], costs[1], costs[2]];
        configuration.activation.destinationWeights = [weights[0], weights[1], weights[2]];
        configuration.activation.burnShareBps = _uint16(json, ".activation.burnShareBps", "burnShareBps");
        configuration.activation.nftShareBps = _uint16(json, ".activation.nftShareBps", "activationNftShareBps");
        configuration.activation.treasuryShareBps =
            _uint16(json, ".activation.treasuryShareBps", "activationTreasuryShareBps");

        configuration.hook = HookConfiguration({
            inputFeeBps: _uint16(json, ".hook.inputFeeBps", "inputFeeBps"),
            outputFeeBps: _uint16(json, ".hook.outputFeeBps", "outputFeeBps"),
            polShareBps: _uint16(json, ".hook.polShareBps", "polShareBps"),
            nftShareBps: _uint16(json, ".hook.nftShareBps", "hookNftShareBps"),
            treasuryShareBps: _uint16(json, ".hook.treasuryShareBps", "hookTreasuryShareBps")
        });
        uint256 maximumWethChunk = vm.parseJsonUint(json, ".buyback.maximumWethChunk");
        if (maximumWethChunk > type(uint128).max) revert NarrowValueOverflow("maximumWethChunk", maximumWethChunk);
        configuration.buyback = BuybackConfiguration({
            slippageBps: _uint16(json, ".buyback.slippageBps", "slippageBps"),
            callerTipBps: _uint16(json, ".buyback.callerTipBps", "callerTipBps"),
            twapWindowSeconds: _uint32(json, ".buyback.twapWindowSeconds", "twapWindowSeconds"),
            maximumWethChunk: uint128(maximumWethChunk)
        });
    }

    function validateTarget(EthereumTarget memory target) public view {
        _validateCode(target.weth, target.wethRuntimeCodeHash);
        _validateCode(target.poolManager, target.poolManagerRuntimeCodeHash);
        _validateCode(target.vrfWrapper, target.vrfWrapperRuntimeCodeHash);
        _validateCode(target.create2Deployer, target.create2DeployerRuntimeCodeHash);
    }

    function validateEconomics(CrottoDeploymentConfiguration memory configuration) public pure {
        if (configuration.treasuryReceiver == address(0)) revert MissingConfigurationAddress("treasuryReceiver");
        if (configuration.guardian == address(0)) revert MissingConfigurationAddress("guardian");
        if (!configuration.enforceRuntimeCodeHashes) revert RuntimeCodeHashEnforcementRequired();
        if (configuration.proposers.length == 0) revert MissingProposer();
        for (uint256 i; i < configuration.proposers.length; ++i) {
            if (configuration.proposers[i] == address(0)) revert MissingProposer();
        }
        LibCrottoValidation.validateRoundConfiguration(configuration.round);
        LibCrottoValidation.validateVrfTimeout(
            configuration.round.vrfTimeoutBlocks, configuration.vrfRequestConfirmations
        );
        LibCrottoValidation.validateBootstrapReachability(configuration.round, configuration.requiredBootstrapWeth);
        LibCrottoValidation.validateActivationConfiguration(configuration.activation, configuration.rewardNFTMaxSupply);
        LibCrottoValidation.validateHookConfiguration(configuration.hook, configuration.maxCombinedHookFeeBps);
        LibCrottoValidation.validateBuybackConfiguration(configuration.buyback);
    }

    function _validateCode(address target, bytes32 expectedHash) private view {
        bytes32 actualHash = target.codehash;
        if (target.code.length == 0 || actualHash != expectedHash) {
            revert InvalidRuntimeCode(target, expectedHash, actualHash);
        }
    }

    function _uint16(string memory json, string memory key, bytes32 field) private pure returns (uint16 value) {
        uint256 parsed = vm.parseJsonUint(json, key);
        if (parsed > type(uint16).max) revert NarrowValueOverflow(field, parsed);
        value = uint16(parsed);
    }

    function _uint32(string memory json, string memory key, bytes32 field) private pure returns (uint32 value) {
        uint256 parsed = vm.parseJsonUint(json, key);
        if (parsed > type(uint32).max) revert NarrowValueOverflow(field, parsed);
        value = uint32(parsed);
    }

    function _uint192(string memory json, string memory key, bytes32 field) internal pure returns (uint192 value) {
        uint256 parsed = vm.parseJsonUint(json, key);
        if (parsed > type(uint192).max) revert NarrowValueOverflow(field, parsed);
        value = uint192(parsed);
    }

    function _int24(string memory json, string memory key) internal pure returns (int24 value) {
        int256 parsed = vm.parseJsonInt(json, key);
        if (parsed < type(int24).min || parsed > type(int24).max) {
            uint256 magnitude = parsed < 0 ? uint256(-(parsed + 1)) + 1 : uint256(parsed);
            revert NarrowValueOverflow("canonicalTickSpacing", magnitude);
        }
        value = int24(parsed);
    }
}
