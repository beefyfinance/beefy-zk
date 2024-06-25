// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {BeaconProxy} from "@openzeppelin-4/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin-4/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Ownable} from "@openzeppelin-4/contracts/access/Ownable.sol";

// Beefy Strategy ConcLiq Proxy Factory
// Minimal upgradeable beacon proxy pattern for creating new Beefy concentrated liquidity vaults
contract StrategyFactory is Ownable {

  /// @notice instance mapping to strategy name with version. 
  mapping (string => UpgradeableBeacon) public instances;

  /// @notice approved rebalancer mapping 
  mapping (address => bool) public rebalancers;

  /// @notice deployed strategy types
  string[] public strategyTypes;

  /// @notice The address of the native token
  address public native;

  /// @notice The address of the keeper
  address public keeper;

  /// @notice The beefy fee recipient
  address public beefyFeeRecipient;

  /// @notice The beefy fee config
  address public beefyFeeConfig;

  /// @notice Global pause state for all strategies that use this
  bool public globalPause;

  /// @notice Emitted when a new Beefy Strategy is created
  event ProxyCreated(string strategyName, address proxy);

  /// @notice Emitted when a Beefy Strategy is upgraded
  event InstanceUpgraded(string strategyName, address newImplementation);

  /// @notice Emitted when a new Beefy Strategy is added
  event NewStrategyAdded(string strategyName, address implementation);

  /// @notice Emitted when the beefy fee recipient address is changed
  event SetBeefyFeeRecipient(address beefyFeeRecipient);

  /// @notice Emitted when the beefy fee config address is changed
  event SetBeefyFeeConfig(address beefyFeeConfig);

  /// @notice Emitted when the keeper address is changed
  event SetKeeper(address keeper);

  /// @notice Emitted when the global pause state is changed
  event GlobalPause(bool paused);

  /// @notice Emitted when a rebalancer is added or removed
  event RebalancerChanged(address rebalancer, bool isRebalancer);

  // Errors
  error NotManager();
  error StratVersionExists();

  /// @notice Throws if called by any account other than the owner or the keeper
  modifier onlyManager() {
    if (msg.sender != owner() && msg.sender != address(keeper)) revert NotManager();
    _;
  }

  /// @notice Constructor initializes the keeper address
  constructor(
    address _native,
    address _keeper,
    address _beefyFeeRecipient,
    address _beefyFeeConfig
  ) Ownable(msg.sender) {
    native = _native;
    keeper = _keeper;
    beefyFeeRecipient = _beefyFeeRecipient;
    beefyFeeConfig = _beefyFeeConfig;
  }

  /** @notice Creates a new Beefy Strategy as a proxy of the template instance
    * @param _strategyName The name of the strategy
    * @return A reference to the new proxied Beefy Strategy
   */
  function createStrategy(string calldata _strategyName) external returns (address) {
    
    // Create a new Beefy Strategy as a proxy of the template instance
    UpgradeableBeacon instance = instances[_strategyName];
    BeaconProxy proxy = new BeaconProxy(address(instance), "");

    emit ProxyCreated(_strategyName, address(proxy));

    return address(proxy);
  }

  /**
   * @notice Upgrades the implementation of a strategy
   * @param _strategyName The name of the strategy
   * @param _newImplementation The new implementation address
   */
  function upgradeTo(string calldata _strategyName, address _newImplementation) external onlyOwner {
    UpgradeableBeacon instance = instances[_strategyName];
    instance.upgradeTo(_newImplementation);
    emit InstanceUpgraded(_strategyName, _newImplementation);
  }

  /**
   * @notice Adds a new strategy to the factory
   * @param _strategyName The name of the strategy
   * @param _implementation The implementation address
   */
  function addStrategy(string calldata _strategyName, address _implementation) external onlyManager {
    if (address(instances[_strategyName]) != address(0)) revert StratVersionExists();
    instances[_strategyName] = new UpgradeableBeacon(_implementation, address(this));

    // Store in our deployed strategy type array
    strategyTypes.push(_strategyName);
    emit NewStrategyAdded(_strategyName, _implementation);
  }

  /**
   * @notice Pauses all strategies
   */
  function pauseAllStrats() external onlyManager {
    globalPause = true;
    emit GlobalPause(true);
  }

  /**
   * @notice Unpauses all strategies
   */
  function unpauseAllStrats() external onlyOwner {
    globalPause = false;
    emit GlobalPause(false);
  }

  /**
   * @notice Adds a rebalancer callable by the owner
   * @param _rebalancer The rebalancer address
   */
  function addRebalancer(address _rebalancer) external onlyOwner {
    rebalancers[_rebalancer] = true;
    emit RebalancerChanged(_rebalancer, true);
  }

  /**
   * @notice Removes a rebalancer callable by a manager
   * @param _rebalancer The rebalancer address
   */
  function removeRebalancer(address _rebalancer) external onlyManager {
    rebalancers[_rebalancer] = false;
    emit RebalancerChanged(_rebalancer, false);
  }

  /**
   * @notice set the beefy fee recipient address
   * @param _beefyFeeRecipient The new beefy fee recipient address
   */
  function setBeefyFeeRecipient(address _beefyFeeRecipient) external onlyOwner {
      beefyFeeRecipient = _beefyFeeRecipient;
      emit SetBeefyFeeRecipient(_beefyFeeRecipient);
  }

  /**
   * @notice set the beefy fee config address
   * @param _beefyFeeConfig The new beefy fee config address
   */
  function setBeefyFeeConfig(address _beefyFeeConfig) external onlyOwner {
      beefyFeeConfig = _beefyFeeConfig;
      emit SetBeefyFeeConfig(_beefyFeeConfig);
  }

  /**
   * @notice set the keeper address
   * @param _keeper The new keeper address
   */
  function setKeeper(address _keeper) external onlyOwner {
      keeper = _keeper;
      emit SetKeeper(_keeper);
  }

  /**
   * @notice Gets the implementation of a strategy
   * @param _strategyName The name of the strategy
   * @return The implementation address
   */
  function getImplementation(string calldata _strategyName) external view returns (address) {
    return instances[_strategyName].implementation();
  }

  /**
   * @notice Gets the array of deployed strategies
   * @return The array of deployed strategies
   */
  function getStrategyTypes() external view returns (string[] memory) {
    return strategyTypes;
  }
}