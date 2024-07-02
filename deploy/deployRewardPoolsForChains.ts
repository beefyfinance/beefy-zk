import { Wallet, utils } from "zksync-web3";
import { Provider } from "zksync-web3";
import * as ethers from "ethers";
import hardhat from "hardhat";
import { HardhatRuntimeEnvironment } from "hardhat/types";
const { addressBook } = require("blockchain-addressbook");
const BeefyVaultConcLiq = require("../artifacts-zk/contracts/vault/BeefyVaultConcLiq.sol/BeefyVaultConcLiq.json");
const BeefyRewardPool = require("../artifacts-zk/contracts/rewardpool/BeefyRewardPool.sol/BeefyRewardPool.json");
const BeefyRewardPoolFactory = require("../artifacts-zk/contracts/rewardpool/BeefyRewardPoolFactory.sol/BeefyRewardPoolFactory.json");

const vaults = [
    '0x0386c81eB83E6BbD8782A47180a1501CC003A232',
    '0x2b98E0f95aAAe12Bb29f54d29130dDB3C7bB3fd8',
    '0x88e2510D116169ea559b4Cf458DF34BD3CaCa903',
    '0x741CF7B1bB7bf4a4e8C402901d59fbD7fa3E681d',
    '0x7c4CC830da7d972E58F32814DB00074c29dda546'
  ];

  type Entry = {
    vault: string;
    rewardPool: string;
  }

let rewardPools = [] as Entry[];

const {
    platforms: { beefyfinance },
} = addressBook.zksync;

const msig = '0xD80e5884C1E2771D4d2A6b3b7C240f10EfA0c766';
const PRIVATE_KEY = process.env.DEPLOYER_PK!;

async function main() {
    
    const count = vaults.length;
    console.log(`Deploying ${count} Reward Pools`);

    const provider = new Provider("https://mainnet.era.zksync.io");
    const signer = new ethers.Wallet(PRIVATE_KEY, provider);

    const rewardPoolFactory = new ethers.Contract(beefyfinance.clmRewardPoolFactory, BeefyRewardPoolFactory.abi, signer);

    for (let i = 0; i < vaults.length; i++) {
        let rewardPool = await rewardPoolFactory.callStatic.createRewardPool("BeefyRewardPool");
        let tx = await rewardPoolFactory.createRewardPool("BeefyRewardPool");
        tx = await tx.wait();

        const rewardPoolContract = new ethers.Contract(rewardPool, BeefyRewardPool.abi, signer);
        const vaultContract = new ethers.Contract(vaults[i], BeefyVaultConcLiq.abi, signer);
        let vaultName = await vaultContract.name();
        let vaultSymbol = await vaultContract.symbol();
        let name = 'Reward ' + vaultName;
        let symbol = 'r' + vaultSymbol;
        let init = await rewardPoolContract.initialize(vaults[i], name, symbol);
        init = await init.wait();

        let setWhitelist = await rewardPoolContract.setWhitelist(beefyfinance.treasuryMultisig, true);
        setWhitelist = await setWhitelist.wait();

        let transferOwnership = await rewardPoolContract.transferOwnership(beefyfinance.devMultisig);
        transferOwnership = await transferOwnership.wait();

        console.log(`${name} deployed at ${rewardPool}`)

        rewardPools.push({
            vault: vaults[i],
            rewardPool: rewardPool,
        });
    }

    console.log(`Reward Pools Deployed`);
    const json = JSON.stringify(rewardPools);
    console.log(json);
}

  // We recommend this pattern to be able to use async/await everywhere
  // and properly handle errors.
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });