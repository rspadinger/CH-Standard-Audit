// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "contracts/LiquidationPool.sol";
import "contracts/interfaces/ILiquidationPoolManager.sol";
import "contracts/interfaces/ISmartVaultManager.sol";
//import "contracts/interfaces/ISmartVaultManagerV2.sol"; //###added
import "contracts/interfaces/ITokenManager.sol";
import "hardhat/console.sol";

contract LiquidationPoolManager is Ownable {
    uint32 public constant HUNDRED_PC = 100000;

    address private immutable TST;
    address private immutable EUROs;
    address public immutable smartVaultManager;
    address payable private immutable protocol; //EOA to pay devs
    address public immutable pool;

    uint32 public poolFeePercentage;

    constructor(address _TST, address _EUROs, address _smartVaultManager, address _eurUsd, address payable _protocol, uint32 _poolFeePercentage) {
        pool = address(new LiquidationPool(_TST, _EUROs, _eurUsd, ISmartVaultManager(_smartVaultManager).tokenManager()));
        TST = _TST;
        EUROs = _EUROs;
        smartVaultManager = _smartVaultManager;
        protocol = _protocol;
        poolFeePercentage = _poolFeePercentage;
    }

    receive() external payable {}

    function distributeFees() public {
        IERC20 eurosToken = IERC20(EUROs);
        //a percentage of the EURO balance will be distributed to stakers
        uint256 _feesForPool = (eurosToken.balanceOf(address(this)) * poolFeePercentage) / HUNDRED_PC;
        if (_feesForPool > 0) {
            eurosToken.approve(pool, _feesForPool);
            LiquidationPool(pool).distributeFees(_feesForPool); //here, EUROS are transferred
        }
        eurosToken.transfer(protocol, eurosToken.balanceOf(address(this))); //transfer the remaining balance out
    }

    //transfer to protocol EOA
    function forwardRemainingRewards(ITokenManager.Token[] memory _tokens) private {
        for (uint256 i = 0; i < _tokens.length; i++) {
            ITokenManager.Token memory _token = _tokens[i];
            if (_token.addr == address(0)) {
                uint256 balance = address(this).balance;
                if (balance > 0) {
                    (bool _sent, ) = protocol.call{value: balance}("");
                    require(_sent);
                }
            } else {
                uint256 balance = IERC20(_token.addr).balanceOf(address(this));
                if (balance > 0) IERC20(_token.addr).transfer(protocol, balance);
            }
        }
    }

    function runLiquidation(uint256 _tokenId) external {
        //console.log("nnnn", 1);
        ISmartVaultManager manager = ISmartVaultManager(smartVaultManager);
        // (uint minted, uint collat) = manager.vault1();
        // console.log("minted: ", minted);
        // console.log("collat: ", collat);
        //console.log("Man addr: ", address(manager));
        //console.log("Tot supply: ", manager.totalSupply());
        //@audit will not work because of onlyLiquidator modifier on liquidateVault
        manager.liquidateVault(_tokenId);
        distributeFees();

        ITokenManager.Token[] memory tokens = ITokenManager(manager.tokenManager()).getAcceptedTokens(); //liq. tokens
        ILiquidationPoolManager.Asset[] memory assets = new ILiquidationPoolManager.Asset[](tokens.length); //struct from liq. tokens
        uint256 ethBalance;

        for (uint256 i = 0; i < tokens.length; i++) {
            ITokenManager.Token memory token = tokens[i];
            if (token.addr == address(0)) {
                ethBalance = address(this).balance;
                if (ethBalance > 0) assets[i] = ILiquidationPoolManager.Asset(token, ethBalance);
            } else {
                IERC20 ierc20 = IERC20(token.addr);
                uint256 erc20balance = ierc20.balanceOf(address(this));
                if (erc20balance > 0) {
                    assets[i] = ILiquidationPoolManager.Asset(token, erc20balance);
                    ierc20.approve(pool, erc20balance);
                }
            }
        }
        //ETH sent directly to LP
        LiquidationPool(pool).distributeAssets{value: ethBalance}(assets, manager.collateralRate(), manager.HUNDRED_PC());
        forwardRemainingRewards(tokens);
    }

    function setPoolFeePercentage(uint32 _poolFeePercentage) external onlyOwner {
        poolFeePercentage = _poolFeePercentage;
    }

    // uint256 private pendingStakingDuration = 1 days;

    // function setPendingStakingDuration(uint256 _pendingStakingDuration) external onlyOwner {
    //     pendingStakingDuration = _pendingStakingDuration;
    // }

    // function consolidatePendingStakes() private {
    //     uint256 deadline = block.timestamp - pendingStakingDuration;
    //     // rest of the code
    // }
}
