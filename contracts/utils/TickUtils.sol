// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Path.sol";
import "./TickMath.sol";
import "./LiquidityAmounts.sol";

library TickUtils {
    using Path for bytes;
    using TickMath for int24;
    
    function floor(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    /// @dev Calc base ticks depending on base threshold and tickspacing
    function baseTicks(
        int24 currentTick,
        int24 baseThreshold,
        int24 tickSpacing
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        int24 tickFloor = floor(currentTick, tickSpacing);

        tickLower = tickFloor - baseThreshold;
        tickUpper = tickFloor + baseThreshold;
    }

    function quoteAddLiquidity(int24 _currentTick, int24 _lowerTick, int24 _upperTick, uint256 _amt0, uint256 _amt1) internal pure returns(uint256 _actualAmount0, uint256 _actualAmount1, uint256 _liquidity) {
        // Grab the amount of liquidity for our token balances
        _liquidity = LiquidityAmounts.getLiquidityForAmounts(
                _currentTick.getSqrtRatioAtTick(),
                _lowerTick.getSqrtRatioAtTick(),
                _upperTick.getSqrtRatioAtTick(),
                _amt0,
                _amt1
        );
        
        ( _actualAmount0,  _actualAmount1) = LiquidityAmounts.getAmountsForLiquidity(
                _currentTick.getSqrtRatioAtTick(),
                _lowerTick.getSqrtRatioAtTick(),
                _upperTick.getSqrtRatioAtTick(),
                uint128(_liquidity)
        );
    }

    function getQuoteAtTick(
        int24 tick,
        uint128 baseAmount,
        address baseToken,
        address quoteToken
    ) internal pure returns (uint256 quoteAmount) {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);

        // Calculate quoteAmount with better precision if it doesn't overflow when multiplied by itself
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    // Convert encoded path to token route
    function pathToRoute(bytes memory _path) internal pure returns (address[] memory, uint24[] memory) {
        uint256 numPools = _path.numPools();
        address[] memory route = new address[](numPools + 1);
        uint24[] memory fees = new uint24[](numPools);
        for (uint256 i; i < numPools; i++) {
            (address tokenA, address tokenB, uint24 fee) = _path.decodeFirstPool();
            route[i] = tokenA;
            route[i + 1] = tokenB;
            fees[i] = fee;
            _path = _path.skipToken();
        }
        return (route, fees);
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