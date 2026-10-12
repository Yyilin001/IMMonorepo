import Foundation
import Synchronization
import IMV2Core
import IMV2ActorContracts
import IMV2ActorCluster
import IMV2ServerContracts
import IMV2ServerApplication
import IMV2ServerGateway
import IMV2ServerInfrastructure
import Logging

/// Owns source publication, bounded online acceleration and local trusted repair.
/// Routing leases only select candidates; the publisher claims each source DB.
final class GatewayJournalRuntime: Sendable {
    let catalog: GatewayJournalSourceCatalog
    let receiver: V2GatewayJournalProjectionReceiver
    private let projection: V2RealtimeJournalSharedProjection
    private let authority: V2GatewayJournalAuthorityIngress
    private let publisher: V2RealtimeJournalPublisher
    private let fanout: V2RealtimeJournalFanout
    private let aliases: [String]
    private let coordinator: V2RealtimeInterestCoordinator
    private let registry: V2DeviceConnectionRegistry
    private let identity: V2GatewayRealtimeIdentity
    private let worker = Mutex<Task<Void, Never>?>(nil)
    private let clock = Mutex<Task<Void, Never>?>(nil)
    private let wakes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let cold = GatewayJournalColdFlights()
    private let logger = Logger(label: "imv2.gateway.journal")
    private let reportedFailures = Mutex<Set<String>>([])

    private func recordFailure(_ error: any Error, phase: String) {
        let reason: String
        if let authority = error as? GatewayJournalAuthorityError { reason = authority.rawValue }
        else if let catalog = error as? GatewayJournalSourceCatalog.CatalogError {
            switch catalog {
            case .sourceNotReady: reason = "sourceNotReady"
            case .invalidSnapshot: reason = "invalidSnapshot"
            case .identityChanged: reason = "identityChanged"
            case .invalidConfiguration: reason = "catalogInvalidConfiguration"
            case .conflictingAlias: reason = "catalogConflictingAlias"
            case .conflictingIdentity: reason = "catalogConflictingIdentity"
            case .unknownSource: reason = "catalogUnknownSource"
            }
        } else if let journal = error as? V2RealtimeJournalError {
            switch journal {
            case .invalidInput: reason = "journalInvalidInput"
            case .authorityLost: reason = "journalLeaseLost"
            case .corruptPersistenceState: reason = "journalCorruptPersistenceState"
            }
        } else if error is CancellationError { return }
        else { reason = "otherRejected" }
        if reportedFailures.withLock({ $0.insert(phase + ":" + reason).inserted }) {
            var metadata = V2SafeLogMetadata.failure(error, stage: "journal_authority")
            metadata["phase"] = .string(phase)
            metadata["reason"] = .string(reason)
            logger.warning("Journal authority did not install", metadata: metadata)
        }
    }

    private init(catalog: GatewayJournalSourceCatalog, receiver: V2GatewayJournalProjectionReceiver,
                 projection: V2RealtimeJournalSharedProjection, authority: V2GatewayJournalAuthorityIngress,
                 publisher: V2RealtimeJournalPublisher,
                 fanout: V2RealtimeJournalFanout, aliases: [String], coordinator: V2RealtimeInterestCoordinator,
                 registry: V2DeviceConnectionRegistry,
                 identity: V2GatewayRealtimeIdentity) {
        self.catalog = catalog; self.receiver = receiver; self.projection = projection; self.authority = authority
        self.publisher = publisher; self.fanout = fanout; self.aliases = aliases
        self.coordinator = coordinator; self.registry = registry; self.identity = identity
    }

    static func build(catalog: GatewayJournalSourceCatalog, handle: V2RealtimeTransportHandle,
                      service: V2RealtimeShardService, coordinator: V2RealtimeInterestCoordinator,
                      registry: V2DeviceConnectionRegistry,
                      identity: V2GatewayRealtimeIdentity) async throws -> GatewayJournalRuntime {
        let aliases = try Set(catalog.logicalAliases.map { try catalog.canonicalAlias(for: catalog.entry(logicalAlias: $0).identity) }).sorted()
        let bindingCapacity = aliases.count * 256
        let projection = V2RealtimeJournalSharedProjection(limits: .init(partitions: bindingCapacity))
        let receiver = V2GatewayJournalProjectionReceiver(projection: projection, maximumBindings: bindingCapacity)
        let authenticationAliases = try Set(catalog.logicalAliases.filter { try catalog.entry(logicalAlias: $0).isAuthenticationSource })
        guard receiver.configureAuthenticationSources(authenticationAliases) else { throw V2RealtimeJournalError.invalidInput }
        let authority = GatewayJournalAuthorityAssembly.build(catalog: catalog, coordinator: coordinator,
            registry: registry, receiver: receiver)
        let fanout = try V2RealtimeJournalFanout(sourceIdentity: { try catalog.entry(logicalAlias: $0).identity },
            recipients: { await service.journalRecipients(partitionID: $0) },
            isCurrent: { await service.journalRecipientIsCurrent($0) }, requestColdSnapshot: { recipient, source, fence, cut in
                let batch = V2RealtimeJournalProjectionBatch(source: source, fence: fence, payload: .baseline(minimumCut: cut))
                guard case .applied(let receipt) = try await handle.sendJournalProjection(batch, to: recipient.session.gateway),
                      receipt.snapshotInstalled, receipt.appliedThrough >= cut else { throw V2RealtimeJournalError.authorityLost }
                return receipt
            }, send: { try await handle.sendJournalProjection(Self.userControlProjection($1), to: $0) })
        let sources = try aliases.map { alias in
            let store = try catalog.entry(logicalAlias: alias).store
            return V2RealtimeJournalPublisherSource(id: alias, store: store)
        }
        let publisher = try V2RealtimeJournalPublisher(sources: sources,
            apply: { try await fanout.apply(sourceID: $0, lease: $1, batch: $2) })
        do { try await handle.configureJournalProjection(authority) }
        catch { await publisher.close(); await fanout.close(); await authority.shutdown(); throw error }
        await registry.configureJournalUserControlReceiver(receiver)
        let runtime = GatewayJournalRuntime(catalog: catalog, receiver: receiver, projection: projection,
            authority: authority, publisher: publisher, fanout: fanout,
            aliases: aliases, coordinator: coordinator, registry: registry, identity: identity)
        coordinator.configureJournalCoverageObserver { [weak runtime] change in
            guard let runtime else { return }
            if case .invalidated(let partition) = change {
                for alias in runtime.aliases {
                    if let source = try? runtime.catalog.source(logicalAlias: alias, partitionID: partition) { runtime.receiver.retire(source: source) }
                }
            }
            runtime.wakes.continuation.yield(())
        }
        await registry.configureJournalInterestChanges { [weak runtime] in runtime?.wakes.continuation.yield(()) }
        await registry.configureJournalUserBaselineBarrier { [weak runtime] user in
            guard let runtime else { throw V2RealtimeJournalError.authorityLost }
            do { return try await runtime.ensureUserBaseline(user) }
            catch let error as GatewayJournalAuthorityError {
                runtime.recordFailure(error, phase: "userBaseline")
                // An uninstalled authority is retryable coverage work. It must
                // not tear down the connection that owns the pending interest.
                throw V2RealtimePublicationBackpressure.receiverQueue
            }
        }
        return runtime
    }

    func install(_ values: [GatewayRealtimePartitionControl.Installed]) async throws {
        for alias in aliases { try await publisher.setLeases(sourceID: alias, leases: values.map(\.lease)) }
    }
    func start() async {
        authority.start(); await publisher.start()
        let task = Task { [weak self, stream = wakes.stream] in
            for await _ in stream {
                guard !Task.isCancelled, let self else { return }
                await self.reconcile()
            }
        }
        worker.withLock { $0 = task }
        let timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.wakes.continuation.yield(())
            }
        }
        clock.withLock { $0 = timer }; wakes.continuation.yield(())
    }
    private func refresh(_ source: V2RealtimeJournalSource) async throws {
        try Task.checkCancellation()
        guard let coverage = coordinator.journalCoverage(partitionID: source.partitionID) else {
            let error = GatewayJournalAuthorityError.coverageChanged
            recordFailure(error, phase: "coldRefresh")
            throw error
        }
        let key = GatewayJournalColdFlights.Key(source: source, routingToken: coverage.token.leaseToken,
            routingEpoch: coverage.token.epoch, session: coverage.sessionID, revision: coverage.revision)
        do {
            try await cold.run(key: key) { [self] in
                guard coordinator.confirmsJournalCoverage(coverage) else { throw V2RealtimeJournalError.authorityLost }
                try await GatewayJournalAuthorityAssembly.refresh(catalog: catalog, coordinator: coordinator,
                    registry: registry, receiver: receiver, source: source, gatewayIdentity: identity)
                guard coordinator.confirmsJournalCoverage(coverage) else { throw V2RealtimeJournalError.authorityLost }
            }
        } catch {
            recordFailure(error, phase: "coldRefresh")
            // Queue saturation is a retry, never a grant. Current coverage
            // remains in the coordinator's bounded discovery set; the owned
            // periodic pass retries it without an immediate failure spin.
            throw error
        }
        try Task.checkCancellation()
    }
    private func reconcile() async {
        // Include room-DB user partitions: membership triggers are physically
        // local and must not be mistaken for the authentication source.
        for coverage in coordinator.activeJournalCoverages().sorted(by: { $0.token.partitionID < $1.token.partitionID }) {
            let partition = coverage.token.partitionID
            for alias in aliases {
                if Task.isCancelled { return }
                do { try await reconcileSource(catalog.source(logicalAlias: alias, partitionID: partition)) }
                catch { recordFailure(error, phase: "reconcile") }
            }
        }
    }
    /// Preserve the evaluated ordered range while removing all room authority
    /// and heads. User/device invalidation remains an authoritative cold repair.
    static func userControlProjection(_ batch: V2RealtimeJournalProjectionBatch) -> V2RealtimeJournalProjectionBatch {
        let payload: V2RealtimeJournalProjectionPayload
        switch batch.payload {
        case .baseline: payload = batch.payload
        case .changes(let from, let through, let entries):
            payload = .changes(fromExclusive: from, throughInclusive: through, entries: entries.filter {
                if case .userControlInvalidation = $0.change { return true }; return false
            })
        case .snapshot(let cut, _): payload = .snapshot(cut: cut, rooms: [])
        case .heads: payload = .heads([])
        }
        return .init(source: batch.source, fence: batch.fence, payload: payload)
    }
    static func matchesSourceLease(_ lease: V2RealtimePartitionLease, fence: V2RealtimeJournalProjectionFence,
                                   host: V2GatewayRealtimeIdentity) -> Bool {
        lease.identity == host && lease.identity.incarnationID == fence.publisherIncarnationID
            && lease.epoch == fence.sourceLeaseEpoch && lease.token == fence.sourceLeaseToken
    }
    private func reconcileSource(_ source: V2RealtimeJournalSource) async throws {
        guard let coverage = coordinator.journalCoverage(partitionID: source.partitionID),
              let binding = receiver.bindingSnapshot(source: source) else { try await refresh(source); return }
        let proof = try await catalog.userSnapshotProof(source: source, userIDs: [], deviceIDs: [])
        guard Self.matchesSourceLease(proof.lease, fence: binding.fence, host: coverage.token.host),
              binding.fence.routingLeaseToken == coverage.token.leaseToken,
              binding.fence.routingPartitionEpoch == coverage.token.epoch,
              binding.fence.sessionID == coverage.sessionID, binding.fence.interestGeneration == coverage.revision,
              coordinator.confirmsJournalCoverage(coverage), proof.validUntil > .now,
              let cut = projection.controlCheckpoint(source: source, isCurrent: { _, f in binding.fence.sameGeneration(as: f) }),
              proof.value.snapshot.cuts.first(where: { $0.partitionID == source.partitionID })?.publishedThrough == cut,
              receiver.renew(source: source, serviceID: coverage.token.host.serviceID, fence: binding.fence,
                deadline: min(coverage.deadline, proof.validUntil), current: { self.coordinator.confirmsJournalCoverage(coverage) }) else {
            try await refresh(source); return
        }
        return
    }
    private func ensureUserBaseline(_ user: UserID) async throws -> V2GatewayJournalUserBaselineProof {
        try Task.checkCancellation()
        if let binding = receiver.authenticationBinding(userID: user) {
            return .init(source: binding.source, fence: binding.fence, userID: user, controlVersion: binding.controlVersion)
        }
        let partition = V2RealtimeTopicKey(kind: .userSync, id: user.rawValue).partitionID()
        // Membership sources are repaired by the owned interest worker. Ready
        // needs the authentication source's actual seed, not every DB reseeded.
        for alias in aliases where try catalog.entry(logicalAlias: alias).isAuthenticationSource {
            try await refresh(catalog.source(logicalAlias: alias, partitionID: partition))
        }
        guard let binding = receiver.authenticationBinding(userID: user) else {
            let error = GatewayJournalAuthorityError.userBindingRejected
            recordFailure(error, phase: "userBaseline")
            throw error
        }
        return .init(source: binding.source, fence: binding.fence, userID: user, controlVersion: binding.controlVersion)
    }
    func close() async {
        let task = worker.withLock { value -> Task<Void, Never>? in defer { value = nil }; return value }
        let timer = clock.withLock { value -> Task<Void, Never>? in defer { value = nil }; return value }
        timer?.cancel(); wakes.continuation.finish(); task?.cancel(); await cold.close(); await timer?.value; await task?.value
        await publisher.close(); await fanout.close(); await authority.shutdown()
    }
}

/// Four real SQL flights; queued sources consume no tasks. FIFO admission means
/// a slow source occupies one slot while other sources continue independently.
private actor GatewayJournalColdFlights {
    struct Key: Hashable, Sendable {
        let source: V2RealtimeJournalSource
        let routingToken: UUID
        let routingEpoch: Int64
        let session: UUID
        let revision: Int64
    }
    private struct Pending {
        let operation: @Sendable () async throws -> Void
        var waiters: [CheckedContinuation<Void, any Error>]
    }
    private var pending: [Key: Pending] = [:]
    private var queue: [Key] = []
    private var actual: [Key: Task<Void, Never>] = [:]
    private var closed = false
    private var waiting = 0

    func run(key: Key, operation: @escaping @Sendable () async throws -> Void) async throws {
        guard !closed else { throw CancellationError() }
        guard (waiting < 1_024), pending[key] != nil || (pending.count < 256) else {
            throw V2RealtimePublicationBackpressure.receiverQueue
        }
        try await withCheckedThrowingContinuation { continuation in
            waiting += 1
            if var value = pending[key] {
                value.waiters.append(continuation); pending[key] = value
            } else {
                pending[key] = Pending(operation: operation, waiters: [continuation]); queue.append(key)
            }
            admit()
        }
    }
    private func admit() {
        while !closed, (actual.count < 4), !queue.isEmpty {
            let key = queue.removeFirst()
            guard let operation = pending[key]?.operation else { continue }
            actual[key] = Task {
                let result: Result<Void, any Error>
                do { try Task.checkCancellation(); try await operation(); result = .success(()) }
                catch { result = .failure(error) }
                finished(key, result: result)
            }
        }
    }
    private func finished(_ key: Key, result: Result<Void, any Error>) {
        actual.removeValue(forKey: key)
        if let value = pending.removeValue(forKey: key) {
            waiting -= value.waiters.count
            for waiter in value.waiters { waiter.resume(with: result) }
        }
        admit()
    }
    func close() async {
        closed = true
        let queued = queue; queue.removeAll()
        for key in queued {
            if let value = pending.removeValue(forKey: key) {
                waiting -= value.waiters.count
                for waiter in value.waiters { waiter.resume(throwing: CancellationError()) }
            }
        }
        let running = Array(actual.values)
        for task in running { task.cancel() }
        for task in running { await task.value }
    }
}
