// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { MockERC20 } from "../mocks/MockERC20.sol";
import { PriceFeed } from "../origin/PriceFeed.sol";

/// @title MockDex (destination chain, Base Sepolia)
/// @notice A fixed-price mock swap venue: it exchanges TOKEN for QUOTE at
///         whatever price the PriceFeed currently reports. It stands in for a
///         real DEX pool so the stop-loss / take-profit exit is a genuine
///         on-chain swap with real token movements, while staying fully
///         deterministic on testnet. Pre-funded with QUOTE liquidity.
contract MockDex {
    MockERC20 public immutable token;
    MockERC20 public immutable quote;
    PriceFeed public immutable feed;

    event Swapped(address indexed trader, uint256 tokenIn, uint256 quoteOut, uint256 price);

    constructor(address token_, address quote_, address feed_) {
        token = MockERC20(token_);
        quote = MockERC20(quote_);
        feed = PriceFeed(feed_);
    }

    /// @notice Swap the caller's TOKEN for QUOTE at the feed's current price.
    /// @param amountIn_ Amount of TOKEN to sell.
    /// @return quoteOut Amount of QUOTE paid out (amountIn * price / 1e18).
    function swapTokenForQuote(uint256 amountIn_) external returns (uint256 quoteOut) {
        require(amountIn_ > 0, "MockDex: zero amount");
        uint256 price = feed.price();
        require(price > 0, "MockDex: no price");
        quoteOut = (amountIn_ * price) / 1e18;
        require(quote.balanceOf(address(this)) >= quoteOut, "MockDex: insufficient QUOTE liquidity");

        require(token.transferFrom(msg.sender, address(this), amountIn_), "MockDex: TOKEN pull failed");
        require(quote.transfer(msg.sender, quoteOut), "MockDex: QUOTE payout failed");

        emit Swapped(msg.sender, amountIn_, quoteOut, price);
    }
}
