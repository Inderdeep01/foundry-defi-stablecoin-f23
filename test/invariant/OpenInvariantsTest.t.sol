// SPDX-License-Identifier:MIT
// What are our invariants ?
// 1. The total supply of DSC should be less than the total value of Collateral
// 2. Getter view functions should never revert - Evergreen Invariant

/*
 * @dev This is just an example of Open Invariant Tests

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OpenInvariantsTest is StdInvariant, Test {
    DeployDSC public deployer;
    DSCEngine public engine;
    DecentralizedStableCoin public dsc;
    HelperConfig public config = new HelperConfig();
    address public weth;
    address public wbtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (,,weth, wbtc,) = config.activeNetworkConfig();
        targetContract(address(engine));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalDsc = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));
        // get USD value
        uint256 wethValue = engine.getUSDValue(weth, totalWethDeposited);
        uint256 wbtcValue = engine.getUSDValue(wbtc, totalWbtcDeposited);

        assert(wethValue + wbtcValue >= totalDsc);
    }

}
*/