// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

contract CrottoSwapFeeHookSurfaceTest is Test {
    error UnexpectedSignature(string signature);
    error MissingSignature(string signature);

    string private constant HOOK_ARTIFACT = "out/CrottoSwapFeeHook.sol/CrottoSwapFeeHook.json";

    function test_ArtifactExposesRequiredPOLSurfaceWithoutEscapePaths() public view {
        // Path is fixed by this test and access is read-only to generated Foundry output.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string[] memory signatures = vm.parseJsonKeys(vm.readFile(HOOK_ARTIFACT), ".methodIdentifiers");
        string[] memory expected = _expectedSignatures();
        assertEq(signatures.length, expected.length);
        for (uint256 i; i < signatures.length; ++i) {
            _assertExpected(expected, signatures[i]);
        }
        for (uint256 i; i < expected.length; ++i) {
            _assertExposed(signatures, expected[i]);
        }
    }

    function _assertExpected(string[] memory expected, string memory actual) private pure {
        bytes32 actualHash = keccak256(bytes(actual));
        for (uint256 i; i < expected.length; ++i) {
            if (keccak256(bytes(expected[i])) == actualHash) return;
        }
        revert UnexpectedSignature(actual);
    }

    function _assertExposed(string[] memory signatures, string memory expected) private pure {
        bytes32 expectedHash = keccak256(bytes(expected));
        for (uint256 i; i < signatures.length; ++i) {
            if (keccak256(bytes(signatures[i])) == expectedHash) return;
        }
        revert MissingSignature(expected);
    }

    function _expectedSignatures() private pure returns (string[] memory expected) {
        expected = new string[](30);
        expected[0] = "activationToken()";
        expected[1] =
            "afterAddLiquidity(address,(address,address,uint24,int24,address),(int24,int24,int256,bytes32),int256,int256,bytes)";
        expected[2] = "afterDonate(address,(address,address,uint24,int24,address),uint256,uint256,bytes)";
        expected[3] = "afterInitialize(address,(address,address,uint24,int24,address),uint160,int24)";
        expected[4] =
            "afterRemoveLiquidity(address,(address,address,uint24,int24,address),(int24,int24,int256,bytes32),int256,int256,bytes)";
        expected[5] = "afterSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),int256,bytes)";
        expected[6] =
        "beforeAddLiquidity(address,(address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)";
        expected[7] = "beforeDonate(address,(address,address,uint24,int24,address),uint256,uint256,bytes)";
        expected[8] = "beforeInitialize(address,(address,address,uint24,int24,address),uint160)";
        expected[9] =
        "beforeRemoveLiquidity(address,(address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)";
        expected[10] = "beforeSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),bytes)";
        expected[11] = "canonicalPoolId()";
        expected[12] = "canonicalPoolKey()";
        expected[13] = "canonicalTickSpacing()";
        expected[14] = "compoundPOL()";
        expected[15] = "crottoDiamond()";
        expected[16] = "donatePOL(uint256,uint256)";
        expected[17] = "getHookPermissions()";
        expected[18] = "hookConfiguration()";
        expected[19] = "initialTokenPerWethWad()";
        expected[20] = "initializeCanonicalPool((address,address,uint24,int24,address),uint160,uint256,uint256)";
        expected[21] = "lockedLiquidity()";
        expected[22] = "maxCombinedHookFeeBps()";
        expected[23] = "pendingPermanentLiquidity(address)";
        expected[24] = "poolInitialized()";
        expected[25] = "poolManager()";
        expected[26] = "setHookConfiguration((uint16,uint16,uint16,uint16,uint16))";
        expected[27] = "totalPendingPermanentLiquidity(address)";
        expected[28] = "unlockCallback(bytes)";
        expected[29] = "weth()";
    }
}
