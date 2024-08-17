// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

contract Handler is Test {
    DSCEngine public engine;
    DecentralizedStableCoin public dsc;
    ERC20Mock public weth;
    ERC20Mock public wbtc;

    uint256 public constant MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 public constant MAX_ALLOWANCE = type(uint256).max;

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;

        address[] memory tokens = engine.getCollateralTokens();
        weth = ERC20Mock(tokens[0]);
        wbtc = ERC20Mock(tokens[1]);
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        weth.approve(address(engine), MAX_ALLOWANCE);
        weth.mint(address(this), amountCollateral);
        wbtc.approve(address(engine), MAX_ALLOWANCE);
        wbtc.mint(address(this), amountCollateral);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        engine.depositCollateral(address(collateral), amountCollateral);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        if(amountCollateral == 0){
            return;
        }
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        dsc.approve(address(engine), MAX_ALLOWANCE);
        uint256 maxRedeemAmount = engine.getTotalCollateralOfUser(address(collateral), msg.sender);
        amountCollateral = bound(amountCollateral, 0, maxRedeemAmount);
        engine.depositCollateral(address(collateral), amountCollateral);
    }

    // Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns(ERC20Mock){
        if(collateralSeed % 2 == 0){
            return weth;
        } else {
            return wbtc;
        }
    }
}