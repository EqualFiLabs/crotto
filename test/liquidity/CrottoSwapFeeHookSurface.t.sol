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
        expected = new string[](33);
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
        expected[15] = "consult(uint32)";
        expected[16] = "creditPOLWeth(uint256)";
        expected[17] = "crottoDiamond()";
        expected[18] = "donatePOL(uint256,uint256)";
        expected[19] = "getHookPermissions()";
        expected[20] = "hookConfiguration()";
        expected[21] = "initialTokenPerWethWad()";
        expected[22] = "initializeCanonicalPool((address,address,uint24,int24,address),uint160,uint256,uint256)";
        expected[23] = "lockedLiquidity()";
        expected[24] = "maxCombinedHookFeeBps()";
        expected[25] = "oracleState()";
        expected[26] = "pendingPermanentLiquidity(address)";
        expected[27] = "poolInitialized()";
        expected[28] = "poolManager()";
        expected[29] = "setHookConfiguration((uint16,uint16,uint16,uint16,uint16))";
        expected[30] = "totalPendingPermanentLiquidity(address)";
        expected[31] = "unlockCallback(bytes)";
        expected[32] = "weth()";
    }
}
