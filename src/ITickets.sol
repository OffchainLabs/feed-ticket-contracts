// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @title  Tickets
/// @notice Sells and tracks feed tickets that grant holders access to a premium sequencer feed.
///         Up to a configurable cap of tickets are sold each round at a single price set by an
///         EIP-4844 style update rule. During a configurable grandfather phase at the start of
///         each round only previous-round ticket holders may purchase; afterwards anyone may
///         purchase. Tickets become active once the round in which they were purchased ends.
interface ITickets {
    error RoundDurationZero();
    error TargetTicketsPerRoundZero();
    error MaxTicketsPerRoundZero();
    error MinimumPriceZero();
    error PriceUpdateFractionZero();

    /// @notice Thrown when an initializer or `setGrandfatherPeriodFraction` is called with
    ///         `type(uint8).max`, which is reserved as the "no update queued" sentinel.
    error GrandfatherPeriodFractionReserved();

    /// @notice Thrown when `setPricingParams` is called with `type(uint56).max` for the `excessTicketsSoldOverride`,
    ///         which is reserved as the "no override queued" sentinel.
    error ExcessTicketsSoldOverrideReserved();

    /// @notice Thrown when `initialize` is given a `firstRoundStart` that is not strictly in the future.
    error FirstRoundStartNotInFuture();

    /// @notice Thrown when `purchaseTicket` is called with an `expectedRound` that does not
    ///         match the current round.
    /// @param  expected The round the caller passed as `expectedRound`.
    /// @param  actual   The contract's current round.
    error RoundNumberMismatch(uint256 expected, uint256 actual);

    /// @notice Thrown when `purchaseTicket` is called with an `expectedPrice` that does not equal
    ///         the current price.
    /// @param  expected The price the caller passed as `expectedPrice`.
    /// @param  actual   The contract's current price.
    error IncorrectTicketPrice(uint256 expected, uint256 actual);

    /// @notice Thrown when `purchaseTicket` would exceed `maxTicketsPerRound` for the current round.
    error MaxTicketsSold();

    /// @notice Thrown when `purchaseTicket` is called by an account that has already purchased a
    ///         ticket in the current round.
    error AlreadyPurchasedInRound();

    /// @notice Thrown when `purchaseTicket` or `withdrawToken` is called by an account whose
    ///         deposited token balance is less than the amount required.
    /// @param  balance  The caller's current deposited token balance.
    /// @param  required The amount required to complete the operation.
    error InsufficientTokenBalance(uint256 balance, uint256 required);

    /// @notice Thrown when `purchaseTicket` is called during the grandfather phase by an account
    ///         that did not hold a ticket from the previous round.
    error NotGrandfathered();

    /// @notice Thrown by `roundsElapsedSinceStored` (and views that depend on it) when called
    ///         before `firstRoundStart`.
    error BeforeFirstRoundStart();

    /// @notice Emitted when a ticket is purchased.
    /// @param  buyer The account that purchased the ticket.
    /// @param  round The round the ticket was purchased in.
    /// @param  apiKeyHash The hash of the API key associated with the ticket purchase.
    /// @param  price The price paid for the ticket.
    event TicketPurchased(address indexed buyer, uint256 indexed round, bytes32 indexed apiKeyHash, uint256 price);

    /// @notice Emitted when accumulated sale proceeds are forwarded to the beneficiary.
    /// @param  beneficiary The account that received the proceeds.
    /// @param  amount      The amount forwarded.
    event ProceedsDistributed(address indexed beneficiary, uint256 amount);

    /// @notice Emitted when an account deposits payment tokens to fund future ticket purchases.
    /// @param  depositor The account whose internal balance is credited.
    /// @param  amount    The amount of payment tokens transferred in.
    event TokensDeposited(address indexed depositor, uint256 amount);

    /// @notice Emitted when an account withdraws unused payment tokens from its internal balance.
    /// @param  withdrawer The account whose internal balance is debited.
    /// @param  amount     The amount of payment tokens transferred out.
    event TokensWithdrawn(address indexed withdrawer, uint256 amount);

    /// @notice Emitted when the beneficiary is updated. Takes effect immediately.
    /// @param  newBeneficiary The new account that will receive sale proceeds.
    event BeneficiarySet(address indexed newBeneficiary);

    /// @notice Emitted when a new round duration is queued. Takes effect next active round.
    /// @param  newDuration The duration of each round.
    event RoundDurationQueued(uint256 newDuration);

    /// @notice Emitted when a new max tickets per round is queued. Takes effect next active round.
    /// @param  newMax The maximum tickets that can be sold per round.
    event MaxTicketsPerRoundQueued(uint256 newMax);

    /// @notice Emitted when a new target tickets per round is queued. Takes effect next active round.
    /// @param  newTarget The targeted number of tickets to sell per round.
    event TargetTicketsPerRoundQueued(uint256 newTarget);

    /// @notice Emitted when new pricing parameters are queued. Takes effect next active round.
    /// @param  newMinimumPrice The minimum ticket price.
    /// @param  newPriceUpdateFraction The price update fraction.
    /// @param  newExcessTicketsSoldOverride The value to install as `excessTicketsSold` when the
    ///                                      queued pricing params are committed.
    event PricingParamsQueued(
        uint256 newMinimumPrice, uint256 newPriceUpdateFraction, uint256 newExcessTicketsSoldOverride
    );

    /// @notice Emitted when a new grandfather period fraction is queued. Takes effect next active round.
    /// @param  newFraction The new grandfather phase length as a fraction of 256 of the round.
    event GrandfatherPeriodFractionQueued(uint256 newFraction);

    /// @notice Emitted when stored round state is rolled forward by the lazy-update path.
    event RoundStateUpdated();

    /// @notice Purchase one ticket for the current round. `expectedPrice` is debited from the
    ///         caller's deposited token balance; the caller must have first funded that balance
    ///         via `depositToken`. During the grandfather phase at the start of a round, only
    ///         holders of a ticket from the previous round may purchase.
    /// @param  expectedRound Round the caller expects to be current. Reverts if it does not match.
    /// @param  expectedPrice Price the caller expects. Reverts if the current price does not equal this value.
    /// @param  apiKeyHash    The hash of the API key to associate with the ticket purchase.
    function purchaseTicket(uint256 expectedRound, uint256 expectedPrice, bytes32 apiKeyHash) external;

    /// @notice Forward accumulated sale proceeds (those already rolled over by a prior lazy
    ///         update) to the current beneficiary. Permissionless. Does not trigger lazy update,
    ///         so revenue from the in-flight round is not included until the next mutative call
    ///         (or an explicit `commitRoundState`) rolls the round over.
    function distributeSaleProceeds() external;

    /// @notice Roll stored round state forward and commit any queued admin updates. Permissionless.
    ///         No-op once the stored round matches the wall-clock round. Reverts with
    ///         `BeforeFirstRoundStart` if called before `firstRoundStart`.
    function commitRoundState() external;

    /// @notice Deposit payment tokens to the caller's internal balance to fund future ticket
    ///         purchases. The caller must have first approved this contract for at least `amount`.
    /// @param  amount Number of payment tokens to pull from the caller.
    function depositToken(uint256 amount) external;

    /// @notice Withdraw unused payment tokens from the caller's internal balance.
    /// @param  amount Number of payment tokens to return to the caller. Reverts with
    ///                `InsufficientTokenBalance` if greater than the caller's balance.
    function withdrawToken(uint256 amount) external;

    /// @notice ERC-20 payment token accepted for ticket purchases. Set at construction; immutable.
    function token() external view returns (address);

    /// @notice Internal payment-token balance of `account`, available to be spent on ticket
    ///         purchases or withdrawn via `withdrawToken`.
    /// @param  account The account whose balance to read.
    function tokenBalance(address account) external view returns (uint256);

    /// @notice Account that receives ticket sale proceeds.
    function beneficiary() external view returns (address);

    /// @notice Duration of a round, in seconds.
    /// @dev    Returns the queued value if one is queued and a round has elapsed, even before a
    ///         mutative call has committed it to storage. The contract's arithmetic keeps using
    ///         the stored value until that commit, so this view can diverge from the value in
    ///         effect until the next mutative call within the round.
    function roundDuration() external view returns (uint256);

    /// @notice Targeted number of tickets to sell per round. Drives the pricing function.
    /// @dev    Returns the queued value if one is queued and a round has elapsed, even before a
    ///         mutative call has committed it to storage. The contract's arithmetic keeps using
    ///         the stored value until that commit, so this view can diverge from the value in
    ///         effect until the next mutative call within the round.
    function targetTicketsPerRound() external view returns (uint256);

    /// @notice Hard cap on tickets sold per round.
    /// @dev    Returns the queued value if one is queued and a round has elapsed, even before a
    ///         mutative call has committed it to storage. The contract's arithmetic keeps using
    ///         the stored value until that commit, so this view can diverge from the value in
    ///         effect until the next mutative call within the round.
    function maxTicketsPerRound() external view returns (uint256);

    /// @notice Minimum ticket price. Floor of the pricing function.
    /// @dev    Returns the queued value if one is queued and a round has elapsed, even before a
    ///         mutative call has committed it to storage. The contract's arithmetic keeps using
    ///         the stored value until that commit, so this view can diverge from the value in
    ///         effect until the next mutative call within the round.
    function minimumPrice() external view returns (uint256);

    /// @notice Parameter controlling how quickly price moves per excess ticket sold.
    /// @dev    Returns the queued value if one is queued and a round has elapsed, even before a
    ///         mutative call has committed it to storage. The contract's arithmetic keeps using
    ///         the stored value until that commit, so this view can diverge from the value in
    ///         effect until the next mutative call within the round.
    function priceUpdateFraction() external view returns (uint256);

    /// @notice Length of the grandfather phase at the start of each round, as a fraction of 256
    ///         of the round duration. During the grandfather phase only holders of a ticket from
    ///         the previous round may purchase. e.g. 128 = first half of the round.
    /// @dev    Returns the queued value if one is queued and a round has elapsed, even before a
    ///         mutative call has committed it to storage. The contract's arithmetic keeps using
    ///         the stored value until that commit, so this view can diverge from the value in
    ///         effect until the next mutative call within the round.
    function grandfatherPeriodFraction() external view returns (uint256);

    /// @notice True iff at least one queued admin update has not yet been committed by lazy update.
    ///         Cleared on the first mutative call of a later round.
    function isAdminUpdateQueued() external view returns (bool);

    /// @notice Queued round duration. Takes effect next active round; zero if none queued.
    function nextRoundDuration() external view returns (uint24);

    /// @notice Queued target tickets per round. Takes effect next active round; zero if none queued.
    function nextTargetTicketsPerRound() external view returns (uint16);

    /// @notice Queued max tickets per round. Takes effect next active round; zero if none queued.
    function nextMaxTicketsPerRound() external view returns (uint16);

    /// @notice Queued minimum price. Takes effect next active round; zero if none queued.
    function nextMinimumPrice() external view returns (uint64);

    /// @notice Queued price update fraction. Takes effect next active round; zero if none queued.
    function nextPriceUpdateFraction() external view returns (uint40);

    /// @notice Queued grandfather period fraction. Takes effect next active round; `type(uint8).max`
    ///         if none queued (since 0 is a valid grandfather fraction meaning "no grandfather phase").
    function nextGrandfatherPeriodFraction() external view returns (uint8);

    /// @notice Queued override for `excessTicketsSold()`, applied together with the next pricing
    ///         params so the admin can keep `currentPrice` relatively stable across a pricing-param change.
    ///         Reads `type(uint56).max` (the "no override queued" sentinel) when no override is queued,
    ///         so that 0 is a valid override value.
    function excessTicketsSoldOverride() external view returns (uint56);

    /// @notice The round into which `user` is grandfathered based on their most recent ticket
    ///         purchase. Concretely, if the user's latest purchase was in round `R`, this returns
    ///         `R + 1` (the round in which they may purchase during the grandfather phase).
    ///         Returns 0 if the user has never purchased a ticket; the +1 encoding lets us
    ///         distinguish "never bought" from "bought in round 0".
    /// @param  user The account to check.
    function grandfatheredIntoRound(address user) external view returns (uint256);

    /// @notice Number of tickets sold in the current round.
    /// @dev    Returns 0 once a round has advanced past the stored round, because the next
    ///         mutative call resets `_ticketsSoldThisRound` before recording any new purchase.
    function ticketsSoldThisRound() external view returns (uint256);

    /// @notice Number of full rounds that have elapsed since the stored round start.
    function roundsElapsedSinceStored() external view returns (uint256);

    /// @notice Current round number. Tickets bought in `roundNumber() - 1` are active;
    ///         tickets bought in `roundNumber()` are still being sold.
    function roundNumber() external view returns (uint256);

    /// @notice Start timestamp of the current round (inclusive).
    function roundStart() external view returns (uint256);

    /// @notice End timestamp of the current round (exclusive).
    /// @dev    Composed from queued-update-aware views, so it reflects queued updates once a round
    ///         has elapsed. The contract's arithmetic keeps using stored values until a mutative
    ///         call commits them, so this view can diverge from the value in effect until the
    ///         next mutative call within the round.
    function roundEnd() external view returns (uint256);

    /// @notice End timestamp of the grandfather phase of the current round (exclusive). Before this
    ///         time only holders of a ticket from the previous round may purchase.
    /// @dev    Composed from queued-update-aware views, so it reflects queued updates once a round
    ///         has elapsed. The contract's arithmetic keeps using stored values until a mutative
    ///         call commits them, so this view can diverge from the value in effect until the
    ///         next mutative call within the round.
    function grandfatherPeriodEnd() external view returns (uint256);

    /// @notice Total tickets sold in excess of the cumulative target as of the end of last round.
    /// @dev    Within the active stored round (no rounds elapsed), returns the stored value directly.
    ///         Once a round has elapsed, this view returns either:
    ///         (a) `excessTicketsSoldOverride` if a pricing update is queued - lets the admin
    ///             avoid a price jump across the param change; or
    ///         (b) the stored value plus `_ticketsSoldThisRound`, minus elapsed
    ///             rounds' worth of target (saturated at zero).
    ///         The contract's arithmetic keeps using the stored value until a mutative call commits.
    function excessTicketsSold() external view returns (uint256);

    /// @notice Ticket price for the current round, in wei.
    /// @dev    The price is `fake_exponential(minimumPrice(), excessTicketsSold(), priceUpdateFraction())`
    ///         (EIP-4844 style), clamped at `type(uint72).max` (~4722e18). If the formula would
    ///         exceed that cap, this returns `type(uint72).max` and tickets are sold at the cap
    ///         rather than at the higher formula price.
    ///
    ///         Composed from queued-update-aware views, so it reflects queued updates once a round
    ///         has elapsed. The contract's arithmetic keeps using stored values until a mutative
    ///         call commits them, so this view can briefly diverge from the value in effect.
    function currentPrice() external view returns (uint256);

    /// @notice Set the account that receives sale proceeds. Takes effect immediately.
    /// @param  newBeneficiary The new beneficiary.
    function setBeneficiary(address newBeneficiary) external;

    /// @notice Queue a new round duration. Takes effect next active round.
    /// @param  newDuration The new duration of each round.
    ///                     Must be greater than zero, which is reserved as the
    ///                     "no update queued" sentinel and is an invalid value.
    function setRoundDuration(uint24 newDuration) external;

    /// @notice Queue a new hard cap on tickets sold per round. Takes effect next active round.
    /// @param  newMax The new max tickets per round.
    ///                Must be greater than zero, which is reserved as the
    ///                "no update queued" sentinel and is an invalid value.
    function setMaxTicketsPerRound(uint16 newMax) external;

    /// @notice Queue a new target tickets per round. Takes effect next active round.
    /// @param  newTarget The new target tickets per round.
    ///                   Must be greater than zero, which is reserved as the
    ///                   "no update queued" sentinel and is an invalid value.
    function setTargetTicketsPerRound(uint16 newTarget) external;

    /// @notice Queue new pricing parameters. Takes effect next active round.
    ///         May cause a discontinuous jump in the current price.
    ///         The resulting price after the update takes effect will be
    ///         `min(fake_exponential(newMinimumPrice, excessTicketsSoldOverride, newPriceUpdateFraction), type(uint72).max)`.
    /// @param  newMinimumPrice              The new minimum ticket price.
    ///                                      Must be greater than zero, which is reserved as the
    ///                                      "no update queued" sentinel and is an invalid value.
    /// @param  newPriceUpdateFraction       The new price update fraction.
    ///                                      Must be greater than zero, which is reserved as the
    ///                                      "no update queued" sentinel and is an invalid value.
    /// @param  newExcessTicketsSoldOverride The value to install as `excessTicketsSold` when the
    ///                                      queued pricing params are committed.
    ///                                      Must not equal `type(uint56).max`, which is reserved as
    ///                                      the "no override queued" sentinel.
    function setPricingParams(
        uint64 newMinimumPrice,
        uint40 newPriceUpdateFraction,
        uint56 newExcessTicketsSoldOverride
    ) external;

    /// @notice Queue a new grandfather period fraction. Takes effect next active round.
    /// @param  newFraction The new grandfather phase length as a fraction of 256 of the round.
    ///                     Must not equal `type(uint8).max`, which is reserved as the
    ///                     "no update queued" sentinel; pass 0 to disable the grandfather phase.
    function setGrandfatherPeriodFraction(uint8 newFraction) external;
}
