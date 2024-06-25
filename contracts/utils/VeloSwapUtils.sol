// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import './Path.sol';
import "../interfaces/velodrome/IVeloRouter.sol";

library VeloSwapUtils {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    using Path for bytes;

    bytes1 constant V3_SWAP_EXACT_IN = 0x00;
    bytes1 constant V2_SWAP_EXACT_IN = 0x08;

    // Swap along an encoded path using known amountIn
    function swap(
        address _router,
        bytes memory _path,
        uint256 _amountIn,
        bool _isV3
    ) internal {
        if (_isV3) {
            bytes memory input = abi.encode(address(this), _amountIn, 0, _path, true);
            bytes[] memory inputs = new bytes[](1);
            inputs[0] = input;
            IVeloRouter(_router).execute(abi.encodePacked(V3_SWAP_EXACT_IN), inputs, block.timestamp);
        } else {
            address[] memory route = pathToRoute(_path);
            bytes memory input = abi.encode(address(this), _amountIn, 0, route, true);
            bytes[] memory inputs = new bytes[](1);
            inputs[0] = input;

            IVeloRouter(_router).execute(abi.encodePacked(V2_SWAP_EXACT_IN), inputs, block.timestamp);
        }
    }

    // Swap along an encoded path using known amountIn
    function swap(
        address _router,
        IVeloRouter.Route[] memory _route,
        uint256 _amountIn
    ) internal {
        bytes memory input = abi.encode(address(this), _amountIn, 0, _route, true);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = input;

        IVeloRouter(_router).execute(abi.encodePacked(V2_SWAP_EXACT_IN), inputs, block.timestamp);
    }

    // Swap along an encoded path using known amountIn
    function swap(
        address _who,
        address _router,
        bytes memory _path,
        uint256 _amountIn,
        bool _isV3
    ) internal {
        if (_isV3) {
            bytes memory input = abi.encode(_who, _amountIn, 0, _path, true);
            bytes[] memory inputs = new bytes[](1);
            inputs[0] = input;
            IVeloRouter(_router).execute(abi.encodePacked(V3_SWAP_EXACT_IN), inputs, block.timestamp);
        } else {
            address[] memory route = pathToRoute(_path);
            bytes memory input = abi.encode(_who, _amountIn, 0, route, true);
            bytes[] memory inputs = new bytes[](1);
            inputs[0] = input;

            IVeloRouter(_router).execute(abi.encodePacked(V2_SWAP_EXACT_IN), inputs, block.timestamp);
        }
    }

    // Convert encoded path to token route
    function pathToRoute(bytes memory _path) internal pure returns (address[] memory) {
        uint256 numPools = _path.numPools();
        address[] memory route = new address[](numPools + 1);
        for (uint256 i; i < numPools; i++) {
            (address tokenA, address tokenB,) = _path.decodeFirstPool();
            route[i] = tokenA;
            route[i + 1] = tokenB;
            _path = _path.skipToken();
        }
        return route;
    }

    // Convert token route to encoded path
    // uint24 type for fees so path is packed tightly
    function routeToPath(
        address[] memory _route,
        uint24[] memory _fee
    ) internal pure returns (bytes memory path) {
        path = abi.encodePacked(_route[0]);
        uint256 feeLength = _fee.length;
        for (uint256 i = 0; i < feeLength; i++) {
            path = abi.encodePacked(path, _fee[i], _route[i+1]);
        }
    }
}
