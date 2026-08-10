// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Shared cross-facet guard with a one-use RewardNFT transfer callback exception.
library LibCrottoGuard {
    bytes32 internal constant STORAGE_SLOT = 0x222f3d1fff79d09f5bc225eee01e52dbc12333ae5f7821701062458661b2b100;

    uint256 internal constant NOT_ENTERED = 1;
    uint256 internal constant ENTERED = 2;

    error ReentrantCall();
    error UnauthorizedRewardNFTCallback(address caller, address expectedRewardNFT);
    error RewardNFTTransferContextAlreadyActive();
    error RewardNFTTransferContextNotActive();
    error UnexpectedRewardNFTTransferCallback(
        address from, address to, uint256 tokenId, address expectedFrom, address expectedTo, uint256 expectedTokenId
    );
    error RewardNFTTransferCallbackNotConsumed();
    error RewardNFTTransferContextNotCleared();
    error CanonicalHookRevenueContextAlreadyActive();
    error CanonicalHookRevenueContextNotActive();
    error CanonicalHookRevenueContextNotCleared();
    error UnauthorizedCanonicalHookCallback(address caller, address expectedHook);
    error UnexpectedCanonicalHookRevenueAsset(address asset);
    error DuplicateCanonicalHookRevenueAsset(address asset);

    // forge-lint: disable-next-line(pascal-case-struct)
    struct RewardNFTTransferContext {
        address rewardNFT;
        address from;
        address to;
        uint256 tokenId;
        bool active;
        bool consumed;
    }

    struct CanonicalHookRevenueContext {
        address hook;
        address weth;
        address token;
        uint8 routedAssets;
        bool active;
    }

    /// @custom:storage-location erc7201:crotto.storage.Guard
    struct Layout {
        uint256 status;
        RewardNFTTransferContext rewardNFTTransfer;
        CanonicalHookRevenueContext canonicalHookRevenue;
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

    function enter() internal {
        Layout storage state = layout();
        if (state.status == ENTERED) revert ReentrantCall();
        state.status = ENTERED;
    }

    function exit() internal {
        Layout storage state = layout();
        RewardNFTTransferContext storage context = state.rewardNFTTransfer;
        if (context.active || context.consumed) revert RewardNFTTransferContextNotCleared();
        if (state.canonicalHookRevenue.active) revert CanonicalHookRevenueContextNotCleared();
        state.status = NOT_ENTERED;
    }

    function beginRewardNFTTransfer(address rewardNFT, address from, address to, uint256 tokenId) internal {
        Layout storage state = layout();
        if (state.status != ENTERED) revert RewardNFTTransferContextNotActive();

        RewardNFTTransferContext storage context = state.rewardNFTTransfer;
        if (context.active || context.consumed) revert RewardNFTTransferContextAlreadyActive();
        context.rewardNFT = rewardNFT;
        context.from = from;
        context.to = to;
        context.tokenId = tokenId;
        context.active = true;
    }

    function finishRewardNFTTransfer() internal {
        Layout storage state = layout();
        RewardNFTTransferContext storage context = state.rewardNFTTransfer;
        if (!context.consumed) revert RewardNFTTransferCallbackNotConsumed();
        delete state.rewardNFTTransfer;
    }

    /// @return rootEntry True when this callback acquired the guard itself.
    function enterRewardNFTTransferCallback(address rewardNFT, address from, address to, uint256 tokenId)
        internal
        returns (bool rootEntry)
    {
        if (msg.sender != rewardNFT) revert UnauthorizedRewardNFTCallback(msg.sender, rewardNFT);

        Layout storage state = layout();
        if (state.status != ENTERED) {
            state.status = ENTERED;
            return true;
        }

        RewardNFTTransferContext storage context = state.rewardNFTTransfer;
        if (!context.active || context.rewardNFT != rewardNFT) revert RewardNFTTransferContextNotActive();
        if (context.from != from || context.to != to || context.tokenId != tokenId) {
            revert UnexpectedRewardNFTTransferCallback(from, to, tokenId, context.from, context.to, context.tokenId);
        }

        context.active = false;
        context.consumed = true;
    }

    function exitRewardNFTTransferCallback(bool rootEntry) internal {
        if (!rootEntry) return;
        Layout storage state = layout();
        if (state.rewardNFTTransfer.active || state.rewardNFTTransfer.consumed) {
            revert RewardNFTTransferContextNotCleared();
        }
        state.status = NOT_ENTERED;
    }

    function beginCanonicalHookRevenue(address hook, address weth, address token) internal {
        Layout storage state = layout();
        if (state.status != ENTERED) revert CanonicalHookRevenueContextNotActive();
        if (state.canonicalHookRevenue.active) revert CanonicalHookRevenueContextAlreadyActive();
        state.canonicalHookRevenue =
            CanonicalHookRevenueContext({hook: hook, weth: weth, token: token, routedAssets: 0, active: true});
    }

    function finishCanonicalHookRevenue() internal {
        Layout storage state = layout();
        if (!state.canonicalHookRevenue.active) revert CanonicalHookRevenueContextNotActive();
        delete state.canonicalHookRevenue;
    }

    /// @return rootEntry True when an ordinary outside swap acquired the guard itself.
    function enterCanonicalHookRevenueCallback(address hook, address asset) internal returns (bool rootEntry) {
        if (msg.sender != hook) revert UnauthorizedCanonicalHookCallback(msg.sender, hook);

        Layout storage state = layout();
        if (state.status != ENTERED) {
            state.status = ENTERED;
            return true;
        }

        CanonicalHookRevenueContext storage context = state.canonicalHookRevenue;
        if (!context.active || context.hook != hook) revert CanonicalHookRevenueContextNotActive();
        uint8 assetBit;
        if (asset == context.weth) assetBit = 1;
        else if (asset == context.token) assetBit = 2;
        else revert UnexpectedCanonicalHookRevenueAsset(asset);
        if ((context.routedAssets & assetBit) != 0) revert DuplicateCanonicalHookRevenueAsset(asset);
        context.routedAssets |= assetBit;
    }

    function exitCanonicalHookRevenueCallback(bool rootEntry) internal {
        if (!rootEntry) return;
        Layout storage state = layout();
        if (state.canonicalHookRevenue.active) revert CanonicalHookRevenueContextNotCleared();
        state.status = NOT_ENTERED;
    }
}
