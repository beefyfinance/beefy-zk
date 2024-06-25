// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import {IERC20Metadata} from "@openzeppelin-4/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin-4/contracts/token/ERC20/utils/SafeERC20.sol";
import {StratFeeManagerInitializable, IFeeConfig} from "../StratFeeManagerInitializable.sol";
import {IRewardPool} from "../../interfaces/beefy/IRewardPool.sol";
import {IBeefyVaultConcLiq} from "../../interfaces/beefy/IBeefyVaultConcLiq.sol";
import {IStrategyConcLiq} from "../../interfaces/beefy/IStrategyConcLiq.sol";
import {IBeefySwapper} from "../../interfaces/beefy/IBeefySwapper.sol";
import {IStrategyFactory} from "../../interfaces/beefy/IStrategyFactory.sol";

/// @title Beefy Reward Pool Strategy. Version: Beefy Reward Pool
/// @author kexley, Beefy
/// @notice This contract compounds rewards for a Beefy CLM.
contract StrategyRewardPool is StratFeeManagerInitializable {
    using SafeERC20 for IERC20Metadata;

    /// @notice clm token address
    address public want;

    /// @notice token0
    address public token0;

    /// @notice token1
    address public token1;

    /// @notice Reward token array
    address[] public rewards;

    /// @dev Location of a reward in the token array
    mapping(address => uint256) index;

    /// @notice Reward pool for clm rewards
    address public rewardPool;

    /// @notice Whether to harvest on deposit
    bool public harvestOnDeposit;
    
    /// @notice Total profit locked on the strategy
    uint256 public totalLocked;

    /// @notice Length of time in seconds to linearly unlock the profit from a harvest
    uint256 public duration;

    /// @notice Allowed slippage when adding liquidity
    uint256 public slippage;

    /// @dev Underlying LP is volatile
    error NotCalm();
    /// @dev Reward entered is a protected token
    error RewardNotAllowed(address reward);
    /// @dev Reward is already in the array
    error RewardAlreadySet(address reward);
    /// @dev Reward is not found in the array
    error RewardNotFound(address reward);
    /// @dev Set slippage is out of bounds
    error SlippageOutOfBounds(uint256 slippage);

    /// @notice Strategy has been harvested
    /// @param harvester Caller of the harvest
    /// @param wantHarvested Amount of want harvested in this tx
    /// @param tvl Total amount of deposits at the time of harvest
    event StratHarvest(address indexed harvester, uint256 wantHarvested, uint256 tvl);
    /// @notice Want tokens have been deposited into the underlying platform
    /// @param tvl Total amount of deposits at the time of deposit 
    event Deposit(uint256 tvl);
    /// @notice Want tokens have been withdrawn by a user
    /// @param tvl Total amount of deposits at the time of withdrawal
    event Withdraw(uint256 tvl);
    /// @notice Fees were charged
    /// @param callFees Amount of native sent to the caller as a harvest reward
    /// @param beefyFees Amount of native sent to the beefy fee recipient
    /// @param strategistFees Amount of native sent to the strategist
    event ChargedFees(uint256 callFees, uint256 beefyFees, uint256 strategistFees);
    /// @notice Duration of the locked profit degradation has been set
    /// @param duration Duration of the locked profit degradation
    event SetDuration(uint256 duration);
    /// @notice A new reward has been added to the array
    /// @param reward New reward
    event SetReward(address reward);
    /// @notice A reward has been removed from the array
    /// @param reward Reward that has been removed
    event RemoveReward(address reward);
    /// @notice Set the slippage to a new value
    /// @param slippage Slippage when adding liquidity
    event SetSlippage(uint256 slippage);

    /// @notice Initialize the contract, callable only once
    /// @param _want clm address
    /// @param _rewardPool Reward pool address
    /// @param _commonAddresses The typical addresses required by a strategy (see StratManager)
    function initialize(
        address _want,
        address _rewardPool,
        CommonAddresses calldata _commonAddresses
    ) external initializer {
        __StratFeeManager_init(_commonAddresses);
        want = _want;
        native = IStrategyFactory(_commonAddresses.factory).native();
        rewardPool = _rewardPool;
        duration = 3 days;
        slippage = 0.98 ether;

        (token0, token1) = IBeefyVaultConcLiq(want).wants();

        harvestOnDeposit = true;

        _giveAllowances();
    }

    /// @notice Deposit all available want on this contract into the underlying platform
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20Metadata(want).balanceOf(address(this));

        if (wantBal > 0) {
            IRewardPool(rewardPool).stake(wantBal);
            emit Deposit(balanceOf());
        }
    }

    /// @notice Withdraw some amount of want back to the vault
    /// @param _amount Some amount to withdraw back to vault
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20Metadata(want).balanceOf(address(this));

        if (wantBal < _amount) {
            IRewardPool(rewardPool).withdraw(_amount - wantBal);
            wantBal = IERC20Metadata(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        IERC20Metadata(want).safeTransfer(vault, wantBal);
        emit Withdraw(balanceOf());
    }

    /// @notice Hook called by the vault before shares are calculated on a deposit
    function beforeDeposit() external {
        if (harvestOnDeposit) {
            require(msg.sender == vault, "!vault");
            _harvest(tx.origin);
        }
    }

    /// @notice Harvest rewards and collect a call fee reward
    function harvest() external {
        _harvest(tx.origin);
    }

    /// @notice Harvest rewards and send the call fee reward to a specified recipient
    /// @param _callFeeRecipient Recipient of the call fee reward
    function harvest(address _callFeeRecipient) external {
        _harvest(_callFeeRecipient);
    }

    /// @dev Harvest rewards, charge fees and compound back into more want
    /// @param _callFeeRecipient Recipient of the call fee reward 
    function _harvest(address _callFeeRecipient) internal whenNotPaused {
        IRewardPool(rewardPool).getReward();
        _swapToNative();
        if (IERC20Metadata(native).balanceOf(address(this)) > 0) {
            if (!IBeefyVaultConcLiq(want).isCalm()) revert NotCalm();
            _chargeFees(_callFeeRecipient);
            _swapToWant();
            uint256 wantHarvested = balanceOfWant();
            (uint256 locked,) = lockedProfit();
            totalLocked = wantHarvested + locked;
            deposit();

            lastHarvest = block.timestamp;
            emit StratHarvest(msg.sender, wantHarvested, balanceOf());
        }
    }

    /// @dev Swap any extra rewards into native
    function _swapToNative() internal {
        for (uint i; i < rewards.length; ++i) {
            address reward = rewards[i];
            uint256 rewardBal = IERC20Metadata(reward).balanceOf(address(this));
            if (rewardBal > 0) IBeefySwapper(unirouter).swap(reward, native, rewardBal);
        }
    }

    /// @dev Charge performance fees and send to recipients
    /// @param _callFeeRecipient Recipient of the call fee reward 
    function _chargeFees(address _callFeeRecipient) internal {
        IFeeConfig.FeeCategory memory fees = getFees();
        uint256 nativeBal = IERC20Metadata(native).balanceOf(address(this)) * fees.total / DIVISOR;

        uint256 callFeeAmount = nativeBal * fees.call / DIVISOR;
        IERC20Metadata(native).safeTransfer(_callFeeRecipient, callFeeAmount);

        uint256 strategistFeeAmount = nativeBal * fees.strategist / DIVISOR;
        IERC20Metadata(native).safeTransfer(strategist, strategistFeeAmount);

        uint256 beefyFeeAmount = nativeBal - callFeeAmount - strategistFeeAmount;
        IERC20Metadata(native).safeTransfer(beefyFeeRecipient(), beefyFeeAmount);

        emit ChargedFees(callFeeAmount, beefyFeeAmount, strategistFeeAmount);
    }

    /// @dev Swap all native into want
    function _swapToWant() internal {
        uint256 nativeBal = IERC20Metadata(native).balanceOf(address(this));
        uint256 price = IStrategyConcLiq(IBeefyVaultConcLiq(want).strategy()).price();
        (uint bal0, uint bal1) = IBeefyVaultConcLiq(want).balances();
        uint256 PRECISION = 1e36;
        uint256 bal0InBal1 = (bal0 * price) / PRECISION;

        uint256 balRequired;
        uint256 nativeToLp0Amount;
        uint256 nativeToLp1Amount;
        uint256 nativeToTokenAmount;
        address tokenRequired;

        // check which side we need to fill more
        if (bal1 > bal0InBal1) {
            tokenRequired = token0;
            balRequired = (bal1 - bal0InBal1) * PRECISION / price;
        } else {
            tokenRequired = token1;
            balRequired = bal0InBal1 - bal1;
        }

        // calculate how much native we should swap from to fill the one side
        if (tokenRequired != native) {
            nativeToTokenAmount = IBeefySwapper(unirouter).getAmountOut(
                tokenRequired, native, balRequired
            );
        } else {
            nativeToTokenAmount = balRequired;
        }

        // only swap up to the amount of native we have
        if (nativeToTokenAmount > nativeBal) nativeToTokenAmount = nativeBal;

        // add in the amount to fill the one side
        if (tokenRequired == token0) {
            nativeToLp0Amount = nativeToTokenAmount;
        } else {
            nativeToLp1Amount = nativeToTokenAmount;
        }

        // whatever native is leftover after filling one side, do the half-half swap calculation
        nativeBal -= nativeToTokenAmount;
        if (nativeBal > 0) {
            uint256 halfNative = nativeBal / 2;
            nativeToLp0Amount += (nativeBal - halfNative);
            nativeToLp1Amount += halfNative;
        }
        
        // do swaps
        if (nativeToLp0Amount > 0 && token0 != native) 
            IBeefySwapper(unirouter).swap(native, token0, nativeToLp0Amount);
        if (nativeToLp1Amount > 0 && token1 != native) 
            IBeefySwapper(unirouter).swap(native, token1, nativeToLp1Amount);

        uint256 amount0 = IERC20Metadata(token0).balanceOf(address(this));
        uint256 amount1 = IERC20Metadata(token1).balanceOf(address(this));
        (uint256 shares,,,,) = IBeefyVaultConcLiq(want).previewDeposit(amount0, amount1);

        // deposit to want, we should be protected by isCalm() and slippage
        IBeefyVaultConcLiq(want).deposit(amount0, amount1, shares * slippage / DIVISOR);
    }

    /// @notice Total want controlled by the strategy in the underlying platform and this contract
    /// @return balance Total want controlled by the strategy 
    function balanceOf() public view returns (uint256 balance) {
        (uint256 locked,) = lockedProfit();
        
        if (harvestOnDeposit) balance = balanceOfWant() + balanceOfPool();
        else balance = balanceOfWant() + balanceOfPool() - locked;
    }

    /// @notice Amount of want held on this contract
    /// @return balanceHeld Amount of want held
    function balanceOfWant() public view returns (uint256 balanceHeld) {
        balanceHeld = IERC20Metadata(want).balanceOf(address(this));
    }

    /// @notice Amount of want controlled by the strategy in the underlying platform
    /// @return balanceInvested Amount of want in the underlying platform
    function balanceOfPool() public view returns (uint256 balanceInvested) {
        balanceInvested = IERC20Metadata(rewardPool).balanceOf(address(this));
    }

    /// @notice Amount of locked profit degrading over time
    /// @return left Amount of locked profit still remaining
    function lockedProfit() public override view returns (uint256 left, uint256 unusedVariable) {
        uint256 elapsed = block.timestamp - lastHarvest;
        uint256 remaining = elapsed < duration ? duration - elapsed : 0;
        left = totalLocked * remaining / duration;
        return (left, unusedVariable);
    }

    /// @notice Unclaimed reward amount from the underlying platform
    /// @return unclaimedReward Amount of reward left unclaimed
    function rewardsAvailable() public view returns (uint256 unclaimedReward) {
        unclaimedReward = IRewardPool(rewardPool).earned(address(this), rewards[0]);
    }

    /// @notice Estimated call fee reward for calling harvest
    /// @return callFee Amount of native reward a harvest caller could claim
    function callReward() public view returns (uint256 callFee) {
        IFeeConfig.FeeCategory memory fees = getFees();
        callFee = rewardsAvailable() * fees.total / DIVISOR * fees.call / DIVISOR;
    }

    /// @notice Manager function to toggle on harvesting on deposits
    /// @param _harvestOnDeposit Turn harvesting on deposit on or off
    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyManager {
        harvestOnDeposit = _harvestOnDeposit;
    }

    /// @notice Called by the vault as part of strategy migration, all funds are sent to the vault
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IRewardPool(rewardPool).withdraw(balanceOfPool());

        uint256 wantBal = IERC20Metadata(want).balanceOf(address(this));
        IERC20Metadata(want).transfer(vault, wantBal);
    }

    /// @notice Pauses deposits and withdraws all funds from the underlying platform
    function panic() public onlyManager {
        pause();
        IRewardPool(rewardPool).withdraw(balanceOfPool());
    }

    /// @notice Pauses deposits but leaves funds still invested
    function pause() public onlyManager {
        _pause();

        _removeAllowances();
    }

    /// @notice Unpauses deposits and reinvests any idle funds
    function unpause() external onlyManager {
        _unpause();

        _giveAllowances();

        deposit();
    }

    /// @notice Set the duration for the degradation of the locked profit
    /// @param _duration Duration for the degradation of the locked profit
    function setDuration(uint256 _duration) external onlyOwner {
        duration = _duration;
        emit SetDuration(_duration);
    }

    /// @notice Add a new reward to the array
    /// @param _reward New reward
    function setReward(address _reward) external onlyOwner {
        if (_reward == want || _reward == native || _reward == rewardPool) {
            revert RewardNotAllowed(_reward);
        }
        if (rewards.length > 0) {
            if (_reward == rewards[index[_reward]]) revert RewardAlreadySet(_reward);
        }
        index[_reward] = rewards.length;
        rewards.push(_reward);
        IERC20Metadata(_reward).forceApprove(unirouter, type(uint).max);
        emit SetReward(_reward);
    }

    /// @notice Remove a reward from the array
    /// @param _reward Removed reward
    function removeReward(address _reward) external onlyManager {
        if (_reward != rewards[index[_reward]]) revert RewardNotFound(_reward);
        address endReward = rewards[rewards.length - 1];
        uint256 replacedIndex = index[_reward];
        index[endReward] = replacedIndex;
        rewards[replacedIndex] = endReward;
        rewards.pop();
        IERC20Metadata(_reward).forceApprove(unirouter, 0);
        emit RemoveReward(_reward);
    }

    /// @notice Set slippage when adding liquidity
    /// @param _slippage Slippage amount
    function setSlippage(uint256 _slippage) external onlyManager {
        if (_slippage > 1 ether) revert SlippageOutOfBounds(_slippage);
        slippage = _slippage;
        emit SetSlippage(_slippage);
    }

    /// @dev Give out allowances to third party contracts
    function _giveAllowances() internal {
        IERC20Metadata(want).forceApprove(rewardPool, type(uint).max);
        IERC20Metadata(native).forceApprove(unirouter, type(uint).max);

        IERC20Metadata(token0).forceApprove(want, 0);
        IERC20Metadata(token0).forceApprove(want, type(uint).max);
        IERC20Metadata(token1).forceApprove(want, 0);
        IERC20Metadata(token1).forceApprove(want, type(uint).max);

        for (uint i; i < rewards.length; ++i) {
            IERC20Metadata(rewards[i]).forceApprove(unirouter, 0);
            IERC20Metadata(rewards[i]).forceApprove(unirouter, type(uint).max);
        }
    }

    /// @dev Revoke allowances from third party contracts
    function _removeAllowances() internal {
        IERC20Metadata(want).forceApprove(rewardPool, 0);
        IERC20Metadata(native).forceApprove(unirouter, 0);

        IERC20Metadata(token0).forceApprove(want, 0);
        IERC20Metadata(token1).forceApprove(want, 0);

        for (uint i; i < rewards.length; ++i) {
            IERC20Metadata(rewards[i]).forceApprove(unirouter, 0);
        }
    }
}