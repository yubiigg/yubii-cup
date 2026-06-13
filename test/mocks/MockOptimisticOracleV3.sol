// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOptimisticOracleV3CallbackRecipient} from "../../src/interfaces/IOptimisticOracleV3.sol";

contract MockOptimisticOracleV3 {
    struct Assertion {
        address callbackRecipient;
        bool resolved;
        bool result;
        bool active;
    }

    mapping(bytes32 => Assertion) public assertions;
    uint256 private _nonce;

    bytes32 public constant DEFAULT_IDENTIFIER = bytes32("ASSERT_TRUTH");

    function defaultIdentifier() external pure returns (bytes32) {
        return DEFAULT_IDENTIFIER;
    }

    function assertTruth(
        bytes memory, /* claim */
        address, /* asserter */
        address callbackRecipient,
        address, /* escalationManager */
        uint64, /* liveness */
        address, /* currency */
        uint256, /* bond */
        bytes32, /* identifier */
        bytes32 /* domainId */
    ) external returns (bytes32 assertionId) {
        assertionId = keccak256(abi.encodePacked(block.timestamp, _nonce++));
        assertions[assertionId] = Assertion({
            callbackRecipient: callbackRecipient,
            resolved: false,
            result: false,
            active: true
        });
    }

    function mockResolve(bytes32 assertionId, bool truthfully) external {
        Assertion storage a = assertions[assertionId];
        require(a.active, "Not active");
        a.resolved = true;
        a.result = truthfully;
        a.active = false;

        IOptimisticOracleV3CallbackRecipient(a.callbackRecipient)
            .assertionResolvedCallback(assertionId, truthfully);
    }

    function mockDispute(bytes32 assertionId) external {
        Assertion storage a = assertions[assertionId];
        require(a.active, "Not active");
        a.active = false;

        IOptimisticOracleV3CallbackRecipient(a.callbackRecipient)
            .assertionDisputedCallback(assertionId);
    }

    function settleAssertion(bytes32 assertionId) external {
        assertions[assertionId].resolved = true;
    }

    function getAssertionResult(bytes32 assertionId) external view returns (bool) {
        return assertions[assertionId].result;
    }

    function settleAndGetAssertionResult(bytes32 assertionId) external returns (bool) {
        assertions[assertionId].resolved = true;
        return assertions[assertionId].result;
    }
}
