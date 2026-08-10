// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {CrottoSwapFeeHook} from "../../src/liquidity/CrottoSwapFeeHook.sol";

contract CrottoSwapFeeHookSurfaceTest is Test {
    error SelectorMissing(bytes4 selector);
    error ForbiddenSignature(string signature);

    string private constant HOOK_ARTIFACT = "out/CrottoSwapFeeHook.sol/CrottoSwapFeeHook.json";

    function test_ArtifactExposesRequiredPOLSurfaceWithoutEscapePaths() public view {
        // Path is fixed by this test and access is read-only to generated Foundry output.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string[] memory signatures = vm.parseJsonKeys(vm.readFile(HOOK_ARTIFACT), ".methodIdentifiers");
        assertEq(signatures.length, 30);
        _assertContains(signatures, CrottoSwapFeeHook.initializeCanonicalPool.selector);
        _assertContains(signatures, CrottoSwapFeeHook.donatePOL.selector);
        _assertContains(signatures, CrottoSwapFeeHook.compoundPOL.selector);
        _assertContains(signatures, CrottoSwapFeeHook.setHookConfiguration.selector);

        _assertAbsent(signatures, "releasePermanentLiquidity(address)");
        _assertAbsent(signatures, "decommissionPool()");
        _assertAbsent(signatures, "withdrawPOL(address,uint256,address)");
        _assertAbsent(signatures, "registerPool((address,address,uint24,int24,address))");
    }

    function _assertContains(string[] memory signatures, bytes4 expected) private pure {
        for (uint256 i; i < signatures.length; ++i) {
            if (bytes4(keccak256(bytes(signatures[i]))) == expected) return;
        }
        revert SelectorMissing(expected);
    }

    function _assertAbsent(string[] memory signatures, string memory forbidden) private pure {
        bytes32 forbiddenHash = keccak256(bytes(forbidden));
        for (uint256 i; i < signatures.length; ++i) {
            if (keccak256(bytes(signatures[i])) == forbiddenHash) revert ForbiddenSignature(forbidden);
        }
    }
}
