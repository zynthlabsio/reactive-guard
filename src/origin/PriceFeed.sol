// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title PriceFeed (origin contract, Base Sepolia)
/// @notice A deliberately simple demo price oracle. Every price update emits
///         `PriceUpdated`, which is the origin event the reactive contract
///         subscribes to. On a production deployment this role would be played
///         by a real DEX pair or oracle; here a permissionless setter keeps the
///         demo reproducible by anyone in seconds.
/// @dev Price convention: QUOTE per 1 TOKEN, scaled by 1e18
///      (e.g. price = 2_000e18 means 1 TOKEN = 2,000 QUOTE).
contract PriceFeed {
    /// @notice The event the ReactiveGuard subscribes to.
    /// @param price New price, QUOTE per TOKEN scaled by 1e18.
    /// @param timestamp Origin-chain block timestamp when the price was set.
    ///        Carried through the whole reactive loop so the destination
    ///        contract can measure end-to-end loop latency.
    event PriceUpdated(uint256 price, uint256 timestamp);

    uint256 public price;
    uint256 public lastUpdateAt;

    constructor(uint256 initialPrice_) {
        price = initialPrice_;
        lastUpdateAt = block.timestamp;
    }

    /// @notice Push a new price and emit the origin event.
    /// @dev Permissionless on purpose: this is a testnet demo oracle so judges
    ///      and users can trigger the reactive loop themselves.
    function updatePrice(uint256 newPrice_) external {
        require(newPrice_ > 0, "PriceFeed: price must be positive");
        price = newPrice_;
        lastUpdateAt = block.timestamp;
        emit PriceUpdated(newPrice_, block.timestamp);
    }
}
