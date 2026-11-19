// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "@forge-std/Script.sol";
import { ReactiveGuard } from "../src/reactive/ReactiveGuard.sol";

/// @notice STEP 2 — deploy ReactiveGuard on Reactive Lasna testnet, funded
///         with lREACT (it pays for its own reactive transactions).
///         Required env: PRICE_FEED (from step 1).
///         Optional env: STOP_LOSS (default 1500e18), TAKE_PROFIT (default
///         3000e18), FUND_LREACT (default 5 ether of lREACT).
///         Run: see DEPLOY.md. Do NOT run with --broadcast until the
///         pre-deployment check has been done.
contract DeployReactive is Script {
    uint256 internal constant BASE_SEPOLIA = 84532;

    function run() external {
        address priceFeed = vm.envAddress("PRICE_FEED");
        uint256 stopLoss = vm.envOr("STOP_LOSS", uint256(1_500e18));
        uint256 takeProfit = vm.envOr("TAKE_PROFIT", uint256(3_000e18));
        uint256 fund = vm.envOr("FUND_LREACT", uint256(5 ether));

        vm.startBroadcast();
        ReactiveGuard guard = new ReactiveGuard{ value: fund }(BASE_SEPOLIA, priceFeed, BASE_SEPOLIA, stopLoss, takeProfit);
        vm.stopBroadcast();

        console.log("ReactiveGuard:", address(guard));
    }
}
