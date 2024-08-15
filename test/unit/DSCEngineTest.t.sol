// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC public deployer;
    DSCEngine public engine;
    DecentralizedStableCoin public dsc;
    HelperConfig public config;
    address public ethUsdPriceFeed;
    address public weth;
    uint256 public constant ETHER_AMOUNT = 10 ether;
    uint256 public constant STARTING_AMOUNT = 100 ether;
    address USR = makeAddr("user");

    function setUp() public{
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, , weth, ,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USR, STARTING_AMOUNT);
    }

    // PRICE TESTS
    function testGetUsdValue() public view{
        uint256 ethAmount = 20e18;
        uint256 expectedValue = 40000e18;
        uint256 actualValue = engine.getUSDValue(weth, ethAmount);
        assertEq(expectedValue, actualValue);
    }

    // Collateral Tests
    function testRevertsIfCollateralZero() public {
        vm.startPrank(USR);
        ERC20Mock(weth).approve(address(engine), ETHER_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__RequiresNonZeroValue.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }
}