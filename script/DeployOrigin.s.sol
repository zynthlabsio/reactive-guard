// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "@forge-std/Script.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { PriceFeed } from "../src/origin/PriceFeed.sol";
import { MockDex } from "../src/destination/MockDex.sol";

/// @notice STEP 1 — deploy the origin + market stack on Base Sepolia:
///         TOKEN, QUOTE, PriceFeed (origin contract) and MockDex (funded).
///         Run: see DEPLOY.md. Do NOT run with --broadcast until the
///         pre-deployment check has been done.
contract DeployOrigin is Script {
    function run() external {
        uint256 initialPrice = vm.envOr("INITIAL_PRICE", uint256(2_000e18));
        uint256 dexLiquidity = vm.envOr("DEX_QUOTE_LIQUIDITY", uint256(10_000_000e18));
        uint256 demoTokens = vm.envOr("DEMO_TOKENS", uint256(10_000e18));

        vm.startBroadcast();

        MockERC20 token = new MockERC20("Guarded Token", "TOKEN");
        MockERC20 quote = new MockERC20("Quote Dollar", "QUOTE");
        PriceFeed feed = new PriceFeed(initialPrice);
        MockDex dex = new MockDex(address(token), address(quote), address(feed));

        quote.mint(address(dex), dexLiquidity);
        token.mint(msg.sender, demoTokens); // demo position funds for the deployer

        vm.stopBroadcast();

        console.log("TOKEN     :", address(token));
        console.log("QUOTE     :", address(quote));
        console.log("PriceFeed :", address(feed));
        console.log("MockDex   :", address(dex));
    }
}
