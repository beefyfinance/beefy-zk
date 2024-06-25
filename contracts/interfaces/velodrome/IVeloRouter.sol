// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IVeloRouter {
        struct Route {
            address from;
            address to;
            bool stable;
            address factory;
        }
        
        function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external;
}