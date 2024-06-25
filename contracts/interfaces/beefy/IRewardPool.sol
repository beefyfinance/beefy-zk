// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IRewardPool {
    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward() external;
    function notifyRewardAmount(address token, uint256 reward, uint256 duration) external;
    function earned(address user, address token) external view returns (uint256);
}