// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";

contract PoolCallsHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    struct CallbackDataModPos {
        address sender;
        PoolKey key;
        IPoolManager.ModifyPositionParams params;
        bytes hookData;
    }

    struct CallbackDataSwap {
        address sender;
        TestSettingsSwap testSettings;
        PoolKey key;
        IPoolManager.SwapParams params;
        bytes hookData;
    }

    struct TestSettingsSwap {
        bool withdrawTokens;
        bool settleUsingTransfer;
    }

    uint8 whichLock;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return
            Hooks.Calls({
                beforeInitialize: true,
                afterInitialize: false,
                beforeModifyPosition: true,
                afterModifyPosition: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false
            });
    }

    /// @notice Copy/paste from PoolModifyPositionTest
    function modifyPosition(
        PoolKey memory key,
        IPoolManager.ModifyPositionParams memory params,
        bytes memory hookData
    ) internal returns (BalanceDelta delta) {
        whichLock = 1;
        delta = abi.decode(
            poolManager.lock(
                abi.encode(
                    CallbackDataModPos(msg.sender, key, params, hookData)
                )
            ),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    /// @notice Copy/paste from PoolSwapTest
    function swap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        TestSettingsSwap memory testSettings,
        bytes memory hookData
    ) public payable returns (BalanceDelta delta) {
        whichLock = 0;
        delta = abi.decode(
            poolManager.lock(
                abi.encode(
                    CallbackDataSwap(
                        msg.sender,
                        testSettings,
                        key,
                        params,
                        hookData
                    )
                )
            ),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0)
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
    }

    function lockAcquired(
        bytes calldata rawData
    ) external override returns (bytes memory) {
        // Should always be one of these two?
        if (whichLock == 0) {
            return lockAcquiredSwap(rawData);
        } else if (whichLock == 1) {
            return lockAcquiredModPos(rawData);
        }
        revert("Bad lock!");
    }

    /// @notice Copy/paste from PoolSwapTest
    function lockAcquiredSwap(
        bytes calldata rawData
    ) internal returns (bytes memory) {
        require(msg.sender == address(poolManager));

        CallbackDataSwap memory data = abi.decode(rawData, (CallbackDataSwap));

        BalanceDelta delta = poolManager.swap(
            data.key,
            data.params,
            data.hookData
        );

        if (data.params.zeroForOne) {
            if (delta.amount0() > 0) {
                if (data.testSettings.settleUsingTransfer) {
                    if (data.key.currency0.isNative()) {
                        poolManager.settle{value: uint128(delta.amount0())}(
                            data.key.currency0
                        );
                    } else {
                        TestERC20(Currency.unwrap(data.key.currency0))
                            .transferFrom(
                                data.sender,
                                address(poolManager),
                                uint128(delta.amount0())
                            );
                        poolManager.settle(data.key.currency0);
                    }
                } else {
                    // the received hook on this transfer will burn the tokens
                    poolManager.safeTransferFrom(
                        data.sender,
                        address(poolManager),
                        uint256(uint160(Currency.unwrap(data.key.currency0))),
                        uint128(delta.amount0()),
                        ""
                    );
                }
            }
            if (delta.amount1() < 0) {
                if (data.testSettings.withdrawTokens) {
                    poolManager.take(
                        data.key.currency1,
                        data.sender,
                        uint128(-delta.amount1())
                    );
                } else {
                    poolManager.mint(
                        data.key.currency1,
                        data.sender,
                        uint128(-delta.amount1())
                    );
                }
            }
        } else {
            if (delta.amount1() > 0) {
                if (data.testSettings.settleUsingTransfer) {
                    if (data.key.currency1.isNative()) {
                        poolManager.settle{value: uint128(delta.amount1())}(
                            data.key.currency1
                        );
                    } else {
                        TestERC20(Currency.unwrap(data.key.currency1))
                            .transferFrom(
                                data.sender,
                                address(poolManager),
                                uint128(delta.amount1())
                            );
                        poolManager.settle(data.key.currency1);
                    }
                } else {
                    // the received hook on this transfer will burn the tokens
                    poolManager.safeTransferFrom(
                        data.sender,
                        address(poolManager),
                        uint256(uint160(Currency.unwrap(data.key.currency1))),
                        uint128(delta.amount1()),
                        ""
                    );
                }
            }
            if (delta.amount0() < 0) {
                if (data.testSettings.withdrawTokens) {
                    poolManager.take(
                        data.key.currency0,
                        data.sender,
                        uint128(-delta.amount0())
                    );
                } else {
                    poolManager.mint(
                        data.key.currency0,
                        data.sender,
                        uint128(-delta.amount0())
                    );
                }
            }
        }

        return abi.encode(delta);
    }

    /// @notice Copy/paste from PoolModifyPositionTest
    function lockAcquiredModPos(
        bytes calldata rawData
    ) internal returns (bytes memory) {
        require(msg.sender == address(poolManager));

        CallbackDataModPos memory data = abi.decode(
            rawData,
            (CallbackDataModPos)
        );

        BalanceDelta delta = poolManager.modifyPosition(
            data.key,
            data.params,
            data.hookData
        );

        if (delta.amount0() > 0) {
            if (data.key.currency0.isNative()) {
                poolManager.settle{value: uint128(delta.amount0())}(
                    data.key.currency0
                );
            } else {
                TestERC20(Currency.unwrap(data.key.currency0)).transferFrom(
                    data.sender,
                    address(poolManager),
                    uint128(delta.amount0())
                );
                poolManager.settle(data.key.currency0);
            }
        }
        if (delta.amount1() > 0) {
            if (data.key.currency1.isNative()) {
                poolManager.settle{value: uint128(delta.amount1())}(
                    data.key.currency1
                );
            } else {
                TestERC20(Currency.unwrap(data.key.currency1)).transferFrom(
                    data.sender,
                    address(poolManager),
                    uint128(delta.amount1())
                );
                poolManager.settle(data.key.currency1);
            }
        }

        if (delta.amount0() < 0) {
            poolManager.take(
                data.key.currency0,
                data.sender,
                uint128(-delta.amount0())
            );
        }
        if (delta.amount1() < 0) {
            poolManager.take(
                data.key.currency1,
                data.sender,
                uint128(-delta.amount1())
            );
        }

        return abi.encode(delta);
    }
}
