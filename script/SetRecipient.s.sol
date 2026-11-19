// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "@forge-std/Script.sol";
import { ReactiveGuard } from "../src/reactive/ReactiveGuard.sol";

/// @notice STEP 4 — point ReactiveGuard (on Lasna) at the StopLossVault
///         deployed in step 3. Until this runs, the guard watches prices but
///         requests no callbacks.
///         Required env: REACTIVE_GUARD, VAULT.
///         Run: see DEPLOY.md. Do NOT run with --broadcast until the
///         pre-deployment check has been done.
contract SetRecipient is Script {
    function run() external {
        address guard = vm.envAddress("REACTIVE_GUARD");
        address vault = vm.envAddress("VAULT");

        vm.startBroadcast();
        ReactiveGuard(payable(guard)).setRecipient(vault);
        vm.stopBroadcast();

        console.log("Recipient set on ReactiveGuard:", guard);
        console.log("Vault:", vault);
    }
}
