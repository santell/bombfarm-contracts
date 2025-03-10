const hardhat = require("hardhat");
const { addressBook } = require("blockchain-addressbook");

/**
 * Script used to deploy the basic infrastructure needed to run Beefy.
 */

const ethers = hardhat.ethers;

const TIMELOCK_ADMIN_ROLE = "0x5f58e3a2316349923ce3780f8d587db2d72378aed66a8261c916544fa6846ca5";
const STRAT_OWNER_DELAY = 21600;
const VAULT_OWNER_DELAY = 0;
const TRUSTED_EOA = "0x0D8e060CA2D847553ec14394ee6B304623E0d1d6";
const KEEPER = "0x0D8e060CA2D847553ec14394ee6B304623E0d1d6";
const chainName = "bsc";

const config = {
  bifi: null, // addressBook[chainName].tokens.BIFI.address,
  wnative: addressBook[chainName].tokens.WNATIVE.address,
  rpc: "https://bsc-dataseed.binance.org",
  chainName: "bsc",
  chainId: 56,
  devMultisig: null,
  treasuryMultisig: null,
  multicall: "0xEF958860Eeb4C2Eb8749a99AB4a24F75772d8B4F",
  vaultOwner: "0x0D8e060CA2D847553ec14394ee6B304623E0d1d6",
  stratOwner: "0x0D8e060CA2D847553ec14394ee6B304623E0d1d6",
  treasury: "0xf01e36CbDcA894C6F8b4A6Dcd882ab65C101448d",
  unirouterHasBifiLiquidity: false,
  unirouter: "0x10ED43C718714eb63d5aA57B78B54704E256024E",
};

const proposer = config.devMultisig || TRUSTED_EOA;
const timelockProposers = [proposer];
const timelockExecutors = [proposer, KEEPER];

const treasurer = config.treasuryMultisig || TRUSTED_EOA;

async function main() {
  await hardhat.run("compile");

  const deployer = await ethers.getSigner();

  const TimelockController = await ethers.getContractFactory("TimelockController");

  console.log("Checking if should deploy vault owner...");
  if (!config.vaultOwner) {
    console.log("Deploying vault owner.");
    let deployParams = [VAULT_OWNER_DELAY, timelockProposers, timelockExecutors];
    const vaultOwner = await TimelockController.deploy(...deployParams);
    await vaultOwner.deployed();
    await vaultOwner.renounceRole(TIMELOCK_ADMIN_ROLE, deployer.address);
    console.log(`Vault owner deployed to ${vaultOwner.address}`);
  } else {
    console.log(`Vault owner already deployed at ${config.vaultOwner}. Skipping...`);
  }

  console.log("Checking if should deploy strat owner...");
  if (!config.stratOwner) {
    console.log("Deploying strategy owner.");
    const stratOwner = await TimelockController.deploy(STRAT_OWNER_DELAY, timelockProposers, timelockExecutors);
    await stratOwner.deployed();
    await stratOwner.renounceRole(TIMELOCK_ADMIN_ROLE, deployer.address);
    console.log(`Strategy owner deployed to ${stratOwner.address}`);
  } else {
    console.log(`Strat owner already deployed at ${config.stratOwner}. Skipping...`);
  }

  console.log("Checking if should deploy treasury...");
  if (!config.treasury) {
    console.log("Deploying treasury.");
    const Treasury = await ethers.getContractFactory("BeefyTreasury");
    const treasury = await Treasury.deploy();
    await treasury.deployed();
    await treasury.transferOwnership(treasurer);
    console.log(`Treasury deployed to ${treasury.address}`);
  } else {
    console.log(`Treasury already deployed at ${config.treasury}. Skipping...`);
  }

  console.log("Checking if it should deploy a multicall contract...");
  if (!config.multicall) {
    console.log("Deploying multicall");
    const Multicall = await ethers.getContractFactory("Multicall");
    const multicall = await Multicall.deploy();
    await multicall.deployed();
    console.log(`Multicall deployed to ${multicall.address}`);
  } else {
    console.log(`There is already a multicall contract deployed at ${config.multicall}. Skipping.`);
  }

  console.log("Checking if it should deploy a Beefy reward pool...");
  if (!config.rewardPool && config.wnative && config.bifi) {
    console.log("Deploying reward pool.");
    const RewardPool = await ethers.getContractFactory("BeefyRewardPool");
    const rewardPool = await RewardPool.deploy(config.bifi, config.wnative);
    await rewardPool.deployed();
    console.log(`Reward pool deployed to ${rewardPool.address}`);
  } else {
    console.log("Skipping the beefy reward pool for now.");
  }

  console.log("Checking if it should deploy a fee batcher...");
  if (config.wnative && config.bifi) {
    console.log("Deploying fee batcher.");
    const provider = deployer.provider;
    const unirouterAddress = config.unirouterHasBifiLiquidity ? config.unirouter : ethers.constants.AddressZero;

    // How do we do a fee batcher without a reward pool?
    const BeefyFeeBatch = await ethers.getContractFactory("BeefyFeeBatchV2");
    const batcher = await upgrades.deployProxy(BeefyFeeBatch, [
      config.bifi,
      config.wnative,
      treasury.address,
      rewardPool.address,
      unirouterAddress,
    ]);
    await batcher.deployed();

    const implementationAddr = await getImplementationAddress(provider, batcher.address);

    console.log(`Deployed proxy at ${batcher.address}`);
    console.log(`Deployed implementation at ${implementationAddr}`);

    await rewardPool.transferOwnership(batcher.address);
  } else {
    console.log("Shouldn't deploy a fee batcher as some of the required elements are missing.");
  }
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
