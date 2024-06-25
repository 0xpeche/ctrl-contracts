// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {IStargateReceiver} from "./interfaces/IStargateReceiver.sol";
import {IStargateRouter} from "./interfaces/IStargateRouter.sol";
import {IStargateEthVault} from "./interfaces/IStargateEthVault.sol";
import {ICtrlRouter} from "./interfaces/ICtrlRouter.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {SafeTransfer} from "./lib/SafeTransfer.sol";
import "hardhat/console.sol";

// wip

contract CtrlStargateRouter is IStargateReceiver {
    using SafeTransfer for IERC20;

    IStargateRouter public immutable stargateRouter;
    address public immutable stargateEthVault;
    uint16 public immutable wethPoolId;
    address public ammRouter;
    address constant OUT_TO_NATIVE = 0x0000000000000000000000000000000000000000;

    constructor(
        IStargateRouter _stargateRouter,
        address _stargateEthVault,
        uint16 _wethPoolId,
        address _ammRouter
    ) {
        stargateRouter = _stargateRouter;
        stargateEthVault = _stargateEthVault;
        wethPoolId = _wethPoolId;
        ammRouter = _ammRouter;
    }

    // this contract needs to accept ETH
    receive() external payable {}

    function nativeToTokens(
        uint16 _dstChainId, // Stargate/LayerZero chainId
        uint16 _dstPoolId, // Stargate/LayerZero poolId
        uint256 _amountLD, // the amount, in Local Decimals, to be swapped
        uint256 _minAmountLD, // the minimum amount accepted out on destination
        address _destStargateComposed,
        uint _destGasLimit,
        address _destToken,
        address _destTargetPair,
        uint256 _destMinAmountOut,
        uint256 _deadline,
        address _to,
        uint24 _fee
    ) external payable {
        require(
            msg.value > _amountLD,
            "Stargate: msg.value must be > _amountLD"
        );
        // wrap the ETH into WETH

        IStargateEthVault(stargateEthVault).deposit{value: _amountLD}();
        IStargateEthVault(stargateEthVault).approve(address(stargateRouter), _amountLD);
        // messageFee is the remainder of the msg.value after wrap
        uint256 messageFee = msg.value - _amountLD;

        bytes memory data;
        {
            data = abi.encode(
                _to,
                _destToken,
                _destTargetPair,
                _destMinAmountOut,
                _deadline,
                _fee
            );
        }
        stargateRouter.swap{value: messageFee}(
            _dstChainId,
            wethPoolId,
            _dstPoolId,
            payable(msg.sender),
            _amountLD,
            _minAmountLD,
            IStargateRouter.lzTxObj(_destGasLimit, 0, "0x"),
            abi.encodePacked(_destStargateComposed),
            data
        );
    }

    function nativeToNative(
        uint16 _dstChainId, // Stargate/LayerZero chainId
        uint256 _amountLD, // the amount, in Local Decimals, to be swapped
        uint256 _minAmountLD // the minimum amount accepted out on destination
    ) external payable {
        require(
            msg.value > _amountLD,
            "Stargate: msg.value must be > _amountLD"
        );

        IStargateEthVault(stargateEthVault).deposit{value: _amountLD}();
        IStargateEthVault(stargateEthVault).approve(
            address(stargateRouter),
            _amountLD
        );

        uint256 messageFee = msg.value - _amountLD;

        stargateRouter.swap{value: messageFee}(
            _dstChainId,
            wethPoolId,
            wethPoolId,
            payable(msg.sender),
            _amountLD,
            _minAmountLD,
            IStargateRouter.lzTxObj(0, 0, "0x"),
            abi.encodePacked(msg.sender),
            bytes("0")
        );
    }

    function sgReceive(
        uint16 /*_chainId*/,
        bytes memory /*_srcAddress*/,
        uint /*_nonce*/,
        address _token,
        uint amountLD,
        bytes memory payload
    ) external override {
        require(
            msg.sender == address(stargateRouter),
            "only stargate router can call sgReceive!"
        );

        (
            address _to,
            address _destToken,
            address _destTargetPair,
            uint _destMinAmountOut,
            uint _deadline,
            uint24 _fee
        ) = abi.decode(
                payload,
                (address, address, address, uint, uint, uint24)
            );

        require(block.timestamp <= _deadline, "deadline passed");

        IERC20(_token).approve(address(ammRouter), amountLD);

        if (_destTargetPair == address(0)) {
            if (_destToken == address(0)) {
                uint balBefore = address(this).balance;
                ICtrlRouter(ammRouter).executeSwapTokenToEthV3(
                    _token,
                    _fee,
                    amountLD,
                    _destMinAmountOut,
                    1000
                );
                uint amountOut = address(this).balance - balBefore;
                SafeTransfer.safeTransferETH(_to, amountOut);
            } else {
                uint balBefore = IERC20(_destToken).balanceOf(address(this));
                ICtrlRouter(ammRouter).executeSwapTokenToTokenV3(
                    _token,
                    _destToken,
                    _fee,
                    amountLD,
                    _destMinAmountOut,
                    1000
                );
                uint amountOut = IERC20(_destToken).balanceOf(address(this)) -
                    balBefore;
                IERC20(_destToken).safeTransfer(_to, amountOut);
            }
        } else {
            if (_destToken == address(0)) {
                uint balBefore = address(this).balance;
                ICtrlRouter(ammRouter).executeSwapTokenToEthV2(
                    _destTargetPair,
                    _token,
                    amountLD,
                    _destMinAmountOut,
                    1000
                );
                uint amountOut = address(this).balance - balBefore;
                SafeTransfer.safeTransferETH(_to, amountOut);
            } else {
                uint balBefore = IERC20(_destToken).balanceOf(address(this));
                ICtrlRouter(ammRouter).executeSwapTokenToTokenV2(
                    _destTargetPair,
                    _token,
                    _destToken,
                    amountLD,
                    _destMinAmountOut,
                    1000
                );
                uint amountOut = IERC20(_destToken).balanceOf(address(this)) -
                    balBefore;
                IERC20(_destToken).safeTransfer(_to, amountOut);
            }
        }
    }
}
