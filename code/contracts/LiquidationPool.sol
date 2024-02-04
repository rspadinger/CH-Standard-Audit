// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol" as Chainlink;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "contracts/interfaces/IEUROs.sol";
import "contracts/interfaces/ILiquidationPool.sol";
import "contracts/interfaces/ILiquidationPoolManager.sol";
import "contracts/interfaces/ISmartVaultManager.sol";
import "contracts/interfaces/ITokenManager.sol";
import "hardhat/console.sol";

contract LiquidationPool is ILiquidationPool {
    using SafeERC20 for IERC20;

    address private immutable TST;
    address private immutable EUROs;
    address private immutable eurUsd;

    //big number of stakers
    address[] public holders;
    mapping(address => Position) public positions; //user => stake position
    mapping(bytes => uint256) private rewards; //token => amount
    PendingStake[] private pendingStakes;
    address payable public manager;
    address public tokenManager;

    struct Position {
        address holder;
        uint256 TST;
        uint256 EUROs;
        uint256 pendingEUROs;
        uint256 pendingTST;
        uint256 pendingStakeCreatedAt;
    }
    struct Reward {
        bytes32 symbol;
        uint256 amount;
        uint8 dec;
    }
    struct PendingStake {
        address holder;
        uint256 createdAt;
        uint256 TST;
        uint256 EUROs;
    }

    constructor(address _TST, address _EUROs, address _eurUsd, address _tokenManager) {
        TST = _TST;
        EUROs = _EUROs;
        eurUsd = _eurUsd;
        tokenManager = _tokenManager;
        manager = payable(msg.sender);
    }

    modifier onlyManager() {
        require(msg.sender == manager, "err-invalid-user");
        _;
    }

    // your stake is valued by the amount of the smaller asset i.e. 1000 TST + 0 EUROs = 0 stake; 100 TST + 2000 EUROs = 100 stake
    function stake(Position memory _position) public pure returns (uint256) {
        //to get max rewards, user should stake at 1:1 - is this intentional
        return _position.TST > _position.EUROs ? _position.EUROs : _position.TST;
    }

    function getStakeTotal() public view returns (uint256 _stakes) {
        for (uint256 i = 0; i < holders.length; i++) {
            Position memory _position = positions[holders[i]];
            _stakes += stake(_position);
        }
    }

    function getTstTotal() public view returns (uint256 _tst) {
        for (uint256 i = 0; i < holders.length; i++) {
            _tst += positions[holders[i]].TST;
        }
        for (uint256 i = 0; i < pendingStakes.length; i++) {
            _tst += pendingStakes[i].TST;
        }
    }

    function findRewards(address _holder) public view returns (Reward[] memory) {
        ITokenManager.Token[] memory _tokens = ITokenManager(tokenManager).getAcceptedTokens();
        Reward[] memory _rewards = new Reward[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            _rewards[i] = Reward(_tokens[i].symbol, rewards[abi.encodePacked(_holder, _tokens[i].symbol)], _tokens[i].dec);
        }
        return _rewards;
    }

    function holderPendingStakes(address _holder) public view returns (uint256 _pendingTST, uint256 _pendingEUROs) {
        for (uint256 i = 0; i < pendingStakes.length; i++) {
            PendingStake memory _pendingStake = pendingStakes[i];
            if (_pendingStake.holder == _holder) {
                _pendingTST += _pendingStake.TST;
                _pendingEUROs += _pendingStake.EUROs;
            }
        }
    }

    function position(address _holder) external view returns (Position memory _position, Reward[] memory _rewards) {
        _position = positions[_holder];
        (uint256 _pendingTST, uint256 _pendingEUROs) = holderPendingStakes(_holder);
        _position.EUROs += _pendingEUROs;
        _position.TST += _pendingTST;

        if (_position.TST > 0) _position.EUROs += (IERC20(EUROs).balanceOf(manager) * _position.TST) / getTstTotal();
        _rewards = findRewards(_holder);
    }

    function empty(Position memory _position) public pure returns (bool) {
        return _position.TST == 0 && _position.EUROs == 0;
    }

    //******************************************************************************************************************* */

    function deleteHolder(address _holder) private {
        for (uint256 i = 0; i < holders.length; i++) {
            if (holders[i] == _holder) {
                holders[i] = holders[holders.length - 1];
                holders.pop();
            }
        }
    }

    function deletePendingStake(uint256 _i) private {
        //use mapping => can we provide an i > arr.length => reverts with out of bounds
        for (uint256 i = _i; i < pendingStakes.length - 1; i++) {
            pendingStakes[i] = pendingStakes[i + 1];
        }
        pendingStakes.pop();
    }

    function addUniqueHolder(address _holder) private {
        for (uint256 i = 0; i < holders.length; i++) {
            if (holders[i] == _holder) return;
        }
        holders.push(_holder);
    }

    function consolidatePendingStakes() public {
        uint256 deadline = block.timestamp - 1 days;
        for (int256 i = 0; uint256(i) < pendingStakes.length; i++) {
            PendingStake memory _stake = pendingStakes[uint256(i)];
            if (_stake.createdAt < deadline) {
                positions[_stake.holder].holder = _stake.holder;
                positions[_stake.holder].TST += _stake.TST;
                positions[_stake.holder].EUROs += _stake.EUROs;
                deletePendingStake(uint256(i));
                i--;
            }
        }
    }

    uint256 private pendingStakingLimit = 1 days;

    function setPendingStakingLimit(uint256 _pendingStakingLimit) external onlyManager {
        pendingStakingLimit = _pendingStakingLimit;
    }

    //modified routine for consolidating the stake for a specific user
    function consolidatePendingStakesUser(address user) private {
        uint256 deadline = block.timestamp - 1 days;
        Position storage pos = positions[user];
        //verify if the user already has a staking position
        if (pos.holder != address(0)) {
            //the pendingTST, pendingEUROs and pendingStakeCreatedAt fields needs to be added to the Position struct
            if (pos.pendingStakeCreatedAt < deadline) {
                pos.TST += pos.pendingTST;
                pos.EUROs += pos.pendingEUROs;
                pos.pendingTST = 0;
                pos.pendingEUROs = 0;
            }
        }
    }

    function increasePosition(uint256 _tstVal, uint256 _eurosVal) external {
        require(_tstVal > 0 || _eurosVal > 0);
        consolidatePendingStakes();
        ILiquidationPoolManager(manager).distributeFees();
        if (_tstVal > 0) IERC20(TST).safeTransferFrom(msg.sender, address(this), _tstVal);
        if (_eurosVal > 0) IERC20(EUROs).safeTransferFrom(msg.sender, address(this), _eurosVal);
        pendingStakes.push(PendingStake(msg.sender, block.timestamp, _tstVal, _eurosVal));
        addUniqueHolder(msg.sender);
    }

    function increasePositionNew(uint256 _tstVal, uint256 _eurosVal) external {
        require(_tstVal > 0 || _eurosVal > 0);
        consolidatePendingStakesUser(msg.sender);

        ILiquidationPoolManager(manager).distributeFees();
        if (_tstVal > 0) IERC20(TST).safeTransferFrom(msg.sender, address(this), _tstVal);
        if (_eurosVal > 0) IERC20(EUROs).safeTransferFrom(msg.sender, address(this), _eurosVal);

        holders.push(msg.sender);

        Position storage pos = positions[msg.sender];
        //verify if the user already has a staking position
        if (pos.holder == address(0)) {
            pos.holder = msg.sender;
            holders.push(msg.sender);
        }

        pos.pendingEUROs = _eurosVal;
        pos.pendingTST = _tstVal;
    }

    function deletePosition(Position memory _position) private {
        deleteHolder(_position.holder);
        delete positions[_position.holder];
    }

    function decreasePosition(uint256 _tstVal, uint256 _eurosVal) external {
        consolidatePendingStakes();
        ILiquidationPoolManager(manager).distributeFees();

        require(_tstVal <= positions[msg.sender].TST && _eurosVal <= positions[msg.sender].EUROs, "invalid-decr-amount");
        if (_tstVal > 0) {
            console.log("Tst:", _tstVal);
            IERC20(TST).safeTransfer(msg.sender, _tstVal);
            positions[msg.sender].TST -= _tstVal;
        }
        if (_eurosVal > 0) {
            IERC20(EUROs).safeTransfer(msg.sender, _eurosVal);
            positions[msg.sender].EUROs -= _eurosVal;
        }
        if (empty(positions[msg.sender])) deletePosition(positions[msg.sender]);
    }

    function claimRewards() external {
        ITokenManager.Token[] memory _tokens = ITokenManager(tokenManager).getAcceptedTokens();
        for (uint256 i = 0; i < _tokens.length; i++) {
            ITokenManager.Token memory _token = _tokens[i];
            uint256 _rewardAmount = rewards[abi.encodePacked(msg.sender, _token.symbol)];
            if (_rewardAmount > 0) {
                delete rewards[abi.encodePacked(msg.sender, _token.symbol)];
                if (_token.addr == address(0)) {
                    (bool _sent, ) = payable(msg.sender).call{value: _rewardAmount}("");
                    require(_sent);
                } else {
                    IERC20(_token.addr).transfer(msg.sender, _rewardAmount);
                }
            }
        }
    }

    uint256 public nextHolderIndexForFees;
    bool public continueFeeDistribution;
    uint256 private constant MIN_GAS_AMOUNT = 200000;

    function distributeFeesNew(uint256 _amount) external onlyManager {
        uint256 tstTotal = getTstTotal(); //total stake of TST + pending

        if (tstTotal > 0) {
            IERC20(EUROs).safeTransferFrom(msg.sender, address(this), _amount);

            continueFeeDistribution = true;
            uint256 i = nextHolderIndexForFees;
            while (i < holders.length && gasleft() > MIN_GAS_AMOUNT) {
                address _holder = holders[i];
                if (positions[_holder].holder == address(0)) continue;
                positions[_holder].EUROs += (_amount * positions[_holder].TST) / tstTotal;
                positions[_holder].pendingEUROs += (_amount * positions[_holder].pendingTST) / tstTotal;
                i++;
            }

            nextHolderIndexForFees = i;
            if (i == holders.length - 1) {
                continueFeeDistribution = false;
                nextHolderIndexForFees = 0;
            }
        }
    }

    function distributeFees(uint256 _amount) external onlyManager {
        uint256 tstTotal = getTstTotal(); //total stake of TST + pending
        if (tstTotal > 0) {
            IERC20(EUROs).safeTransferFrom(msg.sender, address(this), _amount); //transfer EURO to this contract
            for (uint256 i = 0; i < holders.length; i++) {
                address _holder = holders[i];
                //((100 *  1e18 * 9999 * 1e18) / (1000000 * 1e18)  = 999900000000000000
                positions[_holder].EUROs += (_amount * positions[_holder].TST) / tstTotal;
            }
            for (uint256 i = 0; i < pendingStakes.length; i++) {
                pendingStakes[i].EUROs += (_amount * pendingStakes[i].TST) / tstTotal;
            }
        }
    }

    function returnUnpurchasedNative(ILiquidationPoolManager.Asset[] memory _assets, uint256 _nativePurchased) private {
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_assets[i].token.addr == address(0) && _assets[i].token.symbol != bytes32(0)) {
                //manager does not have the funds => they are with protocol
                (bool _sent, ) = manager.call{value: _assets[i].amount - _nativePurchased}("");
                require(_sent);
            }
        }
    }

    //@audit maybe we already have a problem with paxos fees in distributeAssets, if the liquidation pool does not receive the full expected transfer
    //assets from liquidations
    //ETH is forwarded directly from: LPM:runLiquidation
    function distributeAssets(ILiquidationPoolManager.Asset[] memory _assets, uint256 _collateralRate, uint256 _hundredPC) external payable {
        consolidatePendingStakes();
        //@audit oracle manip
        (, int256 priceEurUsd, , , ) = Chainlink.AggregatorV3Interface(eurUsd).latestRoundData();

        console.logInt(priceEurUsd);

        uint256 stakeTotal = getStakeTotal(); //???
        uint256 burnEuros;
        uint256 nativePurchased;

        //the involvement of the collateral rate is because liquidation pools give users a chance to buy assets at a under spot price
        //required smart vault collateral rate is 110% so users purchase liquidated assets at ~9% discount using their staked euros
        //collateralRate defaults to 120% (120000)

        for (uint256 j = 0; j < holders.length; j++) {
            Position memory _position = positions[holders[j]];
            uint256 _positionStake = stake(_position);
            if (_positionStake > 0) {
                for (uint256 i = 0; i < _assets.length; i++) {
                    ILiquidationPoolManager.Asset memory asset = _assets[i];
                    if (asset.amount > 0) {
                        //amount available after liquidation
                        (, int256 assetPriceUsd, , , ) = Chainlink.AggregatorV3Interface(asset.token.clAddr).latestRoundData();
                        console.logInt(assetPriceUsd);

                        // formula & div
                        uint256 _portion = (asset.amount * _positionStake) / stakeTotal;
                        console.log("port: ", _portion);
                        // myAssertPortionInEuros * _hundredPC / _collateralRate => get a slightly lower price than spot because of _collateralRate = 110%
                        uint256 costInEuros = (((_portion * 10 ** (18 - asset.token.dec) * uint256(assetPriceUsd)) / uint256(priceEurUsd)) * _hundredPC) / _collateralRate;
                        if (costInEuros > _position.EUROs) {
                            //adjust _portion & set costInEuros = _position.EUROs
                            _portion = (_portion * _position.EUROs) / costInEuros; //reduce amount of my portion
                            costInEuros = _position.EUROs;
                        }
                        //decrease my staked EURO pos in order to buy liquidated asset at 10% below spot price
                        _position.EUROs -= costInEuros;
                        rewards[abi.encodePacked(_position.holder, asset.token.symbol)] += _portion; //add to my rewards
                        burnEuros += costInEuros;
                        //native token
                        if (asset.token.addr == address(0)) {
                            nativePurchased += _portion;
                        } else {
                            //transfer from LP manager  => in SV, we transferred to SVM.protocol
                            IERC20(asset.token.addr).safeTransferFrom(manager, address(this), _portion);
                        }
                    }
                }
            }
            positions[holders[j]] = _position;
        }
        if (burnEuros > 0) IEUROs(EUROs).burn(address(this), burnEuros);

        //if there is not enough euros in the pool to purchase all of the liquidated assets, then some will be returned to the protocol
        returnUnpurchasedNative(_assets, nativePurchased);
    }

    uint256 public nextHolderIndexForAssets;
    bool public continueAssetDistribution;

    function distributeAssetsNew(ILiquidationPoolManager.Asset[] memory _assets, uint256 _collateralRate, uint256 _hundredPC) external payable onlyManager {
        consolidatePendingStakes();
        (, int256 priceEurUsd, , , ) = Chainlink.AggregatorV3Interface(eurUsd).latestRoundData();
        uint256 stakeTotal = getStakeTotal();
        uint256 burnEuros;
        uint256 nativePurchased;

        continueAssetDistribution = true;
        uint256 j = nextHolderIndexForAssets;
        while (j < holders.length && gasleft() > MIN_GAS_AMOUNT) {
            Position memory _position = positions[holders[j]];
            uint256 _positionStake = stake(_position);
            if (_positionStake > 0) {
                for (uint256 i = 0; i < _assets.length; i++) {
                    ILiquidationPoolManager.Asset memory asset = _assets[i];
                    if (asset.amount > 0) {
                        (, int256 assetPriceUsd, , , ) = Chainlink.AggregatorV3Interface(asset.token.clAddr).latestRoundData();
                        uint256 _portion = (asset.amount * _positionStake) / stakeTotal;
                        uint256 costInEuros = (((_portion * 10 ** (18 - asset.token.dec) * uint256(assetPriceUsd)) / uint256(priceEurUsd)) * _hundredPC) / _collateralRate;
                        if (costInEuros > _position.EUROs) {
                            _portion = (_portion * _position.EUROs) / costInEuros;
                            costInEuros = _position.EUROs;
                        }

                        _position.EUROs -= costInEuros;
                        rewards[abi.encodePacked(_position.holder, asset.token.symbol)] += _portion;
                        burnEuros += costInEuros;
                        if (asset.token.addr == address(0)) {
                            nativePurchased += _portion;
                        } else {
                            IERC20(asset.token.addr).safeTransferFrom(manager, address(this), _portion);
                        }
                    }
                }
            }
            positions[holders[j]] = _position;
            j++;
        }

        nextHolderIndexForAssets = j;
        if (j == holders.length - 1) {
            continueAssetDistribution = false;
            nextHolderIndexForAssets = 0;
        }

        if (burnEuros > 0) IEUROs(EUROs).burn(address(this), burnEuros);
        returnUnpurchasedNative(_assets, nativePurchased);
    }
}
