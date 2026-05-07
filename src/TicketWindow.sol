// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

contract TicketWindow {
    modifier lazyUpdateRoundState() {
        if (roundsMissed() > 0) {
            uint256 __roundNumber = roundNumber();
            uint256 __roundStart = roundStart();
            uint256 __roundEnd = roundEnd();
            uint256 __excessTicketsSold = excessTicketsSold();
            _roundNumber = __roundNumber;
            _roundStart = __roundStart;
            _roundEnd = __roundEnd;
            _excessTicketsSold = __excessTicketsSold;

            emit RoundStateUpdated(...);
        }
        _;
    }

    function purchaseTicket(uint256 expectedRound) external payable lazyUpdateRoundState {
        require(expectedRound == _roundNumber, "Round number mismatch");
        require(msg.value == currentPrice(), "Incorrect ticket price");
        require(ticket.totalSupplyForRound(_roundNumber) < maxTicketsPerRound, "Max tickets sold for this round");

        ticket.mintForRound(msg.sender, _roundNumber);
        beneficiary.call{value: msg.value}("");

        emit TicketPurchased(...);
    }

    setBeneficiary(...) external onlyOwner lazyUpdateRoundState {...}
    setRoundDuration(...) external onlyOwner lazyUpdateRoundState {...}
    setTargetTicketsPerRound(...) external onlyOwner lazyUpdateRoundState {...}
    setMaxTicketsPerRound(...) external onlyOwner lazyUpdateRoundState {...}
    setMinimumPrice(...) external onlyOwner lazyUpdateRoundState {...}
    setPriceUpdateFraction(...) external onlyOwner lazyUpdateRoundState {...}
}
