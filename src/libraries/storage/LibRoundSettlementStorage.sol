// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ProvisionalNFTRewardPosition, RoundSettlement} from "../../types/CrottoTypes.sol";

/// @notice Round escrow, provisional rewards, refunds, and deferred buyback liabilities.
library LibRoundSettlementStorage {
    bytes32 internal constant STORAGE_SLOT = 0x87fcb1a5b0fb9548a9089df5c3d7d8cfbd21f69db456b72942ad80420c083b00;

    /// @custom:storage-location erc7201:crotto.storage.RoundSettlement
    struct Layout {
        mapping(uint256 roundId => RoundSettlement) rounds;
        mapping(uint256 roundId => mapping(address buyer => bool claimed)) refundClaimed;
        mapping(uint256 roundId => mapping(address buyer => uint256 amount)) builderRefundEth;
        mapping(uint256 roundId => mapping(address builder => uint256 amount)) provisionalBuilderCreditEth;
        mapping(uint256 tokenId => ProvisionalNFTRewardPosition) nftPositions;
        uint256 activeTicketEscrowWeth;
        uint256 expiredTicketRefundWeth;
        uint256 pendingBuybackWeth;
        uint256 lotteryNftWethLiability;
        uint256 finalizedNftIndexRay;
        uint256 expiredBuilderRefundEth;
        uint256 lotteryNftClaimableWeth;
    }

    function layout() internal pure returns (Layout storage state) {
        bytes32 slot = STORAGE_SLOT;
        assembly ("memory-safe") {
            state.slot := slot
        }
    }

    function storageSlot() internal pure returns (bytes32) {
        return STORAGE_SLOT;
    }
}
