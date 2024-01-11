// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {PerpHook} from "../src/PerpHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract PerpHookTest is Test, Deployers, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PoolManager manager;
    TestERC20 token0;
    TestERC20 token1;
    TestERC20 token2;

    PerpHook perpHook;
    // poolKey 0 is when USDC is token0, poolKey 1 is when USDC is token1
    PoolKey poolKey0;
    PoolKey poolKey1;
    PoolId poolId0;
    PoolId poolId1;

    function setUp() public {
        // create the pool manager, test tokens, and other utility routers
        manager = new PoolManager(500000);

        uint256 amount = 2 ** 128;
        TestERC20 _tokenA = new TestERC20(amount);
        TestERC20 _tokenB = new TestERC20(amount);
        TestERC20 _tokenC = new TestERC20(amount);

        // pools alphabetically sort tokens by address
        // so align `token0` with `pool.token0` for consistency
        if (address(_tokenA) < address(_tokenB)) {
            if (address(_tokenB) < address(_tokenC)) {
                // Ordering A/B/C
                token0 = _tokenA;
                token1 = _tokenB;
                token2 = _tokenC;
            } else if (address(_tokenA) < address(_tokenC)) {
                // Ordering A/C/B
                token0 = _tokenA;
                token1 = _tokenC;
                token2 = _tokenB;
            } else {
                // Ordering C/A/B
                token0 = _tokenC;
                token1 = _tokenA;
                token2 = _tokenB;
            }
        } else {
            if (address(_tokenC) < address(_tokenB)) {
                // Ordering C/B/A
                token0 = _tokenC;
                token1 = _tokenB;
                token2 = _tokenA;
            } else if (address(_tokenA) < address(_tokenC)) {
                // Ordering B/A/C
                token0 = _tokenB;
                token1 = _tokenA;
                token2 = _tokenC;
            } else {
                // Ordering B/C/A
                token0 = _tokenB;
                token1 = _tokenC;
                token2 = _tokenA;
            }
        }

        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.BEFORE_MODIFY_POSITION_FLAG
        );

        // Pretend token1 is USDC,
        // so we can test USDC being either token0 or token1 in a pool
        address _colTokenAddr = address(token1);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            0,
            type(PerpHook).creationCode,
            abi.encode(address(manager), _colTokenAddr)
        );

        perpHook = new PerpHook{salt: salt}(
            IPoolManager(address(manager)),
            _colTokenAddr
        );
        require(
            address(perpHook) == hookAddress,
            "PerpHookTest: hook address mismatch"
        );

        // Create the pools
        // pool0 has USDC as token0
        poolKey0 = PoolKey(
            Currency.wrap(address(token1)),
            Currency.wrap(address(token2)),
            3000,
            60,
            IHooks(perpHook)
        );
        poolId0 = poolKey0.toId();
        manager.initialize(poolKey0, SQRT_RATIO_1_1, ZERO_BYTES);

        // pool1 has USDC as token1
        poolKey1 = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            3000,
            60,
            IHooks(perpHook)
        );
        poolId1 = poolKey1.toId();
        manager.initialize(poolKey1, SQRT_RATIO_1_1, ZERO_BYTES);
    }

    function testDepositCollateral() public {
        uint256 depositAmount = 1 ether;
        // If we do not approve hook - this should fail!
        vm.expectRevert();
        perpHook.depositCollateral(poolKey1, depositAmount);

        // After we do approve, it should work
        uint256 balBefore = token1.balanceOf(address(this));
        token1.approve(address(perpHook), depositAmount);
        perpHook.depositCollateral(poolKey1, depositAmount);
        uint256 balAfter = token1.balanceOf(address(this));
        assertEq(balBefore, balAfter + depositAmount);
    }

    function testWithdrawCollateral() public {
        // First deposit...
        uint256 depositAmount = 1 ether;
        token1.approve(address(perpHook), depositAmount);
        perpHook.depositCollateral(poolKey1, depositAmount);

        // If we try to withdraw too much, it should fail
        vm.expectRevert();
        perpHook.withdrawCollateral(poolKey1, depositAmount + 1 ether);
        // But withdrawing normal amount should work
        perpHook.withdrawCollateral(poolKey1, depositAmount);

        // Add a position and make sure we can't withdraw with an open position...
        token0.approve(address(perpHook), 100 ether);
        token1.approve(address(perpHook), 100 ether);
        perpHook.depositCollateral(poolKey1, depositAmount);
        // Need to mint before we can do a trade
        perpHook.lpMint(poolKey1, 10 ether);
        perpHook.marginTrade(poolKey1, -2 ether);
        // Check that margin amounts are valid
        assertEq(perpHook.marginSwapsAbs(poolId1), 2 ether);
        assertEq(perpHook.marginSwapsNet(poolId1), -2 ether);

        // open position so this should fail
        vm.expectRevert();
        perpHook.withdrawCollateral(poolKey1, depositAmount);

        // And how after closing trade we should be able to withdraw
        perpHook.marginTrade(poolKey1, 2 ether);
        perpHook.withdrawCollateral(poolKey1, depositAmount);

        // And margin amounts should be at 0
        assertEq(perpHook.marginSwapsAbs(poolId1), 0);
        assertEq(perpHook.marginSwapsNet(poolId1), 0);
    }

    function testLpMint() public {
        token0.approve(address(perpHook), 100 ether);
        token1.approve(address(perpHook), 100 ether);

        //console.log("PERPHOOK", address(perpHook));
        //console.log("TEEST SCIRPT", address(this));

        // Don't need to transfer now since we transfer in the hook
        //token0.transfer(address(perpHook), 11 ether);
        //token1.transfer(address(perpHook), 11 ether);

        // perpHook.mint{value: 10 ether}(poolKey1);
        // These are hardcoded in function, need to change if func changes
        int24 tickLower = TickMath.minUsableTick(60);
        int24 tickUpper = TickMath.maxUsableTick(60);

        //address owner = address(this);
        address owner = address(perpHook);
        Position.Info memory position0 = manager.getPosition(
            poolId1,
            owner,
            tickLower,
            tickUpper
        );
        // Should start with 0...
        assertEq(position0.liquidity, 0);

        perpHook.lpMint(poolKey1, 3 ether);

        //uint128 liquidity = manager.getLiquidity(
        //    id,
        //    owner,
        //    tickLower,
        //    tickUpper
        //);

        Position.Info memory position1 = manager.getPosition(
            poolId1,
            owner,
            tickLower,
            tickUpper
        );
        // We minted 3*10^18 liquidity...
        assertEq(position1.liquidity, 3 ether);
        // console2.log("OUR LIQ 1", position.liquidity);
    }

    function testMarginTrade1() public {
        token0.approve(address(perpHook), 100 ether);
        token1.approve(address(perpHook), 100 ether);

        // Need to mint so we have funds to pull
        // Should add a test to make sure fails gracefully if no free liquidity?
        perpHook.lpMint(poolKey1, 3 ether);

        // int24 tickLower = TickMath.minUsableTick(60);
        // int24 tickUpper = TickMath.maxUsableTick(60);
        // address owner = address(perpHook);
        // uint128 liquidity = manager.getLiquidity(
        //     id1,
        //     owner,
        //     tickLower,
        //     tickUpper
        // );
        // console.log("MINTED LIQUIDITY", liquidity);

        int128 tradeAmount = 1 ether;

        (uint160 sqrtPriceX96_before1, , , ) = manager.getSlot0(poolId1);
        // console2.log("PRICE BEFORE", sqrtPriceX96);

        // With no collateral should fail!
        vm.expectRevert();
        perpHook.marginTrade(poolKey1, tradeAmount);

        uint depositAmount = 5 ether;
        perpHook.depositCollateral(poolKey1, depositAmount);
        perpHook.marginTrade(poolKey1, tradeAmount);

        assertEq(perpHook.marginSwapsAbs(poolId1), 1 ether);
        assertEq(perpHook.marginSwapsNet(poolId1), 1 ether);

        (uint160 sqrtPriceX96_after1, , , ) = manager.getSlot0(poolId1);
        // console2.log("PRICE AFTER", sqrtPriceX962);
        assertLt(sqrtPriceX96_after1, sqrtPriceX96_before1);
    }

    function testMarginTrade0() public {
        // test with USDC as token0
        token1.approve(address(perpHook), 100 ether);
        token2.approve(address(perpHook), 100 ether);

        // Need to mint so we have funds to pull
        // Should add a test to make sure fails gracefully if no free liquidity?
        perpHook.lpMint(poolKey0, 3 ether);
        int128 tradeAmount = 1 ether;

        (uint160 sqrtPriceX96_before0, , , ) = manager.getSlot0(poolId0);

        // With no collateral should fail!
        vm.expectRevert();
        perpHook.marginTrade(poolKey0, tradeAmount);

        uint depositAmount = 5 ether;

        perpHook.depositCollateral(poolKey0, depositAmount);
        perpHook.marginTrade(poolKey0, tradeAmount);

        assertEq(perpHook.marginSwapsAbs(poolId0), 1 ether);
        assertEq(perpHook.marginSwapsNet(poolId0), 1 ether);

        (uint160 sqrtPriceX96_after0, , , ) = manager.getSlot0(poolId0);
        // console2.log("PRICE AFTER", sqrtPriceX962);
        assertGt(sqrtPriceX96_after0, sqrtPriceX96_before0);
    }
}
