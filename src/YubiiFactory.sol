// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MatchMarket} from "./MatchMarket.sol";

contract YubiiFactory is Ownable {
    address public immutable poolManager;
    address public immutable yubiiToken;
    address public immutable oracle;
    address public feeRecipient;

    address[] public markets;

    event MatchCreated(
        address indexed market,
        string teamA,
        string teamB,
        uint256 kickoffTime,
        uint256 initialLiquidity,
        uint256 marketIndex
    );

    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    error NoInitialLiquidity();

    constructor(
        address _poolManager,
        address _yubiiToken,
        address _oracle,
        address _feeRecipient,
        address _owner
    ) Ownable(_owner) {
        poolManager = _poolManager;
        yubiiToken = _yubiiToken;
        oracle = _oracle;
        feeRecipient = _feeRecipient;
    }

    function createMatch(string calldata teamA, string calldata teamB, uint256 kickoffTime)
        external
        payable
        onlyOwner
        returns (address market)
    {
        if (msg.value == 0) revert NoInitialLiquidity();

        MatchMarket m = new MatchMarket{value: msg.value}(
            poolManager,
            yubiiToken,
            feeRecipient,
            oracle,
            teamA,
            teamB,
            kickoffTime,
            owner()
        );

        m.initializeLiquidity();
        market = address(m);
        markets.push(market);

        emit MatchCreated(market, teamA, teamB, kickoffTime, msg.value, markets.length - 1);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function marketCount() external view returns (uint256) {
        return markets.length;
    }
}
