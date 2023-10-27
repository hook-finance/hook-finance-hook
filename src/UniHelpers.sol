// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/contracts/libraries/SqrtPriceMath.sol";
import {SafeCast} from "@uniswap/v4-core/contracts/libraries/SafeCast.sol";
import {LiquidityAmounts} from "lib/v4-periphery/contracts/libraries/LiquidityAmounts.sol";

library UniHelpers {
    using SafeCast for *;

    /// @notice Copied from uni-v3 LiquidityManagement.sol 'addLiquidity' function
    function getLiquidityFromAmounts(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal pure returns (uint128) {
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

    /// @notice Copied from 'modifyPosition' function in Pool.sol
    function getMintBalanceDelta(
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 slot0_tick,
        uint160 slot0_sqrtPriceX96
    ) internal pure returns (BalanceDelta result) {
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
}
