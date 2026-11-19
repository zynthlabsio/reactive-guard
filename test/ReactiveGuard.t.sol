// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "@forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { ReactiveGuard } from "../src/reactive/ReactiveGuard.sol";
import { PriceFeed } from "../src/origin/PriceFeed.sol";
import { MockSystemContract } from "./mocks/MockSystemContract.sol";

contract ReactiveGuardTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant PRICE_TOPIC = uint256(keccak256("PriceUpdated(uint256,uint256)"));

    MockSystemContract internal sys;
    PriceFeed internal feed;
    ReactiveGuard internal guard;
    address internal vault = makeAddr("vault");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));

        feed = new PriceFeed(2_000e18);
        guard = new ReactiveGuard{ value: 1 ether }(BASE_SEPOLIA, address(feed), BASE_SEPOLIA, 1_500e18, 3_000e18);
        guard.setRecipient(vault);
    }

    function _priceLog(uint256 price_, uint256 ts_) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: address(feed),
            topic0: PRICE_TOPIC,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(price_, ts_),
            blockNumber: 1,
            opCode: 1,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function test_SubscribesOnConstruction() public view {
        assertEq(sys.subscriptionCount(), 1);
        (address subscriber, uint256 chainId, address contractAddress, uint256 topic0,,,, bool active) =
            sys.subscriptions(0);
        assertEq(subscriber, address(guard));
        assertEq(chainId, BASE_SEPOLIA);
        assertEq(contractAddress, address(feed));
        assertEq(topic0, PRICE_TOPIC);
        assertTrue(active);
    }

    function test_ReactRevertsForNonSystemCaller() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, SYSTEM_ADDR)
        );
        guard.react(_priceLog(1_400e18, 1_000));
    }

    function test_PriceInsideBandRequestsNoCallback() public {
        sys.deliverLog(address(guard), _priceLog(2_100e18, 1_000));
        assertEq(sys.callbackRequestCount(), 0);
        assertFalse(guard.triggered());
        assertEq(guard.lastPrice(), 2_100e18);
    }

    function test_StopLossRequestsCallback() public {
        sys.deliverLog(address(guard), _priceLog(1_400e18, 1_234));

        assertTrue(guard.triggered());
        assertEq(sys.callbackRequestCount(), 1);

        (uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload) = sys.callbackRequest(0);
        assertEq(chainId, BASE_SEPOLIA);
        assertEq(recipient, vault);
        assertEq(gasLimit, 1_000_000);

        // Payload: executeExit(address,uint8,uint256,uint256), first arg is the
        // reserved placeholder the network overwrites with the guard's address.
        bytes4 selector = bytes4(payload);
        assertEq(selector, bytes4(keccak256("executeExit(address,uint8,uint256,uint256)")));
        bytes memory args = new bytes(payload.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = payload[i + 4];
        }
        (address placeholder, uint8 reason, uint256 price, uint256 originTs) =
            abi.decode(args, (address, uint8, uint256, uint256));
        assertEq(placeholder, address(0));
        assertEq(reason, guard.REASON_STOP_LOSS());
        assertEq(price, 1_400e18);
        assertEq(originTs, 1_234);
    }

    function test_TakeProfitRequestsCallback() public {
        sys.deliverLog(address(guard), _priceLog(3_200e18, 2_000));
        assertEq(sys.callbackRequestCount(), 1);
        (,,, bytes memory payload) = sys.callbackRequest(0);
        bytes memory args = new bytes(payload.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = payload[i + 4];
        }
        (, uint8 reason,,) = abi.decode(args, (address, uint8, uint256, uint256));
        assertEq(reason, guard.REASON_TAKE_PROFIT());
    }

    function test_OneShotSecondBreachRequestsNothing() public {
        sys.deliverLog(address(guard), _priceLog(1_400e18, 1_000));
        sys.deliverLog(address(guard), _priceLog(900e18, 1_005));
        assertEq(sys.callbackRequestCount(), 1);

        // The subscription was dropped when the guard fired.
        (,,,,,,, bool active) = sys.subscriptions(0);
        assertFalse(active);
    }

    function test_UnrelatedLogsAreIgnored() public {
        IReactive.LogRecord memory log_ = _priceLog(100e18, 1_000);
        log_.contractAddress = stranger; // some other contract's event
        sys.deliverLog(address(guard), log_);
        assertEq(sys.callbackRequestCount(), 0);
        assertEq(guard.lastPrice(), 0);
    }

    function test_RearmResubscribesAndRefires() public {
        sys.deliverLog(address(guard), _priceLog(1_400e18, 1_000));
        assertTrue(guard.triggered());

        guard.rearm(1_200e18, 2_800e18);
        assertFalse(guard.triggered());
        assertEq(sys.subscriptionCount(), 2);
        (,,,,,,, bool active) = sys.subscriptions(1);
        assertTrue(active);

        sys.deliverLog(address(guard), _priceLog(1_100e18, 2_000));
        assertEq(sys.callbackRequestCount(), 2);
    }

    function test_RearmRevertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert("ReactiveGuard: not owner");
        guard.rearm(1_200e18, 2_800e18);
    }

    function test_SetRecipientRevertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert("ReactiveGuard: not owner");
        guard.setRecipient(stranger);
    }
}
