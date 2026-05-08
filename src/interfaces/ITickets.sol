// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface ITickets {
    event TicketPurchased(address indexed buyer, uint256 indexed round, uint256 price);
    event BeneficiarySet(address indexed newBeneficiary);
    event RoundDurationSet(uint256 newDuration);
    event MaxTicketsPerRoundSet(uint256 newMax);
    event TargetTicketsPerRoundSet(uint256 newTarget);
    event PricingParamsSet(uint256 newMinimumPrice, uint256 newPriceUpdateFraction);
    event RoundStateUpdated(uint256 indexed roundNumber, uint256 roundStart, uint256 excessTicketsSold);

    function beneficiary() external view returns (address);
    function roundDuration() external view returns (uint256);
    function nextRoundDuration() external view returns (uint256);
    function targetTicketsPerRound() external view returns (uint256);
    function nextTargetTicketsPerRound() external view returns (uint256);
    function maxTicketsPerRound() external view returns (uint256);
    function nextMaxTicketsPerRound() external view returns (uint256);
    function minimumPrice() external view returns (uint256);
    function nextMinimumPrice() external view returns (uint256);
    function priceUpdateFraction() external view returns (uint256);
    function nextPriceUpdateFraction() external view returns (uint256);
    function hasTicket(address user, uint256 round) external view returns (bool);
    function ticketsSold(uint256 round) external view returns (uint256);

    function roundsElapsedSinceStored() external view returns (uint256);
    function roundNumber() external view returns (uint256);
    function roundStart() external view returns (uint256);
    function roundEnd() external view returns (uint256);
    function excessTicketsSold() external view returns (uint256);
    function currentPrice() external view returns (uint256);

    function purchaseTicket(uint256 expectedRound) external payable;
    function setBeneficiary(address newBeneficiary) external;
    function setRoundDuration(uint256 newDuration) external;
    function setMaxTicketsPerRound(uint256 newMax) external;
    function setTargetTicketsPerRound(uint256 newTarget) external;
    function setPricingParams(uint256 newMinimumPrice, uint256 newPriceUpdateFraction) external;
}
