// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "@forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { StopLossVault } from "../src/destination/StopLossVault.sol";

/// @notice STEP 3 — deploy StopLossVault on Base Sepolia. The vault immutably
///         authorizes the ReactiveGuard deployed in step 2, and pays for its
///         callbacks in Base Sepolia ETH, so it is funded at deployment.
///         Required env: REACTIVE_GUARD, TOKEN, QUOTE, DEX.
///         Optional env: FUND_ETH (default 0.05 ether).
///         Run: see DEPLOY.md. Do NOT run with --broadcast until the
///         pre-deployment check has been done.
contract DeployDestination is Script {
    /// @notice Base Sepolia callback proxy (official docs, Origins & Destinations).
    address internal constant BASE_SEPOLIA_CALLBACK_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    function run() external {
        address guard = vm.envAddress("REACTIVE_GUARD");
        address token = vm.envAddress("TOKEN");
        address quote = vm.envAddress("QUOTE");
        address dex = vm.envAddress("DEX");
        uint256 fund = vm.envOr("FUND_ETH", uint256(0.05 ether));

        vm.startBroadcast();
        StopLossVault vault = new StopLossVault{ value: fund }(
            IPayable(payable(BASE_SEPOLIA_CALLBACK_PROXY)), guard, token, quote, dex
        );
        vm.stopBroadcast();

        console.log("StopLossVault:", address(vault));
    }
}
