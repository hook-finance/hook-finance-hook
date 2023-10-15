// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import "forge-std/console2.sol";

contract PerpHook is BaseHook {
    using PoolIdLibrary for PoolKey;

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

    PoolModifyPositionTest modifyPositionRouter;
    PoolSwapTest swapRouter;

    constructor(
        IPoolManager _poolManager,
        address _colTokenAddr
    ) BaseHook(_poolManager) {
        modifyPositionRouter = new PoolModifyPositionTest(_poolManager);
        swapRouter = new PoolSwapTest(_poolManager);
        console2.log("MPR ADDRESS", address(modifyPositionRouter));
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
}
