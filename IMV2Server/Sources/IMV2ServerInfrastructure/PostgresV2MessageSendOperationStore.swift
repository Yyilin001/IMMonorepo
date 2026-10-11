import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit
import NIOCore
import PostgresNIO
import Synchronization

public struct PostgresV2MessageSendOperationStore:Sendable {
    private var database:any Database
    private let initializationDatabase: any Database
    private var executionPrepared = false
    private var postCommitWork: V2OwnerPostCommitWork?

    private func afterCommit(_ action: @escaping @Sendable () async -> Void) async {
        if let postCommitWork { postCommitWork.append(action) }
        else { await action() }
    }
    private var writes:PostgresV2RoomWriteStore
    private let clock:@Sendable () -> Date
    private let committedMessageObserver: (any V2CommittedMessageBatchObserving)?
    private let sendOperationMetrics: V2SendOperationBatchMetrics?
    private let preparationOwner = UUID()
    private let preparationMemory = V2SendPreparationResultMemory()
    private let roomAcceptance = V2DirectRoomSendAcceptanceMemory()

    package func installSendInitialization(_ initialization: V2RoomSendInitialization) async {
        roomAcceptance.install(initialization)
    }

    package func invalidateSendState(token: V2RoomActivationToken) async {
        roomAcceptance.invalidate(token)
    }
    private var pinnedOwnerConnection: V2BorrowedRoomConnection?
    private var pinnedOwnerConnectionIsUsable: (@Sendable () -> Bool)?
    private var ownerTransactionObserver: (@Sendable (Int32, Bool, Int) async throws -> Void)?
    /// Opt in only when database and writes read the same physical owner.
    /// Control reservations still run after the owner connection is released.
    public init(database:any Database,writes:PostgresV2RoomWriteStore,clock:@escaping @Sendable () -> Date = Date.init, committedMessageObserver: (any V2CommittedMessageBatchObserving)? = nil, sendOperationMetrics: V2SendOperationBatchMetrics? = nil,
                initializationDatabase: (any Database)? = nil) {
        self.database=(database as? V2EventLoopBalancedDatabase)?.usingObservationSource(.durableOwner) ?? database
        let reader = initializationDatabase ?? database
        self.initializationDatabase = (reader as? V2EventLoopBalancedDatabase)?.usingObservationSource(.roomSendInitialization) ?? reader
        self.writes=writes;self.clock=clock;self.committedMessageObserver=committedMessageObserver
        self.sendOperationMetrics=sendOperationMetrics
    }
    /// Binds a runtime-owned actual operation, never a queued preparation.
    /// The runtime must retain this execution through the complete SQL future.
    func usingPolicyExecution(_ execution: V2RoomPolicyExecution) throws -> Self {
        var copy = self
        copy.writes = try writes.usingActivationScope(.init(tokens: [execution.activation], reliesOnRuntimeLifecycle: writes.usesMemorySendPreparation))
            .usingPolicyExecution(execution)
        return copy
    }

    package func ownsPreparedBatch(_ prepared: borrowing V2PreparedMessageSendBatch) -> Bool {
        prepared.owner == preparationOwner
    }

    public func send(_ command: V2MessageSendOperationCommand, token: V2RoomActivationToken,
        capacityProfile: V2CapacityProfile, identifiers: V2AcceptanceIdentifiers) async throws -> V2MessageSendOperationRecoveryResult {
        guard let messageID = identifiers.messageID.uuidValue, let eventID = identifiers.eventID.uuidValue else {
            throw V2MessageOperationValidationError.invalidReceipt
        }
        let nextEvent = Mutex(false)
        let factory = V2AcceptanceIDFactory(makeUUID: {
            nextEvent.withLock { next in
                defer { next.toggle() }
                return next ? eventID : messageID
            }
        })
        let results = try await sendBatch([command], token: token, capacityProfile: capacityProfile,
            identifiers: factory, now: clock)
        guard results.count == 1, case .sendOperation(let result) = results[0] else {
            throw V2MessageOperationValidationError.invalidReceipt
        }
        return result
    }

    /// Uses the same Policy Owner preparation and room execution as the Actor path.
    public func sendBatch(_ commands: [V2MessageSendOperationCommand], token: V2RoomActivationToken,
        capacityProfile: V2CapacityProfile, identifiers: V2AcceptanceIDFactory,
        now: @escaping @Sendable () -> Date) async throws -> [V2RoomMessagingResult] {
        guard let policies = writes.currentPolicyAuthorizations else {
            throw V2ActorContractError.invalidConfiguration("message policy preparation required")
        }
        let prepared = try await policies.prepareOwnerBatches(store: self, requests: [
            .init(commands: commands, token: token, deadline: V2RoomSQLDeadline.boundedTransactionDeadline())
        ], now: now)[0].get()
        return try await executePreparedSendBatch(prepared, capacityProfile: capacityProfile,
            identifiers: identifiers, now: now)
    }

    /// Retains actual permits around the physical SQL future, never in queued
    /// handles. All promotions complete before the first connection is borrowed.
    private func withPreparedPolicies<Value: Sendable>(_ prepared: V2PreparedMessageSendBatch,
        operation: @escaping @Sendable (V2PreparedMessageSendBatch) async throws -> Value) async throws -> Value {
        guard prepared.owner == preparationOwner else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        guard let policy = prepared.policyPreparations.first else { return try await operation(prepared) }
        let sendTrace = V2SendPathTrace.current, promotionStartedAt = ContinuousClock.now
        let connectionTimeline = V2OwnerConnectionTimeline.current
        // The policy task owns execution lifetime independently of its caller.
        // Explicitly carry the physical loan's preference across that detached
        // boundary, including recursive promotions.
        return try await policy.runtime.executePreparedBatch(policy,
            executorPreference: pinnedOwnerConnection?.taskExecutor) { execution in
            try await V2SendPathTrace.$current.withValue(sendTrace) {
            try await V2OwnerConnectionTimeline.$current.withValue(connectionTimeline) {
            sendTrace?.record("permission_promotion", from: promotionStartedAt)
            var rebound = prepared
            guard rebound.token == execution.activation else { throw V2RoomActivationLeaseError.activationChanged }
            let scoped = try self.writes.usingActivationScope(.init(tokens: [rebound.token], reliesOnRuntimeLifecycle: writes.usesMemorySendPreparation)).usingPolicyExecution(execution)
            var preparations = rebound.preparations
            for command in rebound.commands where try policy.contains(command.command) {
                preparations[self.operationKey(identity: try command.identity)] = try scoped.operationBatchScopedStore(for: command.command)
            }
            rebound.preparations = preparations
            rebound.policyPreparations.removeFirst()
            return try await self.withPreparedPolicies(rebound, operation: operation)
            }
            }
        }
    }

    /// Prepares current Policy Owner permissions independently for each room.
    /// No durable authorization reservation is created during preparation.
    func prepareOwnerBatches(_ requests: [V2MessageSendPreparationRequest],
        policyDirectory: PostgresV2RoomPolicyAuthorizationDirectory,
        now: @escaping @Sendable () -> Date) async throws
        -> [Result<V2PreparedMessageSendBatch, any Error>] {
        let inputs = try await readOwnerPreparationInputs(requests, now: now)
        var results = Array<Result<V2PreparedMessageSendBatch, any Error>?>(repeating: nil, count: inputs.count)
        await withTaskGroup(of: (Int, Result<V2PreparedMessageSendBatch, any Error>).self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                group.addTask {
                    do {
                        return (index, .success(try await prepareOwnerPolicyInput(inputs[index].get(),
                            policyDirectory: policyDirectory)))
                    } catch { return (index, .failure(error)) }
                }
            }
            while next < min(8, inputs.count) { enqueue(next); next += 1 }
            for await (index, result) in group {
                results[index] = result
                if next < inputs.count { enqueue(next); next += 1 }
            }
        }
        return try results.map { guard let result = $0 else { throw V2MessageOperationValidationError.invalidReceipt }; return result }
    }

    /// Current policy preparation reads only bounded recent results in memory.
    /// The opaque input can be retained through policy demand; it never grants
    /// ownership or authority to bypass the durable execution fence.
    package func readOwnerPreparationInputs(_ requests: [V2MessageSendPreparationRequest],
        now: @escaping @Sendable () -> Date) async throws
        -> [Result<V2OwnerMessageSendPreparationInput, any Error>] {
        guard writes.usesMemorySendPreparation else {
            throw V2ActorContractError.invalidConfiguration("message policy preparation required")
        }
        let preparationReadStartedAt = ContinuousClock.now
        defer { V2SendPathTrace.current?.record("prepare_inputs", from: preparationReadStartedAt) }
        guard !requests.isEmpty, requests.count <= 128,
              requests.reduce(0, { $0 + $1.commands.count }) <= 256 else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        try Task.checkCancellation()
        let inherited = V2RoomSQLDeadline.current
        var results = Array<Result<V2OwnerMessageSendPreparationInput, any Error>?>(repeating: nil, count: requests.count)
        var selected: [(Int, ContinuousClock.Instant)] = []
        for (index, request) in requests.enumerated() {
            do {
                guard !request.commands.isEmpty,
                      request.commands.allSatisfy({ $0.command.roomID == request.token.roomID }) else {
                    throw V2RoomCallFailure.notAccepted(.invalidRequest)
                }
                for command in request.commands { _ = try persistenceKey(identity: command.identity); _ = try command.fingerprint }
                let deadline = inherited.map { min($0, request.deadline) } ?? request.deadline
                guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
                selected.append((index, deadline))
            } catch { results[index] = .failure(error) }
        }
        if let earliest = selected.map({ $0.1 }).min() {
            let commands = selected.flatMap { requests[$0.0].commands }
            let snapshot = try await V2RoomSQLDeadline.withDeadline(earliest) {
                let budget = await preparationMemory.snapshot(commands)
                var prior: Set<String> = []
                for command in commands {
                    let identity = try command.identity, key = operationKey(identity: identity)
                    guard let row = budget[key]?.first else { continue }
                    let receipt = row.receipt, domain = row.domainFingerprint
                    _ = try decodeExisting(.init(receipt: receipt, domainFingerprint: domain),
                        identity: identity, fingerprint: command.fingerprint, domain: command.command.fingerprint)
                    prior.insert(key)
                }
                return (budget, prior)
            }
            let current = try timestamp(now())
            for (index, deadline) in selected {
                do {
                    guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
                    let request = requests[index]
                    let pending = try request.commands.filter {
                        !snapshot.1.contains(try operationKey(identity: $0.identity))
                            && $0.firstSubmissionDeadlineMilliseconds > current
                            && $0.firstSubmissionDeadlineMilliseconds - current <= 86_400_000
                    }
                    results[index] = .success(.init(owner: preparationOwner,
                        request: .init(commands: request.commands, token: request.token, deadline: deadline),
                        pending: pending, preparationSnapshot: snapshot.0))
                } catch { results[index] = .failure(error) }
            }
        }
        return try results.map { guard let result = $0 else { throw V2MessageOperationValidationError.invalidReceipt }; return result }
    }

    /// Resumes the original immutable input. A different store, expired input
    /// or changed command/token cannot mint a prepared execution handle.
    func prepareOwnerPolicyInput(_ input: V2OwnerMessageSendPreparationInput,
        policyDirectory: PostgresV2RoomPolicyAuthorizationDirectory) async throws -> V2PreparedMessageSendBatch {
        guard input.owner == preparationOwner else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        try Task.checkCancellation()
        let request = input.request
        let deadline = V2RoomSQLDeadline.current.map { min($0, request.deadline) } ?? request.deadline
        guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        let policies: [V2RoomPolicyPreparation]
        let stateProbeStartedAt = ContinuousClock.now
        let needsInitialization: Bool
        if input.pending.isEmpty { needsInitialization = false }
        else { needsInitialization = roomAcceptance.needsInitialization(token: request.token) }
        V2SendPathTrace.current?.record("prepare_state_probe", from: stateProbeStartedAt)
        if needsInitialization {
            // Only cold/invalidated state creates parallel child tasks.
            async let initialized: Void = initializeRoomSendState(token: request.token)
            async let loadedPolicies = prepareRoomPolicies(input, directory: policyDirectory, deadline: deadline)
            (_, policies) = try await (initialized, loadedPolicies)
        } else {
            policies = try await prepareRoomPolicies(input, directory: policyDirectory, deadline: deadline)
        }
        try Task.checkCancellation()
        guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        var accepted: [String: V2AcceptedDirectSend] = [:]
        let acceptanceStartedAt = ContinuousClock.now
        for policy in policies {
            guard let current = policy.currentDirectPolicy else { continue }
            for command in input.pending where try policy.contains(command.command) {
                if let decision = try roomAcceptance.accept(command: command.command, token: request.token,
                    policy: current, now: clock()) {
                    accepted[try operationKey(identity: command.identity)] = decision
                }
            }
        }
        V2SendPathTrace.current?.record("prepare_memory_acceptance", from: acceptanceStartedAt)
        let retainedByteBudget = request.commands.reduce(0) { total, command in
            let (sum, overflow) = total.addingReportingOverflow(command.estimatedRetainedBytes)
            return overflow ? Int.max : sum
        }
        return .init(owner: preparationOwner, commands: request.commands,
            retainedByteBudget: retainedByteBudget, token: request.token,
            preparations: [:], deadline: policies.reduce(deadline) { min($0, $1.deadline) },
            preparationSnapshot: input.preparationSnapshot, policyPreparations: policies, acceptedDirect: accepted)
    }

    private func initializeRoomSendState(token: V2RoomActivationToken) async throws {
        let startedAt = ContinuousClock.now
        defer { V2SendPathTrace.current?.record("prepare_room_state_initialization", from: startedAt) }
        try await roomAcceptance.initializeIfNeeded(token: token, database: initializationDatabase)
    }

    private func prepareRoomPolicies(_ input: V2OwnerMessageSendPreparationInput,
        directory: PostgresV2RoomPolicyAuthorizationDirectory, deadline: ContinuousClock.Instant) async throws -> [V2RoomPolicyPreparation] {
        let request = input.request
        var policies: [V2RoomPolicyPreparation] = []
        if !input.pending.isEmpty {
            let registryStartedAt = ContinuousClock.now
            let registry = try await V2RoomSQLDeadline.withDeadline(deadline) {
                try await directory.registry(token: request.token)
            }
            V2SendPathTrace.current?.record("prepare_registry", from: registryStartedAt)
            let directions = Dictionary(grouping: input.pending, by: { $0.command.senderUserID })
            for sender in directions.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let user = sender.uuidValue, let commands = directions[sender] else {
                    throw V2RoomCallFailure.notAccepted(.invalidRequest)
                }
                let runtimeStartedAt = ContinuousClock.now
                let runtime = try await registry.runtime(sender: user, token: request.token)
                V2SendPathTrace.current?.record("prepare_runtime", from: runtimeStartedAt)
                let policyStartedAt = ContinuousClock.now
                policies.append(try await runtime.prepareBatch(commands: commands.map(\.command), callerDeadline: deadline))
                V2SendPathTrace.current?.record("prepare_policy_snapshot", from: policyStartedAt)
            }
        }
        return policies
    }

    /// Only this store (or its immutable value copy) can execute the prepared
    /// handle. Receipt, owner epoch, activation and authorization are rechecked
    /// in the original transaction; preparation is never a write permission.
    /// Prepared permanent envelopes are immutable and bound to the complete
    /// command identity/fingerprint. Replays require no policy or write transaction.
    private func preparedReplay(_ prepared: borrowing V2PreparedMessageSendBatch) throws -> [V2RoomMessagingResult]? {
        guard !prepared.commands.isEmpty, prepared.deadline > .now,
              V2RoomSQLDeadline.current.map({ $0 > .now }) ?? true else { return nil }
        var values: [V2RoomMessagingResult] = []
        for command in prepared.commands {
            let identity = try command.identity, key = operationKey(identity: identity)
            guard let rows = prepared.preparationSnapshot[key], rows.count == 1 else { return nil }
            let receipt = rows[0].receipt, domain = rows[0].domainFingerprint
            values.append(.sendOperation(try decodeExisting(.init(receipt: receipt, domainFingerprint: domain),
                identity: identity, fingerprint: command.fingerprint, domain: command.command.fingerprint)))
        }
        try Task.checkCancellation()
        return values
    }

    public func executePreparedSendBatch(_ prepared: V2PreparedMessageSendBatch,
        capacityProfile: V2CapacityProfile, identifiers: V2AcceptanceIDFactory,
        now: @escaping @Sendable () -> Date) async throws -> [V2RoomMessagingResult] {
        if writes.usesMemorySendPreparation, !writes.contentReviewMode.enqueuesJobs,
           !prepared.commands.isEmpty, prepared.acceptedDirect.count == prepared.commands.count,
           prepared.commands.allSatisfy({ $0.command.media.isEmpty && $0.command.mentions.isEmpty
               && $0.command.replyTo == nil && $0.command.forwardedFrom == nil }) {
            return try await executePreparedRoomSend(prepared, capacityProfile: capacityProfile,
                identifiers: identifiers, now: now)
        }
        return try await executePreparedScalarSendBatch(prepared, capacityProfile: capacityProfile,
            identifiers: identifiers, now: now)
    }

    private func executePreparedScalarSendBatch(_ prepared: V2PreparedMessageSendBatch,
                                        capacityProfile: V2CapacityProfile, identifiers: V2AcceptanceIDFactory,
                                        now: @escaping @Sendable () -> Date) async throws -> [V2RoomMessagingResult] {
        guard prepared.owner == preparationOwner else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        if let replay = try preparedReplay(prepared) { return replay }
        if !executionPrepared {
            return try await withPreparedExecution {
                try await $0.executePreparedScalarSendBatch(prepared, capacityProfile: capacityProfile, identifiers: identifiers, now: now)
            }
        }
        if !prepared.policyPreparations.isEmpty {
            return try await withPreparedPolicies(prepared) { upgraded in
                try await self.executePreparedScalarSendBatch(upgraded, capacityProfile: capacityProfile, identifiers: identifiers, now: now)
            }
        }
        try Task.checkCancellation()
        let selectedDeadline = V2RoomSQLDeadline.current.map { min($0, prepared.deadline) } ?? prepared.deadline
        guard ContinuousClock.now < selectedDeadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        return try await V2RoomSQLDeadline.withDeadline(selectedDeadline) {
            do {
                let results = try await executePreparedBody(prepared, capacityProfile: capacityProfile, identifiers: identifiers, now: now)
                await afterCommit { [preparationMemory, roomAcceptance] in
                    await preparationMemory.remember(commands: prepared.commands, results: results)
                    roomAcceptance.invalidate(prepared.token)
                }
                return results
            } catch {
                roomAcceptance.invalidate(prepared.token)
                throw error
            }
        }
    }

    /// One room turn owns one transaction; other rooms never share its rollback.
    /// Confirmed pre-COMMIT rollback may retry the strict scalar implementation.
    public func executePreparedRoomSend(_ prepared: V2PreparedMessageSendBatch,
        capacityProfile: V2CapacityProfile, identifiers: V2AcceptanceIDFactory,
        now: @escaping @Sendable () -> Date
    ) async throws -> [V2RoomMessagingResult] {
        guard prepared.owner == preparationOwner, !prepared.commands.isEmpty,
              prepared.commands.count <= 256 else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        if let replay = try preparedReplay(prepared) { return replay }
        if !executionPrepared {
            return try await withPreparedExecution {
                try await $0.executePreparedRoomSend(prepared, capacityProfile: capacityProfile, identifiers: identifiers, now: now)
            }
        }
        if !prepared.policyPreparations.isEmpty {
            return try await withPreparedPolicies(prepared) {
                try await self.executePreparedRoomSend($0, capacityProfile: capacityProfile, identifiers: identifiers, now: now)
            }
        }
        let deadline = V2RoomSQLDeadline.current.map { min($0, prepared.deadline) } ?? prepared.deadline
        return try await V2RoomSQLDeadline.withDeadline(deadline) {
            let complex = writes.contentReviewMode.enqueuesJobs || prepared.commands.contains {
                !$0.command.media.isEmpty || !$0.command.mentions.isEmpty || $0.command.replyTo != nil || $0.command.forwardedFrom != nil
            }
            let keys = try prepared.commands.map { try operationKey(identity: $0.identity) }
            var reason: V2SendOperationOwnerScalarFallbackReason = complex ? .complexPayload : .optimizationNotApplicable
            if !complex, Set(keys).count == keys.count {
                if let values = try await executeSingleStatementRoomTurn(prepared,
                    capacityProfile: capacityProfile, identifiers: identifiers, now: now) {
                    return values
                }
                switch try await executePlainRoomTurn(prepared, capacityProfile: capacityProfile, identifiers: identifiers, now: now) {
                case .committed(let results): return results
                case .scalarFallback(let fallback): reason = fallback
                }
            }
            sendOperationMetrics?.recordOwnerScalarFallback(handleCount: 1, commandCount: prepared.commands.count, reason: reason)
            guard pinnedOwnerConnectionIsUsable?() != false else { throw V2RoomCallFailure.notAccepted(.unavailable) }
            return try await executePreparedScalarSendBatch(prepared, capacityProfile: capacityProfile, identifiers: identifiers, now: now)
        }
    }

    /// Promote policy before borrowing, then retain the same physical loan across
    /// confirmed rollback and scalar fallback for this room alone.
    package func executePreparedRoomSendPreborrowing(_ prepared: V2PreparedMessageSendBatch,
        capacityProfile: V2CapacityProfile, identifiers: V2AcceptanceIDFactory,
        now: @escaping @Sendable () -> Date, control: V2OwnerBatchBorrowControl
    ) async throws -> [V2RoomMessagingResult] {
        guard prepared.owner == preparationOwner else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        if let replay = try preparedReplay(prepared) { return replay }
        if !executionPrepared {
            return try await withPreparedExecution {
                try await $0.executePreparedRoomSendPreborrowing(prepared, capacityProfile: capacityProfile,
                    identifiers: identifiers, now: now, control: control)
            }
        }
        let deadline = V2RoomSQLDeadline.current.map { min($0, prepared.deadline) } ?? prepared.deadline
        try await control.beforeFirstBegin()
        if let isUsable = pinnedOwnerConnectionIsUsable {
            guard isUsable() else { throw V2RoomCallFailure.notAccepted(.unavailable) }
            return try await withPreparedPolicies(prepared) { upgraded in
                try await V2RoomSQLDeadline.withDeadline(deadline) {
                    try await self.executePreparedRoomSend(upgraded, capacityProfile: capacityProfile, identifiers: identifiers, now: now)
                }
            }
        }
        return try await withPreparedPolicies(prepared) { upgraded in
            try await v2WithOwnerBatchConnection(database: database, deadline: deadline,
                metrics: sendOperationMetrics, interrupted: control.interrupted) { borrowed, isUsable in
                try await control.connectionAcquired()
                try Task.checkCancellation()
                guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
                guard isUsable() else { throw V2RoomCallFailure.notAccepted(.unavailable) }
                var copy = self
                copy.database = borrowed
                copy.pinnedOwnerConnectionIsUsable = isUsable
                copy.pinnedOwnerConnection = V2BorrowedRoomConnectionScope.current
                let owned = copy
                return try await V2RoomSQLDeadline.withDeadline(deadline) {
                    try await owned.executePreparedRoomSend(upgraded, capacityProfile: capacityProfile, identifiers: identifiers, now: now)
                }
            }
        }
    }

    package func replayedPreparedBatch(_ prepared: borrowing V2PreparedMessageSendBatch) throws -> [V2RoomMessagingResult]? {
        guard ownsPreparedBatch(prepared) else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        return try preparedReplay(prepared)
    }

    /// Pool capacity is the only production execution limit. Non-pool test
    /// databases use the explicit dispatcher capacity supplied by their fixture.
    package var scheduledSendConnectionCapacity: Int? {
        guard let pool = database as? V2EventLoopBalancedDatabase else { return nil }
        return pool.ordinaryConnectionCapacity
    }

    /// Commands are immutable across policy promotion. Cache only their identity
    /// material here; live authorization, sequence allocation and timestamps stay
    /// at their existing execution boundaries.
    package func preparingScheduledCommandPlan(_ prepared: consuming V2PreparedMessageSendBatch) throws -> V2PreparedMessageSendBatch {
        guard ownsPreparedBatch(prepared) else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        if prepared.commandPlan != nil { return prepared }
        let plan = try commandPlan(prepared)
        var owned = consume prepared
        owned.commandPlan = plan
        return owned
    }

    private func commandPlan(_ prepared: borrowing V2PreparedMessageSendBatch) throws -> PreparedRoomCommandPlan {
        let commands = prepared.commands
        let keys = try commands.map { try persistenceKey(identity: $0.identity) }
        let roomID = prepared.token.roomID.uuidValue
        guard keys.allSatisfy({ $0.room == roomID }) else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        let operationKeys = try commands.map { try operationKey(identity: $0.identity) }
        let receiptKeys = try commands.map { try V2DurableSendBatchReceiptInput(command: $0).key }
        return .init(ordered: commands.indices.sorted { receiptKeys[$0] < receiptKeys[$1] },
            operationKeys: operationKeys,
            lockKeys: keys.map { .init(roomID: $0.room, senderID: $0.actor, clientMessageID: $0.operation) },
            successMetadata: try commands.map { try V2SendSuccessMetadata.Prepared($0) })
    }

    package func withScheduledSendConnection<Value: Sendable>(deadline: ContinuousClock.Instant,
        _ body: @escaping @Sendable (V2OwnerConnectionExecutor) async throws -> Value
    ) async throws -> Value {
        let started = try startScheduledSendConnection(deadline: deadline, body)
        return try await started.finish()
    }

    package func startScheduledSendConnection<Value: Sendable>(deadline: ContinuousClock.Instant,
        _ body: @escaping @Sendable (V2OwnerConnectionExecutor) async throws -> Value
    ) throws -> V2StartedRoomConnection<Value> {
        let finalization = V2OwnerPostCommitWork()
        let timeline = V2OwnerConnectionTimeline.current
        let enteredAt = ContinuousClock.now
        timeline?.mark("store_borrow_entered", at: enteredAt)
        if let started = timeline?.marker("ticket_task_started") {
            timeline?.record(.ownerTaskToStoreEnter, from: started, to: enteredAt)
        }
        V2OwnerConnectionTimeline.current?.configure(sendOperationMetrics)
        return try v2StartOwnerBatchConnection(database: database, deadline: deadline,
            metrics: sendOperationMetrics, acquisitionOnly: true, interrupted: { _ in }) { borrowed, isUsable in
            var copy = self
            copy.database = borrowed
            copy.pinnedOwnerConnectionIsUsable = isUsable
            copy.pinnedOwnerConnection = V2BorrowedRoomConnectionScope.current
            copy.postCommitWork = finalization
            let pinned = copy
            return try await body(.init(finalize: { await finalization.finish() }, execute: { prepared, capacity, identifiers, now in
                guard isUsable() else { throw V2RoomCallFailure.notAccepted(.unavailable) }
                return try await pinned.executePreparedRoomSend(prepared,
                    capacityProfile: capacity, identifiers: identifiers, now: now)
            }))
        }
    }

    /// Disposable-database tests observe only backend identity and path kind;
    /// neither a borrowed database nor client configuration escapes this owner.
    package func observingOwnerTransactions(
        _ observer: @escaping @Sendable (Int32, Bool, Int) async throws -> Void
    ) -> Self {
        var copy = self; copy.ownerTransactionObserver = observer; return copy
    }
    private func observeOwnerTransaction(sql: any SQLDatabase, scalar: Bool, handles: Int) async throws {
        guard let observer = ownerTransactionObserver else { return }
        struct Backend: Decodable { let pid: Int32 }
        guard let backend = try await sql.raw("SELECT pg_backend_pid() AS pid").first(decoding: Backend.self) else {
            throw V2MessageOperationValidationError.invalidReceipt
        }
        try await observer(backend.pid, scalar, handles)
    }

    /// Only an established, fully reduced current-policy room can use a single
    /// statement. No policy/projection mutation or receipt lookup follows it.
    private func executeSingleStatementRoomTurn(_ prepared: V2PreparedMessageSendBatch,
        capacityProfile: V2CapacityProfile, identifiers: V2AcceptanceIDFactory,
        now: @escaping @Sendable () -> Date
    ) async throws -> [V2RoomMessagingResult]? {
        guard writes.usesMemorySendPreparation, let connection = pinnedOwnerConnection,
              (connection.borrowed as? any V2RoomSQLSessionDefaults)?.roomSQLSessionTimeouts == .default,
              !prepared.commands.isEmpty else { return nil }
        let plan = try prepared.commandPlan ?? commandPlan(prepared)
        let resolvedAt = now(), milliseconds = try timestamp(resolvedAt)
        var items: [V2RoomWriteDurableOwnerBatchPath.Item] = []
        var policyInputs: [(execution: V2RoomPolicyExecution, command: V2SendMessageCommand)] = []
        var rows: [PlainDirectRoomLogBatchPreflightRow] = []
        for ordinal in plan.ordered {
            let command = prepared.commands[ordinal]
            guard command.firstSubmissionDeadlineMilliseconds > milliseconds,
                  command.firstSubmissionDeadlineMilliseconds - milliseconds <= 86_400_000,
                  command.command.roomID == prepared.token.roomID,
                  let store = prepared.preparations[plan.operationKeys[ordinal]],
                  let execution = store.policyExecution, execution.activation == prepared.token,
                  let policy = execution.snapshot.policy,
                  let accepted = prepared.acceptedDirect[plan.operationKeys[ordinal]] else { return nil }
            try store.validateAuthorizationCommand(command.command)
            policyInputs.append((execution, command.command))
            let key = try persistenceKey(identity: command.identity)
            if let routes = store.ownerRoutes {
                guard let route = routes[key.room], route.shardID == prepared.token.owner.shardID,
                      route.epoch == prepared.token.owner.epoch else { return nil }
            }
            guard store.controlScopeRoomKinds?[key.room] == nil || store.controlScopeRoomKinds?[key.room] == "direct" else { return nil }
            guard let row = try await v2MeasureSendOperationStage(.ownerRuntimeState, metrics: sendOperationMetrics, {
                try roomAcceptance.preflight(command: command.command, token: prepared.token,
                    policy: policy, ordinal: ordinal, now: resolvedAt)
            }), row.usesRuntimeState else { return nil }
            rows.append(row)
            let request = V2RoomWriteRequest(command: command.command, capacityProfile: capacityProfile,
                identifiers: try identifiers.make(at: resolvedAt), now: resolvedAt)
            items.append(.init(index: ordinal, request: request, roomID: key.room, senderID: key.actor,
                operationID: key.operation,
                policy: .init(controlPolicyScope: [.init(roomID: key.room, senderID: key.actor): policy],
                    controlScopeRoomKinds: store.controlScopeRoomKinds), leasedPolicy: policy, accepted: accepted))
        }
        try await V2RoomPolicyExecution.validateActive(policyInputs)
        let path = V2RoomWriteDurableOwnerBatchPath(strangerMessagePolicy: writes.strangerMessagePolicy)
        let appends = try path.reduce(items, rows: rows, usesPreloadedRows: true, metrics: sendOperationMetrics)
        guard V2RoomWriteDirectBatchPath.supportsSingleStatement(appends) else { return nil }
        let combined = V2DurableOwnerCombinedWrite(commands: Dictionary(uniqueKeysWithValues:
            plan.ordered.map { ($0, prepared.commands[$0]) }), resolvedAtMilliseconds: milliseconds)
        let receipts = try combined.receipts(for: appends)
        let byIndex = Dictionary(uniqueKeysWithValues: zip(appends, receipts).map { ($0.0.originalIndex, $0.1.receipt) })
        let values = try prepared.commands.indices.map { ordinal -> V2RoomMessagingResult in
            guard let receipt = byIndex[ordinal] else { throw V2MessageOperationValidationError.invalidReceipt }
            return .sendOperation(.receipt(receipt))
        }
        let metadata = try plan.ordered.map { try V2SendSuccessMetadata.Entry(plan.successMetadata[$0], now: resolvedAt) }
        sendOperationMetrics?.recordOwnerCohortStarted(handleCount: 1, commandCount: prepared.commands.count)
        do {
            try await observeOwnerTransaction(sql: connection.sql, scalar: false, handles: 1)
            let commits = try await V2SendSuccessMetadata.$current.withValue(metadata) {
                try await V2RoomWriteDirectBatchPath(strangerMessagePolicy: writes.strangerMessagePolicy)
                    .completeSingleStatement(appends, connection: connection, combinedWrite: combined,
                        metrics: sendOperationMetrics)
            }
            let outcomes = commits.map { $0.commit.outcome }
            await afterCommit { [preparationMemory, roomAcceptance, sendOperationMetrics, committedMessageObserver] in
                await preparationMemory.remember(commands: prepared.commands, results: values)
                roomAcceptance.committed(commands: prepared.commands, results: values, token: prepared.token)
                sendOperationMetrics?.recordOwnerCohortCommitted(acceptedCommandCount: values.count, replayedCommandCount: 0)
                committedMessageObserver?.observeCommittedMessages(outcomes, activation: prepared.token)
            }
            return values
        } catch {
            roomAcceptance.invalidate(prepared.token)
            // The runner exposes raw constraint failures only after an idle
            // confirmation proved the failed statement has settled. A stale
            // cursor is eligible only when all durable mutation counts were zero.
            if durableOwnerConstraintFailure(error) || error is V2RoomWriteStoreError {
                guard connection.isUsable() else { throw error }
                sendOperationMetrics?.recordOwnerCohortIsolation()
                return nil
            }
            throw error
        }
    }

    private func executePlainRoomTurn(_ prepared: V2PreparedMessageSendBatch,
        capacityProfile: V2CapacityProfile, identifiers: V2AcceptanceIDFactory,
        now: @escaping @Sendable () -> Date
    ) async throws -> PlainRoomTurnExecution {
        do {
            try Task.checkCancellation()
            guard V2RoomSQLDeadline.current.map({ ContinuousClock.now < $0 }) ?? true else {
                throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
            }
            sendOperationMetrics?.recordOwnerCohortStarted(handleCount: 1,
                commandCount: prepared.commands.count)
            let plan = try prepared.commandPlan ?? commandPlan(prepared)
            let committed: PlainRoomTurnCommit = try await v2WithRoomActivationTransactionWithContext(database: database,
                deadline: V2RoomSQLDeadline.boundedTransactionDeadline(),
                sendOperationMetrics: sendOperationMetrics,
                measureConnectionAcquire: pinnedOwnerConnectionIsUsable == nil,
                pinnedConnection: pinnedOwnerConnection) { transaction, fence in
                guard let sql = transaction as? any SQLDatabase else { throw V2MessageOperationValidationError.invalidReceipt }
                try await self.observeOwnerTransaction(sql: sql, scalar: false, handles: 1)
                // Command ordinals preserve this room's FIFO through the SQL vector write.
                let operations = prepared.commands
                let ordered = plan.ordered
                var inputs: [Int: V2DurableSendBatchReceiptInput] = [:]
                var scoped: [Int: PostgresV2RoomWriteStore] = [:]
                let lockKeys = ordered.map { plan.lockKeys[$0] }
                try await v2MeasureSendOperationStage(.ownerLocks, metrics: sendOperationMetrics) {
                    for ordinal in ordered {
                        let operation = operations[ordinal], handle = prepared
                        let command = operation
                        if let store = handle.preparations[plan.operationKeys[ordinal]] {
                            scoped[ordinal] = store
                            guard store.policyExecution != nil else {
                                throw V2ActorContractError.invalidConfiguration("message policy execution required")
                            }
                            inputs[ordinal] = .init(command: command)
                        } else {
                            inputs[ordinal] = .init(command: command)
                        }
                    }
                    var policyInputs: [(execution: V2RoomPolicyExecution, command: V2SendMessageCommand)] = []
                    for ordinal in ordered {
                        if let execution = scoped[ordinal]?.policyExecution {
                            guard execution.activation == prepared.token else {
                                throw V2RoomActivationLeaseError.activationChanged
                            }
                            policyInputs.append((execution, operations[ordinal].command))
                        }
                    }
                    try await V2RoomPolicyExecution.validateActive(policyInputs)
                    // Production room turns already retain their exact lifecycle
                    // until the physical transaction settles. Do not re-read and
                    // lock ownership/activation for each accepted message.
                    if !writes.usesMemorySendPreparation {
                        try await fence.requireDurableOwnersAndActivations(tokens: [prepared.token],
                            operations: lockKeys)
                    }
                }
                let receiptSets = PostgresV2DurableSendBatchReceipts()
                let allInputs = ordered.map { inputs[$0]! }
                let resolvedAt = now(), milliseconds = try timestamp(resolvedAt)
                let successMetadata = try ordered.map { try V2SendSuccessMetadata.Entry(plan.successMetadata[$0], now: resolvedAt) }
                return try await V2SendSuccessMetadata.$current.withValue(successMetadata) {
                let combinesCurrentDirect = Set(try allInputs.map { try $0.key }).count == allInputs.count && ordered.allSatisfy { ordinal in
                    guard let snapshot = scoped[ordinal]?.policyExecution?.snapshot,
                          snapshot.policy != nil else { return false }
                    return true
                }
                var preparedRead: V2DurableOwnerPreparedRead?
                var writeRequests: [Int: V2RoomWriteRequest] = [:]
                let snapshot: V2DurableSendBatchReceiptSnapshot
                if combinesCurrentDirect {
                    let requests = try ordered.map { ordinal -> OrderedRoomWriteRequest in
                        let operation = operations[ordinal], key = try persistenceKey(identity: operation.identity)
                        let request = V2RoomWriteRequest(command: operation.command, capacityProfile: capacityProfile,
                            identifiers: try identifiers.make(at: resolvedAt), now: resolvedAt)
                        writeRequests[ordinal] = request
                        return .init(originalIndex: ordinal, request: request, roomID: key.room, senderID: key.actor,
                            cacheKey: .init(roomID: key.room, senderID: key.actor), cachedDirectPolicy: nil,
                            usesRoomAdmissionCredits: false, preflightOrdinal: ordinal)
                    }
                    let policies = Dictionary(uniqueKeysWithValues: ordered.map { ($0, scoped[$0]!.policyExecution!.snapshot.policy!) })
                    let insertFirst = try ordered.allSatisfy { ordinal in
                        let operation = operations[ordinal]
                        return prepared.acceptedDirect[operationKey(identity: try operation.identity)] != nil
                    }
                    let runtimeRead: V2DurableOwnerPreparedRead?
                    if insertFirst {
                        runtimeRead = try await v2MeasureSendOperationStage(.ownerRuntimeState, metrics: sendOperationMetrics) {
                            var runtimeRows: [Int: PlainDirectRoomLogBatchPreflightRow] = [:]
                            for ordinal in ordered {
                                let command = operations[ordinal]
                                guard let row = try roomAcceptance.preflight(command: command.command,
                                        token: prepared.token, policy: policies[ordinal]!,
                                        ordinal: ordinal, now: resolvedAt) else { return nil }
                                runtimeRows[ordinal] = row
                            }
                            return .init(receipts: .init(existing: [:], completions: [:]), rooms: runtimeRows)
                        }
                    } else { runtimeRead = nil }
                    let combined: V2DurableOwnerPreparedRead
                    if let runtimeRead { combined = runtimeRead }
                    else {
                        combined = try await v2MeasureSendOperationStage(.ownerPreflight, metrics: sendOperationMetrics) {
                            try await V2DurableOwnerPreparedRead.load(inputs: allInputs, ordered: requests,
                                policies: policies, insertFirst: insertFirst, sql: sql)
                        }
                    }
                    preparedRead = combined
                    snapshot = combined.receipts
                } else {
                    snapshot = try await v2MeasureSendOperationStage(.ownerReceiptRead, metrics: sendOperationMetrics) {
                        try await receiptSets.snapshot(allInputs, sql: sql)
                    }
                }
                let (existing, completions) = (snapshot.existing, snapshot.completions)
                var results: [Int: V2MessageSendOperationRecoveryResult] = [:]
                // A turn is indivisible: an unsupported item excludes the whole turn.
                var fresh: [V2RoomWriteDurableOwnerBatchPath.Item] = []
                var replay: [Int: V2MessageSendOperationRecoveryResult] = [:]
                var eligible = true
                for ordinal in operations.indices {
                    let input = inputs[ordinal]!, key = try input.key, command = input.command
                    if let receipt = existing[key] { replay[ordinal] = receipt; continue }
                    guard completions[key] == nil, let store = scoped[ordinal],
                          command.firstSubmissionDeadlineMilliseconds > milliseconds,
                          command.firstSubmissionDeadlineMilliseconds - milliseconds <= 86_400_000 else {
                        eligible = false; break
                    }
                    try store.validateAuthorizationCommand(command.command)
                    let identity = try command.identity, ids = try persistenceKey(identity: identity)
                    if let routes = store.ownerRoutes {
                        guard let route = routes[ids.room], route.shardID == prepared.token.owner.shardID,
                              route.epoch == prepared.token.owner.epoch else { throw V2RoomOwnerFenceError.ownerChanged }
                    }
                    guard store.controlScopeRoomKinds?[ids.room] == nil || store.controlScopeRoomKinds?[ids.room] == "direct" else {
                        eligible = false; break
                    }
                    var policies: [V2DirectSendPolicyCache.Key: V2DirectSendControlPolicy]? = nil
                    if let policy = store.policyExecution?.snapshot.policy {
                        policies = [.init(roomID: ids.room, senderID: ids.actor): policy]
                    }
                    fresh.append(.init(index: ordinal,
                        request: try writeRequests[ordinal] ?? .init(command: command.command, capacityProfile: capacityProfile,
                            identifiers: identifiers.make(at: resolvedAt), now: resolvedAt),
                        roomID: ids.room, senderID: ids.actor, operationID: ids.operation,
                        policy: .init(controlPolicyScope: policies, controlScopeRoomKinds: store.controlScopeRoomKinds),
                        leasedPolicy: store.policyExecution?.snapshot.policy,
                        accepted: prepared.acceptedDirect[operationKey(identity: identity)]))
                }
                guard eligible else {
                    return PlainRoomTurnCommit(results: nil, newlyAccepted: [], usesRuntimeState: false)
                }
                results.merge(replay) { _, newer in newer }
                let items = fresh
                let appended = try await V2RoomWriteDurableOwnerBatchPath(strangerMessagePolicy: writes.strangerMessagePolicy)
                    .append(items, sql: sql, sendOperationMetrics: sendOperationMetrics,
                        preloadedRows: preparedRead?.rooms,
                        combinedWrite: combinesCurrentDirect ? .init(commands: Dictionary(uniqueKeysWithValues: ordered.map { ($0, operations[$0]) }),
                            resolvedAtMilliseconds: milliseconds) : nil)
                // A denied/unready command invalidates its entire turn,
                // including any previously reduced prefix. Isolation occurs
                // only after the actual enclosing transaction rolls back.
                guard appended.commits.count == items.count else {
                    throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
                }
                let commits = appended.commits
                for commit in commits {
                    let command = inputs[commit.originalIndex]!.command
                    guard let accepted = commit.commit.outcome.acceptanceReceipt else { throw V2MessageOperationValidationError.invalidReceipt }
                    let receipt = try V2MessageSendOperationReceipt(identity: command.identity, fingerprint: command.fingerprint,
                        outcome: .accepted(.init(messageID: accepted.messageID, roomSequence: accepted.roomSequence)), resolvedAtMilliseconds: milliseconds)
                    results[commit.originalIndex] = .receipt(receipt)
                }
                // Validate the complete response while the enclosing transaction owns all staged writes.
                let values = try operations.indices.map { ordinal in
                    guard let result = results[ordinal] else { throw V2MessageOperationValidationError.invalidReceipt }
                    return result
                }
                let response = PlainRoomTurnCommit(results: values,
                    newlyAccepted: commits.map { $0.commit.outcome },
                    usesRuntimeState: operations.indices.allSatisfy { preparedRead?.rooms[$0]?.usesRuntimeState == true })
                return response
                }
            }
            guard let values = committed.results else { return .scalarFallback(.optimizationNotApplicable) }
            await afterCommit { [preparationMemory, roomAcceptance, sendOperationMetrics, committedMessageObserver] in
                let results = values.map { V2RoomMessagingResult.sendOperation($0) }
                await preparationMemory.remember(commands: prepared.commands, results: results)
                roomAcceptance.committed(commands: prepared.commands, results: results, token: prepared.token)
                if !committed.usesRuntimeState { roomAcceptance.invalidateCursor(prepared.token) }
                sendOperationMetrics?.recordOwnerCohortCommitted(acceptedCommandCount: committed.newlyAccepted.count,
                    replayedCommandCount: values.count - committed.newlyAccepted.count)
                if !committed.newlyAccepted.isEmpty {
                    committedMessageObserver?.observeCommittedMessages(committed.newlyAccepted, activation: prepared.token)
                }
            }
            return .committed(values.map { .sendOperation($0) })
        } catch {
            // A failed/uncertain transaction cannot leave an authoritative local cursor.
            // Reload on the next execution; the scalar fallback resolves original IDs.
            roomAcceptance.invalidate(prepared.token)
            // Only proven pre-COMMIT failures may retry. COMMIT-unknown
            // failures propagate with the original stable message identities.
            let canRetryScalar: Bool
            switch error {
            case V2RoomActivationLeaseError.outcomeUnknown: canRetryScalar = false
            case is V2AtomicRoomWriteBatchError, is V2RoomActivationLeaseError,
                 is V2RoomOwnerFenceError, is LateShardAdmissionRejection,
                 is V2RoomWriteStoreError:
                canRetryScalar = true
            case V2RoomCallFailure.rolledBack: canRetryScalar = true
            default: canRetryScalar = durableOwnerConstraintFailure(error)
            }
            guard canRetryScalar, pinnedOwnerConnectionIsUsable?() != false else { throw error }
            sendOperationMetrics?.recordOwnerCohortIsolation()
            return .scalarFallback(.domainIsolation)
        }
    }

    private func executePreparedBody(_ prepared: V2PreparedMessageSendBatch,
                                     capacityProfile: V2CapacityProfile, identifiers: V2AcceptanceIDFactory,
                                     now: @escaping @Sendable () -> Date) async throws -> [V2RoomMessagingResult] {
        let commands = prepared.commands, token = prepared.token
        let authorizationPreparations = prepared.preparations
        let committed: ([V2MessageSendOperationRecoveryResult], [V2SendMessageOutcome?]) = try await v2WithRoomScopedTransaction(database: database, sendOperationMetrics: sendOperationMetrics,
                measureConnectionAcquire: pinnedOwnerConnectionIsUsable == nil,
                pinnedConnection: pinnedOwnerConnection) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2MessageOperationValidationError.invalidReceipt }
            try await self.observeOwnerTransaction(sql: sql, scalar: true, handles: 1)
            let keyed = try commands.map { command -> (V2MessageSendOperationCommand, V2OperationIdentity, V2OperationFingerprint) in
                (command, try command.identity, try command.fingerprint)
            }
            if !writes.usesMemorySendPreparation {
                // Acquire every operation lock first. Taking the room/activation
                // lock inside this loop lets two batches each hold an operation
                // lock while waiting for a policy transaction that needs the
                // other operation lock.
                var lockedOperations = Set<String>()
                for (_, identity, _) in keyed.sorted(by: {
                    let lhsActor = $0.1.accountID.uuidValue?.uuidString ?? ""
                    let rhsActor = $1.1.accountID.uuidValue?.uuidString ?? ""
                    if lhsActor != rhsActor { return lhsActor < rhsActor }
                    return $0.1.operation.rawOperationID < $1.1.operation.rawOperationID
                }) {
                    let operationKey = "\(identity.accountID.uuidValue?.uuidString ?? ""):\(identity.operation.rawOperationID)"
                    if lockedOperations.insert(operationKey).inserted {
                        _ = try await self.lockOperation(identity: identity, token: token, database: transaction)
                    }
                }
                try await v2RequireRoomActivation(token: token, sql: sql)
            }
            try await sql.raw("SAVEPOINT v2_message_batch_body").run()
            var results: [V2MessageSendOperationRecoveryResult] = []
            var accepted: [V2SendMessageOutcome?] = []
            for (index, command) in commands.enumerated() {
                let identity = keyed[index].1, fingerprint = keyed[index].2
                let processed = try await self.processSubmission(command, identity: identity,
                    fingerprint: fingerprint, token: token, capacityProfile: capacityProfile,
                    transaction: transaction, sql: sql, makeIdentifiers: { date in try identifiers.make(at: date) },
                    now: now, savepoint: "v2_message_domain_body_\(index)",
                    authorizationPreparation: authorizationPreparations[self.operationKey(identity: identity)],
                    isOperationBatch: true)
                results.append(processed.0)
                accepted.append(processed.1)
            }
            try await sql.raw("RELEASE SAVEPOINT v2_message_batch_body").run()
            return (results, accepted)
        }
        let newlyAccepted = committed.1.compactMap { $0 }
        await afterCommit { [committedMessageObserver] in
            if !newlyAccepted.isEmpty { committedMessageObserver?.observeCommittedMessages(newlyAccepted, activation: token) }
        }
        return committed.0.map(V2RoomMessagingResult.sendOperation)
    }

    private func processSubmission(
        _ command: V2MessageSendOperationCommand,
        identity: V2OperationIdentity,
        fingerprint: V2OperationFingerprint,
        token: V2RoomActivationToken,
        capacityProfile: V2CapacityProfile,
        transaction: any Database,
        sql: any SQLDatabase,
        makeIdentifiers: @Sendable (Date) throws -> V2AcceptanceIdentifiers,
        now: @Sendable () -> Date,
        savepoint: String,
        authorizationPreparation: PostgresV2RoomWriteStore? = nil,
        isOperationBatch: Bool = false,
        priorShardAdmissionReservations: [ShardAdmissionReservation] = [],
        acceptanceRejection: LateShardAdmissionRejection? = nil
    ) async throws -> (V2MessageSendOperationRecoveryResult, V2SendMessageOutcome?, ShardAdmissionReservation?) {
        let instant = now()
        return try await V2SendSuccessMetadata.$current.withValue([try .init(command, now: instant)]) {
            try await processSubmissionBody(command, identity: identity, fingerprint: fingerprint,
                token: token, capacityProfile: capacityProfile, transaction: transaction, sql: sql,
                makeIdentifiers: makeIdentifiers, now: { instant }, savepoint: savepoint,
                authorizationPreparation: authorizationPreparation, isOperationBatch: isOperationBatch,
                priorShardAdmissionReservations: priorShardAdmissionReservations,
                acceptanceRejection: acceptanceRejection)
        }
    }

    private func processSubmissionBody(
        _ command: V2MessageSendOperationCommand,
        identity: V2OperationIdentity,
        fingerprint: V2OperationFingerprint,
        token: V2RoomActivationToken,
        capacityProfile: V2CapacityProfile,
        transaction: any Database,
        sql: any SQLDatabase,
        makeIdentifiers: @Sendable (Date) throws -> V2AcceptanceIdentifiers,
        now: @Sendable () -> Date,
        savepoint: String,
        authorizationPreparation: PostgresV2RoomWriteStore? = nil,
        isOperationBatch: Bool = false,
        priorShardAdmissionReservations: [ShardAdmissionReservation] = [],
        acceptanceRejection: LateShardAdmissionRejection? = nil
    ) async throws -> (V2MessageSendOperationRecoveryResult, V2SendMessageOutcome?, ShardAdmissionReservation?) {
        if let result = try await existing(identity: identity, fingerprint: fingerprint,
            domain: command.command.fingerprint, sql: sql) { return (result, nil, nil) }
        let resolvedAt = now(), milliseconds = try timestamp(resolvedAt)
        guard command.firstSubmissionDeadlineMilliseconds > milliseconds,
              command.firstSubmissionDeadlineMilliseconds - milliseconds <= 86_400_000 else {
            return (.receipt(try makeReceipt(identity: identity, fingerprint: fingerprint, outcome: .rejected(.expiredUnsubmitted), now: resolvedAt)), nil, nil)
        }
        try await sql.raw("SAVEPOINT \(savepoint)").run()
        let outcome: V2SendMessageOutcome
        var shardAdmissionReservation: ShardAdmissionReservation?
        do {
            switch authorizationPreparation {
            case .some(let preparedWrites):
                let scopedWrites = try preparedWrites.usingWorkloadDatabase(transaction).usingOperationTransaction()
                    .usingActivationScope(.init(tokens: [token], reliesOnRuntimeLifecycle: writes.usesMemorySendPreparation))
                if isOperationBatch {
                    let accepted = try await scopedWrites.acceptForOperationBatch(command: command.command,
                        capacityProfile: capacityProfile, identifiers: try makeIdentifiers(resolvedAt), now: resolvedAt,
                        priorShardAdmissionReservations: priorShardAdmissionReservations)
                    outcome = accepted.outcome
                    shardAdmissionReservation = accepted.shardAdmissionReservation
                } else {
                    outcome = try await scopedWrites.accept(command: command.command,
                        capacityProfile: capacityProfile, identifiers: try makeIdentifiers(resolvedAt), now: resolvedAt)
                }
            case nil:
                // A missing preparation is expected only for a replay or an
                // expired command, both handled above.
                throw V2MessageOperationValidationError.invalidReceipt
            }
        } catch V2SendOperationResponseError.directPolicyDenied {
            // Keep the sender-only presentation hint, but never persist a
            // rejection receipt or message. The outer transaction owns commit.
            try await sql.raw("RELEASE SAVEPOINT \(savepoint)").run()
            return (.receipt(try makeReceipt(identity: identity, fingerprint: fingerprint, outcome: .rejected(.directPolicyDenied), now: resolvedAt)), nil, nil)
        } catch V2RoomWriteStoreError.strangerMessageLimitReached {
            try await rollbackBody(sql, savepoint: savepoint)
            return (.deferred(try .init(identity: identity, fingerprint: fingerprint, reason: .rateLimited,
                retryAfterMilliseconds: await quotaRetryAfter(room: token.roomID, actor: identity.accountID,
                    now: resolvedAt, sql: sql))), nil, nil)
        } catch V2RoomWriteStoreError.actorNotEligible, V2RoomWriteStoreError.actorMuted,
                V2RoomWriteStoreError.roomFrozen, V2MentionValidationError.notAuthorized {
            try await rollbackBody(sql, savepoint: savepoint)
            return (.receipt(try makeReceipt(identity: identity, fingerprint: fingerprint, outcome: .rejected(.permissionDenied), now: resolvedAt)), nil, nil)
        } catch V2RoomWriteStoreError.replyTargetNotFound, V2MentionValidationError.invalidTargetSet,
                V2MediaStoreError.mediaUnavailable, V2MediaStoreError.mediaExpired, V2MediaStoreError.invalidReferenceSet {
            // Roll back this command's body and return its current rejection.
            // It creates no durable result; a later submission is re-evaluated.
            // Neighbouring sends and prior successes retain their own results.
            try await rollbackBody(sql, savepoint: savepoint)
            return (.receipt(try makeReceipt(identity: identity, fingerprint: fingerprint, outcome: .rejected(.invalidContent), now: resolvedAt)), nil, nil)
        } catch V2RoomWriteStoreError.roomNotFound {
            try await rollbackBody(sql, savepoint: savepoint)
            return (.receipt(try makeReceipt(identity: identity, fingerprint: fingerprint, outcome: .rejected(.roomNotFound), now: resolvedAt)), nil, nil)
        }
        if case .accepted = outcome, let acceptanceRejection {
            // Recovery may find a rolled-back conflict is now a fresh command.
            // Its new acceptance cannot commit after the batch failed admission.
            try await rollbackBody(sql, savepoint: savepoint)
            return (try admissionDeferred(identity: identity, fingerprint: fingerprint,
                rejection: acceptanceRejection), nil, nil)
        }
        if case .denied = outcome {
            try await rollbackBody(sql, savepoint: savepoint)
        } else {
            try await sql.raw("RELEASE SAVEPOINT \(savepoint)").run()
        }
        if let accepted = outcome.acceptanceReceipt {
            let newlyAccepted: V2SendMessageOutcome? = { if case .accepted = outcome { return outcome }; return nil }()
            return (.receipt(try makeReceipt(identity: identity, fingerprint: fingerprint, outcome: .accepted(.init(messageID: accepted.messageID, roomSequence: accepted.roomSequence)), now: resolvedAt)), newlyAccepted, shardAdmissionReservation)
        }
        switch outcome {
        case .denied:
            return (.receipt(try makeReceipt(identity: identity, fingerprint: fingerprint, outcome: .rejected(.directPolicyDenied), now: resolvedAt)), nil, nil)
        case .idempotencyConflict: return (.fingerprintConflict, nil, nil)
        case .rateLimited(let seconds):
            return (.deferred(try .init(identity: identity, fingerprint: fingerprint, reason: .rateLimited,
                retryAfterMilliseconds: UInt64(min(86_400, max(1, seconds))) * 1000)), nil, nil)
        case .unavailable:
            return (.deferred(try .init(identity: identity, fingerprint: fingerprint,
                reason: .admissionUnavailable, retryAfterMilliseconds: nil)), nil, nil)
        case .accepted, .idempotent: throw V2MessageOperationValidationError.invalidReceipt
        }
    }

    private func requiresDomainRecovery(_ result: V2MessageSendOperationRecoveryResult) -> Bool {
        switch result {
        case .fingerprintConflict: return true
        case .receipt(let receipt): return receipt.outcome == .rejected(.directPolicyDenied)
        default: return false
        }
    }

    private func admissionDeferred(identity: V2OperationIdentity, fingerprint: V2OperationFingerprint,
                                   rejection: LateShardAdmissionRejection) throws -> V2MessageSendOperationRecoveryResult {
        switch rejection {
        case .rateLimited(let seconds):
            return .deferred(try .init(identity: identity, fingerprint: fingerprint,
                reason: .rateLimited, retryAfterMilliseconds: UInt64(min(86_400, max(1, seconds))) * 1000))
        case .unavailable:
            return .deferred(try .init(identity: identity, fingerprint: fingerprint,
                reason: .admissionUnavailable, retryAfterMilliseconds: nil))
        }
    }

    private func withPreparedExecution<T: Sendable>(
        operation: @Sendable (Self) async throws -> T) async throws -> T {
        var scoped = self
        scoped.executionPrepared = true
        return try await operation(scoped)
    }

    private func operationKey(identity: V2OperationIdentity) -> String {
        let room: String
        if case .room(let roomID) = identity.scope { room = roomID.uuidValue?.uuidString.lowercased() ?? "" }
        else { room = "" }
        return "\(room):\(identity.accountID.uuidValue?.uuidString.lowercased() ?? ""):\(identity.operation.rawOperationID.lowercased())"
    }
    /// Recovery is a read of committed results, independent of room activation.
    /// Absence remains unresolved when a query races a late commit.
    public func recover(_ request: V2MessageSendOperationRecoveryRequest,
                        token: V2RoomActivationToken) async throws -> V2MessageSendOperationRecoveryResult {
        guard case .room(let room) = request.identity.scope, room == token.roomID else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        return try await Self.queryRecovery(request, database: database)
    }

    public static func queryRecovery(_ request: V2MessageSendOperationRecoveryRequest,
                                     database: any Database) async throws -> V2MessageSendOperationRecoveryResult {
        guard request.identity.kind == .sendMessage,
              case .room(let room) = request.identity.scope, let roomID = room.uuidValue,
              let actorID = request.identity.accountID.uuidValue,
              let operationID = UUID(uuidString: request.identity.operation.rawOperationID),
              database is any SQLDatabase else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        return try await v2WithOwnerBatchConnection(database: database,
            deadline: V2RoomSQLDeadline.boundedTransactionDeadline(), metrics: nil, interrupted: { _ in }) { borrowed, _ in
            guard let borrowedSQL = borrowed as? any SQLDatabase else {
                throw V2MessageOperationValidationError.invalidReceipt
            }
            guard let row = try await borrowedSQL.raw("""
                SELECT message_id, room_sequence, request_fingerprint AS domain_fingerprint,
                       fingerprint_version, operation_fingerprint, operation_resolved_at_ms
                FROM im_v2.message_send_completions
                WHERE room_id=\(bind: roomID) AND sender_user_id=\(bind: actorID)
                  AND client_message_id=\(bind: operationID)
                """).first(decoding: V2SendSuccessRow.self) else { return .unresolved }
            return try row.result(identity: request.identity, fingerprint: request.fingerprint, domain: request.domainFingerprint)
        }
    }
    private func lock(identity:V2OperationIdentity,token:V2RoomActivationToken,database:any Database) async throws -> any SQLDatabase {
        let sql = try await lockOperation(identity: identity, token: token, database: database)
        try await v2RequireRoomActivation(token:token,sql:sql)
        return sql
    }
    private func lockOperation(identity:V2OperationIdentity,token:V2RoomActivationToken,database:any Database) async throws -> any SQLDatabase {
        let key = try persistenceKey(identity: identity)
        guard key.room == token.roomID.uuidValue, let sql=database as? any SQLDatabase else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended('v2-message-operation:' || \(bind:key.room)::text || ':' || \(bind:key.actor)::text || ':' || \(bind:key.operation)::text,0))").run()
        return sql
    }
    private func persistenceKey(identity: V2OperationIdentity) throws -> (room: UUID, actor: UUID, operation: UUID) {
        guard identity.kind == .sendMessage, case .room(let room) = identity.scope,
              let roomUUID = room.uuidValue, let actor = identity.accountID.uuidValue,
              let operation = UUID(uuidString: identity.operation.rawOperationID) else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        return (roomUUID, actor, operation)
    }
    private func existing(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,domain:V2SendMessageFingerprint,sql:any SQLDatabase) async throws -> V2MessageSendOperationRecoveryResult? {
        let key = try persistenceKey(identity: identity)
        guard let row = try await sql.raw("""
            SELECT message_id, room_sequence, request_fingerprint AS domain_fingerprint,
                   fingerprint_version, operation_fingerprint, operation_resolved_at_ms
            FROM im_v2.message_send_completions
            WHERE room_id=\(bind:key.room) AND sender_user_id=\(bind:key.actor)
              AND client_message_id=\(bind:key.operation)
            """).first(decoding: V2SendSuccessRow.self) else { return nil }
        return try row.result(identity: identity, fingerprint: fingerprint, domain: domain)
    }
    private func decodeExisting(_ row: SendReceiptRow, identity: V2OperationIdentity,
        fingerprint: V2OperationFingerprint, domain: V2SendMessageFingerprint) throws -> V2MessageSendOperationRecoveryResult {
        try row.receipt.result(identity: identity, fingerprint: fingerprint, domain: domain)
    }
    private func makeReceipt(identity: V2OperationIdentity, fingerprint: V2OperationFingerprint,
        outcome: V2MessageSendOperationTerminalOutcome, now: Date) throws -> V2MessageSendOperationReceipt {
        // Success is already durable in completion_insert. Rejections are
        // response-only; constructing an ACK performs no database work.
        try .init(identity: identity, fingerprint: fingerprint, outcome: outcome,
            resolvedAtMilliseconds: timestamp(now))
    }
    private func quotaRetryAfter(room:RoomID,actor:UserID,now:Date,sql:any SQLDatabase) async throws -> UInt64 {
        let seconds=writes.strangerQuotaWindowSeconds
        let row=try await sql.raw("""
            SELECT quota_window.window_started_at AS started_at
            FROM im_v2.direct_room_pairs pair JOIN im_v2.stranger_message_windows quota_window
              ON quota_window.sender_user_id=\(bind:actor.uuidValue!)
              AND quota_window.recipient_user_id=CASE WHEN pair.lower_user_id=\(bind:actor.uuidValue!) THEN pair.higher_user_id ELSE pair.lower_user_id END
            WHERE pair.room_id=\(bind:room.uuidValue!)
            """).first(decoding:QuotaWindow.self)
        let remaining=row.map { $0.startedAt.addingTimeInterval(seconds).timeIntervalSince(now) } ?? seconds
        return UInt64(min(86_400_000,max(1000,ceil(remaining*1000))))
    }
    private func rollbackBody(_ sql:any SQLDatabase, savepoint:String) async throws {
        try await sql.raw("ROLLBACK TO SAVEPOINT \(savepoint)").run()
        try await sql.raw("RELEASE SAVEPOINT \(savepoint)").run()
    }
    private func timestamp(_ date: Date) throws -> UInt64 {
        try v2PositiveMilliseconds(date, invalid: V2MessageOperationValidationError.invalidReceipt)
    }
}
private struct SendReceiptRow:Decodable {
    let receipt:V2SendSuccessRow;let domainFingerprint:Data
    enum CodingKeys:String,CodingKey { case receipt,domainFingerprint="domain_fingerprint" }
}

private struct QuotaWindow:Decodable { let startedAt:Date;enum CodingKeys:String,CodingKey { case startedAt="started_at" } }

/// Store-minted read result, retained with the original room turn budget.
/// It has no execution authority and exposes no mutating or retargeting API.
package struct V2OwnerMessageSendPreparationInput: Sendable {
    fileprivate let owner: UUID
    package let request: V2MessageSendPreparationRequest
    fileprivate let pending: [V2MessageSendOperationCommand]
    fileprivate let preparationSnapshot: [String: [DurableSendPreparationRow]]
}

/// Opaque, immutable preparation owned by one operation-store instance.
/// It cannot be constructed or retargeted by callers. It conveys no authority
/// beyond the commands and exact runtime execution token.
public struct V2PreparedMessageSendBatch: Sendable {
    package var activationToken: V2RoomActivationToken { token }
    package var commandPayload: [V2MessageSendOperationCommand] { commands }
    package var originalDeadline: ContinuousClock.Instant { deadline }
    fileprivate let owner: UUID
    fileprivate let commands: [V2MessageSendOperationCommand]
    package let retainedByteBudget: Int
    fileprivate let token: V2RoomActivationToken
    fileprivate var preparations: [String: PostgresV2RoomWriteStore]
    let deadline: ContinuousClock.Instant
    fileprivate let preparationSnapshot: [String: [DurableSendPreparationRow]]
    fileprivate var policyPreparations: [V2RoomPolicyPreparation] = []
    fileprivate var acceptedDirect: [String: V2AcceptedDirectSend] = [:]
    fileprivate var commandPlan: PreparedRoomCommandPlan? = nil
}

fileprivate struct PreparedRoomCommandPlan: Sendable {
    let ordered: [Int]
    let operationKeys: [String]
    let lockKeys: [V2DurableOwnerBatchOperationKey]
    let successMetadata: [V2SendSuccessMetadata.Prepared]
}

private enum PlainRoomTurnExecution: Sendable {
    case committed([V2RoomMessagingResult])
    case scalarFallback(V2SendOperationOwnerScalarFallbackReason)
}

private struct PlainRoomTurnCommit: Sendable {
    let results: [V2MessageSendOperationRecoveryResult]?
    let newlyAccepted: [V2SendMessageOutcome]
    let usesRuntimeState: Bool
}

// Physical transaction runner only returns raw class-23 errors after the
// pre-COMMIT transaction has actually rolled back. COMMIT uncertainty is
// wrapped as V2RoomTransactionOutcomeUnknown and never matches this predicate.
private func durableOwnerConstraintFailure(_ error: any Error) -> Bool {
    let state: String?
    if let error = error as? PSQLError { state = error.serverInfo?[.sqlState] }
    else if let error = error as? PostgresError, case .server(let message) = error { state = message.fields[.sqlState] }
    else { return false }
    return state?.hasPrefix("23") == true
}

fileprivate struct DurableSendPreparationRow: Sendable {
    let roomID: UUID
    let senderID: UUID
    let receipt: V2SendSuccessRow
    var domainFingerprint: Data { receipt.domainFingerprint }
}

/// Only confirmed permanent outcomes enter this bounded cache. A miss follows
/// the durable execution path; absence in memory never authorizes a new insert.
private actor V2SendPreparationResultMemory {
    private var rows = V2BoundedInsertionCache<String, DurableSendPreparationRow>(capacity: 8192)
    private func key(_ command: V2MessageSendOperationCommand) -> String {
        "\(command.command.roomID.rawValue):\(command.command.senderUserID.rawValue):\(command.command.clientMessageID.rawValue)"
    }
    func snapshot(_ commands: [V2MessageSendOperationCommand]) -> [String: [DurableSendPreparationRow]] {
        var result: [String: [DurableSendPreparationRow]] = [:]
        for command in commands {
            guard let row = rows.value(for: key(command)) else { continue }
            let operation = [row.roomID, row.senderID, UUID(uuidString: command.command.clientMessageID.rawValue)!].map { $0.uuidString.lowercased() }.joined(separator: ":")
            result[operation] = [row]
        }
        return result
    }
    func remember(commands: [V2MessageSendOperationCommand], results: [V2RoomMessagingResult]) {
        guard commands.count == results.count else { return }
        for (command, result) in zip(commands, results) {
            guard case .sendOperation(.receipt(let receipt)) = result,
                  let room = command.command.roomID.uuidValue,
                  let sender = command.command.senderUserID.uuidValue,
                  case .accepted(let accepted) = receipt.outcome,
                  let message = accepted.messageID.uuidValue,
                  let fingerprint = try? command.fingerprint,
                  let resolved = Int64(exactly: receipt.resolvedAtMilliseconds) else { continue }
            let k = key(command)
            rows.insert(.init(roomID: room, senderID: sender, receipt: .init(messageID: message, roomSequence: Int64(accepted.roomSequence),
                    domainFingerprint: command.command.fingerprint.digest, fingerprintVersion: 3,
                    operationFingerprint: fingerprint.digest, resolvedAt: resolved)), for: k)
        }
    }
}
