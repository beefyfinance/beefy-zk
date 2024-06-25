// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IQuoter {
    function quoteExactInput(bytes memory path, uint amountIn) external returns (uint amountOut);
}