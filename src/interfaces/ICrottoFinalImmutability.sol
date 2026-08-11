// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice One-time atomic transition from upgradeable to permanently immutable Crotto routing.
interface ICrottoFinalImmutability {
    event FinalImmutabilityCompleted(bytes32 indexed preFinalManifestHash, bytes32 indexed finalManifestHash);

    function finalizeImmutability(bytes32 expectedPreFinalManifestHash) external;
}
