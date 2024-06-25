// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.19;

import {IERC20} from "./interfaces/IERC20.sol";
import {SafeTransfer} from "./lib/SafeTransfer.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {SafeCast} from "./lib/SafeCast.sol";
import {CallbackValidation, PoolAddress} from "./lib/CallbackValidation.sol";

interface IUniswapV2Pair {
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function swap(
        uint amount0Out,
        uint amount1Out,
        address to,
        bytes calldata data
    ) external;
}

interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

// WIP
// TODO: Change functions to private, use fallback for gas savings same as old router

contract CtrlRouter {
    using SafeTransfer for IERC20;
    using SafeTransfer for IWETH;
    using SafeCast for uint256;

    address public feeAddress;

    event Swap(
        address tokenIn,
        address tokenOut,
        uint actualAmountIn,
        uint actualAmountOut,
        uint feeAmount
    );

    address public immutable WETH;
    address public immutable FACTORY_V3;
    uint32 internal constant FEE_DENOMINATOR = 100000;

    /// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    /// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_RATIO =
        1461446703485210103287273052203988822378723970342;

    struct SwapCallbackData {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address payer;
    }

    constructor(address _weth, address _factory) {
        WETH = _weth;
        feeAddress = msg.sender;
        FACTORY_V3 = _factory;
    }

    function setFeeAddress(address _feeAddress) external {
        require(msg.sender == feeAddress, "CTRL: FORBIDDEN");
        feeAddress = _feeAddress;
    }

    receive() external payable {}

    function recover(address token) external {
        require(msg.sender == feeAddress, "CTRL: FORBIDDEN");
        if (token == address(0)) {
            bool success;
            (success, ) = address(msg.sender).call{
                value: address(this).balance
            }("");
            return;
        } else {
            IERC20(token).safeTransfer(
                msg.sender,
                IERC20(token).balanceOf(address(this))
            );
        }
    }

    function executeSwapEthToTokenV2(
        address targetPair,
        address outputToken,
        uint minAmountOut,
        uint32 feeNumerator
    ) external payable {
        require(msg.value > 0, "CTRL: INVALID_AMOUNT");

        IWETH weth = IWETH(WETH);

        uint feeAmount = (msg.value * feeNumerator) / FEE_DENOMINATOR;
        uint amountIn = msg.value - feeAmount;

        weth.deposit{value: amountIn}();
        weth.safeTransfer(targetPair, amountIn);

        // Prepare variables for calculating expected amount out
        uint reserveIn;
        uint reserveOut;

        {
            (uint reserve0, uint reserve1, ) = IUniswapV2Pair(targetPair)
                .getReserves();

            // sort reserves
            if (WETH < outputToken) {
                // Token0 is equal to inputToken
                // Token1 is equal to outputToken
                reserveIn = reserve0;
                reserveOut = reserve1;
            } else {
                // Token0 is equal to outputToken
                // Token1 is equal to inputToken
                reserveIn = reserve1;
                reserveOut = reserve0;
            }
        }

        uint amountOut = _getAmountOut(amountIn, reserveIn, reserveOut);

        (uint amount0Out, uint amount1Out) = WETH < outputToken
            ? (uint(0), amountOut)
            : (amountOut, uint(0));

        uint balBefore = IERC20(outputToken).balanceOf(msg.sender);

        IUniswapV2Pair(targetPair).swap(
            amount0Out,
            amount1Out,
            msg.sender,
            new bytes(0)
        );

        uint actualAmountOut = IERC20(outputToken).balanceOf(msg.sender) -
            balBefore;

        require(
            actualAmountOut >= minAmountOut,
            "CTRL: INSUFFICIENT_OUTPUT_AMOUNT"
        );

        emit Swap(WETH, outputToken, amountIn, actualAmountOut, feeAmount);
    }

    function executeSwapTokenToEthV2(
        address targetPair,
        address inputToken,
        uint inputAmount,
        uint minAmountOut,
        uint32 feeNumerator
    ) external {
        require(inputAmount > 0, "CTRL: INVALID_AMOUNT");

        IERC20(inputToken).safeTransferFrom(
            msg.sender,
            targetPair,
            inputAmount
        );

        // Prepare variables for calculating expected amount out
        uint reserveIn;
        uint reserveOut;

        {
            (uint reserve0, uint reserve1, ) = IUniswapV2Pair(targetPair)
                .getReserves();

            // sort reserves
            if (inputToken < WETH) {
                // Token0 is equal to inputToken
                // Token1 is equal to outputToken
                reserveIn = reserve0;
                reserveOut = reserve1;
            } else {
                // Token0 is equal to outputToken
                // Token1 is equal to inputToken
                reserveIn = reserve1;
                reserveOut = reserve0;
            }
        }

        uint actualAmountIn = IERC20(inputToken).balanceOf(targetPair) -
            reserveIn;

        uint amountOut = _getAmountOut(actualAmountIn, reserveIn, reserveOut);

        (uint amount0Out, uint amount1Out) = inputToken < WETH
            ? (uint(0), amountOut)
            : (amountOut, uint(0));

        uint balBefore = IERC20(WETH).balanceOf(msg.sender);

        IUniswapV2Pair(targetPair).swap(
            amount0Out,
            amount1Out,
            msg.sender,
            new bytes(0)
        );

        uint actualAmountOut = IERC20(WETH).balanceOf(msg.sender) - balBefore;

        require(
            actualAmountOut >= minAmountOut,
            "CTRL: INSUFFICIENT_OUTPUT_AMOUNT"
        );

        IWETH(WETH).withdraw(actualAmountOut);

        uint feeAmount = (actualAmountOut * feeNumerator) / FEE_DENOMINATOR;
        actualAmountOut = actualAmountOut - feeAmount;

        SafeTransfer.safeTransferETH(msg.sender, actualAmountOut);

        emit Swap(inputToken, WETH, actualAmountIn, actualAmountOut, feeAmount);
    }

    function executeSwapTokenToTokenV2(
        address targetPair,
        address inputToken,
        address outputToken,
        uint inputAmount,
        uint minAmountOut,
        uint32 feeNumerator
    ) external {
        require(inputAmount > 0, "CTRL: INVALID_AMOUNT");
        uint feeAmount = 0;

        if (inputToken == WETH) {
            IERC20(inputToken).safeTransferFrom(
                msg.sender,
                address(this),
                inputAmount
            );
            feeAmount = (inputAmount * feeNumerator) / FEE_DENOMINATOR;
            inputAmount = inputAmount - feeAmount;
            IWETH(WETH).safeTransfer(targetPair, inputAmount);
        } else {
            IERC20(inputToken).safeTransferFrom(
                msg.sender,
                targetPair,
                inputAmount
            );
        }

        // Prepare variables for calculating expected amount out
        uint reserveIn;
        uint reserveOut;

        {
            (uint reserve0, uint reserve1, ) = IUniswapV2Pair(targetPair)
                .getReserves();

            // sort reserves
            if (inputToken < outputToken) {
                // Token0 is equal to inputToken
                // Token1 is equal to outputToken
                reserveIn = reserve0;
                reserveOut = reserve1;
            } else {
                // Token0 is equal to outputToken
                // Token1 is equal to inputToken
                reserveIn = reserve1;
                reserveOut = reserve0;
            }
        }

        uint actualAmountIn = IERC20(inputToken).balanceOf(targetPair) -
            reserveIn;

        uint amountOut = _getAmountOut(actualAmountIn, reserveIn, reserveOut);

        (uint amount0Out, uint amount1Out) = inputToken < outputToken
            ? (uint(0), amountOut)
            : (amountOut, uint(0));

        uint balBefore = IERC20(outputToken).balanceOf(msg.sender);

        IUniswapV2Pair(targetPair).swap(
            amount0Out,
            amount1Out,
            msg.sender,
            new bytes(0)
        );

        uint actualAmountOut = IERC20(outputToken).balanceOf(msg.sender) -
            balBefore;

        require(
            actualAmountOut >= minAmountOut,
            "CTRL: INSUFFICIENT_OUTPUT_AMOUNT"
        );

        IERC20(outputToken).safeTransfer(msg.sender, actualAmountOut);

        emit Swap(
            inputToken,
            outputToken,
            actualAmountIn,
            actualAmountOut,
            feeAmount
        );
    }

    function executeSwapEthToTokenV3(
        address outputToken,
        uint24 fee,
        uint minAmountOut,
        uint32 feeNumerator
    ) external payable {
        require(msg.value > 0, "CTRL: INVALID_AMOUNT");

        IWETH weth = IWETH(WETH);

        uint feeAmount = (msg.value * feeNumerator) / FEE_DENOMINATOR;
        uint amountIn = msg.value - feeAmount;

        weth.deposit{value: amountIn}();

        bytes memory data = abi.encode(
            SwapCallbackData({
                tokenIn: WETH,
                tokenOut: outputToken,
                fee: fee,
                payer: address(this)
            })
        );

        bool zeroForOne = WETH < outputToken;

        uint balBefore = IERC20(outputToken).balanceOf(msg.sender);

        getPool(WETH, outputToken, fee).swap(
            msg.sender,
            zeroForOne,
            amountIn.toInt256(),
            (zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1),
            data
        );

        uint actualAmountOut = IERC20(outputToken).balanceOf(msg.sender) -
            balBefore;

        require(actualAmountOut >= minAmountOut, "Too little received");

        emit Swap(WETH, outputToken, amountIn, actualAmountOut, feeAmount);
    }

    function executeSwapTokenToEthV3(
        address inputToken,
        uint24 fee,
        uint amountIn,
        uint minAmountOut,
        uint32 feeNumerator
    ) external {
        require(amountIn > 0, "CTRL: INVALID_AMOUNT");

        uint balInBefore = IERC20(inputToken).balanceOf(address(this));

        IERC20(inputToken).safeTransferFrom(
            msg.sender,
            address(this),
            amountIn
        );

        uint actualAmountIn = IERC20(inputToken).balanceOf(address(this)) -
            balInBefore;

        bytes memory data = abi.encode(
            SwapCallbackData({
                tokenIn: inputToken,
                tokenOut: WETH,
                fee: fee,
                payer: address(this)
            })
        );

        bool zeroForOne = inputToken < WETH;

        uint balBefore = IERC20(WETH).balanceOf(address(this));

        getPool(inputToken, WETH, fee).swap(
            address(this),
            zeroForOne,
            actualAmountIn.toInt256(),
            (zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1),
            data
        );

        uint actualAmountOut = IERC20(WETH).balanceOf(address(this)) -
            balBefore;

        require(actualAmountOut >= minAmountOut, "Too little received");

        IWETH weth = IWETH(WETH);

        weth.withdraw(actualAmountOut);

        uint feeAmount = (actualAmountOut * feeNumerator) / FEE_DENOMINATOR;

        actualAmountOut = actualAmountOut - feeAmount;

        SafeTransfer.safeTransferETH(msg.sender, actualAmountOut);

        emit Swap(inputToken, WETH, actualAmountIn, actualAmountOut, feeAmount);
    }

    function executeSwapTokenToTokenV3(
        address inputToken,
        address outputToken,
        uint24 fee,
        uint amountIn,
        uint minAmountOut,
        uint32 feeNumerator
    ) external {
        require(amountIn > 0, "CTRL: INVALID_AMOUNT");
        uint feeAmount = 0;

        uint balInBefore = IERC20(inputToken).balanceOf(address(this));

        IERC20(inputToken).safeTransferFrom(
            msg.sender,
            address(this),
            amountIn
        );

        uint actualAmountIn = IERC20(inputToken).balanceOf(address(this)) -
            balInBefore;

        if (inputToken == WETH) {
            feeAmount = (actualAmountIn * feeNumerator) / FEE_DENOMINATOR;
            actualAmountIn = actualAmountIn - feeAmount;
        }

        bytes memory data = abi.encode(
            SwapCallbackData({
                tokenIn: inputToken,
                tokenOut: WETH,
                fee: fee,
                payer: address(this)
            })
        );

        bool zeroForOne = inputToken < WETH;

        uint balBefore = IERC20(WETH).balanceOf(address(this));

        getPool(inputToken, WETH, fee).swap(
            address(this),
            zeroForOne,
            actualAmountIn.toInt256(),
            (zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1),
            data
        );

        uint actualAmountOut = IERC20(WETH).balanceOf(address(this)) -
            balBefore;

        require(actualAmountOut >= minAmountOut, "Too little received");

        IERC20(outputToken).safeTransfer(msg.sender, actualAmountOut);

        emit Swap(inputToken, WETH, actualAmountIn, actualAmountOut, feeAmount);
    }

    function _getAmountOut(
        uint amountIn,
        uint reserveIn,
        uint reserveOut
    ) internal pure returns (uint amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint amountInWithFee = amountIn * 997;
        uint numerator = amountInWithFee * reserveOut;
        uint denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function pay(
        address token,
        address payer,
        address recipient,
        uint256 value
    ) internal {
        if (token == WETH && address(this).balance >= value) {
            // pay with WETH
            IWETH(WETH).deposit{value: value}(); // wrap only what is needed to pay
            IWETH(WETH).transfer(recipient, value);
        } else if (payer == address(this)) {
            IERC20(token).safeTransfer(recipient, value);
        } else {
            // pull payment
            IERC20(token).safeTransferFrom(payer, recipient, value);
        }
    }

    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) internal view returns (IUniswapV3Pool) {
        return
            IUniswapV3Pool(
                PoolAddress.computeAddress(
                    FACTORY_V3,
                    PoolAddress.getPoolKey(tokenA, tokenB, fee)
                )
            );
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) external {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported

        SwapCallbackData memory data = abi.decode(_data, (SwapCallbackData));

        CallbackValidation.verifyCallback(
            FACTORY_V3,
            data.tokenIn,
            data.tokenOut,
            data.fee
        );

        pay(
            data.tokenIn,
            data.payer,
            msg.sender,
            amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta)
        );
    }
}
