// SPDX-License-Identifier: MIT

// Layout of Contract (Style Guide):
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/*
 * @title Decentralized Stable Coin Engine
 * @author Inderdeep Singh
 * @notice The system is designed to be as minimal as possible, and have the tokens maintain the 1 to 1 USD peg
 * Properties :
 * 1. Exogenous Collateral
 * 2. Dollar Pegged
 * 3. Algorithmically Stable
 * The system should always be over-collateralized. The $ value of collateral should always be greater than value of DSC
 * @dev It is similar to DAI if DAI had no governance, no fees and was only backed by wETH and wBTC
 * @notice This contract is the core of the DSC system. It handles the logic for minting and redeeming DSC
 * @notice This contract oversees the depositing and withdrawal of collateral
 * @dev This contract is VERY loosely based on the MakerDAO DSS system
*/
contract DSCEngine is ReentrancyGuard{
      //////////////////////////////////
     //            ERRORS            //
    //////////////////////////////////
    error DSCEngine__RequiresNonZeroValue();
    error DSCEngine__DisallowedCollateralToken();
    error DSCEngine__TokensAndPriceFeedsInputNotValid();
    error DSCEngine__TransferFailed();
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorUnhealthy(uint256 healthFactor);
    error DSCEngine__HealthFactorHealthy(uint256 healthFactor);
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__EngineShouldBeApprovedSpenderOfDSC(uint256 amount);

      //////////////////////////////////
     //          STATE VARIABLES     //
    //////////////////////////////////
    uint256 private constant FEED_PRECISION_CORRECTION = 1e10;
    uint256 private constant PRECISION_CORRECTION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant LIQUIDATION_BONUS_PRECISION_CORRECTION = 100;
    mapping(address token => address priceFeeds) private s_priceFeeds;
    DecentralizedStableCoin private immutable i_dsc;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 dsc) private s_DSCMinted;
    address[] private s_collateralTokens;

      //////////////////////////////////
     //             EVENTS           //
    //////////////////////////////////
    event CollateralDeposited(address indexed depositor, address indexed collateralToken, uint256 amount);
    event CollateralRedeemed(address indexed redeemer, address indexed redeemedTo, address indexed collateralToken, uint256 amount);

      //////////////////////////////////
     //            MODIFIERS         //
    //////////////////////////////////
    modifier nonZero(uint256 _value) {
        if(_value == 0){
            revert DSCEngine__RequiresNonZeroValue();
        }
        _;
    }

    modifier onlyAllowedCollateral(address token) {
        if(s_priceFeeds[token] == address(0)){
            revert DSCEngine__DisallowedCollateralToken();
        }
        _;
    }

      //////////////////////////////////
     //            FUNCTIONS         //
    //////////////////////////////////
    constructor(address[] memory tokens, address[] memory priceFeeds, address dscAddress){
        if(tokens.length != priceFeeds.length){
            revert DSCEngine__TokensAndPriceFeedsInputNotValid();
        }
        for(uint256 i=0; i<tokens.length;i++){
            s_priceFeeds[tokens[i]] = priceFeeds[i];
            s_collateralTokens.push(tokens[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

      ///////////////////////////////////////
     //      EXTERNAL & PUBLIC FUNCTIONS  //
    ///////////////////////////////////////
    /*
     * @notice Follows the CEI pattern
     * @param collateralToken The address of the token to deposit as collateral
     * @param collateralAmount The amount of collateral to deposit */
    function depositCollateral(address collateralToken, uint256 collateralAmount) public nonZero(collateralAmount) onlyAllowedCollateral(collateralToken) nonReentrant{
        s_collateralDeposited[msg.sender][collateralToken] += collateralAmount;
        emit CollateralDeposited(msg.sender, collateralToken, collateralAmount);
        bool success = IERC20(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
     * @param _amount The amount of DSC to mint
     * @notice Follows the CEI pattern
     * @notice The user must have more collateral value in $$$ than the minimum threshold */
    function mintDsc(uint256 _amount) public nonZero(_amount) nonReentrant {
        s_DSCMinted[msg.sender] += _amount;
        _revertIfHealthFactorIsBroken(msg.sender);
        _revertIfNotEnoughAllowanceProvided(msg.sender, _amount);
        bool minted = i_dsc.mint(msg.sender, _amount);
        if (!minted){
            revert DSCEngine__MintFailed();
        }

    }

    /*
     * @notice Deposit Collateral and Mint DSC in one transaction
     * @param collateralToken The address of the token to deposit as collateral
     * @param collateralAmount The amount of collateral to deposit
     * @param amountDsc The amount of DSC to mint */
    function depositCollateralAndMintDsc(address collateralToken, uint256 collateralAmount, uint256 amountDsc) external {
        depositCollateral(collateralToken, collateralAmount);
        mintDsc(amountDsc);
    }

    /*
     * @param collateralToken The address of collateral to redeem/withdraw
     * @param collateralAmount The amount of collateral to redeem/withdraw */
    function redeemCollateral(address collateralToken, uint256 collateralAmount) public nonZero(collateralAmount) nonReentrant {
        _redeemCollateral(collateralToken, collateralAmount, msg.sender, msg.sender);
        // Only need to check the health factor if user has some dsc minted
        if (s_DSCMinted[msg.sender] != 0) {
            _revertIfHealthFactorIsBroken(msg.sender);
        }
    }

    /*
     * @param _amount The amount of DSC to burn */
    function burnDsc(uint256 _amount) nonZero(_amount) public {
        _burnDsc(msg.sender, msg.sender, _amount);
    }

    /*
     * @param collateralToken The address of collateral to redeem/withdraw
     * @param collateralAmount The amount of collateral to redeem/withdraw
     * @param collateralAmount The amount of DSC to burn
     * @notice This function burns DSC and redeems collateral in one transaction */
    function redeemCollateralForDsc(address collateralToken, uint256 collateralAmount, uint256 dscAmount) external{
        burnDsc(dscAmount);
        redeemCollateral(collateralToken, collateralAmount);
    }

    /*
     * @param collateralToken The address of collateral token to be liquidated
     * @param user The address of the user with broken healthFactor
     * @param debtToCover The amount of DSC to burn to improve the broke user's health factor
     * @notice You can partially liquidate a user
     * @notice You will get the liquidation bonus for exiting the user's open position
     * @notice This function works if the protocol is over-collateralized
     * @dev Follows Checks Effects Interactions (CEI) pattern */
    function liquidate(address collateralToken, address user, uint256 debtToCover) external nonZero(debtToCover) nonReentrant {
        // Check health factor of the user
        uint256 initialHealthFactor = _healthFactor(user);
        if(initialHealthFactor >= MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFactorHealthy(initialHealthFactor);
        }
        // Calculate the number of tokens to transfer from the amount of DSC sent (debtToCover) for liquidation request
        uint256 amountToken = getTokenAmountFromUSD(collateralToken, debtToCover);
        uint256 liquidationBonus = (amountToken * LIQUIDATION_BONUS) / LIQUIDATION_BONUS_PRECISION_CORRECTION;
        uint256 totalCollateral = amountToken + liquidationBonus;
        uint256 availableCollateral = s_collateralDeposited[user][collateralToken];
        if(totalCollateral > availableCollateral) {
            uint256 difference = totalCollateral - availableCollateral;
            totalCollateral -= difference;
        }
        _burnDsc(user, msg.sender, debtToCover);
        _redeemCollateral(collateralToken, totalCollateral, user, msg.sender);
        uint256 finalHealthFactor = _healthFactor(user);
        if(finalHealthFactor <= initialHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

      ////////////////////////////////////////////
     //      PRIVATE & INTERNAL FUNCTIONS      //
    ////////////////////////////////////////////
    /*
    /* @notice This function provides information for an account
     * */
    function _getAccountInformation(address _user) private view returns(uint256 totalDSCMinted, uint256 collateralValueUSD){
        totalDSCMinted = s_DSCMinted[_user];
        collateralValueUSD = getAccountCollateralValueInUSD(_user);
    }
    /*
     * @notice This function informs how close to liquidation a user is. If below 1; user can get liquidated
     * */
    function _healthFactor(address _user) private view returns(uint256) {
        (uint256 totalDscMinted, uint256 collateralValueUSD) = _getAccountInformation(_user);
        uint256 collateralAdjustedForThreshold = (collateralValueUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        uint256 healtFactor;
        if(totalDscMinted == 0){
            healtFactor = collateralAdjustedForThreshold;
        } else {
            healtFactor = (collateralAdjustedForThreshold / totalDscMinted) * PRECISION_CORRECTION;
        }
        return healtFactor;
    }

    function _revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 healthFactor = _healthFactor(_user);
        if(healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorUnhealthy(healthFactor);
        }
    }

    function _redeemCollateral(address token, uint256 _amount, address _from, address _to) private {
        s_collateralDeposited[_from][token] -= _amount;
        emit CollateralRedeemed(_from, _to, token, _amount);
        bool success = IERC20(token).transfer(_to, _amount);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDsc(address _onBehalfOf, address _from, uint256 _amount) private {
        s_DSCMinted[_onBehalfOf] -= _amount;
        bool success = i_dsc.transferFrom(_from, address(this), _amount);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(_amount);
    }

    function _revertIfNotEnoughAllowanceProvided(address _user, uint256 _amount) private view {
        uint256 initialBalance = s_DSCMinted[_user];
        uint256 approvedAmount = i_dsc.allowance(_user, address(this));
        if(approvedAmount < initialBalance+_amount){
            revert DSCEngine__EngineShouldBeApprovedSpenderOfDSC(initialBalance+_amount);
        }
    }

      /////////////////////////////////////////////
     //      PUBLIC & EXTERNAL "VIEW" FUNCTIONS //
    /////////////////////////////////////////////
    /*
     * @notice Fetches the USD value of all collateral tokens deposited by "_user" account */
    function getAccountCollateralValueInUSD(address _user) public view returns(uint256){
        uint256 valueInUSD;
        // loop through each collateral token and get the amount deposited by _user
        for(uint256 i=0;i<s_collateralTokens.length;i++){
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[_user][token];
            valueInUSD += getUSDValue(token, amount);
        }
        return valueInUSD;
    }

    /*
     * @notice Fetches the USD value for the given token and value
     * @dev Uses the Chainlink Price Feeds */
    function getUSDValue(address token, uint256 amount) public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * FEED_PRECISION_CORRECTION) * amount) / PRECISION_CORRECTION;
    }

    function getTokenAmountFromUSD(address token, uint256 usdAmount) public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmount * PRECISION_CORRECTION) / (uint256(price) * FEED_PRECISION_CORRECTION);
    }

    /*
    /* @notice This function provides information for an account
     * */
    function getAccountInformation(address _user) external view returns(uint256 totalDSCMinted, uint256 collateralValueUSD){
        return _getAccountInformation(_user);
    }

    /*
     * @notice This function informs how close to liquidation a user is. If below 1; user can get liquidated
     * */
    function getHealthFactor(address _user) external view returns(uint256) {
        return _healthFactor(_user);
    }

    function getCollateralTokens() external view returns(address[] memory){
        return s_collateralTokens;
    }

    function getTotalCollateralOfUser(address collateral, address user) external view returns(uint256){
        return s_collateralDeposited[collateral][user];
    }

}
