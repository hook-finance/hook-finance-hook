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
        uint privateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(privateKey);

        // PoolManager manager = new PoolManager(500000);
        address addrManager = 0x64255ed21366DB43d89736EE48928b890A84E2Cb;

        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.BEFORE_MODIFY_POSITION_FLAG
        );

        MockERC20 weth = new MockERC20(
            "Wrapped ETH",
            "WETH",
            18,
            10000000 * 10 ** 18
        );
        MockERC20 usdc = new MockERC20("USD", "USDC", 18, 10000000 * 10 ** 18);
        address _colTokenAddr = address(usdc);

        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            1000,
            type(PerpHook).creationCode,
            abi.encode(addrManager, _colTokenAddr)
        );

        // Deploy the hook using CREATE2
        PerpHook perpHook = new PerpHook{salt: salt}(
            IPoolManager(addrManager),
            _colTokenAddr
        );
        require(
            address(perpHook) == hookAddress,
            "PerpHookScript: hook address mismatch"
        );

        vm.stopBroadcast();
    }
}

// forge script script/PerpHookSepolia.s.sol:PerpHookScript --rpc-url $SEPOLIA_RPC_URL
// forge script script/PerpHookSepolia.s.sol:PerpHookScript --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
