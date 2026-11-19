// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockDex } from "./MockDex.sol";

/// @title StopLossVault (destination / callback contract, Base Sepolia)
/// @notice Holds users' TOKEN deposits for one guarded position. When the
///         ReactiveGuard on Lasna detects a stop-loss or take-profit breach it
///         requests a callback; Reactive Network delivers it through the Base
///         Sepolia callback proxy to `executeExit`, which sells the vault's
///         entire TOKEN balance on the MockDex in the same transaction.
///         No keeper, no bot, no user transaction at exit time.
/// @dev Authentication follows the official pattern: `onlyServiceProvider`
///      proves the call came through the callback proxy, and
///      `onlyCallbackSender(reactive_)` proves it originated from our
///      ReactiveGuard (the proxy injects its address as the first argument).
contract StopLossVault is AbstractCallback {
    /// @notice Exit reasons, mirroring ReactiveGuard's encoding.
    uint8 public constant REASON_STOP_LOSS = 1;
    uint8 public constant REASON_TAKE_PROFIT = 2;

    MockERC20 public immutable token;
    MockERC20 public immutable quote;
    MockDex public immutable dex;

    /// @notice Per-user TOKEN deposits (before exit).
    mapping(address => uint256) public deposits;
    uint256 public totalDeposits;

    /// @notice Exit state — written exactly once, by the callback.
    bool public exited;
    uint8 public exitReason;
    uint256 public exitTriggerPrice;
    uint256 public totalQuoteOut;
    /// @notice Destination-chain timestamp when the exit executed.
    uint256 public exitedAt;
    /// @notice End-to-end loop latency: destination execution timestamp minus
    ///         the origin event's timestamp, in seconds.
    uint256 public loopLatencySeconds;

    mapping(address => bool) public quoteWithdrawn;

    event Deposited(address indexed user, uint256 amount);
    event TokenWithdrawn(address indexed user, uint256 amount);
    event ExitExecuted(
        uint8 indexed reason, uint256 triggerPrice, uint256 tokenIn, uint256 quoteOut, uint256 loopLatencySeconds
    );
    event QuoteWithdrawn(address indexed user, uint256 amount);

    /// @param callbackProxy_ Base Sepolia callback proxy
    ///        (0x476F44b11F5C942c58f4c8E3d0300E5710743585).
    /// @param reactiveGuard_ Address of the ReactiveGuard on Lasna. Immutable —
    ///        a wrong value means redeploying, per the official docs.
    constructor(
        IPayable callbackProxy_,
        address reactiveGuard_,
        address token_,
        address quote_,
        address dex_
    )
        payable
        AbstractCallback(callbackProxy_, reactiveGuard_)
    {
        token = MockERC20(token_);
        quote = MockERC20(quote_);
        dex = MockDex(dex_);
    }

    /// @notice Deposit TOKEN into the guarded position.
    function deposit(uint256 amount_) external {
        require(!exited, "StopLossVault: position already exited");
        require(amount_ > 0, "StopLossVault: zero amount");
        require(token.transferFrom(msg.sender, address(this), amount_), "StopLossVault: deposit failed");
        deposits[msg.sender] += amount_;
        totalDeposits += amount_;
        emit Deposited(msg.sender, amount_);
    }

    /// @notice Withdraw TOKEN back out — only possible before the exit fires.
    function withdrawToken() external {
        require(!exited, "StopLossVault: position already exited");
        uint256 amount = deposits[msg.sender];
        require(amount > 0, "StopLossVault: nothing deposited");
        deposits[msg.sender] = 0;
        totalDeposits -= amount;
        require(token.transfer(msg.sender, amount), "StopLossVault: withdrawal failed");
        emit TokenWithdrawn(msg.sender, amount);
    }

    /// @notice The callback. Called by Reactive Network via the callback proxy
    ///         when the guard triggers. Sells the entire TOKEN balance.
    /// @param reactive_ Injected by the proxy: the ReactiveGuard's address.
    /// @param reason_ REASON_STOP_LOSS or REASON_TAKE_PROFIT.
    /// @param triggerPrice_ The price that breached the guard (QUOTE per TOKEN, 1e18-scaled).
    /// @param originTimestamp_ Timestamp of the origin PriceUpdated event, for latency measurement.
    function executeExit(address reactive_, uint8 reason_, uint256 triggerPrice_, uint256 originTimestamp_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        require(!exited, "StopLossVault: already exited");
        require(
            reason_ == REASON_STOP_LOSS || reason_ == REASON_TAKE_PROFIT, "StopLossVault: unknown reason"
        );
        exited = true;
        exitReason = reason_;
        exitTriggerPrice = triggerPrice_;
        exitedAt = block.timestamp;
        loopLatencySeconds = block.timestamp >= originTimestamp_ ? block.timestamp - originTimestamp_ : 0;

        uint256 tokenBalance = token.balanceOf(address(this));
        uint256 quoteOut = 0;
        if (tokenBalance > 0) {
            token.approve(address(dex), tokenBalance);
            quoteOut = dex.swapTokenForQuote(tokenBalance);
        }
        totalQuoteOut = quoteOut;

        emit ExitExecuted(reason_, triggerPrice_, tokenBalance, quoteOut, loopLatencySeconds);
    }

    /// @notice After the exit, withdraw your pro-rata share of the QUOTE proceeds.
    function withdrawQuote() external {
        require(exited, "StopLossVault: not exited yet");
        require(!quoteWithdrawn[msg.sender], "StopLossVault: already withdrawn");
        uint256 share = deposits[msg.sender];
        require(share > 0, "StopLossVault: nothing deposited");
        quoteWithdrawn[msg.sender] = true;
        uint256 amount = totalDeposits == 0 ? 0 : (totalQuoteOut * share) / totalDeposits;
        require(quote.transfer(msg.sender, amount), "StopLossVault: payout failed");
        emit QuoteWithdrawn(msg.sender, amount);
    }

    /// @notice Settles outstanding callback debt from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }
}
