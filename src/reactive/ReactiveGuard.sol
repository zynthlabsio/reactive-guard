// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title ReactiveGuard (reactive contract, Reactive Lasna testnet)
/// @notice Watches `PriceUpdated` events from a PriceFeed on Base Sepolia.
///         The moment a price crosses the stop-loss or take-profit threshold,
///         it requests a callback that makes the StopLossVault on Base Sepolia
///         sell the whole guarded position — automatically, in seconds, with
///         no keeper bot and no user transaction.
/// @dev Track: "Every Second Counts" (Reactive Omni Buildathon).
///      Origin: Base Sepolia (84532). Reactive: Lasna (5318007).
///      Destination: Base Sepolia (84532).
///      The guard is one-shot per arming: after it fires it unsubscribes (so
///      it stops being billed) until the owner re-arms it.
contract ReactiveGuard is AbstractReactive {
    /// @notice Exit reasons, mirroring StopLossVault's encoding.
    uint8 public constant REASON_STOP_LOSS = 1;
    uint8 public constant REASON_TAKE_PROFIT = 2;

    /// @notice topic0 of PriceFeed.PriceUpdated(uint256,uint256).
    uint256 internal constant PRICE_UPDATED_TOPIC = uint256(keccak256("PriceUpdated(uint256,uint256)"));

    /// @notice Gas limit forwarded to the destination callback execution.
    uint64 internal constant CALLBACK_GAS_LIMIT = 1_000_000;

    address public owner;

    /// @notice Origin configuration (Base Sepolia PriceFeed).
    uint256 public immutable originChainId;
    address public immutable priceFeed;

    /// @notice Destination configuration (Base Sepolia StopLossVault).
    uint256 public immutable destinationChainId;
    address public recipient;

    /// @notice Guard thresholds: QUOTE per TOKEN, scaled by 1e18.
    uint256 public stopLossPrice;
    uint256 public takeProfitPrice;

    /// @notice True once the guard has fired, until re-armed.
    bool public triggered;
    /// @notice Last price seen from the feed.
    uint256 public lastPrice;
    /// @notice Lasna timestamp of the last reaction — the middle leg of the
    ///         end-to-end latency measurement.
    uint256 public lastReactAt;

    event RecipientSet(address indexed recipient);
    event GuardTriggered(uint8 indexed reason, uint256 price, uint256 originTimestamp);
    event Rearmed(uint256 stopLossPrice, uint256 takeProfitPrice);

    modifier onlyOwner() {
        require(msg.sender == owner, "ReactiveGuard: not owner");
        _;
    }

    /// @param originChainId_ Chain ID of the PriceFeed chain (Base Sepolia = 84532).
    /// @param priceFeed_ PriceFeed contract address on the origin chain.
    /// @param destinationChainId_ Chain ID of the vault chain (Base Sepolia = 84532).
    /// @param stopLossPrice_ Fire a stop-loss at or below this price (1e18-scaled).
    /// @param takeProfitPrice_ Fire a take-profit at or above this price (1e18-scaled).
    constructor(
        uint256 originChainId_,
        address priceFeed_,
        uint256 destinationChainId_,
        uint256 stopLossPrice_,
        uint256 takeProfitPrice_
    )
        payable
    {
        require(priceFeed_ != address(0), "ReactiveGuard: zero feed");
        require(stopLossPrice_ > 0, "ReactiveGuard: stop-loss must be positive");
        require(takeProfitPrice_ > stopLossPrice_, "ReactiveGuard: take-profit must exceed stop-loss");

        owner = msg.sender;
        originChainId = originChainId_;
        priceFeed = priceFeed_;
        destinationChainId = destinationChainId_;
        stopLossPrice = stopLossPrice_;
        takeProfitPrice = takeProfitPrice_;

        _subscribe();
    }

    /// @notice Set the destination vault. Per the official deployment order the
    ///         reactive contract is deployed first, the vault second (it needs
    ///         this contract's address immutably), then the recipient is set here.
    function setRecipient(address recipient_) external onlyOwner {
        require(recipient_ != address(0), "ReactiveGuard: zero recipient");
        recipient = recipient_;
        emit RecipientSet(recipient_);
    }

    /// @notice Re-arm the guard after it fired (or move the thresholds).
    ///         Settles any outstanding debt first — a contract in debt
    ///         receives nothing, per the official docs.
    function rearm(uint256 stopLossPrice_, uint256 takeProfitPrice_) external onlyOwner {
        require(stopLossPrice_ > 0, "ReactiveGuard: stop-loss must be positive");
        require(takeProfitPrice_ > stopLossPrice_, "ReactiveGuard: take-profit must exceed stop-loss");
        _coverDebt();
        stopLossPrice = stopLossPrice_;
        takeProfitPrice = takeProfitPrice_;
        if (triggered) {
            triggered = false;
            _subscribe();
        }
        emit Rearmed(stopLossPrice_, takeProfitPrice_);
    }

    /// @notice Settles outstanding debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @inheritdoc IReactive
    function react(LogRecord memory log_) external onlySystem {
        // Ignore anything that is not our feed's PriceUpdated event.
        if (log_.chainId != originChainId || log_.contractAddress != priceFeed || log_.topic0 != PRICE_UPDATED_TOPIC) {
            return;
        }
        if (triggered || recipient == address(0)) {
            return;
        }

        (uint256 price, uint256 originTimestamp) = abi.decode(log_.data, (uint256, uint256));
        lastPrice = price;
        lastReactAt = block.timestamp;

        uint8 reason = 0;
        if (price <= stopLossPrice) {
            reason = REASON_STOP_LOSS;
        } else if (price >= takeProfitPrice) {
            reason = REASON_TAKE_PROFIT;
        }
        if (reason == 0) {
            return;
        }

        // One-shot: latch and unsubscribe before requesting the callback, so a
        // burst of price updates can never fire the exit twice.
        triggered = true;
        _unsubscribe();

        emit GuardTriggered(reason, price, originTimestamp);
        _requestExitCallback(reason, price, originTimestamp);
    }

    function _requestExitCallback(uint8 reason_, uint256 price_, uint256 originTimestamp_) internal {
        // The first argument is reserved: Reactive Network overwrites it with
        // this contract's address so the vault can authenticate the callback.
        bytes memory payload = abi.encodeWithSignature(
            "executeExit(address,uint8,uint256,uint256)", address(0), reason_, price_, originTimestamp_
        );

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destinationChainId,
                recipient: recipient,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );
    }

    function _subscribe() internal {
        SYSTEM.subscribe(
            originChainId, priceFeed, PRICE_UPDATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    function _unsubscribe() internal {
        // Must match the subscription criteria exactly, per the official docs.
        SYSTEM.unsubscribe(
            originChainId, priceFeed, PRICE_UPDATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }
}
