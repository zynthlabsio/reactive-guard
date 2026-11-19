// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "@forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { StopLossVault } from "../src/destination/StopLossVault.sol";
import { MockDex } from "../src/destination/MockDex.sol";
import { PriceFeed } from "../src/origin/PriceFeed.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockCallbackProxy } from "./mocks/MockCallbackProxy.sol";

contract StopLossVaultTest is Test {
    MockERC20 internal token;
    MockERC20 internal quote;
    PriceFeed internal feed;
    MockDex internal dex;
    MockCallbackProxy internal proxy;
    StopLossVault internal vault;

    address internal reactive = makeAddr("reactiveGuard");
    address internal impostor = makeAddr("impostor");
    address internal user = makeAddr("user");
    address internal user2 = makeAddr("user2");

    function setUp() public {
        token = new MockERC20("Guarded Token", "TOKEN");
        quote = new MockERC20("Quote Dollar", "QUOTE");
        feed = new PriceFeed(2_000e18);
        dex = new MockDex(address(token), address(quote), address(feed));
        quote.mint(address(dex), 10_000_000e18);

        proxy = new MockCallbackProxy();
        vault = new StopLossVault{ value: 1 ether }(
            IPayable(payable(address(proxy))), reactive, address(token), address(quote), address(dex)
        );

        token.mint(user, 1_000e18);
        token.mint(user2, 1_000e18);
    }

    function _deposit(address who_, uint256 amount_) internal {
        vm.startPrank(who_);
        token.approve(address(vault), amount_);
        vault.deposit(amount_);
        vm.stopPrank();
    }

    function test_DepositAccounting() public {
        _deposit(user, 100e18);
        _deposit(user2, 300e18);
        assertEq(vault.deposits(user), 100e18);
        assertEq(vault.totalDeposits(), 400e18);
        assertEq(token.balanceOf(address(vault)), 400e18);
    }

    function test_WithdrawTokenBeforeExit() public {
        _deposit(user, 100e18);
        vm.prank(user);
        vault.withdrawToken();
        assertEq(token.balanceOf(user), 1_000e18);
        assertEq(vault.totalDeposits(), 0);
    }

    function test_StopLossExitSwapsEverythingAndPaysOutProRata() public {
        _deposit(user, 100e18);
        _deposit(user2, 300e18);

        // Price falls to the trigger; the DEX prices the exit off the feed.
        feed.updatePrice(1_400e18);
        vm.warp(1_007);
        proxy.deliverExit(address(vault), reactive, vault.REASON_STOP_LOSS(), 1_400e18, 1_000);

        assertTrue(vault.exited());
        assertEq(vault.exitReason(), vault.REASON_STOP_LOSS());
        assertEq(vault.totalQuoteOut(), 400e18 * 1_400); // 400 TOKEN * 1,400 QUOTE
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.loopLatencySeconds(), 7);

        vm.prank(user);
        vault.withdrawQuote();
        assertEq(quote.balanceOf(user), 100e18 * 1_400);

        vm.prank(user2);
        vault.withdrawQuote();
        assertEq(quote.balanceOf(user2), 300e18 * 1_400);
    }

    function test_ExitRevertsForDirectCaller() public {
        uint8 reason = vault.REASON_STOP_LOSS();
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, user, address(proxy)));
        vault.executeExit(reactive, reason, 1_400e18, 1_000);
    }

    function test_ExitRevertsForWrongReactiveSender() public {
        uint8 reason = vault.REASON_STOP_LOSS();
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, impostor, reactive)
        );
        proxy.deliverExit(address(vault), impostor, reason, 1_400e18, 1_000);
    }

    function test_DoubleExitReverts() public {
        uint8 reason = vault.REASON_TAKE_PROFIT();
        _deposit(user, 10e18);
        proxy.deliverExit(address(vault), reactive, reason, 3_100e18, 1_000);
        vm.expectRevert("StopLossVault: already exited");
        proxy.deliverExit(address(vault), reactive, reason, 3_100e18, 1_001);
    }

    function test_WithdrawQuoteBeforeExitReverts() public {
        _deposit(user, 10e18);
        vm.prank(user);
        vm.expectRevert("StopLossVault: not exited yet");
        vault.withdrawQuote();
    }

    function test_DepositAfterExitReverts() public {
        proxy.deliverExit(address(vault), reactive, vault.REASON_STOP_LOSS(), 1_400e18, 1_000);
        vm.startPrank(user);
        token.approve(address(vault), 10e18);
        vm.expectRevert("StopLossVault: position already exited");
        vault.deposit(10e18);
        vm.stopPrank();
    }
}
