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

      //////////////////////////////////
     //          STATE VARIABLES     //
    //////////////////////////////////
    uint256 private constant FEED_PRECISION_CORRECTION = 1e10;
    uint256 private constant PRECISION_CORRECTION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;
    mapping(address token => address priceFeeds) private s_priceFeeds;
    DecentralizedStableCoin private immutable i_dsc;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 dsc) private s_DSCMinted;
    address[] private s_collateralTokens;

      //////////////////////////////////
     //             EVENTS           //
    //////////////////////////////////
    event CollateralDeposited(address indexed depositor, address indexed collateralToken, uint256 amount);

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

      //////////////////////////////////
     //      EXTERNAL FUNCTIONS      //
    //////////////////////////////////
    /*
     * @notice Follows the CEI pattern
     * @param collateralToken The address of the token to deposit as collateral
     * @param collateralAmount The amount of collateral to deposit */
    function depositCollateral(address collateralToken, uint256 collateralAmount) external nonZero(collateralAmount) onlyAllowedCollateral(collateralToken) nonReentrant{
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
    function mintDsc(uint256 _amount) external nonZero(_amount) nonReentrant {
        s_DSCMinted[msg.sender] += _amount;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, _amount);
        if (!minted){
            revert DSCEngine__MintFailed();
        }
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
        return (collateralAdjustedForThreshold * PRECISION_CORRECTION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 healthFactor = _healthFactor(_user);
        if(healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorUnhealthy(healthFactor);
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
}
