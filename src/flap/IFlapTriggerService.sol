// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @title IFlapTriggerService
/// @author The Flap Team
/// @notice Interface for a generic trigger service that allows smart contracts to schedule
///         function calls to be executed by a trusted backend at a specified time or immediately.
///
/// @dev  ── OVERVIEW ──────────────────────────────────────────────────────────────
///
/// The FlapTriggerService acts as a decentralized scheduler that enables smart
/// contracts to request delayed or immediate function callbacks. This is useful for:
///   • Time-delayed operations (vesting unlocks, periodic distributions, etc.)
///   • Backend-coordinated operations requiring MEV protection
///   • Operations that need external computation before execution
///
///
/// ── WORKFLOW ───────────────────────────────────────────────────────────────────
///
/// 1. **Requester prepares gas payment**
///    Call `getFee()` to determine the amount of native currency (BNB, ETH, etc.)
///    required to pay for the trigger execution.
///
/// 2. **Requester calls requestTrigger()**
///    The requester contract calls `requestTrigger()` with:
///      - `executeAfter`: Unix timestamp for when to execute (0 for immediate)
///      - `msg.value`: Must equal the required gas fee
///    The service records the request and emits a `FlapTriggerRequested` event.
///
/// 3. **Backend monitors events**
///    The off-chain backend listens for `FlapTriggerRequested` events and indexes all
///    pending trigger requests.
///
/// 4. **Backend executes trigger**
///    When the scheduled time arrives (or immediately for executeAfter=0), the backend:
///      - Constructs a transaction to call `trigger(requestId)`
///      - Sends it via an MEV-protected RPC endpoint (e.g., Flashbots, Eden, BloXroute)
///      - This ensures the trigger execution is protected from frontrunning
///
/// 5. **FlapTriggerService calls back**
///    The `trigger(requestId)` method on FlapTriggerService:
///      - Validates the caller has the TRIGGER_ROLE
///      - Marks the request as executed
///      - Calls `requester.trigger(requestId)` with a bounded gas limit
///      - Emits a `FlapTriggerExecuted` event with the outcome
///
/// 6. **Requester handles callback**
///    The requester's `trigger(requestId)` method is invoked. It should:
///      - Check that `msg.sender == address(FlapTriggerService)`
///      - Use the requestId to look up what action to perform
///      - Execute the intended logic within the gas limit
///
///
/// ── TIMING GUARANTEES ──────────────────────────────────────────────────────────
///
/// ⚠ IMPORTANT: Execution at `executeAfter` is NOT guaranteed. The service only
///   guarantees that execution will happen **after** `executeAfter`. Integrators
///   MUST assume that there can be an unpredictable delay between `executeAfter`
///   and the actual on-chain execution, caused by:
///     • Network congestion
///     • Backend processing latency
///     • Block inclusion delays
///     • MEV protection overhead
///
///   Requester contracts MUST be designed to handle late execution gracefully
///   and MUST NOT rely on execution happening at a precise time.
///
///
/// ── SECURITY CONSIDERATIONS ────────────────────────────────────────────────────
///
/// • **Access Control**: Only addresses with TRIGGER_ROLE can call `trigger()`.
///   This role should only be granted to the trusted backend operator(s).
///
/// • **Reentrancy**: Requester contracts MUST implement reentrancy guards in their
///   `trigger(uint256)` callback if they perform external calls or state changes
///   that could be exploited.
///
/// • **Gas Limit**: The maximum gas that can be forwarded to a requester's callback
///   is returned by `getMaxCallbackGas()`. Requesters must ensure their callback
///   logic fits within this limit.
///
/// • **MEV Protection**: The backend MUST use MEV-protected RPC endpoints when calling
///   `trigger()` to prevent frontrunning attacks.
///
/// • **Payment Validation**: The service MUST validate that `msg.value >= getRequiredGasFee()`
///   when `requestTrigger()` is called. Excess payment is accumulated as protocol fees.
///
///
/// ── REQUESTER IMPLEMENTATION GUIDE ─────────────────────────────────────────────
///
/// To integrate with FlapTriggerService, your contract should:
///
/// 1. Store a reference to the FlapTriggerService address
/// 2. Implement a `trigger(uint256 requestId)` function with access control:
///
///    ```solidity
///    address public immutable triggerService;
///
///    mapping(uint256 => bytes) private triggerData;
///
///    function trigger(uint256 requestId) external {
///        require(msg.sender == triggerService, "Only trigger service");
///
///        // Your logic here - use requestId to determine what to do
///        // NOTE: Always assume execution may happen well after executeAfter.
///        bytes memory data = triggerData[requestId];
///        // ... execute the scheduled operation ...
///
///        delete triggerData[requestId]; // Clean up
///    }
///    ```
///
/// 3. When you need a trigger, prepare the payment and call requestTrigger():
///
///    ```solidity
///    function scheduleOperation(uint256 executeAfter) external {
///        uint256 requestId = IFlapTriggerService(triggerService)
///            .requestTrigger{value: requiredFee}(executeAfter);
///
///        triggerData[requestId] = abi.encode(/* your data */);
///    }
///    ```
///
interface IFlapTriggerService {
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════
    // ENUMS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice The execution status of a trigger request
    /// @dev Used to track the lifecycle of each request. Stored as 8 bits within TriggerRequest.
    enum TriggerStatus {
        PENDING, // 0 - Request created, waiting to be executed
        EXECUTED, // 1 - Successfully executed by the backend
        FAILED // 2 - Execution attempted but the callback reverted

    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Information about a trigger request, packed into two 32-byte storage slots.
    /// @dev Slot 0 bit layout (256 bits total, Solidity packs right-to-left):
    ///        [  7:  0] status    — TriggerStatus (8 bits)
    ///        [ 71:  8] executeAfter — Unix timestamp (64 bits)
    ///        [231: 72] requester — requester address (160 bits)
    ///        [255:232] (24 bits unused — reserved for future fields without breaking the slot)
    ///      Slot 1:
    ///        [127:  0] feePaid   — fee amount (128 bits)
    ///
    /// @param requester  The address of the contract that requested the trigger (160 bits).
    /// @param executeAfter  Unix timestamp (in seconds) after which this trigger may be executed.
    ///                   A value of 0 indicates immediate execution.
    ///                   ⚠ Execution is NOT guaranteed to happen exactly at this time — it will
    ///                   only happen **after** this time. Integrators must always assume there
    ///                   can be an unpredictable delay between `executeAfter` and actual execution.
    /// @param status     The current execution status of this request (8 bits).
    /// @param feePaid    The native-currency fee (in wei) paid by the requester (128 bits).
    struct TriggerRequest {
        address requester; // 160 bits
        uint64 executeAfter; // 64 bits
        TriggerStatus status; // 8 bits
        // total slot 0: 232 bits
        uint128 feePaid; // 128 bits — slot 1
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a new trigger request is created.
    /// @param requestId    The unique identifier for this trigger request (auto-incremented).
    /// @param requester    The address of the contract that made the request.
    /// @param executeAfter    The Unix timestamp after which execution is scheduled (0 for immediate).
    ///                     Execution is NOT guaranteed at this exact time — it will happen only
    ///                     **after** this timestamp. Unpredictable delays must be assumed.
    /// @param gasFeesPaid  The amount of native currency paid for gas fees (in wei).
    event FlapTriggerRequested(uint256 requestId, address indexed requester, uint64 executeAfter, uint256 gasFeesPaid);

    /// @notice Emitted when a trigger execution is attempted by the backend (success or failure).
    /// @dev    Both successful and failed executions emit this single event. Inspect `success`
    ///         to distinguish outcomes, and `data` for the revert reason on failure.
    /// @param requestId  The unique identifier of the trigger request.
    /// @param success    True if the requester's callback returned without reverting; false otherwise.
    /// @param data       On success: any return data from the callback (may be empty).
    ///                   On failure: the raw revert data returned by the callback.
    event FlapTriggerExecuted(uint256 requestId, bool success, bytes data);

    /// @notice Emitted when a trigger execution is skipped inside triggerMultiple() due to
    ///         an invalid request ID, non-PENDING status, or the request not yet being due.
    ///         Also emitted inside trigger() (single) when validation fails, instead of reverting.
    /// @param requestId  The unique identifier of the skipped trigger request.
    /// @param reason     A short human-readable description of why the request was skipped.
    event FlapTriggerSkipped(uint256 requestId, string reason);

    /// @notice Emitted when the required gas fee is updated by admin.
    /// @param oldFee  The previous gas fee amount (in wei).
    /// @param newFee  The new gas fee amount (in wei).
    event FlapTriggerGasFeeUpdated(uint256 oldFee, uint256 newFee);

    /// @notice Emitted when the maximum callback gas limit is updated by admin.
    /// @param oldLimit  The previous gas limit.
    /// @param newLimit  The new gas limit.
    event FlapTriggerMaxCallbackGasUpdated(uint256 oldLimit, uint256 newLimit);

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Thrown when the gas fee payment is insufficient.
    /// @param required  The required gas fee amount.
    /// @param provided  The amount actually provided.
    error InsufficientGasFee(uint256 required, uint256 provided);

    /// @notice Thrown when attempting to execute a request that is not in PENDING status.
    /// @param requestId      The ID of the request.
    /// @param currentStatus  The current status of the request.
    error InvalidRequestStatus(uint256 requestId, TriggerStatus currentStatus);

    /// @notice Thrown when attempting to execute a request before its scheduled time.
    /// @param requestId   The ID of the request.
    /// @param executeAfter   The scheduled execution time.
    /// @param currentTime The current block timestamp.
    error TooEarly(uint256 requestId, uint64 executeAfter, uint256 currentTime);

    /// @notice Thrown when an invalid request ID is provided.
    /// @param requestId  The invalid request ID.
    error InvalidRequestId(uint256 requestId);

    /// @notice Thrown when caller lacks the required TRIGGER_ROLE.
    error OnlyTriggerRole();

    /// @notice Thrown when setting an invalid gas fee (e.g., zero).
    error InvalidGasFee();

    /// @notice Thrown when setting an invalid gas limit (e.g., zero or too high).
    error InvalidGasLimit();

    /// @notice Thrown when the fee receiver address is invalid (e.g., zero address).
    error InvalidFeeReceiver();

    /// @notice Thrown when a retried trigger callback reverts.
    /// @param requestId  The ID of the request whose retry failed.
    /// @param data       The revert data returned by the callback.
    error RetryFailed(uint256 requestId, bytes data);

    /// @notice Thrown when msg.value exceeds type(uint128).max and cannot be stored as feePaid.
    /// @param provided  The amount actually provided.
    error FeePaidOverflow(uint256 provided);

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════
    // WRITE METHODS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Request a trigger callback to be executed at or after a specified time.
    /// @dev The caller must send the required gas fee as `msg.value`.
    ///      This function is payable and will revert if insufficient gas fee is provided.
    ///      Emits a `FlapTriggerRequested` event that the backend monitors.
    ///
    ///      ⚠ The `executeAfter` timestamp is a lower bound, NOT a hard deadline. Execution
    ///      will only happen **after** `executeAfter`. Integrators must always assume there
    ///      can be an unpredictable delay between `executeAfter` and the actual on-chain call.
    ///
    /// @param executeAfter  Unix timestamp (in seconds) after which the trigger may be executed.
    ///                   Pass 0 for immediate execution (as soon as the backend processes it).
    ///                   Must be 0 or a future timestamp; cannot schedule in the past.
    ///
    /// @return requestId  The unique identifier for this trigger request. The requester should
    ///                    store this ID to map it to the corresponding operation in their callback.
    ///
    /// Requirements:
    ///   • msg.value >= getRequiredGasFee()
    ///   • If executeAfter > 0, must be >= block.timestamp
    ///
    /// Example:
    ///   ```solidity
    ///   uint256 requestId = triggerService.requestTrigger{value: 0.01 ether}(
    ///       uint64(block.timestamp + 1 days)
    ///   );
    ///   ```
    function requestTrigger(uint64 executeAfter) external payable returns (uint256 requestId);

    /// @notice Execute a single pending trigger request (called by backend with TRIGGER_ROLE).
    /// @dev This function can only be called by addresses with TRIGGER_ROLE.
    ///      It validates the request status and timing, then calls the requester's
    ///      `trigger(uint256)` function with the bounded gas limit.
    ///
    ///      The call is made with a low-level call to handle reverts gracefully:
    ///        • Emits FlapTriggerExecuted with success=true on success
    ///        • Emits FlapTriggerExecuted with success=false on callback revert
    ///
    /// @param requestId  The unique identifier of the trigger request to execute.
    ///
    /// Requirements:
    ///   • Caller must have TRIGGER_ROLE
    ///   • Request must exist and be in PENDING status
    ///   • block.timestamp >= request.executeAfter (or executeAfter == 0)
    ///
    /// Emits: FlapTriggerExecuted
    function trigger(uint256 requestId) external;

    /// @notice Execute multiple pending trigger requests in a single transaction.
    /// @dev Convenience method for the backend to batch multiple trigger executions.
    ///      Each request is executed independently; if one fails, the others continue.
    ///      This function can only be called by addresses with TRIGGER_ROLE.
    ///
    ///      Invalid or already-executed requests are skipped without reverting the batch.
    ///
    /// @param requestIds  Array of request IDs to execute.
    ///
    /// Requirements:
    ///   • Caller must have TRIGGER_ROLE
    ///
    /// Gas considerations:
    ///   • The backend should ensure the batch size fits within block gas limits.
    ///   • A batch of 10–50 requests is a reasonable starting point; the backend should
    ///     monitor actual gas consumption per execution and adjust batch sizes accordingly,
    ///     as heavier callbacks will require smaller batches.
    ///
    /// Example:
    ///   ```solidity
    ///   uint256[] memory ids = new uint256[](3);
    ///   ids[0] = 42; ids[1] = 43; ids[2] = 44;
    ///   triggerService.triggerMultiple(ids);
    ///   ```
    function triggerMultiple(uint256[] calldata requestIds) external;

    /// @notice Retry a previously failed trigger request. Callable by anyone.
    /// @dev Allows anyone to retry a request that is in FAILED status.
    ///      Unlike trigger(), there is no gas cap applied — all available gas is forwarded
    ///      to the requester's callback so the caller can supply sufficient gas.
    ///      On success: marks the request as EXECUTED, transfers the stored fee to feeReceiver,
    ///                  and emits an explorer tracker log.
    ///      On failure: reverts with RetryFailed (status stays FAILED, caller may retry again).
    ///
    /// @param requestId  The unique identifier of the failed trigger request to retry.
    ///
    /// Requirements:
    ///   • Request must exist and be in FAILED status
    ///
    /// Emits: FlapTriggerExecuted (only on success)
    /// Reverts: RetryFailed (with revert data from callback) on failure
    function retryTrigger(uint256 requestId) external;

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════
    // VIEW METHODS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Get the required gas fee to request a trigger.
    /// @dev This is the amount of native currency (in wei) that must be sent as msg.value
    ///      when calling requestTrigger(). The fee covers:
    ///        • Gas costs for the trigger() call by the backend
    ///        • Gas costs for the callback to the requester contract
    ///        • A small service fee (if applicable)
    ///
    /// @return gasFee  The required gas fee in wei.
    ///
    /// Example:
    ///   ```solidity
    ///   uint256 fee = triggerService.getFee();
    ///   triggerService.requestTrigger{value: fee}(uint64(block.timestamp + 3600));
    ///   ```
    function getFee() external view returns (uint256 gasFee);

    /// @notice Get the maximum gas that will be forwarded to the requester's callback.
    /// @dev When trigger() is called, the requester's callback receives at most this amount
    ///      of gas. Requester contracts must ensure their trigger() callback can complete
    ///      within this limit.
    ///
    ///      The actual gas forwarded is: min(gasleft(), maxCallbackGas)
    ///
    /// @return maxGas  The maximum gas amount that can be forwarded to callbacks.
    function getMaxCallbackGas() external view returns (uint256 maxGas);

    /// @notice Get detailed information about a trigger request.
    /// @dev Returns the packed TriggerRequest for a specific request ID.
    ///
    /// @param requestId  The unique identifier of the trigger request.
    /// @return request   The TriggerRequest struct containing all request details.
    ///
    /// Reverts: InvalidRequestId if the request does not exist.
    function getRequest(uint256 requestId) external view returns (TriggerRequest memory request);

    /// @notice Get the total number of trigger requests ever created.
    /// @dev This equals the ID that will be assigned to the next request (IDs start at 0).
    ///      Useful for off-chain indexing and pagination.
    ///
    /// @return count  The total number of requests created so far.
    function getRequestCount() external view returns (uint256 count);

    /// @notice Check whether a specific request is ready to be executed right now.
    /// @dev A request is ready if:
    ///        • It exists
    ///        • Status is PENDING
    ///        • block.timestamp >= executeAfter (or executeAfter is 0)
    ///
    /// @param requestId  The ID of the request to check.
    /// @return ready     True if the request can be executed now, false otherwise.
    function isRequestReady(uint256 requestId) external view returns (bool ready);

    /// @notice Get multiple requests by their IDs in a single call.
    /// @dev Convenience method to fetch multiple requests efficiently.
    ///      Invalid request IDs return zero-initialised structs.
    ///
    /// @param requestIds  Array of request IDs to fetch.
    /// @return requests   Array of TriggerRequest structs in the same order as requestIds.
    function getRequests(uint256[] calldata requestIds) external view returns (TriggerRequest[] memory requests);

    /// @notice Get a paginated list of all requests, sorted newest first (descending by ID).
    /// @dev Designed for UI pagination. IDs are sequential starting from 0, so "newest first"
    ///      means descending order.
    ///
    ///      Example: if there are 100 requests (IDs 0–99), calling with offset=0, limit=10
    ///      returns IDs [99, 98, 97, 96, 95, 94, 93, 92, 91, 90] and total=100.
    ///
    /// @param offset   Number of requests to skip from the newest (0 = start from newest).
    /// @param limit    Maximum number of requests to return.
    /// @return requests  The page of TriggerRequest structs, newest first.
    /// @return total     The total number of requests ever created.
    function getRequestsPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (TriggerRequest[] memory requests, uint256 total);

    /// @notice Get a paginated list of requests for a specific requester, sorted newest first.
    /// @dev Designed for UI pagination. Returns only requests where `requester` matches the
    ///      given address, in descending creation order (newest first).
    ///
    ///      Example: if address 0xABCD has 50 requests, calling with offset=0, limit=10
    ///      returns the 10 most recent request structs for 0xABCD and total=50.
    ///
    /// @param requester  The address whose requests to query.
    /// @param offset     Number of requests to skip from the newest (0 = start from newest).
    /// @param limit      Maximum number of requests to return.
    /// @return requests  The page of TriggerRequest structs for the requester, newest first.
    /// @return total     The total number of requests ever made by this requester.
    function getRequestsByRequesterPaginated(address requester, uint256 offset, uint256 limit)
        external
        view
        returns (TriggerRequest[] memory requests, uint256 total);
}

/// @title ITriggerReceiver
/// @notice Interface that requester contracts must implement to receive trigger callbacks.
/// @dev This interface is complementary to IFlapTriggerService:
///        • Requester contracts call IFlapTriggerService to schedule triggers.
///        • Requester contracts implement ITriggerReceiver to handle the resulting callbacks.
///      Any contract that calls requestTrigger() on FlapTriggerService MUST implement
///      this interface. The trigger() function will be called by FlapTriggerService
///      when the scheduled time has passed and the backend processes the request.
interface ITriggerReceiver {
    /// @notice Callback function invoked by FlapTriggerService when a trigger executes.
    /// @dev SECURITY CRITICAL:
    ///        • MUST validate that msg.sender is the FlapTriggerService address.
    ///        • SHOULD implement reentrancy guards if performing external calls.
    ///        • MUST complete execution within getMaxCallbackGas() limit.
    ///        • SHOULD use requestId to look up and execute the intended operation.
    ///        • MUST NOT assume execution happens exactly at the scheduled time —
    ///          there can be an unpredictable delay after `executeAfter`.
    ///
    /// @param requestId  The unique identifier of the trigger request being executed.
    ///
    /// Example implementation:
    ///   ```solidity
    ///   function trigger(uint256 requestId) external override {
    ///       require(msg.sender == address(triggerService), "Only service");
    ///
    ///       PendingAction memory action = pendingActions[requestId];
    ///       if (action.actionType == ActionType.DISTRIBUTE) {
    ///           _distribute(action.recipient, action.amount);
    ///       }
    ///       delete pendingActions[requestId];
    ///   }
    ///   ```
    function trigger(uint256 requestId) external;
}
