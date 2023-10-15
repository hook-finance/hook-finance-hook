// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
// import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/contracts/libraries/SqrtPriceMath.sol";
import {SafeCast} from "@uniswap/v4-core/contracts/libraries/SafeCast.sol";

import "forge-std/console2.sol";

contract PerpHook is BaseHook {
    using SafeCast for *;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    mapping(PoolId => uint256 count) public beforeSwapCount;
    mapping(PoolId => uint256 count) public afterSwapCount;

    mapping(PoolId => uint256 count) public beforeModifyPositionCount;
    mapping(PoolId => uint256 count) public afterModifyPositionCount;

    // Track collateral amounts of users
    // Collateral is at pool level...
    // mapping(address => uint256 colAmount) public collateral;
    mapping(PoolId => mapping(address => uint256 colAmount)) public collateral;

    // Only accepting one token as collateral for now, set to USDC by default
    address colTokenAddr;

    PoolSwapTest swapRouter;

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyPositionParams params;
        bytes hookData;
    }

    constructor(
        IPoolManager _poolManager,
        address _colTokenAddr
    ) BaseHook(_poolManager) {
        swapRouter = new PoolSwapTest(_poolManager);
        colTokenAddr = _colTokenAddr;
    }

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return
            Hooks.Calls({
                beforeInitialize: false,
                afterInitialize: false,
                beforeModifyPosition: true,
                afterModifyPosition: true,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false
            });
    }

    function depositCollateral(
        PoolKey memory key,
        uint256 depositAmount
    ) external payable {
        TestERC20(colTokenAddr).transferFrom(
            msg.sender,
            address(this),
            depositAmount
        );
        PoolId id = key.toId();
        collateral[id][msg.sender] += depositAmount;
        // TODO - emit some event
    }

    function withdrawCollateral(
        PoolKey memory key,
        uint256 withdrawAmount
    ) external {
        PoolId id = key.toId();
        require(collateral[id][msg.sender] >= withdrawAmount);
        collateral[id][msg.sender] -= withdrawAmount;
        TestERC20(colTokenAddr).transfer(msg.sender, withdrawAmount);
        // TODO - emit some event
    }

    /// @dev Copy/paste from 'modifyPosition' function in Pool.sol, needed so we can transfer funds from LP to stake ourselves
    function getMintBalanceDelta(
        int24 tickLower,
        int24 tickUpper,
        //int256 liquidityDelta,
        int128 liquidityDelta,
        int24 slot0_tick,
        uint160 slot0_sqrtPriceX96
    ) internal returns (BalanceDelta result) {
        // NOTE - function assumes hookFees are 0,
        // if that changes need to add extra logic from Pool.sol function
        if (liquidityDelta != 0) {
            if (slot0_tick < tickLower) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to
                // right, when we'll need _more_ currency0 (it's becoming more valuable) so user must provide it
                result =
                    result +
                    toBalanceDelta(
                        SqrtPriceMath
                            .getAmount0Delta(
                                TickMath.getSqrtRatioAtTick(tickLower),
                                TickMath.getSqrtRatioAtTick(tickUpper),
                                liquidityDelta
                            )
                            .toInt128(),
                        0
                    );
            } else if (slot0_tick < tickUpper) {
                result =
                    result +
                    toBalanceDelta(
                        SqrtPriceMath
                            .getAmount0Delta(
                                slot0_sqrtPriceX96,
                                TickMath.getSqrtRatioAtTick(tickUpper),
                                liquidityDelta
                            )
                            .toInt128(),
                        SqrtPriceMath
                            .getAmount1Delta(
                                TickMath.getSqrtRatioAtTick(tickLower),
                                slot0_sqrtPriceX96,
                                liquidityDelta
                            )
                            .toInt128()
                    );
            } else {
                // current tick is above the passed range; liquidity can only become in range by crossing from right to
                // left, when we'll need _more_ currency1 (it's becoming more valuable) so user must provide it
                result =
                    result +
                    toBalanceDelta(
                        0,
                        SqrtPriceMath
                            .getAmount1Delta(
                                TickMath.getSqrtRatioAtTick(tickLower),
                                TickMath.getSqrtRatioAtTick(tickUpper),
                                liquidityDelta
                            )
                            .toInt128()
                    );
            }
        }
    }

    /// @dev Deposits funds to be used as both pool liquidity and funds to execute swaps
    function lpMint(
        PoolKey memory key,
        int128 liquidityDelta
    ) external payable {
        bytes memory ZERO_BYTES = new bytes(0);
        // mint across entire range?
        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);

        PoolId id = key.toId();
        (uint160 slot0_sqrtPriceX96, int24 slot0_tick, , ) = poolManager
            .getSlot0(id);

        // Need to precompute balance deltas so we can take funds from LP to stake ourselves
        BalanceDelta deltaPred = getMintBalanceDelta(
            tickLower,
            tickUpper,
            liquidityDelta,
            slot0_tick,
            slot0_sqrtPriceX96
        );

        // console2.log("BAL PRED");
        // console2.log(deltaPred.amount0());
        // console2.log(deltaPred.amount1());

        TestERC20 token0 = TestERC20(Currency.unwrap(key.currency0));
        TestERC20 token1 = TestERC20(Currency.unwrap(key.currency1));

        // Because we're minting these values will always be positive, so uint128 cast is safe
        // TODO - better understand what is going on here - if we comment out the token1 transfer it still works!?
        token0.transferFrom(
            msg.sender,
            address(this),
            uint128(deltaPred.amount0())
        );
        token1.transferFrom(
            msg.sender,
            address(this),
            uint128(deltaPred.amount1())
        );

        BalanceDelta delta = modifyPosition(
            key,
            IPoolManager.ModifyPositionParams(tickLower, tickUpper, 3 ether),
            ZERO_BYTES
        );

        // Should match exactly with precomputed values
        // console2.log("BAL DELTA");
        // console2.log(delta.amount0());
        // console2.log(delta.amount1());
    }

    /// @dev Allow a user (who has already deposited collateral) to execute a leveraged trade
    function marginTrade(
        PoolKey memory key,
        int128 tradeAmount
    ) external payable {
        // TODO - make sure collateral sufficient

        // TODO - improve remove/restake logic - need to remove just enough to swap 'tradeAmount'

        // Pull liquidity
        // Restake liquidity (leaving some funds)
        // Execute swawp

        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);
        bytes memory ZERO_BYTES = new bytes(0);
        modifyPosition(
            key,
            IPoolManager.ModifyPositionParams(tickLower, tickUpper, -3 ether),
            ZERO_BYTES
        );

        // And now restake...
        modifyPosition(
            key,
            IPoolManager.ModifyPositionParams(tickLower, tickUpper, 2 ether),
            ZERO_BYTES
        );

        // And now execute swap...

        // Copied from HookTest.sol
        // uint160 MIN_PRICE_LIMIT = TickMath.MIN_SQRT_RATIO + 1;
        // uint160 MAX_PRICE_LIMIT = TickMath.MAX_SQRT_RATIO - 1;
        // int256 amountSpecified =
        // bool zeroForOne = true;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1 ether,
            // sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT // unlimited impact
            sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        TestERC20 token0 = TestERC20(Currency.unwrap(key.currency0));
        TestERC20 token1 = TestERC20(Currency.unwrap(key.currency1));
        token0.approve(address(swapRouter), 100 ether);
        token1.approve(address(swapRouter), 100 ether);
        bytes memory hookData = new bytes(0);
        swapRouter.swap(key, params, testSettings, hookData);

        // TODO - how do we track positions?
        //positions[id][msg.sender] += tradeAmount
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        beforeSwapCount[key.toId()]++;
        return BaseHook.beforeSwap.selector;
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4) {
        afterSwapCount[key.toId()]++;
        return BaseHook.afterSwap.selector;
    }

    function beforeModifyPosition(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        beforeModifyPositionCount[key.toId()]++;
        return BaseHook.beforeModifyPosition.selector;
    }

    function afterModifyPosition(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4) {
        afterModifyPositionCount[key.toId()]++;
        return BaseHook.afterModifyPosition.selector;
    }

    /// @notice Copy/paste from PoolModifyPositionTest - we need it here because we want msg.sender to be our hook when we mint
    function modifyPosition(
        PoolKey memory key,
        IPoolManager.ModifyPositionParams memory params,
        bytes memory hookData
    ) internal returns (BalanceDelta delta) {
        delta = abi.decode(
            poolManager.lock(
                abi.encode(CallbackData(msg.sender, key, params, hookData))
            ),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    /// @notice Copy/paste from PoolModifyPositionTest
    function lockAcquired(
        bytes calldata rawData
    ) external override returns (bytes memory) {
        require(msg.sender == address(poolManager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

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
