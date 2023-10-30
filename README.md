# Perp Hook

Proof of concept for a perpetual exchange built on a Uniswap Hook, built for the ETHGlobal online hackathon 2023.

## Authors

Hook by Thomas Redfern

Other ETHGlobal hackathon team members: Rashad Haddad, Tomas Taylor, Ash

## Overview

The hook combines mechanisms of both margin trading and perpetual exchanges to allow users to take leveraged positions.

Regular swappers can interact with the pool, which helps maintain an efficient price.

Leveraged swappers can deposit collateral (USDC), and then make swaps with up to 10x leverage.

Leveraged swappers face two payments, the first is a margin payment of 10% annualized on the size of their position, made to LPs.  The second is a funding payment made between swappers depending on the total long/short exposure of the leveraged positions.

## Mechanism

Rather than staking directly to the pool, LPs send funds to the hook which manages the stakes.  Leveraged swaps are executed via actual trades in the pool.  Liquidity is withdrawn in order to execute the leveraged swap, with the result that any profit from this swap will be captured by the pool, so can be credited to the leveraged swapper, while any loss from the swap will be offset by the leveraged swapper's collateral.

Initial leverage is set to 10x, and leveraged swappers can be liquidated if their position goes beyond 20x leverage.

Positions are prevented from going underwater via the public `liquidateSwapper` function, which allows an liquidator to liquidate a position once it's beyond the 20x leverage point.  Liquidators receive a portion of the leveraged swapper's collateral in exchange for calling this function.


## Usage

Run tests via:
`forge test`

Hook can be deployed on Sepolia by first creating a .env file in the root directory with the following fields:
```
SEPOLIA_RPC_URL=...
PRIVATE_KEY=...
ETHERSCAN_API_KEY=...
```

And then running the following command: 
`forge script script/PerpHookSepolia.s.sol:PerpHookScript --rpc-url $SEPOLIA_RPC_URL --broadcast --verify`


### Disclaimer

This hook is very much a prototype and not production ready.  Among other issues the hook is vulnerable to a flash loan attack where an attacker could borrow funds to swap the price to an extreme value, allowing them to liquidate leveraged swappers at will.  Manipulations related to the funding rate mechanism are also possible, and management of liquidity has flaws.
