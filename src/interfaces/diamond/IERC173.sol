// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Standard contract ownership interface used by the Crotto Diamond.
interface IERC173 {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function owner() external view returns (address owner_);

    function transferOwnership(address newOwner) external;
}
