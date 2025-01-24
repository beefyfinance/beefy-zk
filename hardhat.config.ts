import "@matterlabs/hardhat-zksync-solc";
import "@matterlabs/hardhat-zksync-deploy";
import "@matterlabs/hardhat-zksync-verify";

module.exports = {
  zksolc: {
    version: "1.5.0",
    compilerSource: "binary",
    settings: {
      // compilerPath: "zksolc",  // optional. Ignored for compilerSource "docker". Can be used if compiler is located in a specific folder
      experimental: {
        dockerImage: "matterlabs/zksolc", // Deprecated! use, compilerSource: "binary"
        tag: "latest"   // Deprecated: used for compilerSource: "docker"
      },
      libraries:{}, // optional. References to non-inlinable libraries
      isSystem: false, // optional.  Enables Yul instructions available only for zkSync system contracts and libraries
      forceEvmla: false, // optional. Falls back to EVM legacy assembly if there is a bug with Yul
      optimizer: {
        enabled: true, // optional. True by default
        mode: 'z' // optional. 3 by default, z to optimize bytecode size
      } 
    }
  },
  networks: {
    mainnet: {
      url: "https://rpc.ankr.com/eth",
      chainId: 1,
    },
    zksync: {
      url: "https://mainnet.era.zksync.io", // The RPC URL of zkSync Era network.
      ethNetwork: "mainnet",
      chainId: 324,
      zksync: true,
      verifyURL: 'https://zksync2-mainnet-explorer.zksync.io/contract_verification'
    }
  },
  etherscan: {
    apiKey: {
      zksync: process.env.ZKSYNC_API_KEY!,
    }
  },
  customChains: [
    {
      network: "zksync",
      chainId: 324,
      urls: {
        apiURL: "https://api-era.zksync.network/api",
        browserURL: "https://era.zksync.network/",
      },
    },
  ],
  defaultNetwork: "zksync", // optional (if not set, use '--network zkTestnet')
  solidity: {
    compilers: [
      {
        version: "0.8.23",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          },
        },
      },
      {
        version: "0.8.19",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          },
        },
      },
      {
        version: "0.8.12",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          },
        },
      }
    ] 
  },
}