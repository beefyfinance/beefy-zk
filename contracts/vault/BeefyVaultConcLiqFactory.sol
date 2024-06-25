// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {BeefyVaultConcLiq} from "./BeefyVaultConcLiq.sol";

// Beefy Finance Vault ConcLiq Proxy Factory
// Minimal proxy pattern for creating new Beefy concentrated liquidity vaults
contract BeefyVaultConcLiqFactory {

  /// @notice Contract template for deploying proxied Beefy vaults
  BeefyVaultConcLiq public instance;

  /// @notice Emitted when a new Beefy Vault is created
  event ProxyCreated(address proxy);

  /** 
   * @notice Constructor initializes the Beefy Vault template instance
   */
  constructor() {
    instance = new BeefyVaultConcLiq();
  }

  /**
   * @notice Create a new Beefy Conc Liq Vault as a proxy of the template instance
   * @return A reference to the new proxied Beefy Vault
   */
  function cloneVault(
  ) external returns (BeefyVaultConcLiq) {
    BeefyVaultConcLiq vault = BeefyVaultConcLiq(_cloneContract());
    return vault;
  }

  /**
   * Deploys and returns the address of a clone that mimics the behaviour of `implementation`
   * @return The address of the newly created clone
  */
  function _cloneContract() private returns (address) {
    address proxy = address(new BeefyVaultConcLiq());
    emit ProxyCreated(proxy);
    return proxy;
  }
}