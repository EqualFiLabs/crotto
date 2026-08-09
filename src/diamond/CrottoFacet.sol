// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LibCrottoGuard} from "../libraries/LibCrottoGuard.sol";
import {LibGovernanceStorage} from "../libraries/storage/LibGovernanceStorage.sol";

/// @notice Shared security modifiers and scoped RewardNFT transfer helpers for Crotto facets.
abstract contract CrottoFacet {
    error ActionPaused(uint256 action);

    modifier nonReentrant() {
        LibCrottoGuard.enter();
        _;
        LibCrottoGuard.exit();
    }

    modifier whenNotPaused(uint256 action) {
        _enforceNotPaused(action);
        _;
    }

    // The callback's root-entry bit must span the facet body so the guard can be released correctly.
    // forge-lint: disable-next-line(unwrapped-modifier-logic)
    modifier onlyRewardNFTTransferCallback(address from, address to, uint256 tokenId) {
        address rewardNFT = LibGovernanceStorage.layout().immutableConfiguration.rewardNFT;
        bool rootEntry = LibCrottoGuard.enterRewardNFTTransferCallback(rewardNFT, from, to, tokenId);
        _;
        LibCrottoGuard.exitRewardNFTTransferCallback(rootEntry);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function _beginRewardNFTTransfer(address from, address to, uint256 tokenId) internal {
        address rewardNFT = LibGovernanceStorage.layout().immutableConfiguration.rewardNFT;
        LibCrottoGuard.beginRewardNFTTransfer(rewardNFT, from, to, tokenId);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function _finishRewardNFTTransfer() internal {
        LibCrottoGuard.finishRewardNFTTransfer();
    }

    function _enforceNotPaused(uint256 action) private view {
        if ((LibGovernanceStorage.layout().pausedActions & action) != 0) revert ActionPaused(action);
    }
}
