// SPDX-License-Identifier: UNLICENSED

// Interface for the chainlinkPricer contract
// Author: Rashad Haddad, github @rashadalh

interface IChainlinkPricer {
    
    // Events (if any) can be defined here

    // Getter functions
    function feed() external view returns (address);
    function decimals() external view returns (uint8);

    /**
      @notice Converts the price to 96 decimals to be compatible with uniswap oracle
      @param price The price to convert
      @return Converted price in 96 decimals
    */
    function _convertToX96(uint256 price) external view returns (uint160);

    /**
      @notice Compute the square root
      @param x The value to compute the square root of
      @return Square root of the given value
    */
    function sqrt(uint256 x) external pure returns (uint256);

    /**
      @notice Gets the latest price from the chainlink oracle but converts it to 96 decimals
      @return Latest price from Chainlink Oracle in 96 decimals
    */
    function getLatestPrice() external view returns (uint160);

    /**
      @notice Gets the square root of the latest price from the Chainlink Oracle
      @return Square root of the latest price from Chainlink Oracle
    */
    function getPriceSquareRoot() external view returns (uint160);
}