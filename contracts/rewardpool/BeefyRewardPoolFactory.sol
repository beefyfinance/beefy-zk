// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {BeaconProxy} from "@openzeppelin-4/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin-4/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Ownable} from "@openzeppelin-4/contracts/access/Ownable.sol";

// Beefy Reward Pool Proxy Factory
// Minimal upgradeable beacon proxy pattern for creating new Beefy concentrated liquidity reward pools
contract BeefyRewardPoolFactory is Ownable {
  /// @notice instance mapping to reward pool name
  mapping (string => UpgradeableBeacon) public instances;

  /// @notice Is Immutable mapping
  mapping (string => bool) public isImmutable;

  /// @notice deployed rewardPool types
  string[] public rewardPoolTypes;

  /// @notice The address of the keeper
  address public keeper;

  /// @notice Emitted when a new Beefy Reward Pool is created
  event ProxyCreated(string rewardPoolName, address proxy);

  /// @notice Emitted when a Beefy Reward Pool is upgraded
  event InstanceUpgraded(string RewardPoolName, address newImplementation);

  /// @notice Emitted when a new Beefy Reward Pool is added
  event NewRewardPoolAdded(string rewardPoolName, address implementation);

  /// @notice Emitted when a reward pool type is set as immutable
  event RewardPoolIsImmutable(string rewardPoolName);

  /// @notice Emitted when the keeper address is changed
  event SetKeeper(address keeper);

  // Errors
  error NotManager();
  error VersionExists();
  error IsImmutable();

  /// @notice Throws if called by any account other than the owner or the keeper.
  modifier onlyManager() {
    if (msg.sender != owner() && msg.sender != address(keeper)) revert NotManager();
    _;
  }

  /// @notice Constructor initializes the keeper address
  constructor( address _keeper) Ownable(msg.sender) {
    keeper = _keeper;
  }

  /** @notice Creates a new Beefy Reward Pool as a proxy of the template instance
    * @param _rewardPoolName The name of the rewardPool
    * @return A reference to the new proxied Beefy Reward Pool
   */
  function createRewardPool(string calldata _rewardPoolName) external returns (address) {
    
    // Create a new Beefy Reward Pool as a proxy of the template instance
    UpgradeableBeacon instance = instances[_rewardPoolName];
    BeaconProxy proxy = new BeaconProxy(address(instance), "");

    emit ProxyCreated(_rewardPoolName, address(proxy));

    return address(proxy);
  }

  /**
   * @notice Upgrades the implementation of a rewardPool
   * @param _rewardPoolName The name of the reward pool
   * @param _newImplementation The new implementation address
   */
  function upgradeTo(string calldata _rewardPoolName, address _newImplementation) external onlyOwner {
    if (isImmutable[_rewardPoolName]) revert IsImmutable();
    UpgradeableBeacon instance = instances[_rewardPoolName];
    instance.upgradeTo(_newImplementation);
    emit InstanceUpgraded(_rewardPoolName, _newImplementation);
  }

  /**
   * @notice Adds a new reward pool to the factory
   * @param _rewardPoolName The name of the reward pool
   * @param _implementation The implementation address
   */
  function addRewardPool(string calldata _rewardPoolName, address _implementation) external onlyManager {
    if (address(instances[_rewardPoolName]) != address(0)) revert VersionExists();
    instances[_rewardPoolName] = new UpgradeableBeacon(_implementation, address(this));

    // Store in our deployed reward pool type array
    rewardPoolTypes.push(_rewardPoolName);
    emit NewRewardPoolAdded(_rewardPoolName, _implementation);
  }

  /**
   * @notice Sets a reward pool type as immutable
   */
  function SetRewardPoolTypeImmutable(string calldata _rewardPoolName) external onlyOwner {
    isImmutable[_rewardPoolName] = true;
    emit RewardPoolIsImmutable(_rewardPoolName);
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
   * @notice Gets the implementation of a reward pool
   * @param _rewardPoolName The name of the reward pool
   * @return The implementation address
   */
  function getImplementation(string calldata _rewardPoolName) external view returns (address) {
    return instances[_rewardPoolName].implementation();
  }

  /**
   * @notice Gets the array of deployed reward pools
   * @return The array of deployed reward pools
   */
  function getRewardPoolTypes() external view returns (string[] memory) {
    return rewardPoolTypes;
  }
}