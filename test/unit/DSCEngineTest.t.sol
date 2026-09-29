//SPDX-License-Identifier:MIT

pragma solidity ^0.8.20;

import {test} from "forge-std/Test.sol";
import {DeployMSDT} from "../../script/DeployMSDT.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/Stablecoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";

contract DSCEngineTest is DeployMSDT, test {
    DecentralizedStableCoin msdt;
    DSCEngine dscEngine;
    DeployMSDT deployer;
    HelperConfig config;
    address ethUsdPriceFeed;
    address weth;

    function setup() public {
        deployer = new DeployMSDT();
        (msdt, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed, , weth, , ) = config.getActiveNetworkConfig();
    }

    //Price Tests

    function testGetUsdValue() public {
        uint256 amount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dscEngine.getUsdValue(weth, amount);
        assertEq(actualUsd, expectedUsd);
    }
}
