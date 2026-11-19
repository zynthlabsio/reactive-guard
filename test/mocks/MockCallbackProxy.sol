// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { StopLossVault } from "../../src/destination/StopLossVault.sol";

/// @title MockCallbackProxy (test double)
/// @notice Stands in for the Base Sepolia callback proxy in local tests.
///         Delivers callbacks to the vault with itself as msg.sender, and —
///         exactly like the real proxy — overwrites the first payload argument
///         with the address of the reactive contract that requested the call.
contract MockCallbackProxy {
    receive() external payable { }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    /// @notice Simulate Reactive Network delivering an executeExit callback.
    function deliverExit(
        address vault_,
        address reactive_,
        uint8 reason_,
        uint256 triggerPrice_,
        uint256 originTimestamp_
    )
        external
    {
        StopLossVault(payable(vault_)).executeExit(reactive_, reason_, triggerPrice_, originTimestamp_);
    }
}
