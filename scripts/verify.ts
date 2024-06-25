const hardhat = require("hardhat");

async function main() {
    await hardhat.run("compile");
  
    await hardhat.run("verify:verify", {
      address: "0x0386c81eB83E6BbD8782A47180a1501CC003A232",
      contract: "contracts/vault/BeefyVaultConcLiq.sol:BeefyVaultConcLiq",
      constructorArguments: [],
    });
  }
  
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
  