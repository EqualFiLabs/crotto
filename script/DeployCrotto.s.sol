// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {CrottoTimelock} from "../src/governance/CrottoTimelock.sol";
import {CrottoDiamondInit} from "../src/diamond/initializers/CrottoDiamondInit.sol";
import {IActivationToken} from "../src/interfaces/IActivationToken.sol";
import {ICrottoGovernance} from "../src/interfaces/ICrottoGovernance.sol";
import {ICrottoSwapFeeHook} from "../src/interfaces/ICrottoSwapFeeHook.sol";
import {ICrottoView} from "../src/interfaces/ICrottoView.sol";
import {IRewardNFT} from "../src/interfaces/IRewardNFT.sol";
import {IDiamondCut} from "../src/interfaces/diamond/IDiamondCut.sol";
import {IERC173} from "../src/interfaces/diamond/IERC173.sol";
import {CrottoConstants} from "../src/libraries/CrottoConstants.sol";
import {LibCrottoValidation} from "../src/libraries/LibCrottoValidation.sol";
import {GovernanceInitialization, HookConfiguration, ImmutableConfiguration, Round} from "../src/types/CrottoTypes.sol";
import {CrottoDeploymentConfig, CrottoDeploymentConfiguration, EthereumTarget} from "./CrottoDeploymentConfig.sol";
import {CrottoScriptBase} from "./CrottoScriptBase.sol";

struct CrottoDeploymentResult {
    address timelock;
    address diamond;
    address activationToken;
    address rewardNFT;
    address canonicalHook;
    bytes32 selectorManifestHash;
}

struct CrottoDeploymentKernel {
    address initializer;
    IDiamondCut.FacetCut shellCut;
}

/// @notice Deterministic Ethereum deployment flow for the complete Crotto protocol.
contract DeployCrotto is CrottoScriptBase {
    uint160 private constant REQUIRED_HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    string[14] private facetNames = [
        "DiamondLoupeFacet",
        "OwnershipFacet",
        "GovernanceFacet",
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

    error DeployerRequired();
    error UnexpectedPredictedAddress(address expected, address actual);
    error HookDeploymentFailed(address expectedHook);
    error UnexpectedDeploymentState(bytes32 field);

    event CrottoDeploymentCompleted(
        uint256 indexed chainId,
        address indexed diamond,
        address indexed timelock,
        address activationToken,
        address rewardNFT,
        address canonicalHook,
        bytes32 selectorManifestHash
    );

    function run() external returns (CrottoDeploymentResult memory result) {
        address deployer = vm.envAddress("DEPLOYER");
        if (deployer == address(0)) revert DeployerRequired();
        string memory configPath = vm.envString("CROTTO_DEPLOYMENT_CONFIG");
        CrottoDeploymentConfig reader =
            CrottoDeploymentConfig(_deployArtifact("CrottoDeploymentConfig.sol:CrottoDeploymentConfig", bytes("")));
        CrottoDeploymentConfiguration memory configuration = reader.loadConfiguration(configPath);
        EthereumTarget memory target = reader.ethereumTarget(block.chainid);

        reader.validateTarget(target, configuration.enforceRuntimeCodeHashes);
        reader.validateEconomics(configuration);

        vm.startBroadcast(deployer);
        result = _deploy(deployer, target, configuration);
        vm.stopBroadcast();

        _verifyDeployment(deployer, target, configuration, result);
        result.selectorManifestHash = manifestHash(result.diamond);
        emit CrottoDeploymentCompleted(
            block.chainid,
            result.diamond,
            result.timelock,
            result.activationToken,
            result.rewardNFT,
            result.canonicalHook,
            result.selectorManifestHash
        );
    }

    function _deploy(address deployer, EthereumTarget memory target, CrottoDeploymentConfiguration memory configuration)
        private
        returns (CrottoDeploymentResult memory result)
    {
        CrottoDeploymentKernel memory kernel;
        (result, kernel) = _deployKernel(deployer, configuration);
        (result.activationToken, result.canonicalHook) =
            _deployTokenAndHook(deployer, target, configuration, result.diamond);

        IDiamondCut.FacetCut[] memory applicationCuts = _deployApplicationFacets();
        GovernanceInitialization memory initialization = _initialization(target, configuration, result);
        IDiamondCut(result.diamond)
            .diamondCut(
                applicationCuts,
                kernel.initializer,
                abi.encodeCall(CrottoDiamondInit.initializeGovernance, (initialization))
            );

        IERC173(result.diamond).transferOwnership(result.timelock);
        CrottoTimelock timelock = CrottoTimelock(payable(result.timelock));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        _verifyFacetCut(result.diamond, kernel.shellCut);
        for (uint256 i; i < applicationCuts.length; ++i) {
            _verifyFacetCut(result.diamond, applicationCuts[i]);
        }
    }

    function _deployKernel(address deployer, CrottoDeploymentConfiguration memory configuration)
        private
        returns (CrottoDeploymentResult memory result, CrottoDeploymentKernel memory kernel)
    {
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        result.timelock = _deployArtifact(
            "CrottoTimelock.sol:CrottoTimelock", abi.encode(configuration.proposers, executors, deployer)
        );

        address cutFacet = _deployArtifact("DiamondCutFacet.sol:DiamondCutFacet", bytes(""));
        kernel.initializer = _deployArtifact("CrottoDiamondInit.sol:CrottoDiamondInit", bytes(""));
        IDiamondCut.FacetCut[] memory shellCut = new IDiamondCut.FacetCut[](1);
        shellCut[0] = _facetCut(cutFacet, "DiamondCutFacet", IDiamondCut.FacetCutAction.Add);
        kernel.shellCut = shellCut[0];
        result.diamond =
            _deployArtifact("CrottoDiamond.sol:CrottoDiamond", abi.encode(deployer, shellCut, address(0), bytes("")));
        result.rewardNFT =
            _deployArtifact("RewardNFT.sol:RewardNFT", abi.encode(result.diamond, configuration.rewardNFTMaxSupply));
    }

    function _deployTokenAndHook(
        address deployer,
        EthereumTarget memory target,
        CrottoDeploymentConfiguration memory configuration,
        address diamond
    ) private returns (address activationToken, address canonicalHook) {
        address predictedToken = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        bytes memory hookArguments = abi.encode(
            target.poolManager,
            diamond,
            predictedToken,
            target.weth,
            configuration.canonicalTickSpacing,
            configuration.initialTokenPerWethWad,
            configuration.maxCombinedHookFeeBps
        );
        bytes memory hookCreationCode = vm.getCode("CrottoSwapFeeHook.sol:CrottoSwapFeeHook");
        (address predictedHook, bytes32 hookSalt) =
            HookMiner.find(target.create2Deployer, REQUIRED_HOOK_FLAGS, hookCreationCode, hookArguments);

        activationToken = _deployArtifact(
            "ActivationToken.sol:ActivationToken", abi.encode(configuration.treasuryReceiver, diamond, predictedHook)
        );
        if (activationToken != predictedToken) {
            revert UnexpectedPredictedAddress(predictedToken, activationToken);
        }

        bytes memory hookInitCode = abi.encodePacked(hookCreationCode, hookArguments);
        (bool hookCreated,) = target.create2Deployer.call(abi.encodePacked(hookSalt, hookInitCode));
        if (!hookCreated || predictedHook.code.length == 0) revert HookDeploymentFailed(predictedHook);
        canonicalHook = predictedHook;
    }

    function _deployApplicationFacets() private returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](facetNames.length);
        for (uint256 i; i < facetNames.length; ++i) {
            string memory facet = facetNames[i];
            address implementation = _deployArtifact(string.concat(facet, ".sol:", facet), bytes(""));
            cuts[i] = _facetCut(implementation, facet, IDiamondCut.FacetCutAction.Add);
        }
    }

    function _initialization(
        EthereumTarget memory target,
        CrottoDeploymentConfiguration memory configuration,
        CrottoDeploymentResult memory result
    ) private pure returns (GovernanceInitialization memory initialization) {
        initialization.immutableConfiguration = ImmutableConfiguration({
            activationToken: result.activationToken,
            rewardNFT: result.rewardNFT,
            weth: target.weth,
            vrfWrapper: target.vrfWrapper,
            uniswapV4PoolManager: target.poolManager,
            canonicalHook: result.canonicalHook,
            rewardNFTMaxSupply: configuration.rewardNFTMaxSupply,
            vaultPrice: configuration.vaultPrice,
            requiredBootstrapWeth: configuration.requiredBootstrapWeth,
            initialTokenPerWethWad: configuration.initialTokenPerWethWad,
            maxCombinedHookFeeBps: configuration.maxCombinedHookFeeBps,
            canonicalTickSpacing: configuration.canonicalTickSpacing,
            vrfCallbackGasLimit: configuration.vrfCallbackGasLimit,
            vrfRequestConfirmations: configuration.vrfRequestConfirmations
        });
        initialization.roundConfiguration = configuration.round;
        initialization.activationConfiguration = configuration.activation;
        initialization.hookConfiguration = configuration.hook;
        initialization.treasuryReceiver = configuration.treasuryReceiver;
        initialization.guardian = configuration.guardian;
        initialization.buybackConfiguration = configuration.buyback;
        LibCrottoValidation.validateImmutableConfiguration(initialization.immutableConfiguration);
    }

    function _verifyDeployment(
        address deployer,
        EthereumTarget memory target,
        CrottoDeploymentConfiguration memory configuration,
        CrottoDeploymentResult memory result
    ) private view {
        CrottoTimelock timelock = CrottoTimelock(payable(result.timelock));
        if (IERC173(result.diamond).owner() != result.timelock) revert UnexpectedDeploymentState("diamondOwner");
        if (timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer)) {
            revert UnexpectedDeploymentState("bootstrapAdmin");
        }
        if (!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), result.timelock)) {
            revert UnexpectedDeploymentState("selfAdmin");
        }
        if (!timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0))) {
            revert UnexpectedDeploymentState("openExecutor");
        }
        for (uint256 i; i < configuration.proposers.length; ++i) {
            if (!timelock.hasRole(timelock.PROPOSER_ROLE(), configuration.proposers[i])) {
                revert UnexpectedDeploymentState("proposer");
            }
        }

        IActivationToken token = IActivationToken(result.activationToken);
        if (token.totalSupply() != CrottoConstants.GENESIS_TREASURY_SUPPLY) {
            revert UnexpectedDeploymentState("tokenSupply");
        }
        if (IERC20(result.activationToken).balanceOf(configuration.treasuryReceiver) != token.totalSupply()) {
            revert UnexpectedDeploymentState("treasuryTokenBalance");
        }
        if (token.crottoDiamond() != result.diamond || token.canonicalHook() != result.canonicalHook) {
            revert UnexpectedDeploymentState("tokenBindings");
        }

        IRewardNFT rewardNFT = IRewardNFT(result.rewardNFT);
        if (
            rewardNFT.crottoDiamond() != result.diamond || rewardNFT.maxSupply() != configuration.rewardNFTMaxSupply
                || rewardNFT.mintedSupply() != 0
        ) revert UnexpectedDeploymentState("rewardNftBindings");

        ICrottoSwapFeeHook hook = ICrottoSwapFeeHook(result.canonicalHook);
        if (
            hook.crottoDiamond() != result.diamond || hook.activationToken() != result.activationToken
                || hook.weth() != target.weth || hook.poolInitialized()
        ) revert UnexpectedDeploymentState("hookBindings");
        HookConfiguration memory deployedHookConfiguration = hook.hookConfiguration();
        if (keccak256(abi.encode(deployedHookConfiguration)) != keccak256(abi.encode(configuration.hook))) {
            revert UnexpectedDeploymentState("hookConfiguration");
        }

        ICrottoGovernance governance = ICrottoGovernance(result.diamond);
        if (governance.treasuryReceiver() != configuration.treasuryReceiver) {
            revert UnexpectedDeploymentState("treasuryReceiver");
        }
        if (governance.guardian() != configuration.guardian) revert UnexpectedDeploymentState("guardian");
        if (keccak256(abi.encode(governance.buybackConfiguration())) != keccak256(abi.encode(configuration.buyback))) {
            revert UnexpectedDeploymentState("buybackConfiguration");
        }
        Round memory firstRound = ICrottoView(result.diamond).round(1);
        if (keccak256(abi.encode(firstRound.config)) != keccak256(abi.encode(configuration.round))) {
            revert UnexpectedDeploymentState("firstRoundConfiguration");
        }
    }
}
