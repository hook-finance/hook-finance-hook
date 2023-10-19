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
// import {LiquidityAmounts} from "@uniswap/v4-periphery/contracts/libraries/LiquidityAmounts.sol";
import {LiquidityAmounts} from "lib/v4-periphery/contracts/libraries/LiquidityAmounts.sol";

import "forge-std/console2.sol";

contract PerpHook is BaseHook {
    using SafeCast for *;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    struct LeveragedPosition {
        int128 position;
        int256 positionNet;
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyPositionParams params;
        bytes hookData;
    }

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
    mapping(PoolId => mapping(address => LeveragedPosition))
        public levPositions;

    mapping(PoolId => mapping(address => uint256 amount)) public lpAmounts;

    // Only accepting one token as collateral for now, set to USDC by default
    address colTokenAddr;

    PoolSwapTest swapRouter;

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
        // Disable withdrawals if they have an open position?
        require(
            levPositions[id][msg.sender].position == 0,
            "Positions must be closed!"
        );
        collateral[id][msg.sender] -= withdrawAmount;
        TestERC20(colTokenAddr).transfer(msg.sender, withdrawAmount);
        // TODO - emit some event
    }

    /// @notice Copy/paste from 'modifyPosition' function in Pool.sol, needed so we can transfer funds from LP to stake ourselves
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

    /// @notice Deposits funds to be used as both pool liquidity and funds to execute swaps
    function lpMint(
        PoolKey memory key,
        int128 liquidityDelta
    ) external payable {
        require(liquidityDelta > 0, "Negative stakes not allowed!");
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

        // BalanceDelta delta
        modifyPosition(
            key,
            IPoolManager.ModifyPositionParams(
                tickLower,
                tickUpper,
                liquidityDelta
            ),
            ZERO_BYTES
        );

        lpAmounts[id][msg.sender] += uint128(liquidityDelta);
    }

    /// @notice Copied from uni-v3 LiquidityManagement.sol 'addLiquidity' function
    function getLiquidityFromAmounts(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal returns (uint128) {
        // compute liquidity amount given some amount0 and amount1
        //(uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            amount0Desired,
            amount1Desired
        );
        return liquidity;
    }

    function removeLiquidity(PoolKey memory key, int128 tradeAmount) internal {
        // Hardcoding full tick range for now
        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);

        PoolId id = key.toId();
        (uint160 slot0_sqrtPriceX96, int24 slot0_tick, , ) = poolManager
            .getSlot0(id);

        uint256 amount0Desired;
        uint256 amount1Desired;
        if (tradeAmount > 0) {
            amount0Desired = uint128(tradeAmount);
            // Note - can't set to 2**256-1 or it causes some kind of overflow
            amount1Desired = 2 ** 64;
        } else {
            amount0Desired = 2 ** 64;
            amount1Desired = uint128(-tradeAmount);
        }
        // console2.log("GOT AMOUNTS");

        // FIgure out how much we have to remove to do the swap...
        uint256 liquidity = getLiquidityFromAmounts(
            slot0_sqrtPriceX96,
            tickLower,
            tickUpper,
            amount0Desired,
            amount1Desired
        );
        // console2.log("LIQ", liquidity);

        bytes memory ZERO_BYTES = new bytes(0);

        modifyPosition(
            key,
            IPoolManager.ModifyPositionParams(
                tickLower,
                tickUpper,
                -int256(liquidity)
            ),
            ZERO_BYTES
        );

        // console2.log("MODIFIED");
    }

    /// @notice from https://ethereum.stackexchange.com/questions/2910/can-i-square-root-in-solidity
    /// @notice Calculates the square root of x, rounding down.
    /// @dev Uses the Babylonian method https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method.
    /// @param x The uint256 number for which to calculate the square root.
    /// @return result The result as an uint256.
    function sqrt(uint256 x) internal pure returns (uint256 result) {
        if (x == 0) {
            return 0;
        }

        // Calculate the square root of the perfect square of a power of two that is the closest to x.
        uint256 xAux = uint256(x);
        result = 1;
        if (xAux >= 0x100000000000000000000000000000000) {
            xAux >>= 128;
            result <<= 64;
        }
        if (xAux >= 0x10000000000000000) {
            xAux >>= 64;
            result <<= 32;
        }
        if (xAux >= 0x100000000) {
            xAux >>= 32;
            result <<= 16;
        }
        if (xAux >= 0x10000) {
            xAux >>= 16;
            result <<= 8;
        }
        if (xAux >= 0x100) {
            xAux >>= 8;
            result <<= 4;
        }
        if (xAux >= 0x10) {
            xAux >>= 4;
            result <<= 2;
        }
        if (xAux >= 0x8) {
            result <<= 1;
        }

        // The operations can never overflow because the result is max 2^127 when it enters this block.
        unchecked {
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1; // Seven iterations should be enough
            uint256 roundedDownResult = x / result;
            return result >= roundedDownResult ? roundedDownResult : result;
        }
    }

    /// @notice from https://ethereum.stackexchange.com/questions/84390/absolute-value-in-solidity
    function abs(int128 x) private pure returns (uint128) {
        return x >= 0 ? uint128(x) : uint128(-x);
    }

    /// @notice Allow a user (who has already deposited collateral) to execute a leveraged trade
    function marginTrade(
        PoolKey memory key,
        int128 tradeAmount
    ) external payable {
        removeLiquidity(key, tradeAmount);

        bool zeroForOne = tradeAmount < 0 ? true : false;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int128(abs(tradeAmount)),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_RATIO + 1
                : TickMath.MAX_SQRT_RATIO - 1 // unlimited impact
            //sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        // TODO - move swapRouter logic into this contract and we won't have to
        // deal with the approvals, need to figure out how it can coexist with
        // position manager logic though
        {
            TestERC20 token0 = TestERC20(Currency.unwrap(key.currency0));
            TestERC20 token1 = TestERC20(Currency.unwrap(key.currency1));
            token0.approve(address(swapRouter), 100 ether);
            token1.approve(address(swapRouter), 100 ether);
        }
        bytes memory hookData = new bytes(0);
        BalanceDelta delta = swapRouter.swap(
            key,
            params,
            testSettings,
            hookData
        );

        // token1 amount is our trade size
        // Assumes token1 will always be USDC - in reality we cannot make this
        // assumption, even if all pairs have USDC it could be token0 or token1
        uint128 amountUSDC = abs(delta.amount1());

        // Remember - collateral is also in USDC
        // Saying max 20x leverage - we'll liquidate at that point
        PoolId id = key.toId();
        uint collateral20x = collateral[id][msg.sender] * 20;

        // Should we multiply by 10^x to get better precision?
        uint ratio = collateral20x / amountUSDC;
        // Saying 10x initial leverage requirement
        // require(amountUSDC <= collateral20x / 2);
        require(ratio >= 2, "Not enough collateral");

        (uint160 slot0_sqrtPriceX96, int24 slot0_tick, , ) = poolManager
            .getSlot0(id);

        // sqrtPriceXs are uint160 - possible but unlikely this will overflow?
        // Actually - when all liquidity is taken think sqrtPriceX96 goes to extreme
        // In that case think it would overflow?
        uint256 liqSqrtPriceX = sqrt(
            (uint256(slot0_sqrtPriceX96) * uint256(slot0_sqrtPriceX96)) * ratio
        );

        // Should we store liquidation prices at tick level instead?
        // TickMath.getTickAtSqrtRatio(uint160 sqrtPriceX96)

        // TODO need to += instead of overwriting position so we can add to and close positions
        //int256 positionNet = int256(tradeAmount) *
        //    int256(int160(slot0_sqrtPriceX96));
        // levPositions[id][msg.sender] = LeveragedPosition(
        //     tradeAmount,
        //     int256(tradeAmount) * int256(int160(slot0_sqrtPriceX96))
        // );

        levPositions[id][msg.sender].position += tradeAmount;
        levPositions[id][msg.sender].positionNet +=
            int256(tradeAmount) *
            int256(int160(slot0_sqrtPriceX96));

        // TODO - how can we track our liquidation prices in a way that
        // makes it possible to perform liquidations?
        // Need a priority queue or something for efficient checking
        // But general form is {sqrtPriceX: [address, address...]}
        // Think it would be vulnerable to attacks as we'd have to iterate over
        // all the addresses to liquidate?
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
