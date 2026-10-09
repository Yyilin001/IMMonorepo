import Foundation
import Synchronization
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerApplication

/// Sole owner of local recovery scopes, proofs, watermarks, scheduling tickets
/// and Ready receipts. It cannot mutate the connection identity directory.
actor V2RealtimeRecoveryCoordinator {
    typealias Generation = UInt64
    typealias RecoveryKey = V2RealtimeRecoveryKey
    typealias PreparedPresenceHandoff = V2PreparedPresenceHandoff
    private nonisolated let contexts = Mutex<[UUID: V2RealtimeRecoveryConnectionContext]>([:])
    private nonisolated let writesEnabled = Mutex(true)
    private nonisolated let realtimeDeliveryFences = Mutex<[RecoveryKey: Generation]>([:])
    private nonisolated let configuredPorts = Mutex<V2RealtimeRecoveryPorts?>(nil)
    private nonisolated var ports: V2RealtimeRecoveryPorts? { configuredPorts.withLock { $0 } }
    private var presenceInterests: V2SharedGroupEventWakeInterests?
    private var typingInterests: V2SharedGroupEventWakeInterests?
    private struct InterestOwnerKey: Hashable, Sendable {
        let connection: UUID
        let kind: V2RealtimeTopicKind
        init(_ key: RecoveryKey) { connection = key.connection; kind = key.kind }
        init(connection: UUID, kind: V2RealtimeTopicKind) { self.connection = connection; self.kind = kind }
    }
    private struct InterestOwners: Sendable {
        private var tickets: [InterestOwnerKey: V2RecoveryInterestTicket] = [:]
        private var retired: Set<InterestOwnerKey> = []
        subscript(_ slot: InterestOwnerKey) -> V2RecoveryInterestTicket? {
            get { tickets[slot] }
            set {
                tickets[slot] = newValue
                if let newValue, !newValue.isActive { retired.insert(slot) }
                else { retired.remove(slot) }
            }
        }
        var values: Dictionary<InterestOwnerKey, V2RecoveryInterestTicket>.Values { tickets.values }
        var count: Int { tickets.count }
        var retiredCount: Int { retired.count }
        var nextRetired: V2RecoveryInterestTicket? { retired.first.flatMap { tickets[$0] } }
        mutating func retire(_ slot: InterestOwnerKey) {
            guard let ticket = tickets[slot] else { return }
            ticket.revoke(); retired.insert(slot)
        }
        mutating func retireAll() {
            for (slot, ticket) in tickets { ticket.revoke(); retired.insert(slot) }
        }
        @discardableResult mutating func removeValue(forKey slot: InterestOwnerKey) -> V2RecoveryInterestTicket? {
            retired.remove(slot); return tickets.removeValue(forKey: slot)
        }
        func hasConnection(_ connection: UUID) -> Bool {
            supportedKinds.contains { tickets[InterestOwnerKey(connection: connection, kind: $0)] != nil }
        }
        private var supportedKinds: Set<V2RealtimeTopicKind> { V2RealtimeRecoveryCoordinator.scopedInterestKinds }
        func connectionTickets(_ connection: UUID) -> [V2RecoveryInterestTicket] {
            supportedKinds.compactMap { tickets[InterestOwnerKey(connection: connection, kind: $0)] }
        }
    }
    // One slot per connection and supported subscription kind, including retired
    // generations until the bounded release stage takes actual ownership.
    private nonisolated let interestTickets = Mutex(InterestOwners())
    private var interestCleanup: Task<Void, Never>?
    // ConnectionDirectory permits only one actual detach owner per connection;
    // its occupied position remains charged while this one receipt is waiting.
    private var interestConnectionDrains: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var liveActivityInstalled = false
    private let interestReleases: V2RecoveryInterestReleaseExecutor
    private static let scopedInterestKinds: Set<V2RealtimeTopicKind> = [.userPresence, .roomTyping]
    private let maximumInterestOwners: Int

    init(maximumConnections: Int = 10_000) {
        precondition(maximumConnections > 0 && maximumConnections <= Int.max / Self.scopedInterestKinds.count)
        maximumInterestOwners = maximumConnections * Self.scopedInterestKinds.count
        interestReleases = V2RecoveryInterestReleaseExecutor()
    }
    private var liveActivityBroker: (any V2LiveActivityInterestManaging & V2LiveActivityPublishing)?
    private var userSyncInterests: V2SharedGroupEventWakeInterests?
    private nonisolated let generations = Mutex(UInt64(0))

    private struct RealtimeRecoveryDemand: Sendable {
        let createdAt: ContinuousClock.Instant = .now
        var reason: V2RegistryRecoveryReason = .initial
        let generation: Generation
        let scopeGeneration: Generation
        let scope: UUID?
        var nextAttempt: ContinuousClock.Instant
        var attempts: Int = 0
        var version = UUID()
        var hintOnly = false
        var notificationValidity: (@Sendable () -> Bool)?
    }
    private var realtimeRecoveryDemands = V2RecoveryOrderedStore<RecoveryKey, RealtimeRecoveryDemand>()
    private var recoveryJobIDs: [RecoveryKey: UUID] = [:]
    private struct RecoveryTask {
        let task: Task<Void, Never>
        let began: ContinuousClock.Instant
        let lane: RecoveryLane
    }
    private enum RecoveryLane { case interest, query, control }
    private var recoveryTasks: [UUID: RecoveryTask] = [:]
    private struct AccountInterestAcquisition {
        let lifecycle: UInt64
        let generation: UInt64
        let scope: UUID
    }
    private var accountInterestAcquisitions: [UUID: AccountInterestAcquisition] = [:]
    // Outbound tickets consume the same bounded work positions as queued
    // scopes, but never an actual permission-query slot.
    private var outboundRecoveryTickets: [RecoveryKey: UUID] = [:]

    // Same outbound position, not another queue: only a failed exact handoff
    // may return its original, still-valid proof to prepared work.
    private var selectedHandoffPositions: Set<RecoveryKey> = []
    private struct AuthorizationReturnTicket {
        let lifecycle: Generation
        let generation: Generation
        let began: ContinuousClock.Instant
    }
    // A selected auth scope keeps its original queue position's capacity until
    // its actual result returns. Scope detachment never lends it to a successor.
    private var authorizationReturns: [UUID: [RecoveryKey: AuthorizationReturnTicket]] = [:]
    private var reservedAuthorizationReturnCount = 0

    // One immutable observation per desired presence scope, under this sole
    // scope owner. Its SQL observation deadline is never extended by delivery.
    private var preparedPresenceObservations: [RecoveryKey: PreparedPresenceHandoff] = [:]

    private struct InlineRetentionTicket {
        let id = UUID()
        let lifecycle: Generation
        let generation: Generation
        let started: ContinuousClock.Instant = .now
    }
    // Actual calls are owned by the existing four ingress consumers, not new
    // Tasks. Scope removal revokes permits but never frees these actual slots.
    private var inlineRetentions: [RecoveryKey: InlineRetentionTicket] = [:]
    private var inlineRetentionDrain: CheckedContinuation<Void, Never>?

    private var realtimeRecoveryWake: Task<Void, Never>?
    private var recoverySchedulerTask: Task<Void, Never>?
    private var recoverySchedulerRequested = false
    private let recoveryScanQuantum = 128
    private nonisolated let schedulingTelemetry = V2RecoverySchedulingTelemetry()
    private enum RecoveryServiceClass: Int, CaseIterable {
        case preparedPresence, presenceQuery, otherInterest, otherScope
    }
    // Admission and actual starts advance this fixed category rotation. Empty
    // classes may borrow separate query/control slots; prepared work cannot
    // indefinitely bypass permission work or account installation.
    private var nextRecoveryServiceClass = RecoveryServiceClass.preparedPresence
    // Queued ownership is a placement on the primary demand node.
    private let maximumQueuedRealtimeRecoveries = 1_024

    private var realtimeRecoveryClosed = false
    private var realtimeRecoveryShutdown: Task<Void, Never>?
    private var userSyncInstalled: Set<UUID> = []
    private nonisolated let scopeGenerations = V2RealtimeScopeGenerations()
    private var installedScopes: Set<RecoveryKey> = []
    private struct ScopeRetentionReceipt {
        let lifecycle: Generation
        let generation: Generation
        var highWatermark: UInt64
        var observedPresence: Bool
        let presenceDeadline: ContinuousClock.Instant?
    }
    // One latest requirement/receipt per currently requested local scope.
    // These are recovery ownership records, never client-applied cursors.
    private var recoveryHeadRequirements: [RecoveryKey: UInt64] = [:]
    private var scopeRetentionReceipts: [RecoveryKey: ScopeRetentionReceipt] = [:]
    private struct RetainedReadyConfirmation {
        let confirmation: V2RealtimeCoverageConfirmation
        let highWatermark: UInt64
    }
    private var retainedConfirmations: [RecoveryKey: RetainedReadyConfirmation] = [:]
    private var recoveryExecutionStage: [RecoveryKey: (V2RegistryRecoveryStage, ContinuousClock.Instant)] = [:]
    private var actualRecoveryReasons: [RecoveryKey: V2RegistryRecoveryReason] = [:]
    private var duplicateRetained: [V2RegistryRecoveryScopeKind: UInt64] = [:]
    private var journalUserBaselineBarrier: (@Sendable (UserID) async throws -> V2GatewayJournalReadyAuthorization)?
    private nonisolated let journalScopeAuthorizations = Mutex<[RecoveryKey: V2GatewayJournalReadyAuthorization]>([:])
    private struct PendingRecoveryState {
        let version: Generation
        let reason: IMV2RealtimeCoverage.Reason
    }
    private var pendingRecoveryStates: [RecoveryKey: PendingRecoveryState] = [:]
    private struct ReadyRetentionFence: Sendable {
        let generation: Generation
        var required: UInt64
        var retained: UInt64?
        var presence: Bool
        var recoveringPending: Bool
    }
    private nonisolated let readyRetentionFences = Mutex<[RecoveryKey: ReadyRetentionFence]>([:])
    private var realtimeCoverageConfirmation: (@Sendable (V2RealtimeTopicKind, String) -> V2RealtimeCoverageConfirmation?)?
    private var realtimeCoverageValidation: (@Sendable (V2RealtimeTopicKind, String, V2RealtimeCoverageConfirmation) -> Bool)?

    // A fixed worker budget, independent of socket authentication and heartbeats.
    private let maximumRealtimeRecoveryJobs = 4

    private nonisolated func context(_ connection: UUID) -> V2RealtimeRecoveryConnectionContext? {
        contexts.withLock { $0[connection] }
    }
    nonisolated func installConnection(_ context: V2RealtimeRecoveryConnectionContext) {
        contexts.withLock { $0[context.handle.connectionID] = context }
    }
    /// The identity owner revokes enqueue capabilities before its first await.
    @discardableResult
    nonisolated func revokeConnection(_ connection: UUID, lifecycle: UInt64) -> Set<V2RealtimeRecoveryKey> {
        let revoked = contexts.withLock { state -> Bool in
            guard state[connection]?.handle.lifecycle == lifecycle else { return false }
            state.removeValue(forKey: connection); return true
        }
        guard revoked else { return [] }
        let keys = scopeGenerations.removeConnection(connection)
        interestTickets.withLock { tickets in
            for kind in Self.scopedInterestKinds { tickets.retire(.init(connection: connection, kind: kind)) }
        }
        for key in keys {
            realtimeDeliveryFences.withLock { $0.removeValue(forKey: key) }
            journalScopeAuthorizations.withLock { $0.removeValue(forKey: key) }
            readyRetentionFences.withLock { $0.removeValue(forKey: key) }
        }
        return keys
    }
    nonisolated func revokeAllWrites() {
        writesEnabled.withLock { $0 = false }
        interestTickets.withLock { $0.retireAll() }
    }
    nonisolated func generation(for key: V2RealtimeRecoveryKey) -> UInt64? { scopeGenerations[key] }
    nonisolated func configurePorts(_ ports: V2RealtimeRecoveryPorts) { configuredPorts.withLock { $0 = ports } }
    func configureCoverage(current: @escaping @Sendable (V2RealtimeTopicKind, String) -> V2RealtimeCoverageConfirmation?,
        confirms: @escaping @Sendable (V2RealtimeTopicKind, String, V2RealtimeCoverageConfirmation) -> Bool) {
        realtimeCoverageConfirmation = current; realtimeCoverageValidation = confirms
    }
    func configureUserSync(_ interests: V2SharedGroupEventWakeInterests) { userSyncInterests = interests }
    func configureLiveActivity(_ broker: any V2LiveActivityInterestManaging & V2LiveActivityPublishing) {
        precondition(!liveActivityInstalled && !realtimeRecoveryClosed && contexts.withLock { $0.isEmpty })
        liveActivityInstalled = true
        liveActivityBroker = broker
        presenceInterests = V2SharedGroupEventWakeInterests(underlying: V2RecoveryLiveInterestAdapter(broker: broker, presence: true))
        typingInterests = V2SharedGroupEventWakeInterests(underlying: V2RecoveryLiveInterestAdapter(broker: broker, presence: false))
    }
    func configureJournalUserBaseline(_ barrier: @escaping @Sendable (UserID) async throws -> V2GatewayJournalReadyAuthorization) {
        precondition(contexts.withLock { $0.isEmpty })
        journalUserBaselineBarrier = barrier
    }
    private nonisolated func makeGeneration(atLeast minimum: UInt64 = 0) -> Generation {
        generations.withLock { value in
            value = max(value, minimum); value &+= 1
            precondition(value != 0, "recovery generation exhausted"); return value
        }
    }
    private nonisolated func advanceGeneration(to value: UInt64) {
        generations.withLock { $0 = max($0, value) }
    }
    /// Subscription owners publish their intent synchronously, then submit the
    /// actor transition with this exact generation. Actor admission order is
    /// never used as a substitute for the intent's version.
    nonisolated func requestScope(_ key: V2RealtimeRecoveryKey, lifecycle: UInt64) -> UInt64? {
        guard key.kind != .roomEvents else { return nil }
        return writesEnabled.withLock { enabled in
            guard enabled else { return nil }
            return contexts.withLock { contexts in
                guard contexts[key.connection]?.handle.lifecycle == lifecycle else { return nil }
                let generation = makeGeneration(atLeast: lifecycle)
                scopeGenerations[key] = generation
                interestTickets.withLock { $0.retire(InterestOwnerKey(key)) }
                return generation
            }
        }
    }
    @discardableResult
    nonisolated func revokeScope(_ key: V2RealtimeRecoveryKey, generation: UInt64) -> Bool {
        guard scopeGenerations.removeValue(forKey: key, ifGeneration: generation) != nil else { return false }
        interestTickets.withLock { tickets in if tickets[InterestOwnerKey(key)]?.generation == generation { tickets.retire(InterestOwnerKey(key)) } }
        realtimeDeliveryFences.withLock { state in
            if state[key] == generation { state.removeValue(forKey: key) }
        }
        readyRetentionFences.withLock { state in
            if state[key]?.generation == generation { state.removeValue(forKey: key) }
        }
        return true
    }
    private var recoveryQueueOccupancy: Int {
        recoveryQueuedCount + reservedAuthorizationReturnCount + outboundRecoveryTickets.count + selectedHandoffPositions.count
    }
    private func connectionsWithInterest(in topic: V2RealtimeTopic) -> Set<UUID> {
        Set(scopeGenerations.matching(kind: topic.kind, id: topic.id).filter { context($0.connection) != nil }.map(\.connection))
    }
    private func interestTicket(_ key: RecoveryKey, demand: RealtimeRecoveryDemand) throws -> V2RecoveryInterestTicket {
        guard scopeIsCurrent(key, demand), !realtimeRecoveryClosed else { throw CancellationError() }
        let shared: V2SharedGroupEventWakeInterests?
        switch key.kind {
        case .roomEvents: shared = nil
        case .userPresence: shared = presenceInterests
        case .roomTyping: shared = typingInterests
        case .userSync: shared = nil
        }
        guard let shared else { throw V2RealtimePublicationBackpressure.receiverQueue }
        return try writesEnabled.withLock { enabled in
            guard enabled else { throw CancellationError() }
            return try contexts.withLock { contexts in
                guard contexts[key.connection]?.handle.lifecycle == demand.generation,
                      scopeGenerations[key] == demand.scopeGeneration else { throw CancellationError() }
                return try interestTickets.withLock { tickets in
                    let slot = InterestOwnerKey(key)
                    if let current = tickets[slot] {
                        guard current.key == key, current.lifecycle == demand.generation,
                              current.generation == demand.scopeGeneration, current.isActive else {
                            // A different target cannot bypass a retired owner.
                            throw V2RealtimePublicationBackpressure.receiverQueue
                        }
                        return current
                    }
                    guard tickets.count < maximumInterestOwners else {
                        throw V2RealtimePublicationBackpressure.receiverQueue
                    }
                    let ticket = V2RecoveryInterestTicket(key: key, lifecycle: demand.generation,
                        generation: demand.scopeGeneration, interests: shared)
                    tickets[slot] = ticket
                    return ticket
                }
            }
        }
    }

    private func releaseInterest(_ key: RecoveryKey, generation: UInt64? = nil,
        excludingGeneration: UInt64? = nil) async {
        let ticket = interestTickets.withLock { tickets -> V2RecoveryInterestTicket? in
            guard let ticket = tickets[InterestOwnerKey(key)], ticket.key == key,
                  generation == nil || ticket.generation == generation,
                  excludingGeneration == nil || ticket.generation != excludingGeneration else { return nil }
            tickets.retire(InterestOwnerKey(key)); return ticket
        }
        guard let ticket else { return }
        if await interestReleases.trySubmit(ticket: ticket) {
            removeTransferredTicket(ticket)
        } else { startInterestCleanup() }
    }

    private func removeTransferredTicket(_ ticket: V2RecoveryInterestTicket) {
        interestTickets.withLock { tickets in
            let slot = InterestOwnerKey(ticket.key)
            if tickets[slot]?.ownerID == ticket.ownerID { tickets.removeValue(forKey: slot) }
        }
        if !interestTickets.withLock({ $0.hasConnection(ticket.key.connection) }) {
            interestConnectionDrains.removeValue(forKey: ticket.key.connection)?.resume()
        }
        if !realtimeRecoveryClosed { pumpRealtimeRecovery() }
    }

    private func waitForConnectionInterestTransfer(_ connection: UUID) async {
        await withCheckedContinuation { continuation in
            guard interestTickets.withLock({ $0.hasConnection(connection) }) else {
                continuation.resume(); return
            }
            precondition(interestConnectionDrains[connection] == nil, "one actual connection detach owner")
            interestConnectionDrains[connection] = continuation
            startInterestCleanup()
        }
    }

    private func startInterestCleanup() {
        guard interestCleanup == nil else { return }
        interestCleanup = Task { await self.runInterestCleanup() }
    }

    private func runInterestCleanup() async {
        defer { interestCleanup = nil }
        while let ticket = interestTickets.withLock({ $0.nextRetired }) {
            // Keep this exact head while capacity is exhausted. New revocations
            // do not create waiters or rescan every currently online owner.
            while !(await interestReleases.trySubmit(ticket: ticket)) {
                await interestReleases.waitForCapacity()
            }
            removeTransferredTicket(ticket)
        }
    }

    private func releaseAllInterests() async {
        interestTickets.withLock { $0.retireAll() }
        startInterestCleanup()
        await interestCleanup?.value
    }

    private func activateMeasured(_ shared: V2SharedGroupEventWakeInterests,
        activations: [V2SharedGroupEventWakeInterests.Activation]) async throws {
        let began = ContinuousClock.now
        defer { schedulingTelemetry.record(.interestProvider, duration: began.duration(to: .now)) }
        try await shared.activate(activations)
    }

    private func activateMeasured(_ manager: any V2GroupEventWakeInterestManaging, room: RoomID) async throws {
        let began = ContinuousClock.now
        defer { schedulingTelemetry.record(.interestProvider, duration: began.duration(to: .now)) }
        try await manager.activate(roomID: room)
    }

    private func activateInterest(_ ticket: V2RecoveryInterestTicket) async throws {
        guard ticket.beginActivation() else { throw CancellationError() }
        do {
            try await activateMeasured(ticket.interests, activations: [try ticket.activation])
            ticket.endActivation(succeeded: true)
            await interestReleases.activationSettled(ticket: ticket)
        } catch {
            ticket.endActivation()
            await interestReleases.activationSettled(ticket: ticket)
            if !ticket.isActive { await releaseInterest(ticket.key, generation: ticket.generation) }
            throw error
        }
        guard ticket.isActive else {
            await releaseInterest(ticket.key, generation: ticket.generation)
            throw CancellationError()
        }
    }

    func realtimeInterestSnapshot() async -> (owners: Int, retired: Int, retainedReleases: Int, actualReleases: Int) {
        let ownership = interestTickets.withLock { (owners: $0.count, retired: $0.retiredCount) }
        let releases = await interestReleases.snapshot()
        return (ownership.owners, ownership.retired, releases.retained, releases.actual)
    }

    private func compensateStaleScope(key: RecoveryKey, demand: RealtimeRecoveryDemand, user: UserID) async {
        if key.kind == .userSync { await ports?.compensateScope(key, demand.generation, demand.scope, user) }
        else { await releaseInterest(key, generation: demand.scopeGeneration) }
    }
    func detachConnection(_ connection: UUID, revokedScopes: Set<V2RealtimeRecoveryKey>) async {
        // Include a scope whose actor transition had already read its context
        // immediately before synchronous revocation. UUID reuse is still fenced
        // by the identity owner's actual connection-operation reservation.
        let ticketKeys = interestTickets.withLock { Set($0.connectionTickets(connection).map(\.key)) }
        let keys = revokedScopes.union(scopeGenerations.removeConnection(connection)).union(ticketKeys)
        for key in keys {
            await releaseInterest(key)
            realtimeDeliveryFences.withLock { $0.removeValue(forKey: key) }
            journalScopeAuthorizations.withLock { $0.removeValue(forKey: key) }
            readyRetentionFences.withLock { $0.removeValue(forKey: key) }
            removeRecoveryDemand(key); installedScopes.remove(key)
            retainedConfirmations.removeValue(forKey: key)
            preparedPresenceObservations.removeValue(forKey: key); recoveryHeadRequirements.removeValue(forKey: key)
            scopeRetentionReceipts.removeValue(forKey: key); pendingRecoveryStates.removeValue(forKey: key)
        }
        await waitForConnectionInterestTransfer(connection)
        accountInterestAcquisitions.removeValue(forKey: connection)
        userSyncInstalled.remove(connection)
        pumpRealtimeRecovery()
    }
    func shutdown() async {
        revokeAllWrites()
        if let shutdown = realtimeRecoveryShutdown { await shutdown.value; return }
        realtimeRecoveryClosed = true
        journalScopeAuthorizations.withLock { $0.removeAll() }
        readyRetentionFences.withLock { $0.removeAll() }
        realtimeDeliveryFences.withLock { $0.removeAll() }
        realtimeRecoveryWake?.cancel()
        recoverySchedulerTask?.cancel()
        let scheduler = recoverySchedulerTask, wake = realtimeRecoveryWake
        realtimeRecoveryDemands.removeAll()
        let jobs = recoveryTasks.values.map(\.task)
        let shutdown = Task {
            await scheduler?.value
            await wake?.value
            self.realtimeRecoveryWake = nil
            for job in jobs { await job.value }
            await self.releaseAllInterests()
            await self.interestReleases.finish()
            await self.presenceInterests?.shutdown()
            await self.typingInterests?.shutdown()
            await self.waitForInlineRetentionDrain()
            self.presenceInterests = nil
            self.typingInterests = nil
            self.liveActivityBroker = nil
            self.clearScopes()
        }
        realtimeRecoveryShutdown = shutdown
        await shutdown.value
    }
    private func clearScopes() {
        retainedConfirmations.removeAll(); preparedPresenceObservations.removeAll()
        userSyncInstalled.removeAll(); accountInterestAcquisitions.removeAll(); scopeGenerations.removeAll(); installedScopes.removeAll()
        recoveryHeadRequirements.removeAll(); scopeRetentionReceipts.removeAll(); pendingRecoveryStates.removeAll()
    }
    func authenticationResponseWritten(connectionID: UUID, lifecycle: UInt64? = nil) async {
        guard !realtimeRecoveryClosed, let captured = context(connectionID),
              let scope = captured.accountScope else { return }
        guard lifecycle == nil || lifecycle == captured.handle.lifecycle else { return }
        let generation = captured.handle.lifecycle, identity = captured.handle.identity
        let stream = captured.handle.stream
        advanceGeneration(to: generation)
        let key = RecoveryKey(connection: connectionID, kind: .userSync, id: identity.userID.rawValue)
        let installed = contexts.withLock { contexts -> Bool in
            guard contexts[connectionID]?.handle.lifecycle == generation,
                  contexts[connectionID]?.accountScope == scope else { return false }
            scopeGenerations[key] = generation
            return true
        }
        guard installed else { return }
        realtimeDeliveryFences.withLock { $0[key] = generation }
        setRecoveryDemand(key, .init(generation: generation, scopeGeneration: generation, scope: scope, nextAttempt: .now))
        queueRecoveryScope(key, newDemand: true)
        await stream.sendRealtimeCoverage(scope: .account, scopeID: key.id, scopeGeneration: generation,
            ready: false, reason: .installing, scopePermit: recoveryWritePermit(key, generation: generation))
        guard context(connectionID)?.handle.lifecycle == generation else { return }
        pumpRealtimeRecovery()
    }

    /// Ephemeral typing cannot recover a notification missed between ACK and
    /// interest installation. Acquire its exact owner before acknowledging;
    /// the subsequent recovery queue reuses this already-acquired ticket.
    func acquireTypingInterestBeforeAcknowledgement(connection: UUID, roomID: RoomID,
        generation: UInt64, lifecycle: UInt64) async throws {
        let key = RecoveryKey(connection: connection, kind: .roomTyping, id: roomID.rawValue)
        let demand = RealtimeRecoveryDemand(generation: lifecycle, scopeGeneration: generation,
            scope: nil, nextAttempt: .now)
        try Task.checkCancellation()
        guard scopeIsCurrent(key, demand), !realtimeRecoveryClosed else { throw CancellationError() }
        // Without a cross-node broker, the registry's local watcher is the
        // complete delivery path and has already been installed by the caller.
        guard typingInterests != nil else { return }
        let ticket = try interestTicket(key, demand: demand)
        if !ticket.isAcquired { try await activateInterest(ticket) }
        try Task.checkCancellation()
        guard scopeIsCurrent(key, demand), ticket.isActive, ticket.isAcquired,
              !realtimeRecoveryClosed else { throw CancellationError() }
    }

    func beginScopeRecovery(connection: UUID, kind: V2RealtimeTopicKind, id: String,
        scopeGeneration requestedGeneration: UInt64? = nil, lifecycle expectedLifecycle: UInt64? = nil) async {
        guard kind != .roomEvents else { return }
        guard !realtimeRecoveryClosed, let captured = context(connection) else { return }
        guard expectedLifecycle == nil || expectedLifecycle == captured.handle.lifecycle else { return }
        let lifecycle = captured.handle.lifecycle, stream = captured.handle.stream
        let key = RecoveryKey(connection: connection, kind: kind, id: id)
        guard let generation = requestedGeneration ?? requestScope(key, lifecycle: lifecycle),
              scopeGenerations[key] == generation else { return }
        let previous = interestTickets.withLock { $0[InterestOwnerKey(key)] }
        if let previous, previous.generation != generation {
            await releaseInterest(previous.key, generation: previous.generation)
        }
        guard scopeGenerations[key] == generation else { return }
        installedScopes.remove(key)
        retainedConfirmations.removeValue(forKey: key)
        preparedPresenceObservations.removeValue(forKey: key)
        recoveryHeadRequirements.removeValue(forKey: key); scopeRetentionReceipts.removeValue(forKey: key)
        pendingRecoveryStates.removeValue(forKey: key)
        journalScopeAuthorizations.withLock { $0.removeValue(forKey: key) }
        readyRetentionFences.withLock { $0.removeValue(forKey: key) }
        realtimeDeliveryFences.withLock { $0[key] = generation }
        setRecoveryDemand(key, .init(generation: lifecycle, scopeGeneration: generation, scope: nil, nextAttempt: .now))
        queueRecoveryScope(key, newDemand: true)
        await stream.sendRealtimeCoverage(scope: key.wireScope, scopeID: id, scopeGeneration: generation,
            ready: false, reason: .installing, scopePermit: recoveryWritePermit(key, generation: generation))
        pumpRealtimeRecovery()
    }

    func endScope(connection: UUID, kind: V2RealtimeTopicKind, id: String, stream: V2GatewayByteStream?,
        expectedGeneration: UInt64? = nil) async {
        let key = RecoveryKey(connection: connection, kind: kind, id: id)
        if let expectedGeneration {
            if let current = scopeGenerations[key], current != expectedGeneration { return }
            _ = scopeGenerations.removeValue(forKey: key, ifGeneration: expectedGeneration)
        } else {
            guard scopeGenerations.removeValue(forKey: key) != nil else { return }
        }
        let endedGeneration = makeGeneration()
        removeRecoveryDemand(key); installedScopes.remove(key)
        retainedConfirmations.removeValue(forKey: key)
        preparedPresenceObservations.removeValue(forKey: key)
        recoveryHeadRequirements.removeValue(forKey: key); scopeRetentionReceipts.removeValue(forKey: key)
        pendingRecoveryStates.removeValue(forKey: key)
        journalScopeAuthorizations.withLock { $0.removeValue(forKey: key) }
        readyRetentionFences.withLock { $0.removeValue(forKey: key) }
        realtimeDeliveryFences.withLock { $0.removeValue(forKey: key) }

        pumpRealtimeRecovery()
        await releaseInterest(key, generation: expectedGeneration)
        await stream?.sendRealtimeCoverage(scope: key.wireScope, scopeID: id, scopeGeneration: endedGeneration,
            ready: false, ended: true, reason: .cancelled)
    }

    private var actualPermissionQueries: Int { recoveryTasks.values.filter { $0.lane == .query }.count }
    private var actualInterestActivations: Int { recoveryTasks.values.filter { $0.lane == .interest }.count }
    private var actualControlDispatches: Int { recoveryTasks.values.filter { $0.lane == .control }.count }
    private var hasRecoveryCapacity: Bool {
        actualPermissionQueries < maximumRealtimeRecoveryJobs || actualInterestActivations < maximumRealtimeRecoveryJobs
            || actualControlDispatches < maximumRealtimeRecoveryJobs
    }
    private func lane(_ kind: RecoveryServiceClass) -> RecoveryLane {
        if kind == .otherInterest { return .interest }
        if kind == .presenceQuery { return .query }
        return .control
    }
    private typealias SchedulingPlacement = V2RecoveryOrderedStore<RecoveryKey, RealtimeRecoveryDemand>.SchedulingPlacement
    private typealias SchedulingDescriptor = V2RecoveryOrderedStore<RecoveryKey, RealtimeRecoveryDemand>.SchedulingDescriptor

    private var recoveryQueuedCount: Int { realtimeRecoveryDemands.schedulingCount(placement: .queued) }
    private func isRecoveryQueued(_ key: RecoveryKey) -> Bool {
        realtimeRecoveryDemands.scheduling(for: key)?.placement == .queued
    }
    private func isRecoveryOwned(_ key: RecoveryKey) -> Bool {
        recoveryJobIDs[key] != nil || inlineRetentions[key] != nil
            || outboundRecoveryTickets[key] != nil || selectedHandoffPositions.contains(key)
    }
    private func setRecoveryDemand(_ key: RecoveryKey, _ demand: RealtimeRecoveryDemand) {
        realtimeRecoveryDemands[key] = demand
        refreshScheduling(key)
    }
    private func removeRecoveryDemand(_ key: RecoveryKey) {
        realtimeRecoveryDemands.removeValue(forKey: key)
    }
    private func enqueueRecoveryKey(_ key: RecoveryKey) {
        refreshScheduling(key, placement: .queued)
    }
    private func dequeueRecoveryKey(_ key: RecoveryKey) {
        refreshScheduling(key, placement: .primary)
    }
    private func claimRecoveryKey(_ key: RecoveryKey) {
        refreshScheduling(key, placement: .owned)
    }
    private func classHasCapacity(_ kind: RecoveryServiceClass) -> Bool {
        switch kind {
        case .otherInterest: actualInterestActivations < maximumRealtimeRecoveryJobs
        case .presenceQuery: actualPermissionQueries < maximumRealtimeRecoveryJobs
        default: actualControlDispatches < maximumRealtimeRecoveryJobs
        }
    }

    /// State transitions are explicit; classification below never evicts a proof
    /// or changes a demand. Every transition then updates this same primary node.
    private func refreshScheduling(_ key: RecoveryKey, placement requested: SchedulingPlacement? = nil) {
        guard var demand = realtimeRecoveryDemands[key] else { return }
        guard !realtimeRecoveryClosed, scopeIsCurrent(key, demand) else {
            realtimeRecoveryDemands.setScheduling(nil, for: key, now: .now)
            return
        }
        let old = realtimeRecoveryDemands.scheduling(for: key)?.placement ?? .primary
        // Terminal owners may return while another ingress has filled the
        // ledger. Their remaining demand is still indexed primary backlog.
        let unowned = old == .owned ? SchedulingPlacement.primary : old
        let placement = isRecoveryOwned(key) ? SchedulingPlacement.owned : (requested ?? unowned)
        if placement != .owned {
            demand = downgradeInvalidHint(key, demand: demand)

            if let proof = preparedPresenceObservations[key], proof.deadline <= .now {
                preparedPresenceObservations.removeValue(forKey: key)
            }
        }
        let kind = recoveryServiceClass(key, demand: demand)
        var refreshAt: ContinuousClock.Instant?
        func include(_ deadline: ContinuousClock.Instant) {
            // Keep an expiry that crosses this synchronous refresh on the heap;
            // the next bounded due pass performs its exact state transition.
            refreshAt = min(refreshAt ?? deadline, deadline)
        }
        if let proof = preparedPresenceObservations[key] { include(proof.deadline) }
        if demand.hintOnly {
            if let confirmation = realtimeCoverageConfirmation?(key.kind, key.id) { include(confirmation.deadline) }
        }
        realtimeRecoveryDemands.setScheduling(.init(classIndex: kind.rawValue, placement: placement,
            readyAt: demand.nextAttempt, refreshAt: refreshAt), for: key, now: .now)
    }

    /// Notifications and provider callbacks only coalesce a request. This
    /// owned root performs bounded passes and yields between them.
    private func pumpRealtimeRecovery() {
        guard !realtimeRecoveryClosed else { return }
        recoverySchedulerRequested = true
        realtimeRecoveryWake?.cancel() // Keep the actual handle until joined.
        guard recoverySchedulerTask == nil else { return }
        recoverySchedulerTask = Task { await self.runRecoveryScheduler() }
    }

    nonisolated func schedulingTelemetrySnapshot() -> V2RecoverySchedulingSnapshot {
        schedulingTelemetry.snapshot()
    }

    func schedulingOwnershipSnapshot() -> (scheduler: Int, wake: Int) {
        (recoverySchedulerTask == nil ? 0 : 1, realtimeRecoveryWake == nil ? 0 : 1)
    }

    func schedulingAdmissionSnapshot() -> (primary: Int, queued: Int, fair: UInt8, pending: UInt8,
        census: UInt8, dirty: Bool, refill: Bool, positions: Int) {
        var pending: UInt8 = 0, queued: UInt8 = 0
        for kind in RecoveryServiceClass.allCases {
            if realtimeRecoveryDemands.schedulingCount(placement: .primary, classIndex: kind.rawValue, eligibleOnly: true) > 0 { pending |= UInt8(1) << kind.rawValue }
            if realtimeRecoveryDemands.schedulingCount(placement: .queued, classIndex: kind.rawValue, eligibleOnly: true) > 0 { queued |= UInt8(1) << kind.rawValue }
        }
        return (realtimeRecoveryDemands.schedulingCount(placement: .primary), recoveryQueuedCount,
            0, pending, queued, false, pending != 0 && recoveryQueueOccupancy < maximumQueuedRealtimeRecoveries, recoveryQueueOccupancy)
    }

    private func runRecoveryScheduler() async {
        defer { recoverySchedulerTask = nil }
        if let wake = realtimeRecoveryWake { await wake.value; realtimeRecoveryWake = nil }
        while !realtimeRecoveryClosed {
            recoverySchedulerRequested = false
            let progressed = runRecoverySchedulingPass()
            let hasDue = realtimeRecoveryDemands.earliestSchedulingDeadline.map { $0 <= .now } ?? false
            if progressed || hasDue || recoverySchedulerRequested { await Task.yield() }
            else { break }
        }
        guard !realtimeRecoveryClosed, let next = realtimeRecoveryDemands.earliestSchedulingDeadline else { return }
        realtimeRecoveryWake = Task {
            do { try await ContinuousClock().sleep(until: next) } catch { return }
            self.pumpRealtimeRecovery()
        }
    }

    /// Exact category/placement links select work without a Q census or D search.
    /// A pass owns at most 128 node inspections, then yields to other actor work.
    private func runRecoverySchedulingPass() -> Bool {
        let passBegan = ContinuousClock.now
        var desiredScanned = 0, queuedScanned = 0, budget = recoveryScanQuantum
        var progressed = false, needsAnotherQuantum = false
        defer {
            schedulingTelemetry.record(.pumpPass, duration: passBegan.duration(to: .now))
            schedulingTelemetry.recordScan(.desired, entries: desiredScanned)
            schedulingTelemetry.recordScan(.queued, entries: queuedScanned)
        }
        let due = realtimeRecoveryDemands.popDueScheduling(now: .now, limit: budget)
        budget -= due.count
        for key in due { refreshScheduling(key); progressed = true }
        // Fill free positions fairly by category. The primary FIFO itself is
        // the backlog; no copied demands or additional admission queue exists.
        while budget > 0, recoveryQueueOccupancy < maximumQueuedRealtimeRecoveries {
            var admitted = false
            for step in 0..<RecoveryServiceClass.allCases.count {
                let kind = RecoveryServiceClass(rawValue: (nextRecoveryServiceClass.rawValue + step) % RecoveryServiceClass.allCases.count)!
                guard let (key, _) = realtimeRecoveryDemands.peekScheduled(classIndex: kind.rawValue, placement: .primary) else { continue }
                budget -= 1; desiredScanned += 1; progressed = true
                refreshScheduling(key)
                guard let descriptor = realtimeRecoveryDemands.scheduling(for: key), descriptor.placement == .primary,
                      descriptor.classIndex == kind.rawValue, descriptor.readyAt <= .now else { admitted = true; break }
                enqueueRecoveryKey(key); admitted = true; progressed = true
                nextRecoveryServiceClass = RecoveryServiceClass(rawValue: (kind.rawValue + 1) % RecoveryServiceClass.allCases.count)!
                break
            }
            guard admitted else { break }
        }
        while budget > 0, hasRecoveryCapacity {
            var chosen: (RecoveryKey, RecoveryServiceClass)?
            for step in 0..<RecoveryServiceClass.allCases.count {
                let kind = RecoveryServiceClass(rawValue: (nextRecoveryServiceClass.rawValue + step) % RecoveryServiceClass.allCases.count)!
                guard classHasCapacity(kind) else { continue }
                if let (key, _) = realtimeRecoveryDemands.peekScheduled(classIndex: kind.rawValue, placement: .queued) {
                    chosen = (key, kind); break
                }
                // A missing runnable class may borrow one queued position,
                // including a future-retry Q node. Actual owners are excluded.
                guard realtimeRecoveryDemands.schedulingCount(placement: .primary, classIndex: kind.rawValue, eligibleOnly: true) > 0,
                      recoveryQueuedCount > 0 else { continue }
                guard budget >= 3 else { needsAnotherQuantum = true; break }
                if let (key, _) = realtimeRecoveryDemands.peekScheduled(classIndex: kind.rawValue, placement: .primary),
                   let victim = queuedVictim(for: kind) {
                    // Charge the primary admission and queued victim as well
                    // as the eventual selected node against this same quantum.
                    budget -= 2; queuedScanned += 1
                    discardQueuedProof(victim)
                    dequeueRecoveryKey(victim)
                    enqueueRecoveryKey(key)
                    desiredScanned += 1
                    chosen = (key, kind); break
                }
            }
            guard let (connection, kind) = chosen else { break }
            budget -= 1; queuedScanned += 1
            refreshScheduling(connection)
            guard let descriptor = realtimeRecoveryDemands.scheduling(for: connection), descriptor.placement == .queued,
                  descriptor.classIndex == kind.rawValue, descriptor.readyAt <= .now,
                  let demand = realtimeRecoveryDemands[connection], scopeIsCurrent(connection, demand) else { progressed = true; continue }
            claimRecoveryKey(connection)
            let taskID = UUID(), began = ContinuousClock.now
            let selected = [connection: demand], selectedKeys = [connection]

            let isAuthorizationBatch = kind == .presenceQuery || kind == .otherInterest
            if isAuthorizationBatch {
                authorizationReturns[taskID] = Dictionary(uniqueKeysWithValues: selectedKeys.map { key in
                    let value = selected[key]!
                    return (key, AuthorizationReturnTicket(lifecycle: value.generation, generation: value.scopeGeneration, began: began))
                })
                reservedAuthorizationReturnCount += selectedKeys.count
            } else {
                selectedHandoffPositions.formUnion(selectedKeys)
            }
            // Every dequeue retains its original ledger position until return
            // transfer or outbound handoff; no stage-specific admission queue.
            let captured = selected, capturedKeys = selectedKeys
            let task: Task<Void, Never>
            if kind == .otherInterest {
                task = Task { await self.runInterestPreparation(captured, orderedKeys: capturedKeys, taskID: taskID) }
            } else if kind == .presenceQuery {
                task = Task { await self.runPresencePreparation(key: connection, demand: demand, taskID: taskID) }
            } else {
                task = Task { await self.runRealtimeRecovery(key: connection, demand: demand, taskID: taskID) }
            }
            nextRecoveryServiceClass = RecoveryServiceClass(rawValue:
                (kind.rawValue + 1) % RecoveryServiceClass.allCases.count)!
            recoveryTasks[taskID] = .init(task: task, began: began, lane: lane(kind))
            for (key, value) in selected {
                actualRecoveryReasons[key] = value.reason
                let stage: V2RegistryRecoveryStage = lane(kind) == .interest ? .interestActivation
                    : (lane(kind) == .query ? .authorization : .retention)
                recoveryExecutionStage[key] = (stage, began)
                recoveryJobIDs[key] = taskID
            }
            progressed = true
        }
        return progressed || needsAnotherQuantum
    }

    private func queuedVictim(for wanted: RecoveryServiceClass) -> RecoveryKey? {
        // Preserve prepared proofs where another queued class can yield. An
        // all-prepared ledger still yields by explicitly dropping its proof.
        for includePrepared in [false, true] {
            for kind in RecoveryServiceClass.allCases where kind != wanted {
                if !includePrepared && kind == .preparedPresence { continue }
                if let (key, _) = realtimeRecoveryDemands.peekScheduled(classIndex: kind.rawValue,
                    placement: .queued, eligibleOnly: false) { return key }
            }
        }
        // Same-class future retries must not block fresh ready demand forever.
        if realtimeRecoveryDemands.schedulingCount(placement: .queued, classIndex: wanted.rawValue, eligibleOnly: true) == 0 {
            return realtimeRecoveryDemands.peekScheduled(classIndex: wanted.rawValue, placement: .queued, eligibleOnly: false)?.key
        }
        return nil
    }

    private func discardQueuedProof(_ key: RecoveryKey) {
        preparedPresenceObservations.removeValue(forKey: key)
    }

    private func finishRecoveryScope(_ key: RecoveryKey, taskID: UUID) {
        guard recoveryJobIDs[key] == taskID else { return }
        selectedHandoffPositions.remove(key)
        recoveryJobIDs.removeValue(forKey: key)
        recoveryExecutionStage.removeValue(forKey: key)
        actualRecoveryReasons.removeValue(forKey: key)
        // A refused handoff may have tried to requeue while this exact root
        // still owned the key. Return it directly once that ownership ends;
        // do not rely on a full-primary scan to rediscover the lost position.
        if authorizationReturns[taskID]?[key] == nil { queueRecoveryScope(key) }
    }

    private func finishRecoveryTask(_ taskID: UUID, keys: Set<RecoveryKey>) {
        let exactKeys = keys.filter { recoveryJobIDs[$0] == taskID }
        for key in keys {
            finishRecoveryScope(key, taskID: taskID)
        }
        // Only the actual outer terminal returns unconsumed positions. Partial
        // callbacks have already atomically consumed their own exact tickets.
        if let unused = authorizationReturns.removeValue(forKey: taskID) {
            reservedAuthorizationReturnCount -= unused.count
        }
        for key in exactKeys { queueRecoveryScope(key) }
        recoveryTasks.removeValue(forKey: taskID)
    }





    private func interestIsAcquired(_ key: RecoveryKey, demand: RealtimeRecoveryDemand) -> Bool {
        if key.kind == .userSync {
            return accountInterestAcquisitions[key.connection].map {
                $0.lifecycle == demand.generation && $0.generation == demand.scopeGeneration && $0.scope == demand.scope
            } == true
        }
        return interestTickets.withLock { owners in
            guard let ticket = owners[InterestOwnerKey(key)] else { return false }
            return ticket.key == key && ticket.lifecycle == demand.generation
                && ticket.generation == demand.scopeGeneration && ticket.isAcquired
        }
    }

    private func runInterestPreparation(_ selected: [RecoveryKey: RealtimeRecoveryDemand],
        orderedKeys: [RecoveryKey], taskID: UUID) async {
        defer { finishRecoveryTask(taskID, keys: Set(selected.keys)); pumpRealtimeRecovery() }
        guard !realtimeRecoveryClosed else { return }
        do {
            guard let key = orderedKeys.first, let demand = selected[key], scopeIsCurrent(key, demand) else { return }
            if key.kind == .userSync {
                guard let interests = userSyncInterests, let scope = demand.scope else { throw V2RealtimePublicationBackpressure.receiverQueue }
                try await activateMeasured(interests.manager(for: .account(scope)), room: RoomID(key.id))
                guard !realtimeRecoveryClosed, scopeIsCurrent(key, demand) else {
                    let user = try UserID(key.id)
                    await compensateStaleScope(key: key, demand: demand, user: user)
                    return
                }
                accountInterestAcquisitions[key.connection] = .init(lifecycle: demand.generation, generation: demand.scopeGeneration, scope: scope)
            } else { try await activateInterest(try interestTicket(key, demand: demand)) }


            for key in orderedKeys {
                guard let demand = selected[key], !realtimeRecoveryClosed, scopeIsCurrent(key, demand),
                      interestIsAcquired(key, demand: demand), consumeAuthorizationReturn(key, demand: demand, taskID: taskID) else { continue }
                // The original result position is transferred atomically, with
                // no await or refill between release and query-ready enqueue.
                finishRecoveryScope(key, taskID: taskID)
                queueRecoveryScope(key)
            }
            pumpRealtimeRecovery()
        } catch {
            for key in orderedKeys {
                if let demand = selected[key], recoveryJobIDs[key] == taskID { retryAuthorizationScope(key, demand: demand, taskID: taskID) }
            }
        }
    }

    /// Preparation may join the Presence owner's existing observation or its
    /// bounded SQL batch. Both use query-root admission; only that owner knows
    /// whether a real provider query was needed, so no SQL metric is inferred here.
    private func runPresencePreparation(key: RecoveryKey, demand: RealtimeRecoveryDemand, taskID: UUID) async {
        defer { finishRecoveryTask(taskID, keys: [key]); pumpRealtimeRecovery() }
        guard !realtimeRecoveryClosed, scopeIsCurrent(key, demand) else { return }
        do {
            guard let ports else { throw V2RealtimePublicationBackpressure.receiverQueue }
            recoveryExecutionStage[key] = (.authorization, .now)
            let proof = try await ports.preparePresence(key, demand.generation, demand.scopeGeneration)
            guard !realtimeRecoveryClosed, scopeIsCurrent(key, demand),
                  proof.connection == key.connection, proof.lifecycle == demand.generation,
                  proof.generation == demand.scopeGeneration, proof.request.targetUserID.rawValue == key.id,
                  proof.request.viewerUserID == context(key.connection)?.handle.identity.userID,
                  proof.stream === context(key.connection)?.handle.stream,
                  proof.state.roomID == proof.request.roomID,
                  proof.state.targetUserID == proof.request.targetUserID,
                  proof.deadline > .now else { throw V2RealtimePublicationBackpressure.receiverQueue }
            recordPreparedPresence(proof)
            guard preparedPresence(key, lifecycle: demand.generation, generation: demand.scopeGeneration) != nil,
                  consumeAuthorizationReturn(key, demand: demand, taskID: taskID) else { return }
            // Transfer the same reserved position without a capacity gap. The
            // absolute observation expiry remains unchanged in control/outbound.
            finishRecoveryScope(key, taskID: taskID)
            queueRecoveryScope(key)
        } catch {
            retryAuthorizationScope(key, demand: demand, taskID: taskID)
        }
    }





    /// A queued hint may lose its lease or permission window before dispatch.
    /// Only its exact demand version may be downgraded; newer merged work keeps
    /// its own validity and head. No prior proof gains authority from this step.
    private func downgradeInvalidHint(_ key: RecoveryKey, demand: RealtimeRecoveryDemand) -> RealtimeRecoveryDemand {
        guard demand.hintOnly,
              demand.notificationValidity?() == false || notificationConfirmation(key) == nil,
              var current = realtimeRecoveryDemands[key], current.version == demand.version,
              current.generation == demand.generation, current.scopeGeneration == demand.scopeGeneration,
              scopeIsCurrent(key, current) else { return demand }
        if current.notificationValidity?() == false {
            recoveryHeadRequirements.removeValue(forKey: key)
            scopeRetentionReceipts.removeValue(forKey: key)
        }
        current.hintOnly = false; current.notificationValidity = nil; current.version = UUID()
        realtimeRecoveryDemands[key] = current
        preparedPresenceObservations.removeValue(forKey: key)
        retainedConfirmations.removeValue(forKey: key)
        journalScopeAuthorizations.withLock { $0.removeValue(forKey: key) }
        readyRetentionFences.withLock { $0.removeValue(forKey: key) }
        pendingRecoveryStates[key] = .init(version: makeGeneration(), reason: .dependencyUnavailable)
        return current
    }

    /// Pure classification. Mutation and absolute-expiry handling belong to
    /// refreshScheduling, so querying a category never invalidates another phase.
    private func recoveryServiceClass(_ key: RecoveryKey, demand: RealtimeRecoveryDemand) -> RecoveryServiceClass {
        if demand.hintOnly { return .otherScope }
        guard interestIsAcquired(key, demand: demand) else {
            return .otherInterest
        }

        if key.kind == .userPresence {
            guard let proof = preparedPresenceObservations[key], proof.deadline > .now,
                  proof.lifecycle == demand.generation, proof.generation == demand.scopeGeneration else { return .presenceQuery }
            return .preparedPresence
        }
        return .otherScope
    }



    private func queueRecoveryScope(_ key: RecoveryKey, newDemand: Bool = false) {
        guard realtimeRecoveryDemands[key] != nil, !isRecoveryOwned(key) else { return }
        refreshScheduling(key)
        guard !isRecoveryQueued(key), recoveryQueueOccupancy < maximumQueuedRealtimeRecoveries else { return }
        enqueueRecoveryKey(key)
    }

    private func consumeAuthorizationReturn(_ key: RecoveryKey, demand: RealtimeRecoveryDemand, taskID: UUID) -> Bool {
        guard recoveryJobIDs[key] == taskID,
              let ticket = authorizationReturns[taskID]?[key],
              ticket.lifecycle == demand.generation, ticket.generation == demand.scopeGeneration else { return false }
        authorizationReturns[taskID]?.removeValue(forKey: key)
        if authorizationReturns[taskID]?.isEmpty == true { authorizationReturns.removeValue(forKey: taskID) }
        reservedAuthorizationReturnCount -= 1
        return true
    }

    private func retryAuthorizationScope(_ key: RecoveryKey, demand: RealtimeRecoveryDemand, taskID: UUID) {
        guard recoveryJobIDs[key] == taskID else { return }
        let interestFailure: Bool
        if case .interest? = recoveryTasks[taskID]?.lane { interestFailure = true } else { interestFailure = false }
        guard consumeAuthorizationReturn(key, demand: demand, taskID: taskID) else { return }
        finishRecoveryScope(key, taskID: taskID)
        guard !realtimeRecoveryClosed, scopeIsCurrent(key, demand) else { return }
        // Interest acquisition owns no permission observation. A periodic
        // observer may have delivered its original proof while this acquisition
        // was suspended. Interest failure cannot erase that authority. Query
        // failure fails closed: an observation starts before its provider read,
        // so its time cannot establish permission ordering against a denial.
        // The same return position now owns retry.
        // Presence preparation can explicitly deny permission. Its proof
        // carries expiry, not an observation/denial ordering version, so query
        // failure must fail closed even if another callback just cached a proof.
        let preservePresenceProof = interestFailure && key.kind == .userPresence
            && preparedPresence(key, lifecycle: demand.generation, generation: demand.scopeGeneration) != nil
        if !preservePresenceProof { preparedPresenceObservations.removeValue(forKey: key) }
        if !interestFailure && !preservePresenceProof {
            retainedConfirmations.removeValue(forKey: key); scopeRetentionReceipts.removeValue(forKey: key)
            journalScopeAuthorizations.withLock { $0.removeValue(forKey: key) }
            readyRetentionFences.withLock { $0.removeValue(forKey: key) }
        }
        // Keeping a proof does not confirm the interest or Ready. Revoke Ready
        // until an actual Recovering predecessor and scope handoff settle.
        readyRetentionFences.withLock { state in
            guard var fence = state[key], fence.generation == demand.scopeGeneration else { return }
            fence.recoveringPending = true; state[key] = fence
        }
        pendingRecoveryStates[key] = .init(version: makeGeneration(), reason: .dependencyUnavailable)
        var next = realtimeRecoveryDemands[key] ?? demand
        next.hintOnly = false; next.attempts = min(6, next.attempts + 1)
        next.nextAttempt = .now + .milliseconds(min(5_000, 250 * (1 << next.attempts)))
        setRecoveryDemand(key, next)
        queueRecoveryScope(key)
    }

    private func runRealtimeRecovery(key: RecoveryKey, demand: RealtimeRecoveryDemand, taskID: UUID) async {
        let began = ContinuousClock.now
        let isControl: Bool
        if case .control? = recoveryTasks[taskID]?.lane { isControl = true } else { isControl = false }
        defer { if isControl { schedulingTelemetry.record(.controlCohort, duration: began.duration(to: .now)) } }
        defer { finishRecoveryTask(taskID, keys: [key]); pumpRealtimeRecovery() }
        await runRealtimeRecoveryScope(key: key, demand: demand)
    }





    private func handoffRecoveryScope(key: RecoveryKey, demand: RealtimeRecoveryDemand,
        additionalHead: UInt64, notificationOnly: Bool, presence: PreparedPresenceHandoff? = nil) async {
        guard !realtimeRecoveryClosed, scopeIsCurrent(key, demand),
              inlineRetentions[key] == nil, outboundRecoveryTickets[key] == nil,
              let identity = context(key.connection)?.handle.identity,
              let stream = context(key.connection)?.handle.stream else { return }
        let retention = InlineRetentionTicket(lifecycle: demand.generation, generation: demand.scopeGeneration)
        selectedHandoffPositions.remove(key)
        inlineRetentions[key] = retention
        outboundRecoveryTickets[key] = retention.id

        let offerBegan = ContinuousClock.now
        let accepted = await stream.offerRecoveryOperation(scope: key.wireScope, scopeID: key.id,
            scopeGeneration: demand.scopeGeneration, operation: {
                await self.executeOutboundRecovery(key: key, demand: demand,
                    ticketID: retention.id, additionalHead: additionalHead, notificationOnly: notificationOnly, presence: presence)
            }, onSettled: { successful in
                await self.settleOutboundRecovery(key: key, demand: demand,
                    ticketID: retention.id, successful: successful)
            })
        schedulingTelemetry.record(.shortOffer, duration: offerBegan.duration(to: .now))
        if !accepted {
            settleOutboundRecovery(key: key, demand: demand, ticketID: retention.id, successful: false)
        }
    }

    private func executeOutboundRecovery(key: RecoveryKey, demand: RealtimeRecoveryDemand,
        ticketID: UUID, additionalHead: UInt64, notificationOnly: Bool, presence: PreparedPresenceHandoff?) async -> Bool {
        guard outboundRecoveryTickets[key] == ticketID, scopeIsCurrent(key, demand),
              !realtimeRecoveryClosed else { return false }
        do {
            guard let identity = context(key.connection)?.handle.identity,
                  let stream = context(key.connection)?.handle.stream else { return false }
            if let pending = pendingRecoveryStates[key] {
                let recoveringAccepted = await stream.retainRealtimeCoverageRecovering(scope: key.wireScope, scopeID: key.id,
                    scopeGeneration: demand.scopeGeneration, reason: pending.reason,
                    scopePermit: recoveryWritePermit(key, generation: demand.scopeGeneration))
                guard recoveringAccepted else { return false }
                guard scopeIsCurrent(key, demand), !realtimeRecoveryClosed else { return false }
                if pendingRecoveryStates[key]?.version == pending.version {
                    pendingRecoveryStates.removeValue(forKey: key)
                    readyRetentionFences.withLock { state in
                        guard var fence = state[key], fence.generation == demand.scopeGeneration else { return }
                        fence.recoveringPending = false; state[key] = fence
                    }
                }
            }
            let userAuthorization: V2GatewayJournalReadyAuthorization?
            if presence != nil, let journalUserBaselineBarrier {
                userAuthorization = try await journalUserBaselineBarrier(identity.userID)
                guard outboundRecoveryTickets[key] == ticketID, scopeIsCurrent(key, demand), !realtimeRecoveryClosed else { return false }
            } else { userAuthorization = nil }
            if let presence {
                guard presence.deadline > .now,
                      presence.lifecycle == demand.generation, presence.generation == demand.scopeGeneration else { return false }
                let alreadyRetained = scopeRetentionReceipts[key].map {
                    $0.lifecycle == demand.generation && $0.generation == demand.scopeGeneration && $0.observedPresence
                        && $0.presenceDeadline == presence.deadline
                } == true
                if !alreadyRetained {
                    let accepted = await presence.stream.retainPresenceState(presence.state,
                        enqueueIfCurrent: recoveryWritePermit(key, generation: demand.scopeGeneration,
                            authorizationDeadline: presence.deadline), primaryAuthPermit: userAuthorization?.permit)
                    guard accepted, presence.deadline > .now, scopeIsCurrent(key, demand) else { return false }
                    recordScopeRetention(key, lifecycle: demand.generation, generation: demand.scopeGeneration,
                        highWatermark: 0, observedPresence: true, presenceDeadline: presence.deadline)
                }
            }
            if notificationOnly {
                guard demand.notificationValidity?() != false,
                      let confirmation = notificationConfirmation(key) else { return false }
                try await retainDurableNotification(key, lifecycle: demand.generation,
                    generation: demand.scopeGeneration, confirmation: confirmation,
                    highWatermark: recoveryHeadRequirements[key] ?? additionalHead, stream: stream,
                    additionalValidity: demand.notificationValidity ?? { true })
                finishNotificationDemand(key, demand: demand)
            } else {
                try await sendScopeReady(key: key, generation: demand.scopeGeneration, additionalHead: additionalHead,
                    authorizationDeadline: presence?.deadline, userAuthorization: userAuthorization)
            }
        } catch { return false }
        guard outboundRecoveryTickets[key] == ticketID, scopeIsCurrent(key, demand),
              !realtimeRecoveryClosed else { return false }
        // The operation itself retains exact head/Ready enqueue receipts. A
        // retained mailbox ticket is never substituted for those receipts.
        return realtimeRecoveryDemands[key] == nil
    }

    private func settleOutboundRecovery(key: RecoveryKey, demand: RealtimeRecoveryDemand,
        ticketID: UUID, successful: Bool) {
        guard outboundRecoveryTickets[key] == ticketID else { return }
        outboundRecoveryTickets.removeValue(forKey: key)
        if inlineRetentions[key]?.id == ticketID { inlineRetentions.removeValue(forKey: key) }
        if inlineRetentions.isEmpty { inlineRetentionDrain?.resume(); inlineRetentionDrain = nil }
        if !successful, !realtimeRecoveryClosed, scopeIsCurrent(key, demand) {
            var retry = realtimeRecoveryDemands[key] ?? demand
            let retiredNotification = retry.version == demand.version && retry.notificationValidity?() == false
            if retiredNotification {
                // A retired notification cannot keep a hint-only retry loop.
                // Retain independently merged H, but obtain fresh authority.
                retry.hintOnly = false; retry.notificationValidity = nil; retry.version = UUID()
            }
            retry.nextAttempt = max(retry.nextAttempt, .now + .milliseconds(100))
            setRecoveryDemand(key, retry)
        }
        if realtimeRecoveryDemands[key] != nil { queueRecoveryScope(key) }
        pumpRealtimeRecovery()
    }

    private func runRealtimeRecoveryScope(key: RecoveryKey, demand: RealtimeRecoveryDemand) async {
        let connection = key.connection
        guard let identity = context(connection)?.handle.identity, scopeIsCurrent(key, demand) else { return }
        do {
            if demand.hintOnly {
                let current = downgradeInvalidHint(key, demand: demand)
                guard current.hintOnly, current.version == demand.version,
                      realtimeRecoveryDemands[key]?.version == demand.version,
                      demand.notificationValidity?() != false, notificationConfirmation(key) != nil else {
                    // This root was granted control admission. Requeue fresh
                    // recovery for its proper lane, never invoke a provider here.
                    if realtimeRecoveryDemands[key] != nil { queueRecoveryScope(key) }
                    return
                }
                await handoffRecoveryScope(key: key, demand: demand,
                    additionalHead: recoveryHeadRequirements[key] ?? 0, notificationOnly: true)
                return
            }
            if demand.notificationValidity?() == false,
               realtimeRecoveryDemands[key]?.version == demand.version {
                // The old notification supplies no head/authority to the new
                // session. Its still-requested scope is recovered afresh.
                recoveryHeadRequirements.removeValue(forKey: key)
                scopeRetentionReceipts.removeValue(forKey: key)
                retainedConfirmations.removeValue(forKey: key)
        preparedPresenceObservations.removeValue(forKey: key)
                journalScopeAuthorizations.withLock { $0.removeValue(forKey: key) }
                readyRetentionFences.withLock { $0.removeValue(forKey: key) }
            }
            recoveryExecutionStage[key] = (.retention, .now)
            guard interestIsAcquired(key, demand: demand) else {
                throw V2RealtimePublicationBackpressure.receiverQueue
            }
            guard !realtimeRecoveryClosed, scopeIsCurrent(key, demand) else {
                // This control root did not acquire an interest. The actual
                // acquisition root and exact lifecycle cleanup own release;
                // awaiting their I/O here would consume control admission.
                return
            }
            if demand.notificationValidity?() == false,
               realtimeRecoveryDemands[key]?.version == demand.version {
                recoveryHeadRequirements.removeValue(forKey: key)
                scopeRetentionReceipts.removeValue(forKey: key)
                journalScopeAuthorizations.withLock { $0.removeValue(forKey: key) }
                readyRetentionFences.withLock { $0.removeValue(forKey: key) }
            }
            var preparedPresence: PreparedPresenceHandoff?
            if key.kind == .userPresence {
                guard let proof = self.preparedPresence(key, lifecycle: demand.generation,
                    generation: demand.scopeGeneration) else { throw V2RealtimePublicationBackpressure.receiverQueue }
                preparedPresence = proof
            }
            if realtimeRecoveryDemands[key]?.version == demand.version { removeRecoveryDemand(key) }
            installedScopes.insert(key)
            if key.kind == .userSync { userSyncInstalled.insert(connection) }
            guard scopeIsCurrent(key, demand) else { return }
            await handoffRecoveryScope(key: key, demand: demand, additionalHead: 0,
                notificationOnly: false, presence: preparedPresence)
        } catch {
            guard !realtimeRecoveryClosed, scopeIsCurrent(key, demand) else { return }
            let current = realtimeRecoveryDemands[key] ?? demand
            var retry = downgradeInvalidHint(key, demand: current)
            retry.attempts = min(6, retry.attempts + 1)
            retry.nextAttempt = .now + .milliseconds(min(5_000, 250 * (1 << retry.attempts)))
            setRecoveryDemand(key, retry)
            queueRecoveryScope(key)
            if !retry.hintOnly {
                pendingRecoveryStates[key] = .init(version: makeGeneration(), reason: .dependencyUnavailable)
            }
        }
    }

    private func scopeIsCurrent(_ key: RecoveryKey, _ demand: RealtimeRecoveryDemand) -> Bool {
        context(key.connection)?.handle.lifecycle == demand.generation && scopeGenerations[key] == demand.scopeGeneration
            && (key.kind != .userSync || context(key.connection)?.accountScope == demand.scope)
    }

    nonisolated func recoveryWritePermit(_ key: V2RealtimeRecoveryKey, generation: UInt64,
        authorizationDeadline: ContinuousClock.Instant? = nil)
        -> @Sendable (@Sendable () -> Void) -> Bool {
        let lifecycle = context(key.connection)?.handle.lifecycle
        return { enqueue in
            self.recoveryWriteResult(key, lifecycle: lifecycle, generation: generation,
                authorizationDeadline: authorizationDeadline, enqueue: enqueue).accepted
        }
    }

    /// Classification is local to this synchronous check. No telemetry lock is
    /// acquired under any write fence; ordinary H permits remain uncounted.
    private nonisolated func recoveryWriteResult(_ key: RecoveryKey, lifecycle: Generation?,
        generation: Generation, authorizationDeadline: ContinuousClock.Instant?,
        enqueue: @Sendable () -> Void) -> (accepted: Bool, rejection: V2RecoveryReadyRejectionReason?) {
        var rejection: V2RecoveryReadyRejectionReason = .generationInvalid
        let accepted = writesEnabled.withLock { enabled in
            guard enabled else { rejection = .closed; return false }
            return contexts.withLock { contexts in
                guard let lifecycle, contexts[key.connection]?.handle.lifecycle == lifecycle else { return false }
                return scopeGenerations.withGeneration(key, generation: generation) {
                    realtimeDeliveryFences.withLock { current in
                        guard current[key] == generation else { return false }
                        guard authorizationDeadline.map({ $0 > .now }) ?? true else {
                            rejection = .permissionExpired; return false
                        }
                        enqueue(); return true
                    }
                }
            }
        }
        return (accepted, accepted ? nil : rejection)
    }

    private func queueScopeRetention(_ key: RecoveryKey, highWatermark: UInt64, schedule: Bool = true) -> Bool {
        guard !realtimeRecoveryClosed, let lifecycle = context(key.connection)?.handle.lifecycle,
              let generation = scopeGenerations[key] else { return false }
        if duplicateRequirementIsRetained(key, lifecycle: lifecycle, generation: generation, highWatermark: highWatermark) {
            duplicateRetained[metricKind(key.kind), default: 0] &+= 1
            return true
        }
        recoveryHeadRequirements[key] = max(recoveryHeadRequirements[key] ?? 0, highWatermark)
        readyRetentionFences.withLock { state in
            var fence = state[key].flatMap { $0.generation == generation ? $0 : nil }
                ?? .init(generation: generation, required: 0, retained: nil, presence: false,
                    recoveringPending: pendingRecoveryStates[key] != nil)
            fence.required = max(fence.required, highWatermark); state[key] = fence
        }
        if var existing = realtimeRecoveryDemands[key], existing.hintOnly {
            existing.hintOnly = false; existing.notificationValidity = nil
            existing.version = UUID(); setRecoveryDemand(key, existing)
            queueRecoveryScope(key)
        }
        if realtimeRecoveryDemands[key] == nil {
            var demand = RealtimeRecoveryDemand(generation: lifecycle, scopeGeneration: generation,
                scope: key.kind == .userSync ? context(key.connection)?.accountScope : nil, nextAttempt: .now)
            if pendingRecoveryStates[key] != nil { demand.reason = .coverageRecovery }
            else if installedScopes.contains(key) {
                demand.reason = highWatermark > (scopeRetentionReceipts[key]?.highWatermark ?? 0) ? .newHead : .recheck
            }
            setRecoveryDemand(key, demand)
            queueRecoveryScope(key, newDemand: true)
        }
        queueRecoveryScope(key)
        if schedule { pumpRealtimeRecovery() }
        return true
    }

    private func duplicateRequirementIsRetained(_ key: RecoveryKey, lifecycle: Generation,
        generation: Generation, highWatermark: UInt64) -> Bool {
        guard key.kind != .userPresence, installedScopes.contains(key), pendingRecoveryStates[key] == nil,
              realtimeRecoveryDemands[key] == nil, recoveryJobIDs[key] == nil,
              let receipt = scopeRetentionReceipts[key], receipt.lifecycle == lifecycle,
              receipt.generation == generation, receipt.highWatermark >= highWatermark,
              receipt.highWatermark >= (recoveryHeadRequirements[key] ?? 0),
              let retained = retainedConfirmations[key],
              let current = realtimeCoverageConfirmation?(key.kind, key.id), current.deadline > .now,
              realtimeCoverageValidation?(key.kind, key.id, current) == true,
              current.token == retained.confirmation.token, current.sessionID == retained.confirmation.sessionID,
              current.interestGeneration == retained.confirmation.interestGeneration,
              receipt.highWatermark >= current.highWatermark else { return false }
        // Installation has a fixed baseline; the separate actual hint receipt
        // proves newer heads. Comparing them to Ready would restart recovery
        // forever after the first post-installation message.
        // The current confirmation validates the Coordinator's exact topic/owner
        // generation. A replaced owner cannot reuse the previous generation.
        guard key.kind != .roomEvents else { return false }
        return true
    }

    func recordScopeRetention(_ key: V2RealtimeRecoveryKey, lifecycle: Generation, generation: Generation,
        highWatermark: UInt64, observedPresence: Bool, presenceDeadline: ContinuousClock.Instant? = nil) {
        guard !realtimeRecoveryClosed, context(key.connection)?.handle.lifecycle == lifecycle,
              scopeGenerations[key] == generation else { return }
        if observedPresence {
            guard let presenceDeadline, presenceDeadline > .now else { return }
        }
        let prior = scopeRetentionReceipts[key].flatMap {
            $0.lifecycle == lifecycle && $0.generation == generation ? $0 : nil
        }
        scopeRetentionReceipts[key] = .init(lifecycle: lifecycle, generation: generation,
            highWatermark: max(prior?.highWatermark ?? 0, highWatermark),
            observedPresence: observedPresence, presenceDeadline: presenceDeadline ?? prior?.presenceDeadline)
        readyRetentionFences.withLock { state in
            var fence = state[key].flatMap { $0.generation == generation ? $0 : nil }
                ?? .init(generation: generation, required: recoveryHeadRequirements[key] ?? 0, retained: nil, presence: false,
                    recoveringPending: pendingRecoveryStates[key] != nil)
            fence.retained = max(fence.retained ?? 0, highWatermark)
            fence.presence = observedPresence; state[key] = fence
        }
    }

    nonisolated func readyWritePermit(_ key: RecoveryKey, generation: Generation, head: UInt64,
        authorizationDeadline: ContinuousClock.Instant?)
        -> @Sendable (@Sendable () -> Void) -> Bool {
        let lifecycle = context(key.connection)?.handle.lifecycle
        return { enqueue in
            guard authorizationDeadline.map({ $0 > .now }) ?? true else {
                self.schedulingTelemetry.recordReadyRejection(.permissionExpired); return false
            }
            let result: (accepted: Bool, rejection: V2RecoveryReadyRejectionReason?) =
                self.readyRetentionFences.withLock { state in
                    guard let fence = state[key], fence.generation == generation else { return (false, .generationInvalid) }
                    guard !fence.recoveringPending else { return (false, .recovering) }
                    guard let retained = fence.retained, retained >= fence.required, head >= fence.required else {
                        return (false, .headUnsatisfied)
                    }
                    guard key.kind != .userPresence || fence.presence else { return (false, .coverageChanged) }
                    return self.recoveryWriteResult(key, lifecycle: lifecycle, generation: generation,
                        authorizationDeadline: authorizationDeadline, enqueue: enqueue)
                }
            // The Coordinator fences have exited; ByteStream may still own its
            // outer fence. The fixed Ready counter uses no mutex or fence.
            if let reason = result.rejection { self.schedulingTelemetry.recordReadyRejection(reason) }
            return result.accepted
        }
    }

    func recordPreparedPresence(_ proof: PreparedPresenceHandoff) {
        let key = RecoveryKey(connection: proof.connection, kind: .userPresence, id: proof.request.targetUserID.rawValue)
        guard proof.deadline > .now, context(proof.connection)?.handle.lifecycle == proof.lifecycle,
              scopeGenerations[key] == proof.generation else { return }
        if let newer = preparedPresenceObservations[key], newer.lifecycle == proof.lifecycle,
           newer.generation == proof.generation, newer.deadline > proof.deadline { return }
        preparedPresenceObservations[key] = proof
        refreshScheduling(key)
    }

    func preparedPresence(_ key: RecoveryKey, lifecycle: UInt64, generation: UInt64) -> PreparedPresenceHandoff? {
        guard let proof = preparedPresenceObservations[key] else { return nil }
        guard proof.deadline > .now, context(key.connection)?.handle.lifecycle == proof.lifecycle,
              scopeGenerations[key] == proof.generation else {
            preparedPresenceObservations.removeValue(forKey: key)
            refreshScheduling(key)
            return nil
        }
        // A delayed predecessor asking for its generation cannot evict the
        // successor's immutable observation.
        guard proof.lifecycle == lifecycle, proof.generation == generation else { return nil }
        return proof
    }

    private func retainScopeHead(_ key: RecoveryKey, lifecycle: Generation, generation: Generation,
        highWatermark: UInt64, stream: V2GatewayByteStream,
        authorizationDeadline: ContinuousClock.Instant?,
        journalAuthorization: V2GatewayJournalReadyAuthorization? = nil) async throws {
        let scopePermit = recoveryWritePermit(key, generation: generation,
            authorizationDeadline: authorizationDeadline)
        let permit: @Sendable (@Sendable () -> Void) -> Bool = { enqueue in
            if let journalAuthorization {
                let dispatched = Mutex(false)
                let allowed = scopePermit {
                    let accepted = journalAuthorization.permit(enqueue)
                    dispatched.withLock { $0 = accepted }
                }
                return allowed && dispatched.withLock { $0 }
            }
            return scopePermit(enqueue)
        }
        let old = scopeRetentionReceipts[key]
        if let old, old.lifecycle == lifecycle, old.generation == generation,
           old.highWatermark >= highWatermark, (key.kind != .userPresence || old.observedPresence) { return }
        let accepted: Bool
        switch key.kind {
        case .roomEvents:
            throw V2RealtimePublicationBackpressure.receiverQueue
        case .userSync:
            if highWatermark == 0 { accepted = true }
            else { accepted = await stream.retainSyncAvailable(eventID: highWatermark,
                highWatermark: highWatermark, enqueueIfCurrent: permit) }
        case .roomTyping: accepted = true // No durable state exists for ephemeral typing.
        case .userPresence:
            accepted = scopeRetentionReceipts[key].map {
                $0.lifecycle == lifecycle && $0.generation == generation && $0.observedPresence
            } == true
        }
        guard context(key.connection)?.handle.lifecycle == lifecycle, scopeGenerations[key] == generation else { return }
        guard accepted else { throw V2RealtimePublicationBackpressure.receiverQueue }
        recordScopeRetention(key, lifecycle: lifecycle, generation: generation,
            highWatermark: highWatermark, observedPresence: key.kind == .userPresence)
    }

    private func sendScopeReady(key: RecoveryKey, generation: Generation, additionalHead: UInt64 = 0,
        authorizationDeadline preparedAuthorizationDeadline: ContinuousClock.Instant? = nil,
        userAuthorization: V2GatewayJournalReadyAuthorization? = nil) async throws {
        guard !realtimeRecoveryClosed else {
            schedulingTelemetry.recordReadyRejection(.closed); return
        }
        guard scopeGenerations[key] == generation else {
            schedulingTelemetry.recordReadyRejection(.generationInvalid)
            throw V2RealtimePublicationBackpressure.receiverQueue
        }
        guard pendingRecoveryStates[key] == nil, installedScopes.contains(key) else {
            schedulingTelemetry.recordReadyRejection(.recovering)
            throw V2RealtimePublicationBackpressure.receiverQueue
        }
        guard let lifecycle = context(key.connection)?.handle.lifecycle, let identity = context(key.connection)?.handle.identity,
              let stream = context(key.connection)?.handle.stream else {
            schedulingTelemetry.recordReadyRejection(.generationInvalid)
            throw V2RealtimePublicationBackpressure.receiverQueue
        }
        guard let confirmation = realtimeCoverageConfirmation?(key.kind, key.id) else {
            schedulingTelemetry.recordReadyRejection(.coverageChanged)
            throw V2RealtimePublicationBackpressure.receiverQueue
        }
        let authorizationDeadline = preparedAuthorizationDeadline
        let journalAuthorization: V2GatewayJournalReadyAuthorization?
        if let userAuthorization { journalAuthorization = userAuthorization
        } else if let journalUserBaselineBarrier {
            journalAuthorization = try await journalUserBaselineBarrier(identity.userID)
            guard context(key.connection)?.handle.lifecycle == lifecycle, scopeGenerations[key] == generation,
                  pendingRecoveryStates[key] == nil, installedScopes.contains(key) else { throw V2RealtimePublicationBackpressure.receiverQueue }
        } else { journalAuthorization = nil }
        let originalAuthorizationDeadline = authorizationDeadline
        let validator = realtimeCoverageValidation
        // ByteStream calls this both before and inside actual enqueue, and
        // retains it for retries. Only fixed lock-free counters are touched:
        // no timing mutex, event record, task or proof extension is introduced.
        let telemetry = schedulingTelemetry
        let validates: @Sendable () -> Bool = {
            guard originalAuthorizationDeadline.map({ $0 > .now }) ?? true else {
                telemetry.recordReadyRejection(.permissionExpired); return false
            }
            guard validator?(key.kind, key.id, confirmation) == true else {
                telemetry.recordReadyRejection(.coverageChanged); return false
            }
            return true
        }
        guard validates() else {
            throw V2RealtimePublicationBackpressure.receiverQueue
        }
        let head = max(journalAuthorization?.highWatermark ?? 0, max(additionalHead, max(confirmation.highWatermark, recoveryHeadRequirements[key] ?? 0)))
        if recoveryJobIDs[key] != nil { recoveryExecutionStage[key] = (.retention, .now) }
        try await retainScopeHead(key, lifecycle: lifecycle, generation: generation, highWatermark: head, stream: stream, authorizationDeadline: originalAuthorizationDeadline, journalAuthorization: journalAuthorization)
        guard !realtimeRecoveryClosed else { schedulingTelemetry.recordReadyRejection(.closed); return }
        guard context(key.connection)?.handle.lifecycle == lifecycle, scopeGenerations[key] == generation else {
            schedulingTelemetry.recordReadyRejection(.generationInvalid); return
        }
        guard validates() else {
            throw V2RealtimePublicationBackpressure.receiverQueue
        }
        guard let receipt = scopeRetentionReceipts[key] else {
            schedulingTelemetry.recordReadyRejection(.headUnsatisfied)
            throw V2RealtimePublicationBackpressure.receiverQueue
        }
        guard receipt.lifecycle == lifecycle, receipt.generation == generation else {
            schedulingTelemetry.recordReadyRejection(.generationInvalid)
            throw V2RealtimePublicationBackpressure.receiverQueue
        }
        guard receipt.highWatermark >= max(head, recoveryHeadRequirements[key] ?? 0) else {
            schedulingTelemetry.recordReadyRejection(.headUnsatisfied)
            throw V2RealtimePublicationBackpressure.receiverQueue
        }
        guard key.kind != .userPresence || receipt.observedPresence else {
            schedulingTelemetry.recordReadyRejection(.coverageChanged)
            throw V2RealtimePublicationBackpressure.receiverQueue
        }
        journalScopeAuthorizations.withLock { $0[key] = journalAuthorization }
        if let old = retainedConfirmations[key], old.confirmation.token == confirmation.token,
           old.confirmation.sessionID == confirmation.sessionID,
           old.confirmation.interestGeneration == confirmation.interestGeneration,
           receipt.highWatermark >= head {
            // Ready describes the fixed installation baseline. Later heads
            // have their own retained hint and never redefine that baseline.
            // Permission rechecks can refresh authority without another Ready.
            retainedConfirmations[key] = .init(confirmation: confirmation, highWatermark: old.highWatermark)
            return
        }
        if recoveryJobIDs[key] != nil { recoveryExecutionStage[key] = (.coverageWrite, .now) }
        let scopeReadyPermit = readyWritePermit(key, generation: generation, head: head,
            authorizationDeadline: originalAuthorizationDeadline)
        let readyPermit: @Sendable (@Sendable () -> Void) -> Bool = { enqueue in
            guard let journalAuthorization else { return scopeReadyPermit(enqueue) }
            let dispatched = Mutex(false)
            let allowed = scopeReadyPermit {
                let accepted = journalAuthorization.permit(enqueue)
                dispatched.withLock { $0 = accepted }
            }
            return allowed && dispatched.withLock { $0 }
        }
        let accepted = await stream.retainRealtimeCoverageReady(scope: key.wireScope, scopeID: key.id,
            scopeGeneration: generation, highWatermark: head, confirms: validates,
            scopePermit: readyPermit)
        guard !realtimeRecoveryClosed else { schedulingTelemetry.recordReadyRejection(.closed); return }
        guard context(key.connection)?.handle.lifecycle == lifecycle, scopeGenerations[key] == generation else {
            schedulingTelemetry.recordReadyRejection(.generationInvalid); return
        }
        guard validates() else {
            throw V2RealtimePublicationBackpressure.receiverQueue
        }
        guard accepted else {
            schedulingTelemetry.recordReadyRejection(.enqueueRefused)
            throw V2RealtimePublicationBackpressure.receiverQueue
        }
        retainedConfirmations[key] = .init(confirmation: confirmation, highWatermark: head)
    }

    private func metricKind(_ kind: V2RealtimeTopicKind) -> V2RegistryRecoveryScopeKind {
        switch kind { case .roomEvents: .room; case .userSync: .account; case .userPresence: .presence; case .roomTyping: .typing }
    }

    func registryRecoveryMetricsSnapshot() -> V2RegistryRecoveryMetricsSnapshot {
        let now = ContinuousClock.now
        var snapshot = V2RegistryRecoveryMetricsSnapshot(duplicateRetained: duplicateRetained)
        snapshot.schedulingTelemetry = schedulingTelemetry.snapshot()
        func age(_ began: ContinuousClock.Instant) -> Double {
            let value = began.duration(to: now).components
            return max(0, Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15)
        }
        // This is the admission ledger itself, not a sum of overlapping scope
        // phases. Return reservations include retired attempts until actual
        // terminal; prepared proofs are already represented in queued positions.
        let queuedOldest = realtimeRecoveryDemands.keys(at: .queued).compactMap { realtimeRecoveryDemands[$0]?.createdAt }.map(age).max() ?? 0
        let returnsOldest = authorizationReturns.values.flatMap { $0.values }.map { age($0.began) }.max() ?? 0
        let selectedOldest = selectedHandoffPositions.compactMap { key in
            recoveryJobIDs[key].flatMap { recoveryTasks[$0]?.began }
        }.map(age).max() ?? 0
        let outboundOldest = outboundRecoveryTickets.keys.compactMap { inlineRetentions[$0]?.started }.map(age).max() ?? 0
        snapshot.positionLedger = .init(capacity: maximumQueuedRealtimeRecoveries, stages: [
            .queued: .init(count: recoveryQueuedCount, oldestMilliseconds: queuedOldest),
            .authorizationReturns: .init(count: reservedAuthorizationReturnCount, oldestMilliseconds: returnsOldest),
            .selectedHandoff: .init(count: selectedHandoffPositions.count, oldestMilliseconds: selectedOldest),
            .outbound: .init(count: outboundRecoveryTickets.count, oldestMilliseconds: outboundOldest)
        ])
        func add(_ kind: V2RegistryRecoveryScopeKind, _ stage: V2RegistryRecoveryStage, _ began: ContinuousClock.Instant) {
            var value = snapshot.stages[kind]?[stage] ?? .init()
            value.count += 1; value.oldestMilliseconds = max(value.oldestMilliseconds, age(began))
            snapshot.stages[kind, default: [:]][stage] = value
        }
        for (key, demand) in realtimeRecoveryDemands {
            let kind = metricKind(key.kind)
            add(kind, .desired, demand.createdAt)
            snapshot.reasons[kind, default: [:]][demand.reason, default: 0] += 1
            let receipt = scopeRetentionReceipts[key]
            if receipt?.lifecycle != demand.generation || receipt?.generation != demand.scopeGeneration
                || (receipt?.highWatermark ?? 0) < (recoveryHeadRequirements[key] ?? 0)
                || (key.kind == .userPresence && receipt?.observedPresence != true) {
                add(kind, .awaitingRetention, demand.createdAt)
            }
            if isRecoveryQueued(key) { add(kind, .queued, demand.createdAt) }
        }
        for tickets in authorizationReturns.values {
            for (key, ticket) in tickets { add(metricKind(key.kind), .authorizationReturns, ticket.began) }
        }
        for (key, taskID) in recoveryJobIDs {
            guard let began = recoveryTasks[taskID]?.began else { continue }
            let kind = metricKind(key.kind)
            add(kind, .actualScopes, began)
            add(kind, .actual, began)
            if let (stage, phaseStarted) = recoveryExecutionStage[key] { add(kind, stage, phaseStarted) }
            if let reason = actualRecoveryReasons[key] { snapshot.actualReasons[kind, default: [:]][reason, default: 0] += 1 }
        }
        func addAttempt(_ stage: V2RecoveryAttemptStage, _ began: ContinuousClock.Instant) {
            var value = snapshot.recoveryAttemptStages[stage] ?? .init()
            value.count += 1; value.oldestMilliseconds = max(value.oldestMilliseconds, age(began))
            snapshot.recoveryAttemptStages[stage] = value
        }
        for task in recoveryTasks.values {
            switch task.lane {
            case .interest: addAttempt(.interestActivation, task.began)
            case .query: addAttempt(.queryRoot, task.began)
            case .control: addAttempt(.control, task.began)
            }
        }
        for (key, ticket) in inlineRetentions {
            add(metricKind(key.kind), outboundRecoveryTickets[key] != nil ? .outboundRetention : .inlineRetention, ticket.started)
        }
        return snapshot
    }

    func realtimeRecoverySnapshot() -> (desired: Int, queued: Int, actual: Int, closed: Bool, control: Int, positions: Int, interest: Int, queryRoots: Int) {
        (realtimeRecoveryDemands.count, recoveryQueuedCount, recoveryTasks.count, realtimeRecoveryClosed, actualControlDispatches, recoveryQueueOccupancy, actualInterestActivations, actualPermissionQueries)
    }

    func retainDurableRealtimeDelivery(_ delivery: V2RealtimeDelivery,
        isCurrent: @escaping @Sendable () -> Bool) async {
        let head: UInt64
        switch delivery.payload {
        case .userSync(_, let value): head = value
        default: return
        }
        guard isCurrent() else { invalidateDurableRealtimeDelivery(delivery); return }
        let keys = connectionsWithInterest(in: delivery.topic).map {
            RecoveryKey(connection: $0, kind: delivery.topic.kind, id: delivery.topic.id)
        }
        // Merge all bounded scope state before any actual handoff. Existing
        // ingress consumers may inline healthy hints independently of recovery
        // jobs blocked on interest installation or authoritative reads.
        for key in keys {
            guard !realtimeRecoveryClosed, let lifecycle = context(key.connection)?.handle.lifecycle,
                  let generation = scopeGenerations[key] else { continue }
            if realtimeRecoveryDemands[key]?.notificationValidity?() == false {
                // A new valid delivery cannot inherit an obsolete owner's H.
                recoveryHeadRequirements.removeValue(forKey: key)
                scopeRetentionReceipts.removeValue(forKey: key)
                journalScopeAuthorizations.withLock { $0.removeValue(forKey: key) }
                readyRetentionFences.withLock { $0.removeValue(forKey: key) }
            }
            recoveryHeadRequirements[key] = max(recoveryHeadRequirements[key] ?? 0, head)
            readyRetentionFences.withLock { state in
                var fence = state[key].flatMap { $0.generation == generation ? $0 : nil }
                    ?? .init(generation: generation, required: 0, retained: nil, presence: false,
                        recoveringPending: pendingRecoveryStates[key] != nil)
                fence.required = max(fence.required, head); state[key] = fence
            }
            if let receipt = scopeRetentionReceipts[key], receipt.lifecycle == lifecycle,
               receipt.generation == generation, receipt.highWatermark >= head,
               notificationConfirmation(key) != nil { continue }
            let isNewDemand = realtimeRecoveryDemands[key] == nil
            var demand = realtimeRecoveryDemands[key] ?? .init(generation: lifecycle,
                scopeGeneration: generation, scope: key.kind == .userSync ? context(key.connection)?.accountScope : nil, nextAttempt: .now)
            demand.version = UUID()
            demand.notificationValidity = isCurrent
            demand.hintOnly = realtimeRecoveryDemands[key].map { $0.hintOnly } ?? (notificationConfirmation(key) != nil)
            if demand.hintOnly { demand.reason = .newHead }
            setRecoveryDemand(key, demand)
            queueRecoveryScope(key, newDemand: isNewDemand)
        }
        for key in keys {
            await inlineRetainDurableNotification(key)
        }
        pumpRealtimeRecovery()
    }

    private func inlineRetainDurableNotification(_ key: RecoveryKey) async {
        guard !realtimeRecoveryClosed, inlineRetentions.count < 4,
              inlineRetentions[key] == nil, recoveryJobIDs[key] == nil,
              let demand = realtimeRecoveryDemands[key], demand.hintOnly,
              scopeIsCurrent(key, demand), notificationConfirmation(key) != nil else { return }
        let ticket = InlineRetentionTicket(lifecycle: demand.generation, generation: demand.scopeGeneration)
        inlineRetentions[key] = ticket
        refreshScheduling(key)
        defer {
            if inlineRetentions[key]?.id == ticket.id { inlineRetentions.removeValue(forKey: key) }
            if inlineRetentions.isEmpty { inlineRetentionDrain?.resume(); inlineRetentionDrain = nil }
            queueRecoveryScope(key)
            pumpRealtimeRecovery()
        }
        // Chase merged H on this existing consumer. Original authority/lease
        // deadlines bound the loop; they are never refreshed by notification.
        while !realtimeRecoveryClosed, let current = realtimeRecoveryDemands[key], current.hintOnly,
              current.generation == ticket.lifecycle, current.scopeGeneration == ticket.generation,
              scopeIsCurrent(key, current), current.notificationValidity?() != false,
              let confirmation = notificationConfirmation(key), let identity = context(key.connection)?.handle.identity,
              let stream = context(key.connection)?.handle.stream {
            let head = recoveryHeadRequirements[key] ?? 0
            do {
                try await retainDurableNotification(key, lifecycle: ticket.lifecycle, generation: ticket.generation,
                    confirmation: confirmation, highWatermark: head, stream: stream,
                    additionalValidity: current.notificationValidity ?? { true })
                finishNotificationDemand(key, demand: current)
            } catch { break } // Actual failure stays owned by bounded recovery.
        }
    }

    private func waitForInlineRetentionDrain() async {
        precondition(outboundRecoveryTickets.allSatisfy { key, id in inlineRetentions[key]?.id == id })
        guard !inlineRetentions.isEmpty else { return }
        await withCheckedContinuation { inlineRetentionDrain = $0 }
        precondition(outboundRecoveryTickets.isEmpty && inlineRetentions.isEmpty)
    }

    func invalidateDurableRealtimeDelivery(_ delivery: V2RealtimeDelivery) {
        guard !realtimeRecoveryClosed else { return }
        switch delivery.payload {
        case .roomWake, .roomEvents, .userSync: break
        default: return
        }
        for connection in connectionsWithInterest(in: delivery.topic) {
            let key = RecoveryKey(connection: connection, kind: delivery.topic.kind, id: delivery.topic.id)
            guard scopeGenerations[key] != nil else { continue }
            // Stale work owns no authority over a successor's proof or H.
            // A current confirmed scope needs no action for an obsolete item.
            if let current = realtimeCoverageConfirmation?(key.kind, key.id), current.deadline > .now,
               realtimeCoverageValidation?(key.kind, key.id, current) == true,
               let retained = retainedConfirmations[key],
               retained.confirmation.token == current.token,
               retained.confirmation.sessionID == current.sessionID,
               retained.confirmation.interestGeneration == current.interestGeneration {
                continue
            }
            // No confirmed local successor: request a fresh authoritative read.
            // Preserve existing (possibly newer) requirements and receipts; do
            // not merge any value from this obsolete payload or revoke Ready.
            queueScopeRetention(key, highWatermark: recoveryHeadRequirements[key] ?? 0)
            if var demand = realtimeRecoveryDemands[key] {
                demand.hintOnly = false; demand.notificationValidity = nil
                demand.version = UUID(); setRecoveryDemand(key, demand)
            }
        }
    }

    private func notificationConfirmation(_ key: RecoveryKey) -> V2RealtimeCoverageConfirmation? {
        guard installedScopes.contains(key), pendingRecoveryStates[key] == nil,
              let retained = retainedConfirmations[key], let current = realtimeCoverageConfirmation?(key.kind, key.id),
              realtimeCoverageValidation?(key.kind, key.id, current) == true,
              // Same exact live session may renew its deadline. The old Ready
              // enqueue proof remains valid; only current lease authority and
              // the original successful permission window authorize new hints.
              current.deadline > .now, retained.confirmation.token == current.token,
              retained.confirmation.sessionID == current.sessionID,
              retained.confirmation.interestGeneration == current.interestGeneration else { return nil }
        guard key.kind != .roomEvents else { return nil }
        if key.kind == .userSync, journalUserBaselineBarrier != nil {
            guard let authority = journalScopeAuthorizations.withLock({ $0[key] }), authority.permit({}) else { return nil }
        }
        return current
    }

    private func retainDurableNotification(_ key: RecoveryKey, lifecycle: Generation, generation: Generation,
        confirmation: V2RealtimeCoverageConfirmation, highWatermark: UInt64, stream: V2GatewayByteStream,
        additionalValidity: @escaping @Sendable () -> Bool = { true }) async throws {
        let validator = realtimeCoverageValidation
        let journalAuthority = journalScopeAuthorizations.withLock { $0[key] }
        guard key.kind != .roomEvents else { throw V2RealtimePublicationBackpressure.receiverQueue }
        let permissionDeadline = confirmation.deadline
        let scopePermit = recoveryWritePermit(key, generation: generation)
        let permit: @Sendable (@Sendable () -> Void) -> Bool = { enqueue in
            guard permissionDeadline > .now, additionalValidity(),
                  validator?(key.kind, key.id, confirmation) == true else { return false }
            return self.readyRetentionFences.withLock { state in
                guard let fence = state[key], fence.generation == generation,
                      !fence.recoveringPending else { return false }
                guard let journalAuthority else { return scopePermit(enqueue) }
                let dispatched = Mutex(false)
                let accepted = scopePermit {
                    let written = journalAuthority.permit(enqueue)
                    dispatched.withLock { $0 = written }
                }
                return accepted && dispatched.withLock { $0 }
            }
        }
        let accepted: Bool
        switch key.kind {
        case .userSync:
            accepted = await stream.retainSyncAvailable(eventID: highWatermark,
                highWatermark: highWatermark, enqueueIfCurrent: permit)
        default: return
        }
        guard accepted, !realtimeRecoveryClosed, context(key.connection)?.handle.lifecycle == lifecycle,
              scopeGenerations[key] == generation, additionalValidity(),
              validator?(key.kind, key.id, confirmation) == true else { throw V2RealtimePublicationBackpressure.receiverQueue }
        recordScopeRetention(key, lifecycle: lifecycle, generation: generation,
            highWatermark: highWatermark, observedPresence: false)
    }

    private func finishNotificationDemand(_ key: RecoveryKey, demand: RealtimeRecoveryDemand) {
        guard scopeIsCurrent(key, demand), let current = realtimeRecoveryDemands[key], current.hintOnly,
              current.version == demand.version, let receipt = scopeRetentionReceipts[key],
              receipt.lifecycle == demand.generation, receipt.generation == demand.scopeGeneration,
              receipt.highWatermark >= (recoveryHeadRequirements[key] ?? 0) else { return }
        removeRecoveryDemand(key)
    }

    func invalidateRealtimeCoverage(topics: Set<V2RealtimeTopic>, registeredThrough cutoff: ContinuousClock.Instant) async {
        // Revoke local presentation synchronously. A coordinator callback never
        // waits on a socket; existing bounded scope workers own the transitions.
        for topic in topics {
            for connection in connectionsWithInterest(in: topic) {
                guard let began = context(connection)?.registeredAt, began <= cutoff,
                      context(connection)?.handle.lifecycle != nil else { continue }
                let key = RecoveryKey(connection: connection, kind: topic.kind, id: topic.id)
                guard scopeGenerations[key] != nil else { continue }
                scopeRetentionReceipts.removeValue(forKey: key)
                retainedConfirmations.removeValue(forKey: key)
        preparedPresenceObservations.removeValue(forKey: key)
                journalScopeAuthorizations.withLock { $0.removeValue(forKey: key) }
                readyRetentionFences.withLock { $0.removeValue(forKey: key) }
                pendingRecoveryStates[key] = .init(version: makeGeneration(), reason: .coverageLost)
                queueScopeRetention(key, highWatermark: recoveryHeadRequirements[key] ?? 0, schedule: false)
            }
        }
        pumpRealtimeRecovery()
    }

    func realtimeCoverageReady(confirmations: [V2RealtimeTopic: V2RealtimeCoverageConfirmation],
        confirms: @escaping @Sendable (V2RealtimeTopic, V2RealtimeCoverageConfirmation) -> Bool) async {
        for (topic, confirmation) in confirmations where confirms(topic, confirmation) {
            for connection in connectionsWithInterest(in: topic) {
                queueScopeRetention(.init(connection: connection, kind: topic.kind, id: topic.id),
                    highWatermark: confirmation.highWatermark, schedule: false)
            }
        }
        pumpRealtimeRecovery()
    }

    func arrangeRealtimeRecoveryHeads(_ heads: [V2RealtimeTopic: UInt64]) async throws -> Set<V2RealtimeTopic> {
        var scheduled: Set<V2RealtimeTopic> = []
        for (topic, head) in heads {
            guard !realtimeRecoveryClosed else { break }
            var retained = false
            for connection in connectionsWithInterest(in: topic) {
                if queueScopeRetention(.init(connection: connection, kind: topic.kind, id: topic.id), highWatermark: head, schedule: false) {
                    retained = true
                }
            }
            if retained { scheduled.insert(topic) }
        }
        pumpRealtimeRecovery()
        return scheduled
    }
}

/// One synchronized generation authority used by the coordinator state machine
/// and enqueue permits. Connection removal touches only its own scope bucket.
final class V2RealtimeScopeGenerations: Sendable {
    private struct Topic: Hashable, Sendable {
        let kind: V2RealtimeTopicKind
        let id: String
        init(_ key: V2RealtimeRecoveryKey) { kind = key.kind; id = key.id }
        init(kind: V2RealtimeTopicKind, id: String) {
            self.kind = kind; self.id = UUID(uuidString: id)?.uuidString ?? id
        }
    }
    private struct State: Sendable {
        var values: [V2RealtimeRecoveryKey: UInt64] = [:]
        var keysByConnection: [UUID: Set<V2RealtimeRecoveryKey>] = [:]
        var keysByTopic: [Topic: Set<V2RealtimeRecoveryKey>] = [:]
        mutating func removeIndexes(_ key: V2RealtimeRecoveryKey) {
            keysByConnection[key.connection]?.remove(key)
            if keysByConnection[key.connection]?.isEmpty == true { keysByConnection.removeValue(forKey: key.connection) }
            let topic = Topic(key)
            keysByTopic[topic]?.remove(key)
            if keysByTopic[topic]?.isEmpty == true { keysByTopic.removeValue(forKey: topic) }
        }
    }
    private let state = Mutex(State())
    subscript(_ key: V2RealtimeRecoveryKey) -> UInt64? {
        get { state.withLock { $0.values[key] } }
        set { state.withLock { state in
            state.values[key] = newValue
            if newValue != nil {
                state.keysByConnection[key.connection, default: []].insert(key)
                state.keysByTopic[Topic(key), default: []].insert(key)
            } else { state.removeIndexes(key) }
        } }
    }
    func matching(kind: V2RealtimeTopicKind, id: String) -> Set<V2RealtimeRecoveryKey> {
        state.withLock { $0.keysByTopic[Topic(kind: kind, id: id)] ?? [] }
    }
    func withGeneration(_ key: V2RealtimeRecoveryKey, generation: UInt64, body: () -> Bool) -> Bool {
        state.withLock { state in
            guard state.values[key] == generation else { return false }
            return body()
        }
    }
    @discardableResult func removeValue(forKey key: V2RealtimeRecoveryKey, ifGeneration generation: UInt64) -> UInt64? {
        state.withLock { state in
            guard state.values[key] == generation else { return nil }
            state.removeIndexes(key)
            return state.values.removeValue(forKey: key)
        }
    }
    @discardableResult func removeValue(forKey key: V2RealtimeRecoveryKey) -> UInt64? {
        state.withLock { state in
            state.removeIndexes(key)
            return state.values.removeValue(forKey: key)
        }
    }
    func removeConnection(_ connection: UUID) -> Set<V2RealtimeRecoveryKey> {
        state.withLock { state in
            let keys = state.keysByConnection.removeValue(forKey: connection) ?? []
            for key in keys { state.values.removeValue(forKey: key); state.removeIndexes(key) }
            return keys
        }
    }
    func removeAll() { state.withLock { $0 = State() } }
}
