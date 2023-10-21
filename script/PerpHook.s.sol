// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/contracts/test/PoolDonateTest.sol";
import {MockERC20} from "@uniswap/v4-core/test/foundry-tests/utils/MockERC20.sol";
import {PerpHook} from "../src/PerpHook.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

/// @notice Forge script for deploying v4 & hooks to **anvil**
/// @dev This script only works on an anvil RPC because v4 exceeds bytecode limits
contract PerpHookScript is Script {
    address constant CREATE2_DEPLOYER =
        address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    function setUp() public {}

    function run() public {
        vm.startBroadcast(
            0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
        );
        PoolManager manager = new PoolManager(500000);

        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_MODIFY_POSITION_FLAG |
                Hooks.AFTER_MODIFY_POSITION_FLAG
        );

        MockERC20 weth = new MockERC20(
            "Wrapped ETH",
            "WETH",
            18,
            10000000 * 10 ** 18
        );
        MockERC20 usdc = new MockERC20("USD", "USDC", 18, 10000000 * 10 ** 18);
        address _colTokenAddr = address(usdc);

        // TODO - if we actually want to deploy need to deploy an ERC20 to represent USDC first
        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            1000,
            type(PerpHook).creationCode,
            abi.encode(address(manager), _colTokenAddr)
        );

        // Deploy the hook using CREATE2

        PerpHook perpHook = new PerpHook{salt: salt}(
            IPoolManager(address(manager)),
            _colTokenAddr
        );
        require(
            address(perpHook) == hookAddress,
            "PerpHookScript: hook address mismatch"
        );

        // Additional helpers for interacting with the pool
        //vm.startBroadcast();
        //new PoolModifyPositionTest(IPoolManager(address(manager)));
        //new PoolSwapTest(IPoolManager(address(manager)));
        //new PoolDonateTest(IPoolManager(address(manager)));
        //vm.stopBroadcast();

        vm.stopBroadcast();
    }
}

// anvil --code-size-limit 30000
// forge script script/PerpHook.s.sol:PerpHookScript --fork-url http://localhost:8545 --broadcast
