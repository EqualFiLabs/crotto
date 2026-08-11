// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IVRFV2PlusWrapper} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFV2PlusWrapper.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IActivationToken} from "../../src/interfaces/IActivationToken.sol";
import {ICrotto} from "../../src/interfaces/ICrotto.sol";
import {ICrottoGovernance} from "../../src/interfaces/ICrottoGovernance.sol";
import {ICrottoSwapFeeHook} from "../../src/interfaces/ICrottoSwapFeeHook.sol";
import {INFTVault} from "../../src/interfaces/INFTVault.sol";
import {IPOLInitialization} from "../../src/interfaces/IPOLInitialization.sol";
import {IRewardNFT} from "../../src/interfaces/IRewardNFT.sol";
import {POLAccountingView, ProtocolAccountingView, VaultAccountingView} from "../../src/types/CrottoTypes.sol";

contract ProtocolFoundationTest is Test {
    IERC20 private openzeppelinDependency;
    IERC721 private openzeppelinNftDependency;
    IVRFV2PlusWrapper private chainlinkDependency;
    IPoolManager private uniswapCoreDependency;
    BaseHook private uniswapPeripheryDependency;

    function test_DependencyInterfacesCompileTogether() public view {
        assertEq(address(openzeppelinDependency), address(0));
        assertEq(address(openzeppelinNftDependency), address(0));
        assertEq(address(chainlinkDependency), address(0));
        assertEq(address(uniswapCoreDependency), address(0));
        assertEq(address(uniswapPeripheryDependency), address(0));
    }

    function test_CoreLifecycleSelectorsAreStable() public pure {
        assertEq(ICrotto.buyTickets.selector, bytes4(keccak256("buyTickets(uint256)")));
        assertEq(ICrotto.requestRandomness.selector, bytes4(keccak256("requestRandomness(uint256)")));
        assertEq(ICrotto.finalizeLottery.selector, bytes4(keccak256("finalizeLottery(uint256)")));
        assertEq(ICrotto.expireLottery.selector, bytes4(keccak256("expireLottery(uint256)")));
        assertEq(IPOLInitialization.initializePOL.selector, bytes4(keccak256("initializePOL()")));
    }

    function test_ActivationTokenExposesGenesisSupplySelector() public pure {
        assertEq(IActivationToken.GENESIS_TREASURY_SUPPLY.selector, bytes4(keccak256("GENESIS_TREASURY_SUPPLY()")));
    }

    function test_ActivationTokenExposesOnlyRestrictedMintSelectors() public pure {
        assertEq(IActivationToken.mintPlayerReward.selector, bytes4(keccak256("mintPlayerReward(address,uint256)")));
        assertEq(IActivationToken.mintBootstrapPOL.selector, bytes4(keccak256("mintBootstrapPOL(address,uint256)")));
    }

    function test_GovernanceExposesTreasuryReceiverWithoutCustodySelectors() public pure {
        assertEq(ICrottoGovernance.setTreasuryReceiver.selector, bytes4(keccak256("setTreasuryReceiver(address)")));
        assertEq(ICrottoGovernance.treasuryReceiver.selector, bytes4(keccak256("treasuryReceiver()")));
    }

    function test_GovernedPolAdditionAndBackupCompoundingSelectorsAreStable() public pure {
        assertEq(ICrottoGovernance.addPOL.selector, bytes4(keccak256("addPOL(address,uint256,uint256)")));
        assertEq(ICrottoSwapFeeHook.addPOL.selector, bytes4(keccak256("addPOL(address,uint256,uint256)")));
        assertEq(ICrottoSwapFeeHook.compoundPOL.selector, bytes4(keccak256("compoundPOL()")));
    }

    function test_RewardNftExposesDiamondMintWithoutBurn() public pure {
        assertEq(IRewardNFT.mint.selector, bytes4(keccak256("mint(address)")));
    }

    function test_CompiledInterfacesExcludeForbiddenFunctions() public view {
        assertEq(INFTVault.redeemRewardNFT.selector, bytes4(keccak256("redeemRewardNFT(uint256,address)")));
        assertTrue(_artifactHasFunction("out/IActivationToken.sol/IActivationToken.json", "mintPlayerReward"));
        assertTrue(_artifactHasFunction("out/IActivationToken.sol/IActivationToken.json", "GENESIS_TREASURY_SUPPLY"));
        assertTrue(_artifactHasFunction("out/IRewardNFT.sol/IRewardNFT.json", "mint"));
        assertTrue(_artifactHasFunction("out/INFTVault.sol/INFTVault.json", "redeemRewardNFT"));
        assertTrue(_artifactHasFunction("out/ICrottoGovernance.sol/ICrottoGovernance.json", "treasuryReceiver"));
        assertTrue(_artifactHasFunction("out/ICrottoGovernance.sol/ICrottoGovernance.json", "addPOL"));
        assertTrue(_artifactHasFunction("out/ICrottoSwapFeeHook.sol/ICrottoSwapFeeHook.json", "addPOL"));
        assertTrue(_artifactHasFunction("out/ICrottoSwapFeeHook.sol/ICrottoSwapFeeHook.json", "compoundPOL"));

        _assertArtifactExcludes(
            "out/IActivationToken.sol/IActivationToken.json", _names("mint", "ownerMint", "", "", "")
        );
        _assertArtifactExcludes(
            "out/IActivationToken.sol/IActivationToken.json",
            _names("mintTreasury", "mintGenesisTreasury", "mintGenesis", "treasuryMint", "")
        );
        _assertArtifactExcludes("out/IRewardNFT.sol/IRewardNFT.json", _names("burn", "publicMint", "ownerMint", "", ""));
        _assertArtifactExcludes(
            "out/INFTVault.sol/INFTVault.json", _names("withdrawBacking", "sweep", "recoverToken", "", "")
        );
        _assertArtifactExcludes(
            "out/ICrottoGovernance.sol/ICrottoGovernance.json",
            _names("withdrawTreasuryWeth", "withdrawTreasuryToken", "setTreasury", "treasury", "")
        );
        _assertArtifactExcludes(
            "out/ICrotto.sol/ICrotto.json",
            _names("withdrawTreasuryWeth", "withdrawTreasuryToken", "claimTreasury", "spendTreasury", "")
        );
        _assertArtifactExcludes(
            "out/ICrottoSwapFeeHook.sol/ICrottoSwapFeeHook.json",
            _names("decommissionPool", "releasePermanentLiquidity", "registerPool", "addLiquidity", "removeLiquidity")
        );
        _assertArtifactExcludes(
            "out/ICrottoSwapFeeHook.sol/ICrottoSwapFeeHook.json",
            _names("compoundPermanentLiquidity", "claimDonation", "refundDonation", "withdrawPOL", "releasePOL")
        );
    }

    function test_AccountingViewsRoundTripWithoutClassOverlap() public pure {
        ProtocolAccountingView memory protocol = ProtocolAccountingView({
            winnerPoolWethLiability: 1,
            rewardNftWethLiability: 2,
            bootstrapPolWeth: 3,
            operationsReserveEth: 4,
            callerCreditsEth: 5,
            playerTokenLiability: 6,
            rewardNftTokenLiability: 7,
            vaultBackingToken: 8,
            ticketEscrowWeth: 9,
            expiredTicketRefundWeth: 10,
            pendingBuybackWeth: 11,
            provisionalBuilderEth: 12,
            expiredBuilderRefundEth: 13
        });
        VaultAccountingView memory vault = VaultAccountingView({
            vaultPrice: 9,
            maxSupply: 10,
            mintedSupply: 11,
            vaultInventory: 12,
            circulatingNfts: 13,
            vaultTokenBacking: 14,
            requiredTokenBacking: 15
        });
        POLAccountingView memory pol = POLAccountingView({
            initialized: true,
            poolId: PoolId.wrap(bytes32(uint256(16))),
            lockedLiquidity: 17,
            pendingToken: 18,
            pendingWeth: 19
        });

        (
            ProtocolAccountingView memory decodedProtocol,
            VaultAccountingView memory decodedVault,
            POLAccountingView memory decodedPol
        ) = abi.decode(
            abi.encode(protocol, vault, pol), (ProtocolAccountingView, VaultAccountingView, POLAccountingView)
        );

        assertEq(decodedProtocol.bootstrapPolWeth, 3);
        assertEq(decodedProtocol.operationsReserveEth, 4);
        assertEq(decodedProtocol.vaultBackingToken, 8);
        assertEq(decodedVault.vaultTokenBacking, 14);
        assertEq(PoolId.unwrap(decodedPol.poolId), bytes32(uint256(16)));
        assertEq(decodedPol.pendingToken, 18);
        assertEq(decodedPol.pendingWeth, 19);
    }

    function _assertArtifactExcludes(string memory artifactPath, string[5] memory forbiddenNames) private view {
        // Paths are fixed by this test and access is read-only to generated Foundry output.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string[] memory signatures = vm.parseJsonKeys(vm.readFile(artifactPath), ".methodIdentifiers");

        for (uint256 i; i < signatures.length; ++i) {
            for (uint256 j; j < forbiddenNames.length; ++j) {
                if (bytes(forbiddenNames[j]).length == 0) continue;
                assertFalse(_hasFunctionName(signatures[i], forbiddenNames[j]), forbiddenNames[j]);
            }
        }
    }

    function _artifactHasFunction(string memory artifactPath, string memory functionName) private view returns (bool) {
        // Paths are fixed by this test and access is read-only to generated Foundry output.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string[] memory signatures = vm.parseJsonKeys(vm.readFile(artifactPath), ".methodIdentifiers");

        for (uint256 i; i < signatures.length; ++i) {
            if (_hasFunctionName(signatures[i], functionName)) return true;
        }
        return false;
    }

    function _hasFunctionName(string memory signature, string memory functionName) private pure returns (bool) {
        bytes memory signatureBytes = bytes(signature);
        bytes memory nameBytes = bytes(functionName);
        if (signatureBytes.length <= nameBytes.length || signatureBytes[nameBytes.length] != "(") return false;

        for (uint256 i; i < nameBytes.length; ++i) {
            if (signatureBytes[i] != nameBytes[i]) return false;
        }
        return true;
    }

    function _names(
        string memory first,
        string memory second,
        string memory third,
        string memory fourth,
        string memory fifth
    ) private pure returns (string[5] memory names) {
        names = [first, second, third, fourth, fifth];
    }
}
