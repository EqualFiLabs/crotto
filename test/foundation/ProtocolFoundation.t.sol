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
        assertEq(ICrotto.retryRandomness.selector, bytes4(keccak256("retryRandomness(uint256)")));
        assertEq(ICrotto.finalizeLottery.selector, bytes4(keccak256("finalizeLottery(uint256)")));
        assertEq(IPOLInitialization.initializePOL.selector, bytes4(keccak256("initializePOL()")));
    }

    function test_ActivationTokenExposesOnlyRestrictedMintSelectors() public pure {
        assertEq(IActivationToken.mintPlayerReward.selector, bytes4(keccak256("mintPlayerReward(address,uint256)")));
        assertEq(IActivationToken.mintBootstrapPOL.selector, bytes4(keccak256("mintBootstrapPOL(address,uint256)")));
    }

    function test_RewardNftExposesDiamondMintWithoutBurn() public pure {
        assertEq(IRewardNFT.mint.selector, bytes4(keccak256("mint(address)")));
    }

    function test_CompiledInterfacesExcludeForbiddenFunctions() public view {
        assertEq(INFTVault.redeemRewardNFT.selector, bytes4(keccak256("redeemRewardNFT(uint256,address)")));
        assertEq(
            ICrottoSwapFeeHook.compoundPermanentLiquidity.selector, bytes4(keccak256("compoundPermanentLiquidity()"))
        );
        assertTrue(_artifactHasFunction("out/IActivationToken.sol/IActivationToken.json", "mintPlayerReward"));
        assertTrue(_artifactHasFunction("out/IRewardNFT.sol/IRewardNFT.json", "mint"));
        assertTrue(_artifactHasFunction("out/INFTVault.sol/INFTVault.json", "redeemRewardNFT"));
        assertTrue(
            _artifactHasFunction("out/ICrottoSwapFeeHook.sol/ICrottoSwapFeeHook.json", "compoundPermanentLiquidity")
        );

        _assertArtifactExcludes(
            "out/IActivationToken.sol/IActivationToken.json", _names("mint", "ownerMint", "", "", "")
        );
        _assertArtifactExcludes("out/IRewardNFT.sol/IRewardNFT.json", _names("burn", "publicMint", "ownerMint", "", ""));
        _assertArtifactExcludes(
            "out/INFTVault.sol/INFTVault.json", _names("withdrawBacking", "sweep", "recoverToken", "", "")
        );
        _assertArtifactExcludes(
            "out/ICrottoSwapFeeHook.sol/ICrottoSwapFeeHook.json",
            _names("decommissionPool", "releasePermanentLiquidity", "registerPool", "addLiquidity", "removeLiquidity")
        );
    }

    function test_AccountingViewsRoundTripWithoutClassOverlap() public pure {
        ProtocolAccountingView memory protocol = ProtocolAccountingView({
            winnerPoolWethLiability: 1,
            rewardNftWethLiability: 2,
            treasuryWeth: 3,
            bootstrapPolWeth: 4,
            operationsReserveEth: 5,
            callerCreditsEth: 6,
            playerTokenLiability: 7,
            rewardNftTokenLiability: 8,
            vaultBackingToken: 9,
            treasuryToken: 10
        });
        VaultAccountingView memory vault = VaultAccountingView({
            vaultPrice: 11,
            maxSupply: 12,
            mintedSupply: 13,
            vaultInventory: 14,
            circulatingNfts: 15,
            vaultTokenBacking: 16,
            requiredTokenBacking: 17
        });
        POLAccountingView memory pol = POLAccountingView({
            initialized: true,
            poolId: PoolId.wrap(bytes32(uint256(18))),
            lockedLiquidity: 19,
            pendingToken: 20,
            pendingWeth: 21
        });

        (
            ProtocolAccountingView memory decodedProtocol,
            VaultAccountingView memory decodedVault,
            POLAccountingView memory decodedPol
        ) = abi.decode(
            abi.encode(protocol, vault, pol), (ProtocolAccountingView, VaultAccountingView, POLAccountingView)
        );

        assertEq(decodedProtocol.bootstrapPolWeth, 4);
        assertEq(decodedProtocol.operationsReserveEth, 5);
        assertEq(decodedProtocol.vaultBackingToken, 9);
        assertEq(decodedVault.vaultTokenBacking, 16);
        assertEq(PoolId.unwrap(decodedPol.poolId), bytes32(uint256(18)));
        assertEq(decodedPol.pendingToken, 20);
        assertEq(decodedPol.pendingWeth, 21);
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
