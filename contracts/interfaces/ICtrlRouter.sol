// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.19;

interface ICtrlRouter {
    function WETH() external view returns (address);

    function executeSwapEthToTokenV2(
        address targetPair,
        address outputToken,
        uint minAmountOut,
        uint32 feeNumerator
    ) external payable;

    function executeSwapTokenToEthV2(
        address targetPair,
        address inputToken,
        uint inputAmount,
        uint minAmountOut,
        uint32 feeNumerator
    ) external;

    function executeSwapEthToTokenV3(
        address outputToken,
        uint24 fee,
        uint minAmountOut,
        uint32 feeNumerator
    ) external payable;

    function executeSwapTokenToEthV3(
        address inputToken,
        uint24 fee,
        uint amountIn,
        uint minAmountOut,
        uint32 feeNumerator
    ) external;

    function executeSwapTokenToTokenV3(
        address inputToken,
        address outputToken,
        uint24 fee,
        uint amountIn,
        uint minAmountOut,
        uint32 feeNumerator
    ) external;

    function executeSwapTokenToTokenV2(
        address targetPair,
        address inputToken,
        address outputToken,
        uint inputAmount,
        uint minAmountOut,
        uint32 feeNumerator
    ) external;
}
