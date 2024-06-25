// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20Metadata} from "@openzeppelin-4/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin-4/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin-4/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignedMath} from "@openzeppelin-4/contracts/utils/math/SignedMath.sol";
import {StratFeeManagerInitializable, IFeeConfig} from "../StratFeeManagerInitializable.sol";
import {IVeloPool} from "../../interfaces/velodrome/IVeloPool.sol";
import {IVeloRouter} from "../../interfaces/velodrome/IVeloRouter.sol";
import {LiquidityAmounts} from "../../utils/LiquidityAmounts.sol";
import {TickMath} from "../../utils/TickMath.sol";
import {TickUtils, FullMath} from "../../utils/TickUtils.sol";
import {VeloSwapUtils} from "../../utils/VeloSwapUtils.sol";
import {IBeefyVaultConcLiq} from "../../interfaces/beefy/IBeefyVaultConcLiq.sol";
import {IStrategyConcLiq} from "../../interfaces/beefy/IStrategyConcLiq.sol";
import {IStrategyVelodrome} from "../../interfaces/beefy/IStrategyVelodrome.sol";
import {IStrategyFactory} from "../../interfaces/beefy/IStrategyFactory.sol";
import {INftPositionManager} from "../../interfaces/velodrome/INftPositionManager.sol";
import {ICLGauge} from "../../interfaces/velodrome/ICLGauge.sol";
import {IRewardPool} from "../../interfaces/beefy/IRewardPool.sol";
import {IQuoter} from "../../interfaces/uniswap/IQuoter.sol";

/// @title Beefy Passive Position Manager. Version: Velodrome
/// @author weso, Beefy
/// @notice This is a contract for managing a passive concentrated liquidity position on Velodrome.
contract StrategyPassiveManagerVelodrome is StratFeeManagerInitializable, IStrategyConcLiq, IStrategyVelodrome {
    using SafeERC20 for IERC20Metadata;
    using TickMath for int24;

    /// @notice The precision for pricing.
    uint256 private constant PRECISION = 1e36;
    uint256 private constant SQRT_PRECISION = 1e18;

    /// @notice The max and min ticks univ3 allows.
    int56 private constant MIN_TICK = -887272;
    int56 private constant MAX_TICK = 887272;

    /// @notice The address of the Velodrome pool.
    address public pool;
    /// @notice The address of the quoter.
    address public quoter;
    /// @notice The address of the NFT position manager.
    address public nftManager;
    /// @notice The address of the gauge. 
    address public gauge;
    /// @notice The address of the output. 
    address public output;
    /// @notice The address of the first token in the liquidity pool.
    address public lpToken0;
    /// @notice The address of the second token in the liquidity pool.
    address public lpToken1;
    /// @notice The address of the rewardPool.
    address public rewardPool;

    /// @notice The amount of unharvested output in the strategy.
    uint256 public fees;

    /// @notice The path to swap the output to the native token for fee harvesting.
    bytes public outputToNativePath;
    /// @notice The path to swap the first token to the native token for data pricing.
    bytes public lpToken0ToNativePath;
    /// @notice The path to swap the second token to the native token for data pricing.
    bytes public lpToken1ToNativePath;

    /// @notice The struct to store our tick positioning.
    struct Position {
        uint256 nftId;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice The main position of the strategy.
    /// @dev this will always be a 50/50 position that will be equal to position width * tickSpacing on each side.
    Position public positionMain;

    /// @notice The alternative position of the strategy.
    /// @dev this will always be a single sided (limit order) position that will start closest to current tick and continue to width * tickSpacing.
    /// This will always be in the token that has the most value after we fill our main position. 
    Position public positionAlt;

    /// @notice The width of the position, thats a multiplier for tick spacing to find our range. 
    int24 public positionWidth;

    /// @notice the max tick deviations we will allow for deposits/setTick. 
    int56 public maxTickDeviation;

    /// @notice The twap interval seconds we use for the twap check. 
    uint32 public twapInterval;

    /// @notice Initializes the ticks on first deposit. 
    bool private initTicks;

    // Errors 
    error NotAuthorized();
    error NotPool();
    error InvalidEntry();
    error NotVault();
    error InvalidInput();
    error InvalidOutput();
    error NotCalm();
    error TooMuchSlippage();

    // Events
    event TVL(uint256 bal0, uint256 bal1);
    event Harvest(uint256 fees);
    event SetPositionWidth(int24 oldWidth, int24 width);
    event SetDeviation(int56 maxTickDeviation);
    event SetTwapInterval(uint32 oldInterval, uint32 interval);
    event SetOutputToNativePath(bytes path);
    event SetRewardPool(address rewardPool);
    event ChargedFees(uint256 callFeeAmount, uint256 beefyFeeAmount, uint256 strategistFeeAmount);
    event ClaimedFees(uint256 fees);
 
     /// @notice Modifier to only allow deposit/setTick actions when current price is within a certain deviation of twap.
    modifier onlyCalmPeriods() {
        _onlyCalmPeriods();
        _;
    }

    /// @notice function to only allow deposit/setTick actions when current price is within a certain deviation of twap.
    function _onlyCalmPeriods() private view {
        if (!isCalm()) revert NotCalm();
    }

    modifier onlyRebalancers() {
        if (!IStrategyFactory(factory).rebalancers(msg.sender)) revert NotAuthorized();
        _;
    }

    /// @notice function to only allow deposit/setTick actions when current price is within a certain deviation of twap.
    function isCalm() public view returns (bool) {
        int24 tick = currentTick();
        int56 twapTick = twap();

        int56 minCalmTick = int56(SignedMath.max(twapTick - maxTickDeviation, MIN_TICK));
        int56 maxCalmTick = int56(SignedMath.min(twapTick + maxTickDeviation, MAX_TICK));

        // Calculate if tick move more than allowed from twap and revert if it did. 
        if(minCalmTick > tick  || maxCalmTick < tick) return false;
        else return true;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the strategy and the inherited strat fee manager.
     * @dev Make sure cardinality is set appropriately for the twap.
     * @param _pool The underlying Velodrome pool.
     * @param _nftManager The NFT position manager.
     * @param _output The output token for the strategy.
     * @param _positionWidth The multiplier for tick spacing to find our range.
     * @param _paths The bytes paths for swapping (Output To Native, Token0 to Native, Token1 to Native).
     * @param _commonAddresses The common addresses needed for the strat fee manager.
     */
    function initialize (
        address _pool,
        address _quoter,
        address _nftManager,
        address _gauge,
        address _rewardPool,
        address _output, 
        int24 _positionWidth,
        bytes[] calldata _paths,
        CommonAddresses calldata _commonAddresses
    ) external initializer {
        __StratFeeManager_init(_commonAddresses);

        pool = _pool;
        quoter = _quoter;
        output = _output;
        nftManager = _nftManager;
        gauge = _gauge;
        rewardPool = _rewardPool;   
        lpToken0 = IVeloPool(_pool).token0();
        lpToken1 = IVeloPool(_pool).token1();

        // Our width multiplier. The tick distance of each side will be width * tickSpacing.
        positionWidth = _positionWidth;

        outputToNativePath = _paths[0];
        lpToken0ToNativePath = _paths[1];
        lpToken1ToNativePath = _paths[2];
    
        // Set the twap interval to 120 seconds.
        twapInterval = 120;

        _giveAllowances();
    
    }

    /// @notice Only allows the vault to call a function.
    function _onlyVault () private view {
        if (msg.sender != vault) revert NotVault();
    }

    /// @notice Called during deposit and withdraw to remove liquidity and harvest fees for accounting purposes.
    function beforeAction() external {
        _onlyVault();
        _claimEarnings();
        _removeLiquidity();
    }

    /// @notice Called during deposit to add all liquidity back to their positions. 
    function deposit() external onlyCalmPeriods {
        _onlyVault();

        if (!initTicks) {
            _setTicks();
            initTicks = true;
        }

        // Add all liquidity
        _addLiquidity();
        
        (uint256 bal0, uint256 bal1) = balances();

        // TVL Balances after deposit
        emit TVL(bal0, bal1);
    }

    /**
     * @notice Withdraws the specified amount of tokens from the strategy as calculated by the vault.
     * @param _amount0 The amount of token0 to withdraw.
     * @param _amount1 The amount of token1 to withdraw.
     */
    function withdraw(uint256 _amount0, uint256 _amount1) external {
        _onlyVault();

        // Liquidity has already been removed in beforeAction() so this is just a simple withdraw.
        if (_amount0 > 0) IERC20Metadata(lpToken0).safeTransfer(vault, _amount0);
        if (_amount1 > 0) IERC20Metadata(lpToken1).safeTransfer(vault, _amount1);

        // After we take what is needed we add it all back to our positions. 
        if (!_isPaused()) _addLiquidity();

        (uint256 bal0, uint256 bal1) = balances();

        // TVL Balances after withdraw
        emit TVL(bal0, bal1);
    }

    /// @notice Adds liquidity to the main and alternative positions called on deposit, harvest and withdraw.
    function _addLiquidity() private {
        _whenStrategyNotPaused();

        (uint256 bal0, uint256 bal1) = balancesOfThis();

        int24 mainLower = positionMain.tickLower;
        int24 mainUpper = positionMain.tickUpper;
        int24 altLower = positionAlt.tickLower;
        int24 altUpper = positionAlt.tickUpper;
        uint160 sqrtprice = sqrtPrice();

        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;

        // Then we fetch how much liquidity we get for adding at the main position ticks with our token balances. 
        {
            uint160 mainLowerSqrt = TickMath.getSqrtRatioAtTick(mainLower);
            uint160 mainUpperSqrt = TickMath.getSqrtRatioAtTick(mainUpper);

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtprice,
                mainLowerSqrt,
                mainUpperSqrt,
                bal0,
                bal1
            );

            (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtprice,
                mainLowerSqrt,
                mainUpperSqrt,
                liquidity
            );
        }

        // Mint or add liquidity to the position. 
        if (liquidity > 0 && !(amount0 == 0 || amount1 == 0)) {
            _mintPosition(mainLower, mainUpper, amount0, amount1, true);
            (bal0, bal1) = balancesOfThis();
        }

        // Fetch how much liquidity we get for adding at the alternative position ticks with our token balances.
        {
            uint160 altLowerSqrt = TickMath.getSqrtRatioAtTick(altLower);
            uint160 altUpperSqrt = TickMath.getSqrtRatioAtTick(altUpper);

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtprice,
                altLowerSqrt,
                altUpperSqrt,
                bal0,
                bal1
            );

            (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtprice,
                altLowerSqrt,
                altUpperSqrt,
                liquidity
            );
        }

        // Mint or add liquidity to the position.
        if (liquidity > 0 && (amount0 > 0 || amount1 > 0)) {
            _mintPosition(altLower, altUpper, amount0, amount1, false);
        }

        if (positionMain.nftId != 0) ICLGauge(gauge).deposit(positionMain.nftId);
        if (positionAlt.nftId != 0) ICLGauge(gauge).deposit(positionAlt.nftId);
    }

    /// @notice Mints a new position for the main or alternative position.
    function _mintPosition(int24 _tickLower, int24 _tickUpper, uint256 _amount0, uint256 _amount1, bool _mainPosition) private {
        INftPositionManager.MintParams memory mintParams = INftPositionManager.MintParams({
            token0: lpToken0,
            token1: lpToken1,
            tickSpacing: _tickDistance(),
            tickLower: _tickLower,
            tickUpper: _tickUpper,
            amount0Desired: _amount0,
            amount1Desired: _amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp,
            sqrtPriceX96: 0
        });

        (uint256 nftId,,,) = INftPositionManager(nftManager).mint(mintParams);

        if (_mainPosition) positionMain.nftId = nftId;
        else positionAlt.nftId = nftId;

        IERC721(nftManager).approve(gauge, nftId);
    }

    /// @notice Removes liquidity from the main and alternative positions, called on deposit, withdraw and harvest.
    function _removeLiquidity() private {
        uint128 liquidity;
        uint128 liquidityAlt;
        if (positionMain.nftId != 0) {
            (,,,,,,,liquidity,,,,) = INftPositionManager(nftManager).positions(positionMain.nftId);
            ICLGauge(gauge).withdraw(positionMain.nftId);
        } 

        if (positionAlt.nftId != 0) {
            (,,,,,,,liquidityAlt,,,,) = INftPositionManager(nftManager).positions(positionAlt.nftId);
            ICLGauge(gauge).withdraw(positionAlt.nftId);
        }

        // init our params
        INftPositionManager.DecreaseLiquidityParams memory decreaseLiquidityParams;
        INftPositionManager.CollectParams memory collectParams;

        // If we have liquidity in the positions we remove it and collect our tokens.
        if (liquidity > 0) {
            decreaseLiquidityParams = INftPositionManager.DecreaseLiquidityParams({
                tokenId: positionMain.nftId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            });

            collectParams = INftPositionManager.CollectParams({
                tokenId: positionMain.nftId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });

            INftPositionManager(nftManager).decreaseLiquidity(decreaseLiquidityParams);
            INftPositionManager(nftManager).collect(collectParams);
            INftPositionManager(nftManager).burn(positionMain.nftId);
            positionMain.nftId = 0;
            
        }

        if (liquidityAlt > 0) {
            decreaseLiquidityParams = INftPositionManager.DecreaseLiquidityParams({
                tokenId: positionAlt.nftId,
                liquidity: liquidityAlt,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            });

            collectParams = INftPositionManager.CollectParams({
                tokenId: positionAlt.nftId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });

            INftPositionManager(nftManager).decreaseLiquidity(decreaseLiquidityParams);
            INftPositionManager(nftManager).collect(collectParams);
            INftPositionManager(nftManager).burn(positionAlt.nftId);
            positionAlt.nftId = 0;
            
        }
    }

    /// @notice Function called to rebalance the position 
    function moveTicks() external onlyCalmPeriods onlyRebalancers {
        _claimEarnings();
        _removeLiquidity();
        _setTicks();
        _addLiquidity();

        (uint256 bal0, uint256 bal1) = balances();
        emit TVL(bal0, bal1);
    }

    /// @notice Harvest call to claim rewards from gauge then charge fees for Beefy and notify rewards.
    /// @param _callFeeRecipient The address to send the call fee to.
    function harvest(address _callFeeRecipient) external {
        _harvest(_callFeeRecipient);
    }

    /// @notice Harvest call to claim rewards from gauge then charge fees for Beefy and notify rewards.
    /// @dev Call fee goes to the tx.origin. 
    function harvest() external {
        _harvest(tx.origin);
    }

    /// @notice Internal function to claim rewards from gauge then charge fees for Beefy and notify rewards
    function _harvest (address _callFeeRecipient) private {
        // Claim rewards from gauge
        _claimEarnings();

        // Charge fees for Beefy and send them to the appropriate addresses, charge fees to accrued state fee amounts.
        (uint256 feeLeft) = _chargeFees(_callFeeRecipient, fees);

        // Reset state fees to 0. 
        fees = 0;

        // Notify rewards with our velo. 
        IRewardPool(rewardPool).notifyRewardAmount(output, feeLeft, 1 days);

        // Log the last time we claimed fees. 
        lastHarvest = block.timestamp;

        // Log the fees post Beefy fees.
        emit Harvest(feeLeft);
    }

    /// @notice Internal function to claim rewards from the gauge and collect them.
    function _claimEarnings() private {
        // Claim rewards
        uint256 feeBefore = _balanceOfOutput();

        if (positionMain.nftId != 0) ICLGauge(gauge).getReward(positionMain.nftId);
        if (positionAlt.nftId != 0) ICLGauge(gauge).getReward(positionAlt.nftId);

        uint256 claimed = _balanceOfOutput() - feeBefore;
        fees = fees + claimed;

        emit ClaimedFees(claimed);
    }

    /**
     * @notice Internal function to charge fees for Beefy and send them to the appropriate addresses.
     * @param _callFeeRecipient The address to send the call fee to.
     * @param _amount The amount of output to charge fees on.
     * @return _amountLeft The amount of token0 left after fees.
     */
    function _chargeFees(address _callFeeRecipient, uint256 _amount) private returns (uint256 _amountLeft){
        /// Fetch our fee percentage amounts from the fee config.
        IFeeConfig.FeeCategory memory fee = getFees();

        /// We calculate how much to swap and then swap both tokens to native and charge fees.
        uint256 nativeEarned;
        if (_amount > 0) {
            // Calculate amount of token 0 to swap for fees.
            uint256 amountToSwap = _amount * fee.total / DIVISOR;
            _amountLeft = _amount - amountToSwap;
            
            // If token0 is not native, swap to native the fee amount.
            uint256 out;
            uint256 nativeBefore = _balanceOfNative();
            if (output != native) {
                VeloSwapUtils.swap(unirouter, outputToNativePath, amountToSwap, true);
                out = _balanceOfNative() - nativeBefore;
            }
            
            // Add the native earned to the total of native we earned for beefy fees, handle if token0 is native.
            if (output == native)  nativeEarned += amountToSwap;
            else nativeEarned += out;
        }

        // Distribute the native earned to the appropriate addresses.
        uint256 callFeeAmount = nativeEarned * fee.call / DIVISOR;
        IERC20Metadata(native).safeTransfer(_callFeeRecipient, callFeeAmount);

        uint256 strategistFeeAmount = nativeEarned * fee.strategist / DIVISOR;
        IERC20Metadata(native).safeTransfer(strategist, strategistFeeAmount);

        uint256 beefyFeeAmount = nativeEarned - callFeeAmount - strategistFeeAmount;
        IERC20Metadata(native).safeTransfer(beefyFeeRecipient(), beefyFeeAmount);

        emit ChargedFees(callFeeAmount, beefyFeeAmount, strategistFeeAmount);
    }

    /** 
     * @notice Returns total token balances in the strategy.
     * @return token0Bal The amount of token0 in the strategy.
     * @return token1Bal The amount of token1 in the strategy.
    */
    function balances() public view returns (uint256 token0Bal, uint256 token1Bal) {
        (uint256 thisBal0, uint256 thisBal1) = balancesOfThis();
        (uint256 poolBal0, uint256 poolBal1,,,,) = balancesOfPool();

        uint256 total0 = thisBal0 + poolBal0;
        uint256 total1 = thisBal1 + poolBal1;

        // For token0 and token1 we return balance of this contract + balance of positions - feesUnharvested.
        return (total0, total1);
    }

    /**
     * @notice Returns total tokens sitting in the strategy.
     * @return token0Bal The amount of token0 in the strategy.
     * @return token1Bal The amount of token1 in the strategy.
    */
    function balancesOfThis() public view returns (uint256 token0Bal, uint256 token1Bal) {
        return (IERC20Metadata(lpToken0).balanceOf(address(this)), IERC20Metadata(lpToken1).balanceOf(address(this)));
    }

    /** 
     * @notice Returns total tokens in pool positions (is a calculation which means it could be a little off by a few wei). 
     * @return token0Bal The amount of token0 in the pool.
     * @return token1Bal The amount of token1 in the pool.
     * @return mainAmount0 The amount of token0 in the main position.
     * @return mainAmount1 The amount of token1 in the main position.
     * @return altAmount0 The amount of token0 in the alt position.
     * @return altAmount1 The amount of token1 in the alt position.
    */
    function balancesOfPool() public view returns (uint256 token0Bal, uint256 token1Bal, uint256 mainAmount0, uint256 mainAmount1, uint256 altAmount0, uint256 altAmount1) {
        uint160 sqrtPriceX96 = sqrtPrice();

        uint128 liquidity; 
        uint128 altLiquidity;
        uint256 owed0;
        uint256 owed1;
        uint256 altOwed0;
        uint256 altOwed1;
        if (positionMain.nftId != 0) (,,,,,,,liquidity,,,owed0, owed1) = INftPositionManager(nftManager).positions(positionMain.nftId);
        if (positionAlt.nftId != 0) (,,,,,,, altLiquidity,,,altOwed0, altOwed1) = INftPositionManager(nftManager).positions(positionAlt.nftId);

        (mainAmount0, mainAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(positionMain.tickLower),
            TickMath.getSqrtRatioAtTick(positionMain.tickUpper),
            liquidity
        );

        (altAmount0, altAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,   
            TickMath.getSqrtRatioAtTick(positionAlt.tickLower),
            TickMath.getSqrtRatioAtTick(positionAlt.tickUpper),
            altLiquidity
        );

        mainAmount0 += owed0;
        mainAmount1 += owed1;

        altAmount0 += altOwed0;
        altAmount1 += altOwed1;
        
        token0Bal = mainAmount0 + altAmount0;
        token1Bal = mainAmount1 + altAmount1;
    }

    /// @notice Returns the balance of the output in the strategy.
    function _balanceOfOutput() private view returns (uint256) {
        return IERC20Metadata(output).balanceOf(address(this));
    }

    /// @notice Returns the balance of native in the strategy.
    function _balanceOfNative() private view returns (uint256) {
        return IERC20Metadata(native).balanceOf(address(this));
    }
    
    /**
     * @notice Returns the range of the pool, will always be the main position.
     * @return lowerPrice The lower price of the position.
     * @return upperPrice The upper price of the position.
    */
    function range() external view returns (uint256 lowerPrice, uint256 upperPrice) {
        // the main position is always covering the alt range
        lowerPrice = FullMath.mulDiv(uint256(TickMath.getSqrtRatioAtTick(positionMain.tickLower)), SQRT_PRECISION, (2 ** 96)) ** 2;
        upperPrice = FullMath.mulDiv(uint256(TickMath.getSqrtRatioAtTick(positionMain.tickUpper)), SQRT_PRECISION, (2 ** 96)) ** 2;
    }

    /**
     * @notice The current tick of the pool.
     * @return tick The current tick of the pool.
    */
    function currentTick() public view returns (int24 tick) {
        (,tick,,,,) = IVeloPool(pool).slot0();
    }

    /**
     * @notice The current price of the pool.
     * @return _price The current price of the pool.
    */
    function price() public view returns (uint256 _price) {
        uint160 sqrtPriceX96 = sqrtPrice();
        _price = FullMath.mulDiv(uint256(sqrtPriceX96), SQRT_PRECISION, (2 ** 96)) ** 2;
    }

    /**
     * @notice The sqrt price of the pool.
     * @return sqrtPriceX96 The sqrt price of the pool.
    */
    function sqrtPrice() public view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,,,) = IVeloPool(pool).slot0();
    }

    /**
     * @notice The swap fee variable is the fee charged for swaps in the underlying pool in 18 decimals
     * @return fee The swap fee of the underlying pool
    */
    function swapFee() external override view returns (uint256 fee) {
        fee = uint256(IVeloPool(pool).fee()) * SQRT_PRECISION / 1e6;
    }

    /** 
     * @notice The tick distance of the pool.
     * @return int24 The tick distance/spacing of the pool.
    */
    function _tickDistance() private view returns (int24) {
        return IVeloPool(pool).tickSpacing();
    }

    /// @notice Sets the tick positions for the main and alternative positions.
    function _setTicks() private onlyCalmPeriods {
        int24 tick = currentTick();
        int24 distance = _tickDistance();
        int24 width = positionWidth * distance;

        _setMainTick(tick, distance, width);
        _setAltTick(tick, distance, width);

        lastPositionAdjustment = block.timestamp;
    }

    /// @notice Sets the main tick position.
    function _setMainTick(int24 tick, int24 distance, int24 width) private {
        (positionMain.tickLower, positionMain.tickUpper) = TickUtils.baseTicks(
            tick,
            width,
            distance
        );
    }

    /// @notice Sets the alternative tick position.
    function _setAltTick(int24 tick, int24 distance, int24 width) private {
        (uint256 bal0, uint256 bal1) = balancesOfThis();

        // We calculate how much token0 we have in the price of token1. 
        uint256 amount0;

        if (bal0 > 0) {
            amount0 = bal0 * price() / PRECISION;
        }

        // We set the alternative position based on the token that has the most value available. 
        if (amount0 < bal1) {
            (positionAlt.tickLower, ) = TickUtils.baseTicks(
                tick,
                width,
                distance
            );

            (positionAlt.tickUpper, ) = TickUtils.baseTicks(
                tick,
                distance,
                distance
            ); 
        } else if (bal1 < amount0) {
            (, positionAlt.tickLower) = TickUtils.baseTicks(
                tick,
                distance,
                distance
            );

            (, positionAlt.tickUpper) = TickUtils.baseTicks(
                tick,
                width,
                distance
            ); 
        }
    }

    /* Removing for code size
    function setOutputToNativePath(bytes calldata _path) public onlyOwner {
        if (_path.length > 0) {
            (address[] memory _route) = VeloSwapUtils.pathToRoute(_path);
            if (_route[0] != output) revert InvalidInput();
            if (_route[_route.length - 1] != native) revert InvalidOutput();
            outputToNativePath = _path;
            emit SetOutputToNativePath(_path);
        }
    }
    */

    /**
     * @notice Sets the deviation from the twap we will allow on adding liquidity.
     * @param _maxDeviation The max deviation from twap we will allow.
    */
    function setDeviation(int56 _maxDeviation) external onlyOwner {
        emit SetDeviation(_maxDeviation);

        // Require the deviation to be less than or equal to 4 times the tick spacing.
        if (_maxDeviation >= _tickDistance() * 4) revert InvalidInput();

        maxTickDeviation = _maxDeviation;
    }

    /**
     * @notice Returns the route to swap the output token to the native token for fee harvesting.
     * @return address[] The route to swap the output to the native token.
    */
    function outputToNative() public view returns (address[] memory) {
        if (outputToNativePath.length == 0) return new address[](0);
        return VeloSwapUtils.pathToRoute(outputToNativePath);
    }

    /// @notice Returns the price of the first token in native token.
    function lpToken0ToNativePrice() public returns (uint256) {
        uint amount = 10**IERC20Metadata(lpToken0).decimals() / 10;
        if (lpToken0 == native) return amount;
        return IQuoter(quoter).quoteExactInput(lpToken0ToNativePath, amount);
    }

    /// @notice Returns the price of the second token in native token.
    function lpToken1ToNativePrice() public returns (uint256) {
        uint amount = 10**IERC20Metadata(lpToken1).decimals() / 10;
        if (lpToken1 == native) return amount;
        return IQuoter(quoter).quoteExactInput(lpToken1ToNativePath, amount);
    }

    /** 
     * @notice The twap of the last minute from the pool.
     * @return twapTick The twap of the last minute from the pool.
    */
    function twap() public view returns (int56 twapTick) {
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = uint32(twapInterval);
        secondsAgo[1] = 0;

        (int56[] memory tickCuml,) = IVeloPool(pool).observe(secondsAgo);
        twapTick = (tickCuml[1] - tickCuml[0]) / int32(twapInterval);
    }

    function setTwapInterval(uint32 _interval) external onlyOwner {
        emit SetTwapInterval(twapInterval, _interval);

        // Require the interval to be greater than 60 seconds.
        if (_interval < 60) revert InvalidInput();

        twapInterval = _interval;
    }

    /** 
     * @notice Sets our position width and readjusts our positions.
     * @param _width The new width multiplier of the position.
    */
    function setPositionWidth(int24 _width) external onlyOwner {
        emit SetPositionWidth(positionWidth, _width);
        _claimEarnings();
        _removeLiquidity();
        positionWidth = _width;
        _setTicks();
        _addLiquidity();
    }

    /**
     * @notice Sets the reward pool address.
     * @param _rewardPool The new reward pool address.
     */
    function setRewardPool(address _rewardPool) external onlyOwner {
        rewardPool = _rewardPool;
        emit SetRewardPool(_rewardPool);
    }

    /**
     * @notice set the unirouter address
     * @param _unirouter The new unirouter address
     */
    function setUnirouter(address _unirouter) external override onlyOwner {
        _removeAllowances();
        unirouter = _unirouter;
        _giveAllowances();
        emit SetUnirouter(_unirouter);
    }

    /// @notice Retire the strategy and return all the dust to the fee recipient.
    function retireVault() external onlyOwner {
        if (IBeefyVaultConcLiq(vault).totalSupply() != 10**3) revert NotAuthorized();
        panic(0,0);
        address feeRecipient = beefyFeeRecipient();
        IERC20Metadata(lpToken0).safeTransfer(feeRecipient, IERC20Metadata(lpToken0).balanceOf(address(this)));
        IERC20Metadata(lpToken1).safeTransfer(feeRecipient, IERC20Metadata(lpToken1).balanceOf(address(this)));
        _transferOwnership(address(0));
    }

    /**  
     * @notice Remove Liquidity and Allowances, then pause deposits.
     * @param _minAmount0 The minimum amount of token0 in the strategy after panic.
     * @param _minAmount1 The minimum amount of token1 in the strategy after panic.
     */
    function panic(uint256 _minAmount0, uint256 _minAmount1) public onlyManager {
        _claimEarnings();
        _removeLiquidity();
        _removeAllowances();
        _pause();

        (uint256 bal0, uint256 bal1) = balances();
        if (bal0 < _minAmount0 || bal1 < _minAmount1) revert TooMuchSlippage();
    }

    /// @notice Unpause deposits, give allowances and add liquidity.
    function unpause() external onlyManager {
        if (owner() == address(0)) revert NotAuthorized();
        _giveAllowances();
        _unpause();
        _setTicks();
        _addLiquidity();
    }

    /// @notice gives swap permisions for the tokens to the unirouter.
    function _giveAllowances() private {
        IERC20Metadata(output).forceApprove(unirouter, type(uint256).max);
        IERC20Metadata(output).forceApprove(rewardPool, type(uint256).max);
        IERC20Metadata(lpToken0).forceApprove(nftManager, type(uint256).max);
        IERC20Metadata(lpToken1).forceApprove(nftManager, type(uint256).max);
    }

    /// @notice removes swap permisions for the tokens from the unirouter.
    function _removeAllowances() private {
        IERC20Metadata(output).forceApprove(unirouter, 0);
        IERC20Metadata(output).forceApprove(rewardPool, 0);
        IERC20Metadata(lpToken0).forceApprove(nftManager, 0);
        IERC20Metadata(lpToken1).forceApprove(nftManager, 0);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}