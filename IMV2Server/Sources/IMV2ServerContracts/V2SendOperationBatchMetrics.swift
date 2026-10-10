import Foundation

public enum V2SendOperationStage: String, CaseIterable, Sendable {
    case receiptPreflight = "receipt_preflight"
    case authorizationRoute = "authorization_route"
    case authorizationControl = "authorization_control"
    /// Memory policy preparation: actual preflight SQL, excluding admission wait.
    case preparationOwnerRead = "preparation_owner_read"
    /// One cold snapshot's complete owner state fetch, including remote RPC.
    case policyOwnerState = "policy_owner_state"
    case policyOwnerMemoryProbe = "policy_owner_memory_probe"
    /// Receiver-side wait for actual state SQL admission; excludes the transaction.
    case policyOwnerStateDatabaseAdmission = "policy_owner_state_database_admission"
    /// Receiver-side actual state transaction, including borrow, BEGIN and COMMIT.
    case policyOwnerStateTransaction = "policy_owner_state_transaction"
    /// Fact locks and reads inside state initialization; absent on validated reuse.
    case policyOwnerStateFacts = "policy_owner_state_facts"
    /// Durable registration after state fetch; excludes room lease installation.
    case policySnapshotRegistration = "policy_snapshot_registration"
    case ownerConnectionAcquire = "owner_connection_acquire"
    case roomQueueWait = "room_queue_wait"
    case ownerReadyWait = "owner_ready_wait"
    case ownerSelectRoom = "owner_select_room"
    case ownerTicketTaskWait = "owner_ticket_task_wait"
    /// Scheduling selection to synchronous registration of the actual loan.
    case ownerTicketRegistrationWait = "owner_ticket_registration_wait"
    case ownerTaskToPoolRequest = "owner_task_to_pool_request"
    case ownerTaskToStoreEnter = "owner_task_to_store_enter"
    case ownerStoreToPhysicalEnter = "owner_store_to_physical_enter"
    case ownerPhysicalToPoolRequest = "owner_physical_to_pool_request"
    /// Request registration through pool assignment publication, including gate wait.
    case ownerPoolAssignmentWait = "owner_pool_assignment_wait"
    /// Non-overlapping children of assignment wait, using the winning gate.
    /// Before-gate includes failed probes and original wait before a peer wins.
    case ownerPoolBeforeWinningGate = "owner_pool_before_winning_gate"
    case ownerGateRequestPreparation = "owner_gate_request_preparation"
    case ownerGateLockWait = "owner_gate_lock_wait"
    case ownerGateAdmission = "owner_gate_admission"
    case ownerGateCapacityWait = "owner_gate_capacity_wait"
    case ownerGateGrantToPromise = "owner_gate_grant_to_promise"
    case ownerGateDeliveryWait = "owner_gate_delivery_wait"
    case ownerPoolPublishWork = "owner_pool_publish_work"
    /// Subsets of delivery wait; these must not be added to the parent.
    case ownerGateOffLoopDelivery = "owner_gate_off_loop_delivery"
    case ownerGateOnLoopDelivery = "owner_gate_on_loop_delivery"
    case ownerGateCallbackRegistration = "owner_gate_callback_registration"
    case ownerGateRegisteredToCallback = "owner_gate_registered_to_callback"
    case ownerGateQueuedCapacityWait = "owner_gate_queued_capacity_wait"
    case ownerPoolPeerBeforeGate = "owner_pool_peer_before_gate"
    case ownerPoolAssignmentCallbackWait = "owner_pool_assignment_callback_wait"
    /// Driver borrowing after the actual pool assignment callback starts.
    case ownerPoolToDriverWait = "owner_pool_to_driver_wait"
    case policySnapshotSQLFuture = "policy_snapshot_sql_future"
    case policySnapshotSQLResume = "policy_snapshot_sql_resume"
    case ownerDriverCallbackTaskWait = "owner_driver_callback_task_wait"
    case ownerBorrowedWatchdogJoin = "owner_borrowed_watchdog_join"
    case ownerBeforeFirstSQL = "owner_before_first_sql"
    case ownerAfterBeginGap = "owner_after_begin_gap"
    case ownerAfterWriteGap = "owner_after_write_gap"
    case ownerCommitFutureToExecuteReturn = "owner_commit_future_to_execute_return"
    case ownerRecordOutcome = "owner_record_outcome"
    case ownerExecuteReturnToPoolReturn = "owner_execute_return_to_pool_return"
    /// Children of pool-return to scheduling capacity release.
    case ownerReturnCallbackWait = "owner_return_callback_wait"
    case ownerReturnLockWait = "owner_return_lock_wait"
    case ownerReturnLockToRelease = "owner_return_lock_to_release"
    /// Scheduling after capacity release; not a child of return-to-release.
    case ownerReturnScheduleWork = "owner_return_schedule_work"
    case ownerPoolReturnToResourceRelease = "owner_pool_return_to_resource_release"
    case ownerBeginResume = "owner_begin_resume"
    case ownerWriteResume = "owner_write_resume"
    case ownerCommitResume = "owner_commit_resume"
    case ownerBeginFuture = "owner_begin_future"
    case ownerWriteFuture = "owner_write_future"
    case ownerCommitFuture = "owner_commit_future"
    case ownerSetup = "owner_setup"
    /// Whole one-statement implicit transaction, including backend confirmation.
    case ownerSingleStatement = "owner_single_statement"
    case ownerBody = "owner_body"
    case ownerCommit = "owner_commit"
    case ownerRollback = "owner_rollback"
    /// Non-overlapping sub-stages within ownerBody; never add them to their parent.
    case ownerLocks = "owner_locks"
    case ownerReceiptRead = "owner_receipt_read"
    case ownerPreflight = "owner_preflight"
    case ownerRuntimeState = "owner_runtime_state"
    case ownerReduction = "owner_reduction"
    case ownerPolicy = "owner_policy"
    case ownerMessagePersistence = "owner_message_persistence"
    case ownerProjection = "owner_projection"
    case ownerProof = "owner_proof"
    case ownerReceiptPersistence = "owner_receipt_persistence"
    case ownerAdmission = "owner_admission"
}

public struct V2SendOperationStageMetricsSnapshot: Equatable, Sendable {
    public var inFlight = 0
    public var count: UInt64 = 0
    public var totalMilliseconds: Double = 0
    public var maxMilliseconds: Double = 0
    public init() {}
}

/// Closed vocabulary for why an owner handle takes its original scalar transaction.
/// A handle is recorded only at that execution boundary, never once per isolation depth.
public enum V2SendOperationOwnerScalarFallbackReason: String, CaseIterable, Sendable {
    case multiCommand = "multi_command"
    case complexPayload = "complex_payload"
    case legacyOrNotReady = "legacy_or_not_ready"
    case domainIsolation = "domain_isolation"
}

public struct V2SendOperationOwnerScalarFallbackSnapshot: Equatable, Sendable {
    public var handles: UInt64 = 0
    public var commands: UInt64 = 0
    public init() {}
}

/// Fixed successful admission paths, recorded immediately before COMMIT dispatch.
public enum V2SendOperationAdmissionPath: String, CaseIterable, Sendable {
    case singleSuccess = "single_success"
    case singleFallback = "single_fallback"
    case multiGroup = "multi_group"
}

/// Two non-overlapping handoff segments spanning admission result validation
/// and transaction finalization before COMMIT dispatch. They overlap body,
/// admission and finalization stage measurements and must not be added to stage
/// latency. This is not proof of successful COMMIT or socket delivery.
public struct V2SendOperationAdmissionHandoffSnapshot: Equatable, Sendable {
    public var count: UInt64 = 0
    public var resultReadyToValidatedMillisecondsTotal: Double = 0
    public var resultReadyToValidatedMillisecondsMax: Double = 0
    public var validatedToCommitDispatchMillisecondsTotal: Double = 0
    public var validatedToCommitDispatchMillisecondsMax: Double = 0
    public init() {}
}

/// Fixed SQL boundaries observed while the actual transaction retains its locks.
public enum V2RoomSQLContinuationSource: String, CaseIterable, Sendable {
    case durableFenceRooms = "durable_fence_rooms"
    case durableFenceLeases = "durable_fence_leases"
    case durableFenceCombined = "durable_fence_combined"
    case configuredFenceRooms = "configured_fence_rooms"
    case configuredFenceLeases = "configured_fence_leases"
    case scalarFenceRooms = "scalar_fence_rooms"
    case scalarFenceLeases = "scalar_fence_leases"
    case lifecycleRooms = "lifecycle_rooms"
    case lifecycleLeases = "lifecycle_leases"
}

/// Independent segments from actual observed SQL settlement through its Swift
/// continuation to an explicitly recorded adjacent API dispatch. Settlement includes SQL failures;
/// neither segment proves successful COMMIT or physical socket delivery. They
/// overlap transaction stages and must not be added to stage latency. Pending
/// gauges cover only these observations, not every SQL operation or actor task.
public struct V2RoomSQLContinuationSnapshot: Equatable, Sendable {
    public var settledNotResumed = 0
    public var resumedNotDispatched = 0
    public var settledToResumedCount: UInt64 = 0
    public var settledToResumedTotalMilliseconds: Double = 0
    public var settledToResumedMaxMilliseconds: Double = 0
    public var resumedToDispatchCount: UInt64 = 0
    public var resumedToDispatchTotalMilliseconds: Double = 0
    public var resumedToDispatchMaxMilliseconds: Double = 0
    /// Observations ending without a recorded successor dispatch, including
    /// sequence failure or closure. Unobserved SQL/COMMIT/ROLLBACK may still run.
    public var noNextDispatch: UInt64 = 0
    public init() {}
}

/// Counters for the durable sendOperation path, independent of legacy append batching.
public enum V2PolicyMemoryEvent: String, CaseIterable, Sendable {
    case snapshotProbeHit = "snapshot_probe_hit", snapshotProbeMiss = "snapshot_probe_miss"
}

public struct V2SendOperationBatchMetricsSnapshot: Equatable, Sendable {
    public var policyMemoryEvents: [V2PolicyMemoryEvent: UInt64] = [:]
    public var inFlightBatches = 0
    public var attemptedBatches: UInt64 = 0
    public var submittedCommands: UInt64 = 0
    public var committedBatches: UInt64 = 0
    public var committedCommands: UInt64 = 0
    public var rolledBackBatches: UInt64 = 0
    public var outcomeUnknownBatches: UInt64 = 0
    public var singletonBatches: UInt64 = 0
    public var largestBatch = 0
    public var executionMillisecondsTotal: UInt64 = 0
    public var executionMillisecondsMax: UInt64 = 0
    /// Actual Store setwise transaction attempts, including isolated subcohorts.
    /// These counters are distinct from coordinator selections and room turns.
    public var ownerCohortAttempts: UInt64 = 0
    public var ownerCohortHandles: UInt64 = 0
    public var ownerCohortCommands: UInt64 = 0
    public var ownerCohortCommits: UInt64 = 0
    public var ownerCohortAcceptedCommands: UInt64 = 0
    public var ownerCohortReplayedCommands: UInt64 = 0
    public var ownerCohortIsolations: UInt64 = 0
    public var ownerScalarFallbacks: [V2SendOperationOwnerScalarFallbackReason: V2SendOperationOwnerScalarFallbackSnapshot] =
        Dictionary(uniqueKeysWithValues: V2SendOperationOwnerScalarFallbackReason.allCases.map { ($0, .init()) })
    public var ownerAdmissionHandoffs: [V2SendOperationAdmissionPath: V2SendOperationAdmissionHandoffSnapshot] =
        Dictionary(uniqueKeysWithValues: V2SendOperationAdmissionPath.allCases.map { ($0, .init()) })
    public var sqlContinuations: [V2RoomSQLContinuationSource: V2RoomSQLContinuationSnapshot] =
        Dictionary(uniqueKeysWithValues: V2RoomSQLContinuationSource.allCases.map { ($0, .init()) })
    public var stages: [V2SendOperationStage: V2SendOperationStageMetricsSnapshot] =
        Dictionary(uniqueKeysWithValues: V2SendOperationStage.allCases.map { ($0, .init()) })
    public init() {}
}

public protocol V2SendOperationBatchMetricsReading: Sendable {
    func sendOperationBatchMetricsSnapshot() -> V2SendOperationBatchMetricsSnapshot
}

/// Fixed lifecycle stages of retained owner roots, not SQL transaction counts.
public enum V2SendOperationOwnerBatchStage: String, CaseIterable, Hashable, Sendable {
    case acquiringConnection = "acquiring_connection"
    case executing = "executing"
}

/// Physical-owner coordinator cohorts, distinct from individual room turns.
/// Started cohorts include owner admission; completed means its actual executor
/// (or admission rejection) has settled, irrespective of commit outcome.
public struct V2SendOperationOwnerMetricsSnapshot: Equatable, Sendable {
    public var retainedItems = 0
    public var retainedBytes = 0
    public var queuedTurns = 0
    public var waitingPolicyTurns = 0
    public var inFlightBatches = 0
    /// nil means the provider does not expose stage ownership. Supported
    /// providers partition all retained roots, including actual cleanup.
    public var stages: [V2SendOperationOwnerBatchStage: Int]? = nil
    public var batchesStarted: UInt64 = 0
    public var batchesCompleted: UInt64 = 0
    public var commandsSubmitted: UInt64 = 0
    public var largestBatch = 0
    /// Distinct rooms selected in a single cohort, independent of commands per room.
    public var largestRoomCount = 0
    public init() {}
}

public protocol V2SendOperationOwnerMetricsReading: Sendable {
    func sendOperationOwnerMetricsSnapshot() async -> V2SendOperationOwnerMetricsSnapshot
}
