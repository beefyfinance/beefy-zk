// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {IFeeConfig} from "../interfaces/beefy/IFeeConfig.sol";
import {IStrategyFactory} from "../interfaces/beefy/IStrategyFactory.sol";

contract StratFeeManagerInitializable is OwnableUpgradeable, PausableUpgradeable {
    struct CommonAddresses {
        address vault;
        address unirouter;
        address strategist;
        address factory;
    }

    /// @notice The native address of the chain
    address public native;

    /// @notice The address of the vault
    address public vault;

    /// @notice The address of the unirouter
    address public unirouter;

    /// @notice The address of the strategist
    address public strategist;

    /// @notice The address of the strategy factory
    IStrategyFactory public factory;

    /// @notice The total amount of token0 locked in the vault
    uint256 public totalLocked0;

    /// @notice The total amount of token1 locked in the vault
    uint256 public totalLocked1;

    /// @notice The last time the strat harvested
    uint256 public lastHarvest;

    /// @notice The last time we adjusted the position
    uint256 public lastPositionAdjustment;

    /// @notice The duration of the locked rewards
    uint256 constant DURATION = 1 hours;

    /// @notice The divisor used to calculate the fee
    uint256 constant DIVISOR = 1 ether;


    // Events
    event SetStratFeeId(uint256 feeId);
    event SetUnirouter(address unirouter);
    event SetStrategist(address strategist);

    // Errors
    error NotManager();
    error NotStrategist();
    error OverLimit();
    error StrategyPaused();

    /**
     * @notice Initialize the Strategy Fee Manager inherited contract with the common addresses
     * @param _commonAddresses The common addresses of the vault, unirouter, keeper, strategist, beefyFeeRecipient and beefyFeeConfig
     */
    function __StratFeeManager_init(CommonAddresses calldata _commonAddresses) internal onlyInitializing {
        __Ownable_init();
        __Pausable_init();
        vault = _commonAddresses.vault;
        unirouter = _commonAddresses.unirouter;
        strategist = _commonAddresses.strategist;
        factory = IStrategyFactory(_commonAddresses.factory);
        native = factory.native();
    }

    /**
     * @notice function that throws if the strategy is paused
     */
    function _whenStrategyNotPaused() internal view {
        if (paused() || factory.globalPause()) revert StrategyPaused();
    }

    /**
     * @notice function that returns true if the strategy is paused
     */
    function _isPaused() internal view returns (bool) {
        return paused() || factory.globalPause();
    }

    /** 
     * @notice Modifier that throws if called by any account other than the manager or the owner
    */
    modifier onlyManager() {
        if (msg.sender != owner() && msg.sender != keeper()) revert NotManager();
        _;
    }

    /// @notice The address of the keeper, set on the factory. 
    function keeper() public view returns (address) {
        return factory.keeper();
    }

    /// @notice The address of the beefy fee recipient, set on the factory.
    function beefyFeeRecipient() public view returns (address) {
        return factory.beefyFeeRecipient();
    }

    /// @notice The address of the beefy fee config, set on the factory.
    function beefyFeeConfig() public view returns (IFeeConfig) {
        return IFeeConfig(factory.beefyFeeConfig());
    }

    /**
     * @notice get the fees breakdown from the fee config for this contract
     * @return IFeeConfig.FeeCategory The fees breakdown
     */
    function getFees() internal view returns (IFeeConfig.FeeCategory memory) {
        return beefyFeeConfig().getFees(address(this));
    }

    /**
     * @notice get all the fees from the fee config for this contract
     * @return IFeeConfig.AllFees The fees
     */
    function getAllFees() external view returns (IFeeConfig.AllFees memory) {
        return IFeeConfig.AllFees(getFees(), depositFee(), withdrawFee());
    }

    /**
     * @notice get the strat fee id from the fee config
     * @return uint256 The strat fee id
     */
    function getStratFeeId() external view returns (uint256) {
        return beefyFeeConfig().stratFeeId(address(this));
    }

    /**
     * @notice set the strat fee id in the fee config
     * @param _feeId The new strat fee id
     */
    function setStratFeeId(uint256 _feeId) external onlyManager {
        beefyFeeConfig().setStratFeeId(_feeId);
        emit SetStratFeeId(_feeId);
    }

    /**
     * @notice set the unirouter address
     * @param _unirouter The new unirouter address
     */
    function setUnirouter(address _unirouter) external virtual onlyOwner {
        unirouter = _unirouter;
        emit SetUnirouter(_unirouter);
    }

    /**
     * @notice set the strategist address
     * @param _strategist The new strategist address
     */
    function setStrategist(address _strategist) external {
        if (msg.sender != strategist) revert NotStrategist();
        strategist = _strategist;
        emit SetStrategist(_strategist);
    }

    /**
     * @notice The deposit fee variable will alwasy be 0. This is used by the UI. 
     * @return uint256 The deposit fee
     */
    function depositFee() public virtual view returns (uint256) {
        return 0;
    }

    /**
     * @notice The withdraw fee variable will alwasy be 0. This is used by the UI. 
     * @return uint256 The withdraw fee
     */
    function withdrawFee() public virtual view returns (uint256) {
        return 0;
    }

    /**
     * @notice The locked profit is the amount of token0 and token1 that is locked in the vault, this can be overriden by the strategy contract.
     * @return locked0 The amount of token0 locked
     * @return locked1 The amount of token1 locked
     */
    function lockedProfit() public virtual view returns (uint256 locked0, uint256 locked1) {
        uint256 elapsed = block.timestamp - lastHarvest;
        uint256 remaining = elapsed < DURATION ? DURATION - elapsed : 0;
        return (totalLocked0 * remaining / DURATION, totalLocked1 * remaining / DURATION);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}