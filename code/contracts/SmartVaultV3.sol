// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "contracts/interfaces/IEUROs.sol";
import "contracts/interfaces/IPriceCalculator.sol";
import "contracts/interfaces/ISmartVault.sol";
import "contracts/interfaces/ISmartVaultManagerV3.sol";
import "contracts/interfaces/ISwapRouter.sol";
import "contracts/interfaces/ITokenManager.sol";
import "contracts/interfaces/IWETH.sol";
import "hardhat/console.sol";

contract SmartVaultV3 is ISmartVault {
    using SafeERC20 for IERC20;

    string private constant INVALID_USER = "err-invalid-user";
    string private constant UNDER_COLL = "err-under-coll";
    uint8 private constant version = 2;
    bytes32 private constant vaultType = bytes32("EUROs");
    bytes32 private immutable NATIVE;
    address public immutable manager;
    IEUROs public immutable EUROs;
    IPriceCalculator public immutable calculator;

    address public owner;
    uint256 public minted;
    bool private liquidated;

    event CollateralRemoved(bytes32 symbol, uint256 amount, address to);
    event AssetRemoved(address token, uint256 amount, address to);
    event EUROsMinted(address to, uint256 amount, uint256 fee);
    event EUROsBurned(uint256 amount, uint256 fee);

    error TheVaultIsLiquidated();

    constructor(bytes32 _native, address _manager, address _owner, address _euros, address _priceCalculator) {
        NATIVE = _native;
        owner = _owner;
        manager = _manager;
        EUROs = IEUROs(_euros);
        calculator = IPriceCalculator(_priceCalculator);
    }

    modifier onlyVaultManager() {
        require(msg.sender == manager, INVALID_USER);
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, INVALID_USER);
        _;
    }

    modifier ifMinted(uint256 _amount) {
        require(minted >= _amount, "err-insuff-minted");
        _;
    }

    modifier ifNotLiquidated() {
        require(!liquidated, "err-liquidated");
        _;
    }

    function getTokenManager() private view returns (ITokenManager) {
        return ITokenManager(ISmartVaultManagerV3(manager).tokenManager());
    }

    function euroCollateral() public view returns (uint256 euros) {
        ITokenManager.Token[] memory acceptedTokens = getTokenManager().getAcceptedTokens();
        for (uint256 i = 0; i < acceptedTokens.length; i++) {
            ITokenManager.Token memory token = acceptedTokens[i];
            euros += calculator.tokenToEurAvg(token, getAssetBalance(token.symbol, token.addr));
        }
    }

    function maxMintable() public view returns (uint256) {
        // HUNDRED_PC = 1e5
        return (euroCollateral() * ISmartVaultManagerV3(manager).HUNDRED_PC()) / ISmartVaultManagerV3(manager).collateralRate();
    }

    function getAssetBalance(bytes32 _symbol, address _tokenAddress) public view returns (uint256 amount) {
        return _symbol == NATIVE ? address(this).balance : IERC20(_tokenAddress).balanceOf(address(this));
    }

    function getAssets() public view returns (Asset[] memory) {
        ITokenManager.Token[] memory acceptedTokens = getTokenManager().getAcceptedTokens();
        Asset[] memory assets = new Asset[](acceptedTokens.length);
        for (uint256 i = 0; i < acceptedTokens.length; i++) {
            ITokenManager.Token memory token = acceptedTokens[i];
            uint256 assetBalance = getAssetBalance(token.symbol, token.addr);
            assets[i] = Asset(token, assetBalance, calculator.tokenToEurAvg(token, assetBalance));
        }
        return assets;
    }

    function status() external view returns (Status memory) {
        return Status(address(this), minted, maxMintable(), euroCollateral(), getAssets(), liquidated, version, vaultType);
    }

    function undercollateralised() public view returns (bool) {
        return minted > maxMintable();
    }

    function liquidateNative() private {
        if (address(this).balance != 0) {
            //console.log("ETH: ", address(this).balance);
            //@audit why are funds sent to the protocol and not the liquidation pool => rather transfer funds to manager
            (bool sent, ) = payable(ISmartVaultManagerV3(manager).protocol()).call{value: address(this).balance}("");
            require(sent, "err-native-liquidate");
            //console.log("SVM address: ", manager);
            //console.log("SVM.Protocol address: ", ISmartVaultManagerV3(manager).protocol());
            //console.log("SVM ETH after: ", address(manager).balance);
        }
    }

    function liquidateERC20(IERC20 _token) private {
        //@audit why are funds sent to the protocol and not the liquidation pool manager => rather transfer funds to manager
        // => see: LP:distributeAssets () & LPM:forwardRemainingRewards : remaining tokens sent to protocol
        if (_token.balanceOf(address(this)) != 0) _token.safeTransfer(ISmartVaultManagerV3(manager).protocol(), _token.balanceOf(address(this)));
    }

    function liquidate() external onlyVaultManager {
        require(undercollateralised(), "err-not-liquidatable");
        liquidated = true;
        minted = 0;
        liquidateNative();
        ITokenManager.Token[] memory tokens = getTokenManager().getAcceptedTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i].symbol != NATIVE) liquidateERC20(IERC20(tokens[i].addr));
        }
    }

    receive() external payable {
        require(!liquidated, "the vault has been liquidated");
        //if (liquidated) revert TheVaultIsLiquidated();
    }

    function canRemoveCollateral(ITokenManager.Token memory _token, uint256 _amount) private view returns (bool) {
        if (minted == 0) return true;
        uint256 eurValueToRemove = calculator.tokenToEurAvg(_token, _amount);
        uint256 euroCollateral = euroCollateral();

        if (eurValueToRemove >= euroCollateral) return false;

        uint256 collateralEuroLeft = euroCollateral - eurValueToRemove;
        uint256 maxMintableWithCollateraleLeft = (collateralEuroLeft * ISmartVaultManagerV3(manager).HUNDRED_PC()) / ISmartVaultManagerV3(manager).collateralRate();

        return minted <= maxMintableWithCollateraleLeft;
    }

    function canRemoveCollateralOLD(ITokenManager.Token memory _token, uint256 _amount) private view returns (bool) {
        if (minted == 0) return true;
        uint256 currentMintable = maxMintable();
        uint256 eurValueToRemove = calculator.tokenToEurAvg(_token, _amount);
        return currentMintable >= eurValueToRemove && minted <= currentMintable - eurValueToRemove;
    }

    function removeCollateralNative(uint256 _amount, address payable _to) external onlyOwner {
        require(canRemoveCollateral(getTokenManager().getToken(NATIVE), _amount), UNDER_COLL);
        (bool sent, ) = _to.call{value: _amount}("");
        require(sent, "err-native-call");
        emit CollateralRemoved(NATIVE, _amount, _to);
    }

    function removeCollateral(bytes32 _symbol, uint256 _amount, address _to) external onlyOwner {
        ITokenManager.Token memory token = getTokenManager().getToken(_symbol);
        require(canRemoveCollateral(token, _amount), UNDER_COLL);
        IERC20(token.addr).safeTransfer(_to, _amount);
        emit CollateralRemoved(_symbol, _amount, _to);
    }

    function removeAsset(address _tokenAddr, uint256 _amount, address _to) external onlyOwner {
        ITokenManager.Token memory token = getTokenManager().getTokenIfExists(_tokenAddr);
        if (token.addr == _tokenAddr) require(canRemoveCollateral(token, _amount), UNDER_COLL);
        IERC20(_tokenAddr).safeTransfer(_to, _amount);
        emit AssetRemoved(_tokenAddr, _amount, _to);
    }

    function fullyCollateralised(uint256 _amount) private view returns (bool) {
        return minted + _amount <= maxMintable();
    }

    function mint(address _to, uint256 _amount) external onlyOwner ifNotLiquidated {
        uint256 fee = (_amount * ISmartVaultManagerV3(manager).mintFeeRate()) / ISmartVaultManagerV3(manager).HUNDRED_PC();
        //console.log("Fee: ", fee);

        require(fullyCollateralised(_amount + fee), UNDER_COLL);
        minted = minted + _amount + fee;
        EUROs.mint(_to, _amount);
        EUROs.mint(ISmartVaultManagerV3(manager).protocol(), fee);
        emit EUROsMinted(_to, _amount, fee);

        //console.log("Mint: ", minted);
    }

    function burn(uint256 _amount) external ifMinted(_amount) {
        uint256 fee = (_amount * ISmartVaultManagerV3(manager).burnFeeRate()) / ISmartVaultManagerV3(manager).HUNDRED_PC();
        minted = minted - _amount;
        EUROs.burn(msg.sender, _amount);
        IERC20(address(EUROs)).safeTransferFrom(msg.sender, ISmartVaultManagerV3(manager).protocol(), fee);
        emit EUROsBurned(_amount, fee);
    }

    function getToken(bytes32 _symbol) public view returns (ITokenManager.Token memory _token) {
        ITokenManager.Token[] memory tokens = getTokenManager().getAcceptedTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i].symbol == _symbol) _token = tokens[i];
        }
        require(_token.symbol != bytes32(0), "err-invalid-swap");
    }

    function getSwapAddressFor(bytes32 _symbol) private view returns (address) {
        ITokenManager.Token memory _token = getToken(_symbol);
        //console.log("Token: ", _token.);
        return _token.addr == address(0) ? ISmartVaultManagerV3(manager).weth() : _token.addr;
    }

    function executeNativeSwapAndFee(ISwapRouter.ExactInputSingleParams memory _params, uint256 _swapFee) private {
        (bool sent, ) = payable(ISmartVaultManagerV3(manager).protocol()).call{value: _swapFee}("");
        require(sent, "err-swap-fee-native");
        ISwapRouter(ISmartVaultManagerV3(manager).swapRouter2()).exactInputSingle{value: _params.amountIn}(_params);
        console.log("ok:", 1);
    }

    function executeERC20SwapAndFee(ISwapRouter.ExactInputSingleParams memory _params, uint256 _swapFee) private {
        IERC20(_params.tokenIn).safeTransfer(ISmartVaultManagerV3(manager).protocol(), _swapFee);
        IERC20(_params.tokenIn).safeApprove(ISmartVaultManagerV3(manager).swapRouter2(), _params.amountIn); //amount - swapFee

        //swap is done & dest token sent to this contract - user Vault
        ISwapRouter(ISmartVaultManagerV3(manager).swapRouter2()).exactInputSingle(_params);

        IWETH weth = IWETH(ISmartVaultManagerV3(manager).weth());
        // convert potentially received weth to eth
        uint256 wethBalance = weth.balanceOf(address(this));
        if (wethBalance > 0) weth.withdraw(wethBalance);
    }

    function calculateMinimumAmountOutOLD(
        bytes32 _inTokenSymbol,
        bytes32 _outTokenSymbol,
        uint256 _amount,
        uint256 _swapFee,
        uint256 _minAmountOutUser
    ) private view returns (uint256) {
        ISmartVaultManagerV3 _manager = ISmartVaultManagerV3(manager);
        uint256 requiredCollateralValue = (minted * _manager.collateralRate()) / _manager.HUNDRED_PC();
        uint256 collateralValueMinusSwapValue = euroCollateral() - calculator.tokenToEur(getToken(_inTokenSymbol), _amount);
        return
            collateralValueMinusSwapValue >= requiredCollateralValue
                ? 0
                : calculator.eurToToken(getToken(_outTokenSymbol), requiredCollateralValue - collateralValueMinusSwapValue);
    }

    //### this is probably wrong: delete the _swapFee argument & all occurences of _swapFee in the code
    function calculateMinimumAmountOut2(
        bytes32 _inTokenSymbol,
        bytes32 _outTokenSymbol,
        uint256 _amount,
        uint256 _swapFee,
        uint256 _minAmountOutUser
    ) private view returns (uint256) {
        ISmartVaultManagerV3 _manager = ISmartVaultManagerV3(manager);
        uint256 requiredCollateralValue = (minted * _manager.collateralRate()) / _manager.HUNDRED_PC(); //borrowed+fee * rate

        //take fee into account => see change of formula above => the rest can stay the same, but we
        //need to add the fee as arg to this function & from the calling function, we need to use amount - fee instead of amount
        uint256 collateralValueMinusSwapValueAndFee = euroCollateral() - calculator.tokenToEur(getToken(_inTokenSymbol), _amount - _swapFee) - _swapFee;

        if (collateralValueMinusSwapValueAndFee >= requiredCollateralValue) {
            return _minAmountOutUser;
        } else {
            uint256 calculatedMinOut = calculator.eurToToken(getToken(_outTokenSymbol), requiredCollateralValue - collateralValueMinusSwapValueAndFee);

            console.log("calculatedMinOut: ", calculatedMinOut);

            return calculatedMinOut >= _minAmountOutUser ? calculatedMinOut : _minAmountOutUser;
        }
    }

    function calculateMinimumAmountOut(bytes32 _inTokenSymbol, bytes32 _outTokenSymbol, uint256 _amount, uint256 _minAmountOutUser) private view returns (uint256) {
        ISmartVaultManagerV3 _manager = ISmartVaultManagerV3(manager);
        uint256 requiredCollateralValue = (minted * _manager.collateralRate()) / _manager.HUNDRED_PC();
        uint256 collateralValueMinusSwapValue = euroCollateral() - calculator.tokenToEur(getToken(_inTokenSymbol), _amount);

        if (collateralValueMinusSwapValue >= requiredCollateralValue) {
            return _minAmountOutUser;
        } else {
            uint256 calculatedMinOut = calculator.eurToToken(getToken(_outTokenSymbol), requiredCollateralValue - collateralValueMinusSwapValue);
            return calculatedMinOut >= _minAmountOutUser ? calculatedMinOut : _minAmountOutUser;
        }
    }

    function swap(bytes32 _inToken, bytes32 _outToken, uint256 _amount, uint256 _minAmountOutUser, uint24 uniswapFee) external onlyOwner {
        //require(_amount > 0, "err_swap_amount_0");
        uint256 swapFee = (_amount * ISmartVaultManagerV3(manager).swapFeeRate()) / ISmartVaultManagerV3(manager).HUNDRED_PC(); //in ETH
        console.log("SF:", swapFee);
        address inToken = getSwapAddressFor(_inToken);

        uint256 minimumAmountOut = calculateMinimumAmountOut(_inToken, _outToken, _amount, _minAmountOutUser);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: inToken,
            tokenOut: getSwapAddressFor(_outToken),
            fee: uniswapFee,
            recipient: address(this),
            deadline: block.timestamp + 1800,
            amountIn: _amount - swapFee,
            amountOutMinimum: minimumAmountOut,
            sqrtPriceLimitX96: 0
        });

        inToken == ISmartVaultManagerV3(manager).weth() ? executeNativeSwapAndFee(params, swapFee) : executeERC20SwapAndFee(params, swapFee);
    }

    function setOwner(address _newOwner) external onlyVaultManager {
        owner = _newOwner;
    }
}
