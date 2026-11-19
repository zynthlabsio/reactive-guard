// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "@forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { ReactiveGuard } from "../src/reactive/ReactiveGuard.sol";
import { StopLossVault } from "../src/destination/StopLossVault.sol";
import { MockDex } from "../src/destination/MockDex.sol";
import { PriceFeed } from "../src/origin/PriceFeed.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockSystemContract } from "./mocks/MockSystemContract.sol";
import { MockCallbackProxy } from "./mocks/MockCallbackProxy.sol";

/// @title End-to-end loop test
/// @notice Simulates the complete reactive loop locally, leg by leg, exactly as
///         it will run across Base Sepolia → Lasna → Base Sepolia:
///         1. PriceFeed emits PriceUpdated on the origin chain.
///         2. The system contract delivers the log to ReactiveGuard.react().
///         3. ReactiveGuard requests a callback via the system contract.
///         4. The callback proxy delivers the callback to StopLossVault,
///            injecting the guard's address as the first argument.
///         5. The vault exits the position on the MockDex; the user withdraws.
contract EndToEndTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant PRICE_TOPIC = uint256(keccak256("PriceUpdated(uint256,uint256)"));

    MockSystemContract internal sys;
    MockCallbackProxy internal proxy;
    PriceFeed internal feed;
    MockERC20 internal token;
    MockERC20 internal quote;
    MockDex internal dex;
    ReactiveGuard internal guard;
    StopLossVault internal vault;
    address internal user = makeAddr("user");

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));
        proxy = new MockCallbackProxy();

        // Origin + destination stack (Base Sepolia roles).
        feed = new PriceFeed(2_000e18);
        token = new MockERC20("Guarded Token", "TOKEN");
        quote = new MockERC20("Quote Dollar", "QUOTE");
        dex = new MockDex(address(token), address(quote), address(feed));
        quote.mint(address(dex), 10_000_000e18);

        // Reactive contract first (official deployment order)...
        guard = new ReactiveGuard{ value: 1 ether }(BASE_SEPOLIA, address(feed), BASE_SEPOLIA, 1_500e18, 3_000e18);
        // ...then the vault, which immutably authorizes the guard...
        vault = new StopLossVault{ value: 1 ether }(
            IPayable(payable(address(proxy))), address(guard), address(token), address(quote), address(dex)
        );
        // ...then the guard learns its recipient.
        guard.setRecipient(address(vault));

        token.mint(user, 1_000e18);
        vm.startPrank(user);
        token.approve(address(vault), 50e18);
        vault.deposit(50e18);
        vm.stopPrank();
    }

    function test_FullStopLossLoop() public {
        // Leg 1 — the price crashes on the origin chain.
        vm.warp(10_000);
        feed.updatePrice(1_450e18);

        // Leg 2 — the network delivers the log to the reactive contract.
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: address(feed),
            topic0: PRICE_TOPIC,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(1_450e18, block.timestamp),
            blockNumber: 42,
            opCode: 1,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        sys.deliverLog(address(guard), log_);

        // Leg 3 — exactly one callback was requested, addressed to the vault.
        assertEq(sys.callbackRequestCount(), 1);
        (uint256 chainId, address recipient,, bytes memory payload) = sys.callbackRequest(0);
        assertEq(chainId, BASE_SEPOLIA);
        assertEq(recipient, address(vault));

        bytes memory args = new bytes(payload.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = payload[i + 4];
        }
        (, uint8 reason, uint256 triggerPrice, uint256 originTs) =
            abi.decode(args, (address, uint8, uint256, uint256));
        assertEq(reason, vault.REASON_STOP_LOSS());
        assertEq(triggerPrice, 1_450e18);

        // Leg 4 — the proxy delivers the callback 6 seconds later, injecting
        // the guard's address as the first argument (as the real proxy does).
        vm.warp(10_006);
        proxy.deliverExit(address(vault), address(guard), reason, triggerPrice, originTs);

        // Leg 5 — the position is out, proceeds sit in the vault, latency recorded.
        assertTrue(vault.exited());
        assertEq(vault.totalQuoteOut(), 50e18 * 1_450);
        assertEq(vault.loopLatencySeconds(), 6);
        assertEq(token.balanceOf(address(vault)), 0);

        vm.prank(user);
        vault.withdrawQuote();
        assertEq(quote.balanceOf(user), 50e18 * 1_450);
    }

    function test_NoBreachNoExit() public {
        feed.updatePrice(1_900e18); // dips, but stays above the 1,500 stop-loss
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: address(feed),
            topic0: PRICE_TOPIC,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(1_900e18, block.timestamp),
            blockNumber: 42,
            opCode: 1,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        sys.deliverLog(address(guard), log_);
        assertEq(sys.callbackRequestCount(), 0);
        assertFalse(vault.exited());
    }
}
