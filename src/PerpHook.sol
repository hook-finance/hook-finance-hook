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
import {SqrtPriceMath} from "@uniswap/v4-core/contracts/libraries/SqrtPriceMath.sol";
import {SafeCast} from "@uniswap/v4-core/contracts/libraries/SafeCast.sol";
// import {LiquidityAmounts} from "@uniswap/v4-periphery/contracts/libraries/LiquidityAmounts.sol";
import {LiquidityAmounts} from "lib/v4-periphery/contracts/libraries/LiquidityAmounts.sol";
import {PoolCallsHook} from "./PoolCallsHook.sol";

// import "forge-std/console2.sol";

contract PerpHook is PoolCallsHook {
    using SafeCast for *;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // By keeping track of result of swaps executed on behalf of user we can track profits
    struct LeveragedPosition {
        int128 position0;
        int128 position1;
        uint256 startSwapMarginFeesPerUnit;
        int256 startSwapFundingFeesPerUnit;
    }

    struct LPPosition {
        uint256 liquidity;
        uint256 startLpMarginFeesPerUnit;
    }

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    // Track collateral amounts of users
    // Collateral is at pool level...
    // mapping(address => uint256 colAmount) public collateral;
    // Should collateral be an int just in case it goes negative?
    mapping(PoolId => mapping(address => uint256)) public collateral;
    // Profits from margin fees paid to LPs - will represent amount in USDC
    mapping(PoolId => mapping(address => uint256)) public lpProfits;
    mapping(PoolId => mapping(address => LeveragedPosition))
        public levPositions;

    mapping(PoolId => mapping(address => LPPosition)) public lpPositions;

    mapping(PoolId => uint256) public lastFundingTime;

    // Absolute value of margin swaps, so if open positions are [-100, +200], should be 300
    mapping(PoolId => uint256) public marginSwapsAbs;
    // Net value of margin swaps, so if open positions are [-100, +200], should be -100
    mapping(PoolId => int256) public marginSwapsNet;
    // Need to keep track of how much liquidity LPs have deposited rather than how
    // much there actually is, so we can properly credit margin payments
    mapping(PoolId => uint256) public lpLiqTotal;
    // keep track of margin fees owed to LPs
    mapping(PoolId => uint256) public lpMarginFeesPerUnit;
    // keep track of margin fees owed by swappers
    mapping(PoolId => uint256) public swapMarginFeesPerUnit;
    // keep track of funding fees owed between swappers
    mapping(PoolId => int256) public swapFundingFeesPerUnit;

    // Only accepting one token as collateral for now, set to USDC by default
    address colTokenAddr;

    event Mint(address indexed minter, int256 amount);
    event Burn(address indexed burner, int256 amount);
    event Deposit(address indexed swapper, uint256 amount);
    event Withdraw(address indexed swapper, uint256 amount);
    event Trade(address indexed swapper, int256 amount);
    event Liquidate(
        address indexed liquidator,
        address indexed swapper,
        int256 amount
    );

    constructor(
        IPoolManager _poolManager,
        address _colTokenAddr
    ) PoolCallsHook(_poolManager) {
        // swapRouter = new PoolSwapTest(_poolManager);
        colTokenAddr = _colTokenAddr;
    }

    /// @notice manage margin and funding payments for swappers
    function settleSwapper(PoolId id, address addrSwapper) internal {
        uint256 marginFeesPerUnit = swapMarginFeesPerUnit[id] -
            levPositions[id][addrSwapper].startSwapMarginFeesPerUnit;
        uint256 marginPaid = marginFeesPerUnit *
            abs(levPositions[id][addrSwapper].position0);

        int256 fundingFeesPerUnit = swapFundingFeesPerUnit[id] -
            levPositions[id][addrSwapper].startSwapFundingFeesPerUnit;
        int256 fundingPaid = fundingFeesPerUnit *
            levPositions[id][addrSwapper].position0;

        collateral[id][addrSwapper] -= marginPaid;
        if (fundingPaid > 0) {
            collateral[id][addrSwapper] += uint256(fundingPaid);
        } else {
            collateral[id][addrSwapper] -= uint256(-fundingPaid);
        }
    }

    /// @notice manage margin payments to LPs
    function settleLP(PoolId id, address addrLP) internal {
        // Need to add all their margin fees to profits
        // so move current fees to profits...
        uint marginFeesPerUnit = lpMarginFeesPerUnit[id] -
            lpPositions[id][addrLP].startLpMarginFeesPerUnit;

        uint lpProfit = marginFeesPerUnit * lpPositions[id][addrLP].liquidity;
        lpProfits[id][addrLP] += lpProfit;
    }

    function liquidateSwapper(PoolKey calldata key, address liqSwapper) public {
        PoolId id = key.toId();

        // We can just execute the swap and confirm that it was a valid liquidation
        // based on amounts post-swap, and revert if it's invalid
        int128 tradeAmount = -levPositions[id][liqSwapper].position0;
        BalanceDelta delta = execMarginTrade(key, tradeAmount);
        // This is the current position value
        int128 positionVal = delta.amount1();

        settleSwapper(id, liqSwapper);

        uint256 swapperCol = collateral[id][liqSwapper];
        LeveragedPosition memory swapperPos = levPositions[id][liqSwapper];
        int128 profit = positionVal - swapperPos.position1;

        uint remainingCollateral;
        if (profit < 0) {
            remainingCollateral = swapperCol - uint128(-profit);
        } else {
            remainingCollateral = swapperCol + uint128(profit);
        }

        // Must be greater than 20x leverage in order to liquidate!
        require(
            abs(positionVal) / remainingCollateral > 20,
            "Invalid liquidation!"
        );

        // Pay a fee to the liquidator
        uint256 liqFee = remainingCollateral / 20;
        TestERC20(colTokenAddr).transfer(msg.sender, liqFee);

        // And do position accounting
        levPositions[id][liqSwapper].position0 += delta.amount0();
        levPositions[id][liqSwapper].position1 += delta.amount1();

        levPositions[id][liqSwapper]
            .startSwapMarginFeesPerUnit = swapMarginFeesPerUnit[id];
        levPositions[id][liqSwapper]
            .startSwapFundingFeesPerUnit = swapFundingFeesPerUnit[id];

        // This should take care of calculating current swapper collateral
        profitToCollateral(key, liqSwapper);

        emit Liquidate(msg.sender, liqSwapper, tradeAmount);
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
        emit Deposit(msg.sender, depositAmount);
    }

    function withdrawCollateral(
        PoolKey memory key,
        uint256 withdrawAmount
    ) external {
        PoolId id = key.toId();
        require(collateral[id][msg.sender] >= withdrawAmount);
        // Disable withdrawals if they have an open position?
        require(
            levPositions[id][msg.sender].position0 == 0,
            "Positions must be closed!"
        );
        // This should always be closed if position0 is closed, remove check to save gas?
        require(
            levPositions[id][msg.sender].position1 == 0,
            "Positions must be closed!"
        );
        collateral[id][msg.sender] -= withdrawAmount;
        TestERC20(colTokenAddr).transfer(msg.sender, withdrawAmount);
        emit Withdraw(msg.sender, withdrawAmount);
    }

    /// @notice If position is flat calculate profit and move it to collateral
    function profitToCollateral(
        PoolKey memory key,
        address addrSwapper
    ) internal {
        PoolId id = key.toId();
        require(
            levPositions[id][addrSwapper].position0 == 0,
            "Positions must be closed!"
        );
        if (levPositions[id][addrSwapper].position1 > 0) {
            collateral[id][addrSwapper] += uint128(
                levPositions[id][addrSwapper].position1
            );
        } else {
            collateral[id][addrSwapper] += uint128(
                -levPositions[id][addrSwapper].position1
            );
        }
        levPositions[id][addrSwapper].position1 = 0;
    }

    /// @notice Removes an LPs stake
    function lpBurn(PoolKey memory key, int128 liquidityDelta) external {
        require(liquidityDelta < 0);
        PoolId id = key.toId();
        require(
            lpPositions[id][msg.sender].liquidity >= uint128(-liquidityDelta),
            "Not enough liquidity!"
        );

        // mint across entire range?
        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);

        BalanceDelta delta = modifyPosition(
            key,
            IPoolManager.ModifyPositionParams(
                tickLower,
                tickUpper,
                liquidityDelta
            ),
            ""
        );

        settleLP(id, msg.sender);

        lpLiqTotal[id] -= uint128(-liquidityDelta);
        lpPositions[id][msg.sender].liquidity -= uint128(liquidityDelta);
        lpPositions[id][msg.sender]
            .startLpMarginFeesPerUnit = lpMarginFeesPerUnit[id];

        TestERC20 token0 = TestERC20(Currency.unwrap(key.currency0));
        TestERC20 token1 = TestERC20(Currency.unwrap(key.currency1));
        // Return tokens to sender...
        token0.transfer(msg.sender, uint128(delta.amount0()));

        // Include margin fees in this transfer
        token1.transfer(
            msg.sender,
            uint128(delta.amount1()) + lpProfits[id][msg.sender]
        );
        lpProfits[id][msg.sender] = 0;

        emit Burn(msg.sender, liquidityDelta);
    }

    /// @notice Deposits funds to be used as both pool liquidity and funds to execute swaps
    function lpMint(
        PoolKey memory key,
        int128 liquidityDelta
    ) external payable {
        require(liquidityDelta > 0, "Negative stakes not allowed!");

        // mint across entire range?
        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);

        PoolId id = key.toId();
        (uint160 slot0_sqrtPriceX96, int24 slot0_tick, , ) = poolManager
            .getSlot0(id);

        lpLiqTotal[id] += uint128(liquidityDelta);
        // Must be gt 0
        // if (liquidityDelta > 0) {
        //     lpLiqTotal[id] += uint128(liquidityDelta);
        // } else {
        //     lpLiqTotal[id] -= uint128(-liquidityDelta);
        // }

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
            ""
        );

        settleLP(id, msg.sender);

        // Now that we've settled margin amounts we can adjust liquidity values

        lpPositions[id][msg.sender].liquidity += uint128(liquidityDelta);
        lpPositions[id][msg.sender]
            .startLpMarginFeesPerUnit = lpMarginFeesPerUnit[id];

        emit Mint(msg.sender, liquidityDelta);
    }

    function execMarginTrade(
        PoolKey memory key,
        int128 tradeAmount
    ) internal returns (BalanceDelta delta) {
        removeLiquidity(key, tradeAmount);

        /*
        We're expressing tradeAmount as the trade size in token0, where a positive
        number represents a long position, while a negative number represents a
        short position, but when actually executing we have to use (-tradeAmount),
        since for the pool logic if we have:
        zeroForOne = true
        tradeAmount = 100 (or any positive number)
        it means we'll swap 100 token0s for token1s, so this is actually SELLING token0
        */
        bool zeroForOne = tradeAmount > 0 ? false : true;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -tradeAmount,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_RATIO + 1
                : TickMath.MAX_SQRT_RATIO - 1 // unlimited impact
        });

        TestSettingsSwap memory testSettings = TestSettingsSwap({
            withdrawTokens: true,
            settleUsingTransfer: true
        });

        delta = swap(key, params, testSettings, "");
    }

    /// @notice Allow a user (who has already deposited collateral) to execute a leveraged trade
    function marginTrade(
        PoolKey memory key,
        int128 tradeAmount
    ) external payable {
        BalanceDelta delta = execMarginTrade(key, tradeAmount);

        PoolId id = key.toId();
        settleSwapper(id, msg.sender);

        // token1 amount is our trade size
        // Assumes token1 will always be USDC - in reality we cannot make this
        // assumption, even if all pairs have USDC it could be token0 or token1
        uint128 amountUSDC = abs(delta.amount1());

        // Remember - collateral is also in USDC
        // Saying max 20x leverage - we'll liquidate at that point
        uint collateral20x = collateral[id][msg.sender] * 20;

        // Should we multiply by 10^x to get better precision?
        uint ratio = collateral20x / amountUSDC;
        // Saying 10x initial leverage requirement
        // require(amountUSDC <= collateral20x / 2);
        require(ratio >= 2, "Not enough collateral");

        // (uint160 slot0_sqrtPriceX96, , , ) = poolManager.getSlot0(id);

        // sqrtPriceXs are uint160 - possible but unlikely this will overflow?
        // Actually - when all liquidity is taken think sqrtPriceX96 goes to extreme
        // In that case think it would overflow?
        // Don't need this value if we rely on external liquidators
        // uint256 liqSqrtPriceX = sqrt(
        //     (uint256(slot0_sqrtPriceX96) * uint256(slot0_sqrtPriceX96)) * ratio
        // );

        // Should we store liquidation prices at tick level instead?
        // TickMath.getTickAtSqrtRatio(uint160 sqrtPriceX96)

        // Track our positions
        levPositions[id][msg.sender].position0 += delta.amount0();
        levPositions[id][msg.sender].position1 += delta.amount1();

        levPositions[id][msg.sender]
            .startSwapMarginFeesPerUnit = swapMarginFeesPerUnit[id];
        levPositions[id][msg.sender]
            .startSwapFundingFeesPerUnit = swapFundingFeesPerUnit[id];

        // If they've closed their position, calculate their profit and add to collateral
        if (levPositions[id][msg.sender].position0 == 0) {
            profitToCollateral(key, msg.sender);
        }

        emit Trade(msg.sender, tradeAmount);
    }

    function doFundingMarginPayments(PoolKey memory key) internal {
        PoolId id = key.toId();

        while (block.timestamp > lastFundingTime[id] + 3600) {
            /*
            margin fee:
            10% annual on position size, charged hourly
            365*24 = 8760 periods
            So divide by 87600 every hour to get payment
            1*10**18 / 87600 * 8760 = 1*10**17
            */
            uint marginPayment = marginSwapsAbs[id] / 87600;
            if (marginPayment > 0) {
                lpMarginFeesPerUnit[id] += marginPayment / lpLiqTotal[id];
                swapMarginFeesPerUnit[id] += marginPayment / marginSwapsAbs[id];

                int256 fundingPayment = marginSwapsNet[id] / 17520;
                // Scale funding payment proportional to net long/short exposure
                // 17520 = 50% max payment
                // Note that this will be apply even if there's no
                // other side of the trade?  What happens to the payment in the
                // scenario where we have 1 position of +1000?
                int256 payAdj = fundingPayment / marginSwapsNet[id];
                swapFundingFeesPerUnit[id] += payAdj;
            }

            lastFundingTime[id] += 3600;
        }
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160,
        bytes calldata
    ) external override returns (bytes4) {
        PoolId id = key.toId();
        // Round down to nearest hour
        lastFundingTime[id] = (block.timestamp / (3600)) * 3600;
        return BaseHook.beforeInitialize.selector;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        doFundingMarginPayments(key);
        return BaseHook.beforeSwap.selector;
    }

    function beforeModifyPosition(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        // TODO - enable this when we deploy, makes setup more challenging otherwise
        // require(
        //     msg.sender == address(this),
        //     "Only hook can deposit liquidity!"
        // );
        doFundingMarginPayments(key);
        return BaseHook.beforeModifyPosition.selector;
    }

    /// @notice from https://ethereum.stackexchange.com/questions/84390/absolute-value-in-solidity
    function abs(int128 x) internal pure returns (uint128) {
        return x >= 0 ? uint128(x) : uint128(-x);
    }

    function removeLiquidity(PoolKey memory key, int128 tradeAmount) internal {
        // Hardcoding full tick range for now
        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);

        PoolId id = key.toId();
        (uint160 slot0_sqrtPriceX96, , , ) = poolManager.getSlot0(id);

        uint256 amount0Desired;
        uint256 amount1Desired;
        // tradeAmount is ALWAYS amount0?
        // When we trade oneForZero will we get exact amount though?
        amount0Desired = uint128(abs(tradeAmount));
        amount1Desired = 2 ** 64;

        // FIgure out how much we have to remove to do the swap...
        uint256 liquidity = getLiquidityFromAmounts(
            slot0_sqrtPriceX96,
            tickLower,
            tickUpper,
            amount0Desired,
            amount1Desired
        );

        modifyPosition(
            key,
            IPoolManager.ModifyPositionParams(
                tickLower,
                tickUpper,
                -int256(liquidity)
            ),
            ""
        );
    }

    /// @notice Copied from uni-v3 LiquidityManagement.sol 'addLiquidity' function
    function getLiquidityFromAmounts(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal pure returns (uint128) {
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

    /// @notice Copy/paste from 'modifyPosition' function in Pool.sol, needed so we can transfer funds from LP to stake ourselves
    function getMintBalanceDelta(
        int24 tickLower,
        int24 tickUpper,
        //int256 liquidityDelta,
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
