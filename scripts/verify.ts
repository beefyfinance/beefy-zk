const hardhat = require("hardhat");

async function main() {
    await hardhat.run("compile");
  
    await hardhat.run("verify:verify", {
      address: "0x1E2D6370Ae2c466749EA710Ba90a22744CEbd697",
      constructorArguments: [21600, ["0xdAec0E93A98b6184816dFDA318B1A01EAF026164"],["0xdAec0E93A98b6184816dFDA318B1A01EAF026164","0x4fED5491693007f0CD49f4614FFC38Ab6A04B619"],"0x0000000000000000000000000000000000000000"],
    });
  
  }
  
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
  