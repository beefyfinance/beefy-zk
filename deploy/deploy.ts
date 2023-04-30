import { Wallet, utils } from "zksync-web3";
import * as ethers from "ethers";
import hardhat from "hardhat";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
const { addressBook } = require("blockchain-addressbook");

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

// load wallet private key from env file
const PRIVATE_KEY = process.env.DEPLOYER_PK!;

if (!PRIVATE_KEY)
  throw "⛔️ Private key not detected! Add it to the .env file!";

// An example of a deploy script that will deploy and call a simple contract.
export default async function (hre: HardhatRuntimeEnvironment) {
  console.log(`Running deploy script`);

  // Initialize the wallet.
  const wallet = new Wallet(PRIVATE_KEY);

  // Create deployer object and load the artifact of the contract you want to deploy.
  const deployer = new Deployer(hre, wallet);

 // const vault = await deployer.loadArtifact("BeefyVaultV7");
  const artifact = await deployer.loadArtifact("BeefyUniV2ZapSolidly");

//  const beefyVault = await deployer.deploy(vault, []);
//  await beefyVault.deployed();

  const contract = await deployer.deploy(artifact, [velocore.router, ETH]);

  await contract.deployed();
 // await contract.renounceRole(TIMELOCK_ADMIN_ROLE, deployer.ethWallet.address);

 await hardhat.run("verify:verify", {
  address: contract.address,
  constructorArguments: [],
});

  // Show the contract info.
  const contractAddress = contract.address;
 // console.log(`${vault.contractName} was deployed to ${beefyVault.address}`);
  console.log(`${artifact.contractName} was deployed to ${contractAddress}`);
  console.log();
}
