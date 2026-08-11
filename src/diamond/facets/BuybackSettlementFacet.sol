// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAutomaticTicketBuyback} from "../../interfaces/IAutomaticTicketBuyback.sol";
import {LibAssetTransfer} from "../../libraries/LibAssetTransfer.sol";
import {LibAutomaticBuyback} from "../../libraries/LibAutomaticBuyback.sol";
import {CrottoConstants} from "../../libraries/CrottoConstants.sol";
import {LibWethSolvency} from "../../libraries/LibWethSolvency.sol";
import {LibGovernanceStorage} from "../../libraries/storage/LibGovernanceStorage.sol";
import {LibRoundSettlementStorage} from "../../libraries/storage/LibRoundSettlementStorage.sol";
import {BuybackConfiguration} from "../../types/CrottoTypes.sol";
import {CrottoFacet} from "../CrottoFacet.sol";

/// @notice Permissionless pending buyback execution and authenticated Uniswap v4 settlement callback.
contract BuybackSettlementFacet is CrottoFacet, IUnlockCallback, IAutomaticTicketBuyback {
    error EmptyPendingBuyback();
    error BuybackChunkConsumedByTip(uint256 chunk, uint256 tip);

    function executePendingBuyback() external nonReentrant returns (uint256 consumedWeth, uint256 actualNetTokenOut) {
        LibRoundSettlementStorage.Layout storage settlements = LibRoundSettlementStorage.layout();
        uint256 pending = settlements.pendingBuybackWeth;
        if (pending == 0) revert EmptyPendingBuyback();
        BuybackConfiguration memory configuration = LibGovernanceStorage.layout().buybackConfiguration;
        consumedWeth = Math.min(pending, configuration.maximumWethChunk);
        uint256 callerTip = Math.mulDiv(consumedWeth, configuration.callerTipBps, CrottoConstants.BPS);
        if (callerTip >= consumedWeth) revert BuybackChunkConsumedByTip(consumedWeth, callerTip);
        uint256 buybackBudget = consumedWeth - callerTip;

        settlements.pendingBuybackWeth = pending - consumedWeth;
        (, actualNetTokenOut) = LibAutomaticBuyback.execute(msg.sender, consumedWeth, callerTip, buybackBudget);
        if (callerTip != 0) {
            LibAssetTransfer.pushExact(LibGovernanceStorage.layout().immutableConfiguration.weth, msg.sender, callerTip);
        }
        LibWethSolvency.enforce();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        return LibAutomaticBuyback.unlockCallback(data);
    }
}
