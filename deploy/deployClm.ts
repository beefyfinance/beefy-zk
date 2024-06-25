import { Wallet, utils } from "zksync-web3";
import { Provider } from "zksync-web3";
import * as ethers from "ethers";
import hardhat from "hardhat";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
const { addressBook } = require("blockchain-addressbook");
const BeefyVaultConcLiq = require("../artifacts-zk/contracts/vault/BeefyVaultConcLiq.sol/BeefyVaultConcLiq.json");
const BeefyVaultConcLiqFactory = require("../artifacts-zk/contracts/vault/BeefyVaultConcLiqFactory.sol/BeefyVaultConcLiqFactory.json");
const StrategyPassiveManagerUniswap = require("../artifacts-zk/contracts/strategies/uniswap/StrategyPassiveManagerUniswap.sol/StrategyPassiveManagerUniswap.json");
const StrategyPassiveManagerUniswapFactory = require("../artifacts-zk/contracts/strategies/StrategyFactory.sol/StrategyFactory.json");

// load env file
import dotenv from "dotenv";
dotenv.config();

const {
  platforms: { beefyfinance },
  tokens: {
    USDCe: {address: USDCe},
    WETH: { address: WETH },
    WBTC: {address: WBTC},
    ZK: {address: ZK},
    USDT: {address: USDT},
  },
} = addressBook.zksync;

const vaultFactoryAddress = "0x59c7EC7387A480c0a5d953fCb45513D01B94286D";
const stratFactoryAddress = beefyfinance.clmStrategyFactory;

const config = {
    name: "Cow Uniswap zkSync WETH-WBTC",
    symbol: "cowUniswapzkSyncWETH-WBTC",
    strategyName: "StrategyPassiveManagerUniswap_V1",
    pool: "0xf8C42655373A280e8800BEeE44fcC12ffC99E797",
    quoter: "0x8Cb537fc92E26d8EBBb760E632c95484b6Ea3e28",
    width: 70,
    strategist: "0x4cC72219fc8aEF162FC0c255D9B9C3Ff93B10882",
    unirouter: beefyfinance.beefySwapper
}

const lp0TokenToNative = '0x';//ethers.utils.solidityPack(["address", "uint24", "address"], [USDCe, 500, WETH]);
const lp1TokenToNative = ethers.utils.solidityPack(["address", "uint24", "address"], [WBTC, 500, WETH]);

// load wallet private key from env file
const PRIVATE_KEY = process.env.DEPLOYER_PK!;

if (!PRIVATE_KEY)
  throw "⛔️ Private key not detected! Add it to the .env file!";

// An example of a deploy script that will deploy and call a simple contract.
export default async function (hre: HardhatRuntimeEnvironment) {
  console.log(`Running deploy vault script`);

  const provider = new Provider("https://mainnet.era.zksync.io");
  const signer = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log(`Deploying: `, config.name);

  const vaultFactory = new ethers.Contract(vaultFactoryAddress, BeefyVaultConcLiqFactory.abi, signer);
  const strategyFactory = new ethers.Contract(stratFactoryAddress, StrategyPassiveManagerUniswapFactory.abi, signer);

  let vault = await vaultFactory.callStatic.cloneVault();
  let tx = await vaultFactory.cloneVault();
  tx = await tx.wait();
  tx.status === 1
  ? console.log(`Vault ${vault} is deployed with tx: ${tx.transactionHash}`)
  : console.log(`Vault ${vault} deploy failed with tx: ${tx.transactionHash}`);

  let strat = await strategyFactory.callStatic.createStrategy(config.strategyName);
  let stratTx = await strategyFactory.createStrategy(config.strategyName);
  stratTx = await stratTx.wait();
  stratTx.status === 1
  ? console.log(`Strat ${strat} is deployed with tx: ${stratTx.transactionHash}`)
  : console.log(`Strat ${strat} deploy failed with tx: ${stratTx.transactionHash}`);

  const vaultContract = new ethers.Contract(vault, BeefyVaultConcLiq.abi, signer);
  let vaultInitTx = await vaultContract.initialize(strat, config.name, config.symbol);
  vaultInitTx = await vaultInitTx.wait();
  vaultInitTx === 1
  ? console.log(`Vault Initialized with tx: ${vaultInitTx.transactionHash}`)
  : console.log(`Vault Initialization failed with tx: ${vaultInitTx.transactionHash}`);

  vaultInitTx = await vaultContract.transferOwnership(beefyfinance.vaultOwner);
  vaultInitTx = await vaultInitTx.wait();
  vaultInitTx === 1
  ? console.log(`Ownership Transfered with tx: ${vaultInitTx.transactionHash}`)
  : console.log(`Ownership Transfered failed with tx: ${vaultInitTx.transactionHash}`);

  const constructorArguments = [
    config.pool,
    config.quoter,
    config.width,
    lp0TokenToNative,
    lp1TokenToNative,
    [
      vault,
      config.unirouter,
      config.strategist,
      stratFactoryAddress
    ]
  ];

  const stratContract = new ethers.Contract(strat, StrategyPassiveManagerUniswap.abi, signer);
  let stratInitTx = await stratContract.initialize(...constructorArguments);
  stratInitTx = await stratInitTx.wait();
  stratInitTx === 1
  ? console.log(`Strategy Initialized with tx: ${stratInitTx.transactionHash}`)
  : console.log(`Strategy Initialization failed with tx: ${stratInitTx.transactionHash}`);

  await hardhat.run("verify:verify", {
    address: vault,
    contract: "contracts/vault/BeefyVaultConcLiq.sol:BeefyVaultConcLiq",
    constructorArguments: [],
  });
  
  console.log();
  console.log("Finished deploying Concentrated Liquidity Vault");
}
