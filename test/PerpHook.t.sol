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
import {HookTest} from "./utils/HookTest.sol";
import {PerpHook} from "../src/PerpHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";

contract PerpHookTest is HookTest, Deployers, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PerpHook perpHook;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        // creates the pool manager, test tokens, and other utility routers
        HookTest.initHookTestEnv();

        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_MODIFY_POSITION_FLAG |
                Hooks.AFTER_MODIFY_POSITION_FLAG
        );

        // Pretend token1 is USDC...
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

        // Create the pool
        poolKey = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            3000,
            60,
            IHooks(perpHook)
        );
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_RATIO_1_1, ZERO_BYTES);

        // Provide liquidity to the pool
        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(-60, 60, 10 ether),
            ZERO_BYTES
        );
        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(-120, 120, 10 ether),
            ZERO_BYTES
        );
        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(
                TickMath.minUsableTick(60),
                TickMath.maxUsableTick(60),
                10 ether
            ),
            ZERO_BYTES
        );
    }

    function disabledtestPerpHookHooks() public {
        // positions were created in setup()
        assertEq(perpHook.beforeModifyPositionCount(poolId), 3);
        assertEq(perpHook.afterModifyPositionCount(poolId), 3);

        assertEq(perpHook.beforeSwapCount(poolId), 0);
        assertEq(perpHook.afterSwapCount(poolId), 0);

        // Perform a test swap //
        int256 amount = 100;
        bool zeroForOne = true;
        swap(poolKey, amount, zeroForOne, ZERO_BYTES);
        // ------------------- //

        assertEq(perpHook.beforeSwapCount(poolId), 1);
        assertEq(perpHook.afterSwapCount(poolId), 1);
    }

    function testAdjustCollateral() public {
        uint256 depositAmount = 1 ether;
        // If we do not approve hook - this should fail!
        vm.expectRevert();
        perpHook.depositCollateral(poolKey, depositAmount);

        // After we do approve, it should work
        uint256 balBefore = token1.balanceOf(address(this));
        token1.approve(address(perpHook), depositAmount);
        perpHook.depositCollateral(poolKey, depositAmount);
        uint256 balAfter = token1.balanceOf(address(this));
        assertEq(balBefore, balAfter + depositAmount);

        // If we try to withdraw too much, it should fail
        vm.expectRevert();
        perpHook.withdrawCollateral(poolKey, depositAmount + 1 ether);
        // But withdrawing normal amount should work
        perpHook.withdrawCollateral(poolKey, depositAmount);
    }
}
