// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LibAutomaticBuyback} from "../../libraries/LibAutomaticBuyback.sol";

/// @notice Authenticated Uniswap v4 unlock callback for automatic ticket buybacks.
contract BuybackSettlementFacet is IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        return LibAutomaticBuyback.unlockCallback(data);
    }
}
