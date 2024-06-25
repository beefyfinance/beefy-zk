import { Wallet, utils } from "zksync-web3";
import { Provider } from "zksync-web3";
import * as ethers from "ethers";
import hardhat from "hardhat";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
const { addressBook } = require("blockchain-addressbook");
import swapperAbi from "../artifacts-zk/contracts/infra/BeefySwapper.sol/BeefySwapper.json";
import UniswapV3RouterAbi from "../abi/UniswapV3Router.json";

// load env file
import dotenv from "dotenv";
dotenv.config();

const {
  platforms: { beefyfinance },
  tokens: {
    //USDC: { address: USDC},
    WETH: { address: WETH},
    WBTC: {address: WBTC},
  },
} = addressBook.zksync;
const USDT = "0x493257fD37EDB34451f62EDf8D2a0C418852bA4C";
const USDC = "0x1d17CBcF0D6D143135aE902365D2E5e2A16538D4";
const ZK = "0x5A7d6b2F92C77FAD6CCaBd7EE0624E64907Eaf3E"

//const ethers = hardhat.ethers;

const nullAddress = "0x0000000000000000000000000000000000000000";
const uint256Max = "115792089237316195423570985008687907853269984665640564039457584007913129639935";
const int256Max = "57896044618658097711785492504343953926634992332820282019728792003956564819967";
const beefyfinanceSwapper = "0x46b9821E57a68274342E679B2a44c1acb5Af55C8";

const uniswapV3Router = "0x99c56385daBCE3E81d8499d0b8d0257aBC07E8A3";

const config = {
  type: "uniswapV3",
  uniswapV3: {
    path: [[USDT, WETH, 500]],
    router: uniswapV3Router,
  }
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

  const provider = new Provider("https://mainnet.era.zksync.io");
  const signer = new ethers.Wallet(PRIVATE_KEY, provider);

  const router = new ethers.Contract(config.uniswapV3.router, UniswapV3RouterAbi, signer);

  let path = ethers.utils.solidityPack(
    ["address"],
    [config.uniswapV3.path[0][0]]
  );
  for (let i = 0; i < config.uniswapV3.path.length; i++) {
      path = ethers.utils.solidityPack(
        ["bytes", "uint24", "address"],
        [path, config.uniswapV3.path[i][2], config.uniswapV3.path[i][1]]
      );
  }
  const exactInputParams = [
    path,
    beefyfinanceSwapper,
    uint256Max,
    0,
    0
  ];
  const txData = await router.populateTransaction.exactInput(exactInputParams);
  const amountIndex = 100;
  const minIndex = 132;

  const minAmountSign = 0;

  const swapInfo = [
    config.uniswapV3.router,
    txData.data,
    amountIndex,
    minIndex,
    minAmountSign
  ];

  const fromToken = config.uniswapV3.path[0][0];
  const toToken = config.uniswapV3.path[config.uniswapV3.path.length - 1][1];

  console.log(fromToken, toToken, swapInfo);

  const swapper = new ethers.Contract(beefyfinanceSwapper, swapperAbi.abi, signer);

  /*let tx = await swapper.setSwapInfo(fromToken, toToken, swapInfo);
  tx = await tx.wait();
    tx.status === 1
      ? console.log(`Info set for ${fromToken} with tx: ${tx.transactionHash}`)
      : console.log(`Could not set info for ${fromToken}} with tx: ${tx.transactionHash}`)*/

}
