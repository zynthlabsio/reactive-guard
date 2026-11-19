// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";

/// @title MockSystemContract (test double)
/// @notice Stands in for the Reactive system contract at
///         0x8888888888888888888888888888888888888888 in local tests. Records
///         subscriptions and callback requests, and can deliver log records to
///         a reactive contract exactly the way the real system contract does
///         (as msg.sender). Tests etch this contract's code at the real
///         system address and drive it through that address.
contract MockSystemContract {
    struct Subscription {
        address subscriber;
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
        bool active;
    }

    Subscription[] public subscriptions;
    ISystemContract.CallbackConfiguration_V_1_0[] internal _callbackRequests;

    event Subscribed(address indexed subscriber, uint256 chainId, address contractAddress, uint256 topic0);
    event Unsubscribed(address indexed subscriber, uint256 chainId, address contractAddress, uint256 topic0);

    receive() external payable { }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    )
        external
    {
        subscriptions.push(
            Subscription({
                subscriber: msg.sender,
                chainId: chainId_,
                contractAddress: contract_,
                topic0: topic0_,
                topic1: topic1_,
                topic2: topic2_,
                topic3: topic3_,
                active: true
            })
        );
        emit Subscribed(msg.sender, chainId_, contract_, topic0_);
    }

    function unsubscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    )
        external
    {
        for (uint256 i = 0; i < subscriptions.length; i++) {
            Subscription storage s = subscriptions[i];
            if (
                s.active && s.subscriber == msg.sender && s.chainId == chainId_ && s.contractAddress == contract_
                    && s.topic0 == topic0_ && s.topic1 == topic1_ && s.topic2 == topic2_ && s.topic3 == topic3_
            ) {
                s.active = false;
            }
        }
        emit Unsubscribed(msg.sender, chainId_, contract_, topic0_);
    }

    function requestCallback(ISystemContract.CallbackVersion version_, bytes memory config_) external {
        require(version_ == ISystemContract.CallbackVersion.V_1_0, "MockSystem: bad version");
        _callbackRequests.push(abi.decode(config_, (ISystemContract.CallbackConfiguration_V_1_0)));
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        _callbackRequests.push(config_);
    }

    function callbackRequestCount() external view returns (uint256) {
        return _callbackRequests.length;
    }

    function callbackRequest(uint256 index_)
        external
        view
        returns (uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload)
    {
        ISystemContract.CallbackConfiguration_V_1_0 storage c = _callbackRequests[index_];
        return (c.chainId, c.recipient, c.gasLimit, c.payload);
    }

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    /// @notice Deliver a log record to a reactive contract, as the system contract.
    function deliverLog(address target_, IReactive.LogRecord memory log_) external {
        IReactive(payable(target_)).react(log_);
    }
}
