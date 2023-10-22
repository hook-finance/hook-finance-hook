// Author: Rashad Haddad, github @rashadalh
// Description: Chainlink Pricer for the hook-finance

import "../lib/chainlink/AggregatorV3Interface.sol";
import "./IchainlinkPricer.sol";

address constant ETHUSDC_feed = 0x986b5E1e1755e3C2440e960477f25201B0a8bbD4;

contract chainlinkPricer is IChainlinkPricer {
    
    address public feed;
    AggregatorV3Interface internal priceFeed;
    uint8 public decimals;
    constructor(address _feed) {
        feed = _feed;
        priceFeed = AggregatorV3Interface(feed);
        decimals = priceFeed.decimals();
    }

    /**
      @notice Converts the price to 96 decimals to be compatible subbing with uniswap oracle
      @param price The price to convert
    */
    function _convertToX96(uint256 price) external view returns (uint160) {
        return uint160(price * 2**(96  - decimals));
    }

    /// @notice from https://ethereum.stackexchange.com/questions/2910/can-i-square-root-in-solidity
    /// @notice Calculates the square root of x, rounding down.
    /// @dev Uses the Babylonian method https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method.
    /// @param x The uint256 number for which to calculate the square root.
    /// @return result The result as an uint256.
    function sqrt(uint256 x) public pure returns (uint256 result) {
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

    /**
      @notice Gets the latest price from the chainlink oracle but converts it to 96 decimals
    */
    function getLatestPrice() external view returns (uint160) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return this._convertToX96(uint256(price));
    }

    function getPriceSquareRoot() external view returns (uint160) {
        uint160 price = this.getLatestPrice();
        return uint160(sqrt(uint256(price)));
    }
}

