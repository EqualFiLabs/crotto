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
        assertTrue(IActivationToken.mintPlayerReward.selector != bytes4(keccak256("mint(address,uint256)")));
        assertTrue(IActivationToken.mintBootstrapPOL.selector != bytes4(keccak256("mint(address,uint256)")));
    }

    function test_RewardNftExposesDiamondMintWithoutBurn() public pure {
        assertEq(IRewardNFT.mint.selector, bytes4(keccak256("mint(address)")));
        assertTrue(IRewardNFT.mint.selector != bytes4(keccak256("burn(uint256)")));
        assertTrue(IRewardNFT.mint.selector != bytes4(keccak256("publicMint(address)")));
    }

    function test_VaultAndHookExcludeEscapePathSelectors() public pure {
        bytes4 vaultPurchase = INFTVault.buyNewRewardNFT.selector;
        assertTrue(vaultPurchase != bytes4(keccak256("withdrawBacking(address,uint256)")));
        assertTrue(vaultPurchase != bytes4(keccak256("sweep(address,address,uint256)")));

        bytes4 compound = ICrottoSwapFeeHook.compoundPermanentLiquidity.selector;
        assertTrue(compound != bytes4(keccak256("decommissionPool()")));
        assertTrue(compound != bytes4(keccak256("releasePermanentLiquidity(address)")));
        assertTrue(compound != bytes4(keccak256("registerPool(bytes32)")));
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
}
