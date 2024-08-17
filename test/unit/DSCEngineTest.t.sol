// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
import "forge-std/console.sol";

contract DSCEngineTest is Test {
    DeployDSC public deployer;
    DSCEngine public engine;
    DecentralizedStableCoin public dsc;
    HelperConfig public config;
    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public constant ETHER_AMOUNT = 10 ether;
    uint256 public constant ETHER_AMOUNT_REDEEM = 9 ether;
    uint256 public constant STARTING_AMOUNT = 100 ether;
    uint256 public constant APPROVAL_AMOUNT = 1e25;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    uint256 public constant LIQUIDATION_PRECISION = 100;
    uint256 public constant PRECISION_CORRECTION = 1e18;
    int256 public constant UPDATED_ETH_USD_PRICE = 1500e8;
    address USR = makeAddr("user");

    function setUp() public{
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USR, STARTING_AMOUNT);
    }

    // PRICE TESTS
    function testGetUsdValue() public view{
        uint256 ethAmount = 20e18;
        uint256 expectedValue = 40000e18;
        uint256 actualValue = engine.getUSDValue(weth, ethAmount);
        assertEq(expectedValue, actualValue);
    }

    function testGetTokenAmountFromUSD() public view{
        uint256 usdAmount = 1000 ether;
        uint256 expectedAmount = 0.5 ether;
        uint256 actualAmount = engine.getTokenAmountFromUSD(weth, usdAmount);
        assertEq(expectedAmount, actualAmount);
    }

    // Collateral Tests
    function testRevertsIfCollateralZero() public {
        vm.startPrank(USR);
        ERC20Mock(weth).approve(address(engine), ETHER_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__RequiresNonZeroValue.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    // Constructor Tests
    address[] public tokens;
    address[] public priceFeeds;
    function testRevertsIfPriceFeedsLengthNotEqualTokenLength() public {
        tokens.push(weth);
        priceFeeds.push(ethUsdPriceFeed);
        priceFeeds.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__TokensAndPriceFeedsInputNotValid.selector);
        engine = new DSCEngine(tokens, priceFeeds, address(dsc));
    }

    function testDepositCollateralRevertsWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock("Random Token", "RNT", USR, STARTING_AMOUNT);
        vm.startPrank(USR);
        vm.expectRevert(DSCEngine.DSCEngine__DisallowedCollateralToken.selector);
        engine.depositCollateral(address(randomToken), STARTING_AMOUNT);
        vm.stopPrank();
    }

    modifier depositCollateral() {
        vm.startPrank(USR);
        ERC20Mock(weth).approve(address(engine), ETHER_AMOUNT);
        engine.depositCollateral(weth, ETHER_AMOUNT);
        vm.stopPrank();
        _;
    }

    modifier mintLimitedDsc() {
        (, uint256 collateralAmountUsd) = engine.getAccountInformation(USR);
        vm.startPrank(USR);
        dsc.approve(address(engine), APPROVAL_AMOUNT);
        engine.mintDsc(collateralAmountUsd/10);
        vm.stopPrank();
        _;
    }
    modifier mintEqualDsc() {
        uint256 allAmountThatCanBeMinted = engine.getHealthFactor(USR);
        vm.startPrank(USR);
        dsc.approve(address(engine), APPROVAL_AMOUNT);
        engine.mintDsc(allAmountThatCanBeMinted);
        vm.stopPrank();
        _;
    }

    function testDepositCollateralAndVerifyAccountInformation() public depositCollateral {
        (uint256 dscMinted, uint256 collateralActualAmountUsd) = engine.getAccountInformation(USR);
        uint256 expectedDsc = 0;
        uint256 expectedCollateralValue = engine.getUSDValue(address(weth), ETHER_AMOUNT);
        assertEq(dscMinted, expectedDsc);
        assertEq(collateralActualAmountUsd, expectedCollateralValue);
    }

    function testHealthFactorWhenNoDscMinted() public depositCollateral {
        (, uint256 collateralAmountUsd) = engine.getAccountInformation(USR);
        uint256 expectedHealthFactor = (collateralAmountUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        uint256 actualHealthFactor = engine.getHealthFactor(USR);
        assertEq(expectedHealthFactor, actualHealthFactor);
    }

    function testHealthFactorWhenDscMinted() public depositCollateral mintLimitedDsc {
        (uint256 mintedDsc, uint256 collateralAmountUsd) = engine.getAccountInformation(USR);
        uint256 expectedHealthFactor = (((collateralAmountUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION) / mintedDsc) * PRECISION_CORRECTION;
        uint256 actualHealthFactor = engine.getHealthFactor(USR);
        assertEq(expectedHealthFactor, actualHealthFactor);
    }

    function testHealthFactorIsOneWhenEqualDscMinted() public depositCollateral mintEqualDsc {
        (uint256 mintedDsc, uint256 collateralAmountUsd) = engine.getAccountInformation(USR);
        uint256 expectedHealthFactor = (((collateralAmountUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION) / mintedDsc)* PRECISION_CORRECTION;
        uint256 actualHealthFactor = engine.getHealthFactor(USR);
        assertEq(expectedHealthFactor, actualHealthFactor);
    }

    function testMintDscRevertsWithZeroValue() public depositCollateral {
        vm.prank(USR);
        vm.expectRevert(DSCEngine.DSCEngine__RequiresNonZeroValue.selector);
        engine.mintDsc(0);
    }

    function testDepositCollateralAndMintDsc() public {
        vm.startPrank(USR);
        ERC20Mock(weth).approve(address(engine), ETHER_AMOUNT);
        dsc.approve(address(engine), APPROVAL_AMOUNT);
        engine.depositCollateralAndMintDsc(address(weth), ETHER_AMOUNT, 9000 ether);
        vm.stopPrank();
        (uint256 mintedDsc, uint256 collateralAmountUsd) = engine.getAccountInformation(USR);
        assertEq(mintedDsc, 9000 ether);
        assertEq(collateralAmountUsd, 20000 ether);
    }

    function testRedeemCollateral() public depositCollateral {
        vm.startPrank(USR);
        engine.redeemCollateral(address(weth), ETHER_AMOUNT_REDEEM);
        vm.stopPrank();
    }

    function testRedeemCollateralRedeemsRightAmount() public depositCollateral {
        vm.prank(USR);
        engine.redeemCollateral(address(weth), ETHER_AMOUNT_REDEEM);
        uint256 userBalance = ERC20Mock(weth).balanceOf(USR);
        assertEq(userBalance, 99 ether);
    }

    function testRedeemCollateralRevertsIfWrongTokenRedeemed() public depositCollateral{
        vm.prank(USR);
        vm.expectRevert();
        engine.redeemCollateral(address(wbtc), ETHER_AMOUNT_REDEEM);
    }

    function testBurnDsc() public depositCollateral mintLimitedDsc {
        (uint256 mintedDsc,) = engine.getAccountInformation(USR);
        vm.prank(USR);
        engine.burnDsc(mintedDsc);
        (uint256 mintedDscFinal,) = engine.getAccountInformation(USR);
        assertEq(mintedDscFinal, 0);
        assertEq(dsc.balanceOf(USR), 0);
        assertEq(dsc.balanceOf(address(dsc)), 0);
    }

    function testRedeemCollateralForDsc() public depositCollateral mintEqualDsc {
        (uint256 mintedDsc,) = engine.getAccountInformation(USR);
        vm.startPrank(USR);
        engine.redeemCollateralForDsc(address(weth), ETHER_AMOUNT, mintedDsc);
        vm.stopPrank();
        (uint256 mintedDscFinal,) = engine.getAccountInformation(USR);
        assertEq(mintedDscFinal, 0);
        assertEq(dsc.balanceOf(USR), 0);
        assertEq(dsc.balanceOf(address(dsc)), 0);
    }

    function testLiquidate() public depositCollateral mintEqualDsc {
        // Arrange the liquidator with enough funds
        address liquidator = makeAddr("liquidator");
        ERC20Mock(weth).mint(liquidator, STARTING_AMOUNT);
        // Make the liquidator mint some DSC
        uint256 liquidatorCollateral = 90 ether;
        uint256 liquidatorDsc = 50000 ether;
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(engine), liquidatorCollateral);
        dsc.approve(address(engine), APPROVAL_AMOUNT);
        engine.depositCollateralAndMintDsc(address(weth), liquidatorCollateral, liquidatorDsc);
        vm.stopPrank();
        console.log("Liquidator Is Funded");
        // Change the price of ETH
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(UPDATED_ETH_USD_PRICE);
        console.log("PRICE of ETH changed !!");
        // Assertion 1: Health factor for USR should be broken
        uint256 healthFactor = engine.getHealthFactor(USR);
        assert(healthFactor < 1e18);
        // Prepare to liquidate the USR fully
        (uint256 mintedDsc,) = engine.getAccountInformation(USR);
        vm.startPrank(liquidator);
        engine.liquidate(address(weth), USR, mintedDsc);
        vm.stopPrank();
        // Assertion 2: Check if the right amount has been transferred
        (uint256 finalDsc, uint256 finalCollateralAmount) = engine.getAccountInformation(USR);
        console.log("DSC remaining: %s Collateral Remaining: %s",finalDsc, finalCollateralAmount);
    }
}