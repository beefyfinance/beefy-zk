// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/// @notice Interface for the Uniswap V3 strategy contract.
interface IStrategyVelodrome {
    /// @notice The sqrt price of the pool.
    function sqrtPrice() external view returns (uint160 sqrtPriceX96);
    
    /// @notice The range covered by the strategy.
    function range() external view returns (uint256 lowerPrice, uint256 upperPrice);
}