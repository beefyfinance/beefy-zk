// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/// all the functions and events the CLM subgraph is depending on
interface ICLMStrategy {
    // required for all strategies
    event Initialized(uint8);
    event Paused(address);
    event Unpaused(address);
    event TVL(uint256 bal0, uint256 bal1);
    event ChargedFees(uint256 callFeeAmount, uint256 beefyFeeAmount, uint256 strategistFeeAmount);
    function pool() external view returns (address);
    function vault() external view returns (address);
    function price() external view returns (uint256 _price);
    function range() external view returns (uint256 lowerPrice, uint256 upperPrice);
    function balancesOfPool() external view returns (uint256 token0Bal, uint256 token1Bal, uint256 mainAmount0, uint256 mainAmount1, uint256 altAmount0, uint256 altAmount1);
    function lpToken0ToNativePrice() external returns (uint256);
    function lpToken1ToNativePrice() external returns (uint256);
    
    // optional, depends on the strat type
    event Harvest(uint256 fee0, uint256 fee1);
    event ClaimedFees(uint256 feeMain0, uint256 feeMain1, uint256 feeAlt0, uint256 feeAlt1);
    event HarvestRewards(uint256 fees);
    event ClaimedRewards(uint256 fees);
    function output() external view returns (address);
    function outputToNativePrice() external returns (uint256);
}