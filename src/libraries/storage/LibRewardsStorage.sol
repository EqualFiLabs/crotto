// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {NFTRewardPosition, RewardBook} from "../../types/CrottoTypes.sol";

/// @notice Two-asset Reward NFT indexes, positions, and active weight.
library LibRewardsStorage {
    bytes32 internal constant STORAGE_SLOT = 0xdaa92313f6d077aa2b982384e7c85ae621c1e5a78e1c8edd46dff50fadd1f000;

    /// @custom:storage-location erc7201:crotto.storage.Rewards
    struct Layout {
        RewardBook wethBook;
        RewardBook tokenBook;
        uint256 totalActiveWeight;
        mapping(uint256 tokenId => NFTRewardPosition) positions;
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
