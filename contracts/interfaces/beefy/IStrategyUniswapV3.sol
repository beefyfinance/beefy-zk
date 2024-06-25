// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/// @notice Interface for the Uniswap V3 strategy contract.
interface IStrategyUniswapV3 {

    /// @notice The sqrt price of the pool.
    function sqrtPrice() external view returns (uint160 sqrtPriceX96);
    
    /// @notice The range covered by the strategy.
    function range() external view returns (uint256 lowerPrice, uint256 upperPrice);

    /// @notice Returns the route to swap the first token to the native token for fee harvesting.
    function lpToken0ToNativePath() external view returns (bytes memory);

    /// @notice Returns the route to swap the second token to the native token for fee harvesting.
    function lpToken1ToNativePath() external view returns (bytes memory);
}