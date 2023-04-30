import { Wallet, utils } from "zksync-web3";
import { Provider } from "zksync-web3";
import * as ethers from "ethers";
import hardhat from "hardhat";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
const { addressBook } = require("blockchain-addressbook");
import vaultV7 from "../artifacts-zk/contracts/vault/BeefyVaultV7.sol/BeefyVaultV7.json";
import stratAbi from "../artifacts-zk/contracts/strategies/Common/StrategyCommonSolidlyGaugeLP.sol/StrategyCommonSolidlyGaugeLP.json";

// load env file
import dotenv from "dotenv";
dotenv.config();

const {
  platforms: { velocore, beefyfinance },
  tokens: {
    VC: {address: VC},
    USDC: { address: USDC },
    BUSD: {address: BUSD},
    ETH: {address: ETH},
  },
} = addressBook.zksync;


const want = ethers.utils.getAddress("0x80aB452b8Ba46722029a69308aC52c0897d3a855");
const gauge = ethers.utils.getAddress("0xCB6ad4A0c25bDdAd2E99EE51Fe468b6CDB4B2576");
//const ensId = ethers.utils.formatBytes32String("cake.eth");

const vaultParams = {
  mooName: "Moo Velocore VC-ETH",
  mooSymbol: "mooVelocoreVC-ETH",
  delay: 21600,
};

const strategyParams = {
  want: want,
  gauge: gauge,
  unirouter: velocore.router,
  strategist: process.env.STRATEGIST_ADDRESS, // some address
  keeper: beefyfinance.keeper,
  beefyFeeRecipient: beefyfinance.beefyFeeRecipient,
  feeConfig: beefyfinance.beefyFeeConfig,
  outputToNativeRoute: [[VC, ETH, false]],
  outputToLp0Route: [[VC, ETH, false]],
  outputToLp1Route: [[VC, VC, false]],
  verifyStrat: false,
  spiritswapStrat: false,
  gaugeStakerStrat: false,
  beefyVaultProxy: "0x42F93644403C6cA1dD4F6446aA720F019a757FEA", //beefyfinance.vaultFactory,
  strategyImplementation: "0x442b84b85403c5d1C3d12a049fA0D7aCc25C1438",
  useVaultProxy: true,
 // ensId
};

// load wallet private key from env file
const PRIVATE_KEY = process.env.DEPLOYER_PK!;

if (!PRIVATE_KEY)
  throw "⛔️ Private key not detected! Add it to the .env file!";

// An example of a deploy script that will deploy and call a simple contract.
export default async function (hre: HardhatRuntimeEnvironment) {
  console.log(`Running deploy vault script`);

  const wallet = new Wallet(PRIVATE_KEY);

  // Create deployer object and load the artifact of the contract you want to deploy.
  const deployer = new Deployer(hre, wallet);

  const vaultContract = await deployer.loadArtifact("BeefyVaultV7");
  const strategyContract = await deployer.loadArtifact("StrategyCommonSolidlyGaugeLP");

  const provider = new Provider("https://mainnet.era.zksync.io");
  const signer = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log("Deploying:", vaultParams.mooName);

  let vault = await deployer.deploy(vaultContract, []);
  await vault.deployed();
  console.log(`Vault ${vault.address} is deployed`)

  let strat = await deployer.deploy(strategyContract, []);
  await strat.deployed();
  console.log(`Strat ${strat.address} is deployed`);

  const vaultConstructorArguments = [
    strat.address,
    vaultParams.mooName,
    vaultParams.mooSymbol,
    vaultParams.delay,
  ];

  const vaultCont = new ethers.Contract(vault.address, vaultV7.abi, signer);
  let vaultInitTx = await vaultCont.initialize(...vaultConstructorArguments);
  vaultInitTx = await vaultInitTx.wait()
  vaultInitTx.status === 1
  ? console.log(`Vault Intilization done with tx: ${vaultInitTx.transactionHash}`)
  : console.log(`Vault Intilization failed with tx: ${vaultInitTx.transactionHash}`);



  vaultInitTx = await vaultCont.transferOwnership(beefyfinance.vaultOwner);
  vaultInitTx = await vaultInitTx.wait()
  vaultInitTx.status === 1
  ? console.log(`Vault OwnershipTransfered done with tx: ${vaultInitTx.transactionHash}`)
  : console.log(`Vault Intilization failed with tx: ${vaultInitTx.transactionHash}`);


  const strategyConstructorArguments = [
    strategyParams.want,
    strategyParams.gauge,
    [
      vault.address,
      strategyParams.unirouter,
      strategyParams.keeper,
      strategyParams.strategist,
      strategyParams.beefyFeeRecipient,
      strategyParams.feeConfig,
    ],
    strategyParams.outputToNativeRoute,
    strategyParams.outputToLp0Route, 
    strategyParams.outputToLp1Route
  ];

  
  const stratContract = new ethers.Contract(strat.address, stratAbi.abi, signer);
  let args = strategyConstructorArguments;
  let stratInitTx = await stratContract.initialize(...args);
  stratInitTx = await stratInitTx.wait()
  stratInitTx.status === 1
  ? console.log(`Strat Intilization done with tx: ${stratInitTx.transactionHash}`)
  : console.log(`Strat Intilization failed with tx: ${stratInitTx.transactionHash}`);

  await hardhat.run("verify:verify", {
    address: vault.address,
    constructorArguments: [],
  });

  await hardhat.run("verify:verify", {
    address: strat.address,
    constructorArguments: [],
  });
}
