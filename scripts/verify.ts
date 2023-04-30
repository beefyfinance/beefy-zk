const hardhat = require("hardhat");

async function main() {
    await hardhat.run("compile");
  
    await hardhat.run("verify:verify", {
      address: "0x3f02b129138377722FfE9d374B3F65fc7599475e",
      constructorArguments: ["0x46dbd39e26a56778d88507d7aEC6967108C0BD36","0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91"],
    });
  
  }
  
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
  