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
    private let repairWorker = Mutex<Task<Void, Never>?>(nil)
    private struct Repairs: Sendable {
        var pending: [V2RealtimeJournalSource: GatewayJournalSourceCatalog.SourceProof] = [:]
        var running: Set<V2RealtimeJournalSource> = []
        var order = V2RealtimeKeyQueue<V2RealtimeJournalSource>()
    }
    private let repairs = Mutex(Repairs())
    private struct CachedProofs: Sendable {
        let observedAt: ContinuousClock.Instant
        var requested: Set<Int>
        var values: [Int: GatewayJournalSourceCatalog.SourceProof]
    }
    private let proofCache = Mutex<[String: CachedProofs]>([:])
    private let repairWakes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let wakes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let recovery: GatewayJournalRecoveryCoordinator
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
                 recovery: GatewayJournalRecoveryCoordinator,
                 identity: V2GatewayRealtimeIdentity) {
        self.catalog = catalog; self.receiver = receiver; self.projection = projection; self.authority = authority
        self.publisher = publisher; self.fanout = fanout; self.aliases = aliases
        self.coordinator = coordinator; self.registry = registry; self.identity = identity
        self.recovery = recovery
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
        let recovery = GatewayJournalAuthorityAssembly.recovery(catalog: catalog, coordinator: coordinator,
            registry: registry, receiver: receiver)
        let authority = GatewayJournalAuthorityAssembly.build(catalog: catalog, coordinator: coordinator,
            registry: registry, receiver: receiver, recovery: recovery)
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
        catch { await recovery.close(); await publisher.close(); await fanout.close(); await authority.shutdown(); throw error }
        await registry.configureJournalUserControlReceiver(receiver)
        let runtime = GatewayJournalRuntime(catalog: catalog, receiver: receiver, projection: projection,
            authority: authority, publisher: publisher, fanout: fanout,
            aliases: aliases, coordinator: coordinator, registry: registry, recovery: recovery, identity: identity)
        coordinator.configureJournalCoverageObserver { [weak runtime] change in
            guard let runtime else { return }
            // Coverage withdrawal already makes the captured current() gate deny.
            // Retain bounded local floors for a same-session incremental rebuild;
            // they cannot authorize a socket while coverage is withdrawn.
            _ = change
            runtime.wakes.continuation.yield(())
        }
        coordinator.configureTrustedJournalRenewal { [weak runtime] coverage in
            guard let runtime else { return false }
            return runtime.controlProgressIsCurrent(coverage)
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
        let repairTask = Task { [weak self, stream = repairWakes.stream] in
            for await _ in stream {
                guard !Task.isCancelled, let self else { return }
                await self.drainRepairs()
            }
        }
        repairWorker.withLock { $0 = repairTask }
        let timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.wakes.continuation.yield(())
            }
        }
        clock.withLock { $0 = timer }; wakes.continuation.yield(())
    }
    private func refresh(_ source: V2RealtimeJournalSource, minimumCut: Int64 = 0,
        sourceProof: GatewayJournalSourceCatalog.SourceProof? = nil) async throws {
        try Task.checkCancellation()
        guard let coverage = coordinator.journalCoverage(partitionID: source.partitionID) else {
            let error = GatewayJournalAuthorityError.coverageChanged
            recordFailure(error, phase: "coldRefresh")
            throw error
        }
        do {
            guard coordinator.confirmsJournalCoverage(coverage) else { throw V2RealtimeJournalError.authorityLost }
            try await GatewayJournalAuthorityAssembly.refresh(catalog: catalog, coordinator: coordinator,
                registry: registry, receiver: receiver, source: source, gatewayIdentity: identity,
                recovery: recovery, minimumCut: minimumCut, sourceProof: sourceProof)
            guard coordinator.confirmsJournalCoverage(coverage) else { throw V2RealtimeJournalError.authorityLost }
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
        let span = GatewayJournalDiagnostics.begin()
        defer { GatewayJournalDiagnostics.end(span, stage: .reconcile) }
        // Include room-DB user partitions: membership triggers are physically
        // local and must not be mistaken for the authentication source.
        let partitions = coordinator.activeJournalCoverages().map { $0.token.partitionID }.sorted()
        guard !partitions.isEmpty else { return }
        for alias in aliases {
            if Task.isCancelled { return }
            var captured: [Int: V2RealtimeJournalProjectionFence] = [:]
            for partition in partitions {
                if let source = try? catalog.source(logicalAlias: alias, partitionID: partition),
                   let binding = receiver.recoveryBindingSnapshot(source: source) { captured[partition] = binding.fence }
            }
            do {
                let proofSpan = GatewayJournalDiagnostics.begin()
                let proofs: [Int: GatewayJournalSourceCatalog.SourceProof]
                do {
                    defer { GatewayJournalDiagnostics.end(proofSpan, stage: .batchProof) }
                    proofs = try await reconciliationProofs(alias: alias, partitions: partitions)
                }
                for partition in partitions {
                    try Task.checkCancellation()
                    do {
                        let sourceSpan = GatewayJournalDiagnostics.begin()
                        defer { GatewayJournalDiagnostics.end(sourceSpan, stage: .reconcileSource) }
                        let source = try catalog.source(logicalAlias: alias, partitionID: partition)
                        guard let proof = proofs[partition] else {
                            if let fence = captured[partition] { receiver.retire(source: source, fence: fence) }
                            throw GatewayJournalSourceCatalog.CatalogError.sourceNotReady
                        }
                        if !renewSource(source, proof: proof) {
                            let offered = repairs.withLock { value in
                                guard !value.running.contains(source) else { return false }
                                value.pending[source] = proof; value.order.insert(source); return true
                            }
                            if offered { repairWakes.continuation.yield(()) }
                        }
                    } catch { recordFailure(error, phase: "reconcile") }
                }
            } catch {
                if error as? GatewayJournalSourceCatalog.CatalogError == .identityChanged {
                    for (partition, fence) in captured {
                        if let source = try? catalog.source(logicalAlias: alias, partitionID: partition) { receiver.retire(source: source, fence: fence) }
                    }
                }
                recordFailure(error, phase: "reconcile")
            }
        }
    }
    /// Interest churn may wake the worker much faster than the source lease
    /// observation cadence. Reuse conservative live proofs within that cadence;
    /// every actual cold recovery still verifies the publisher in the database.
    private func reconciliationProofs(alias: String, partitions: [Int]) async throws
        -> [Int: GatewayJournalSourceCatalog.SourceProof] {
        let now = ContinuousClock.now
        let old = proofCache.withLock { $0[alias] }
        let fresh = old.map { $0.observedAt + .seconds(5) > now } ?? false
        let needed = fresh ? partitions.filter { partition in
            old?.requested.contains(partition) != true || old?.values[partition].map { $0.validUntil <= now } == true
        } : partitions
        if needed.isEmpty { return old?.values ?? [:] }
        let values = try await catalog.sourceProofs(logicalAlias: alias, partitionIDs: needed)
        var cached = fresh ? old! : CachedProofs(observedAt: now, requested: [], values: [:])
        for partition in needed { cached.requested.insert(partition); cached.values[partition] = values[partition] }
        proofCache.withLock { $0[alias] = cached }
        return cached.values
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
    private func renewSource(_ source: V2RealtimeJournalSource,
        proof: GatewayJournalSourceCatalog.SourceProof) -> Bool {
        let ready = { () -> Bool in
            let checkSpan = GatewayJournalDiagnostics.begin()
            defer { GatewayJournalDiagnostics.end(checkSpan, stage: .bindingCheck) }
            guard let coverage = coordinator.journalCoverage(partitionID: source.partitionID),
                  let binding = receiver.bindingSnapshot(source: source) else { return false }
            guard Self.matchesSourceLease(proof.lease, fence: binding.fence, host: coverage.token.host),
                  binding.fence.routingLeaseToken == coverage.token.leaseToken,
                  binding.fence.routingPartitionEpoch == coverage.token.epoch,
                  binding.fence.sessionID == coverage.sessionID, binding.fence.interestGeneration == coverage.revision,
                  coordinator.confirmsJournalCoverage(coverage), proof.validUntil > .now,
                  let cut = projection.controlCheckpoint(source: source, isCurrent: { _, f in binding.fence.sameGeneration(as: f) }),
                  proof.value.publishedThrough <= cut,
                  receiver.renew(source: source, serviceID: coverage.token.host.serviceID, fence: binding.fence,
                    deadline: min(coverage.deadline, proof.validUntil), current: { self.coordinator.confirmsJournalCoverage(coverage) }) else {
                return false
            }
            return true
        }()
        return ready
    }
    /// A live exact control baseline plus the acknowledged reliable delivery
    /// session makes a periodic all-topic head reread redundant. Lost progress
    /// returns false; initial/replacement sessions still seed their actual heads.
    private func controlProgressIsCurrent(_ coverage: V2RealtimeInterestCoordinator.JournalCoverage) -> Bool {
        let sources = aliases.compactMap { try? catalog.source(logicalAlias: $0, partitionID: coverage.token.partitionID) }
        guard sources.count == aliases.count else { return false }
        return Self.confirmsControlProgress(coverage, sources: sources, coordinator: coordinator, receiver: receiver)
    }
    static func confirmsControlProgress(_ coverage: V2RealtimeInterestCoordinator.JournalCoverage,
        sources: [V2RealtimeJournalSource], coordinator: V2RealtimeInterestCoordinator,
        receiver: V2GatewayJournalProjectionReceiver) -> Bool {
        guard !sources.isEmpty, coordinator.confirmsJournalCoverage(coverage) else { return false }
        return sources.allSatisfy { source in
            guard source.partitionID == coverage.token.partitionID,
                  let binding = receiver.bindingSnapshot(source: source),
                  binding.fence.publisherIncarnationID == coverage.token.host.incarnationID,
                  binding.fence.routingPartitionEpoch == coverage.token.epoch,
                  binding.fence.routingLeaseToken == coverage.token.leaseToken,
                  binding.fence.sessionID == coverage.sessionID,
                  binding.fence.interestGeneration == coverage.revision else { return false }
            return receiver.recoveryCheckpoint(source: source, fence: binding.fence, minimumCut: 0) != nil
        }
    }
    private func takeRepair() -> (V2RealtimeJournalSource, GatewayJournalSourceCatalog.SourceProof)? {
        repairs.withLock { value in
            guard let source = value.order.popFirst(), let proof = value.pending.removeValue(forKey: source) else { return nil }
            value.running.insert(source)
            return (source, proof)
        }
    }
    private func drainRepairs() async {
        await withTaskGroup(of: Void.self) { group in
            func submit(_ item: (V2RealtimeJournalSource, GatewayJournalSourceCatalog.SourceProof)) {
                group.addTask { [self] in
                    defer { repairs.withLock { _ = $0.running.remove(item.0) } }
                    do {
                        try await refresh(item.0, minimumCut: item.1.value.publishedThrough,
                            sourceProof: item.1.validUntil > .now ? item.1 : nil)
                    } catch { recordFailure(error, phase: "reconcile") }
                }
            }
            for _ in 0..<4 { if let item = takeRepair() { submit(item) } }
            while await group.next() != nil {
                if Task.isCancelled { group.cancelAll(); continue }
                if let item = takeRepair() { submit(item) }
            }
        }
    }
    private func ensureUserBaseline(_ user: UserID) async throws -> V2GatewayJournalUserBaselineProof {
        try Task.checkCancellation()
        // Account floors alone do not prove a newly registered device lifecycle.
        // The shared owner checks the current local revision; a warm exact hit
        // returns without SQL, while a new lifecycle seeds only its own state.
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
        let repairTask = repairWorker.withLock { value -> Task<Void, Never>? in defer { value = nil }; return value }
        timer?.cancel(); wakes.continuation.finish(); task?.cancel()
        repairWakes.continuation.finish(); repairTask?.cancel()
        await recovery.close(); await timer?.value; await task?.value; await repairTask?.value
        repairs.withLock { $0.pending.removeAll(); $0.running.removeAll(); $0.order.removeAll() }; proofCache.withLock { $0.removeAll() }
        await publisher.close(); await fanout.close(); await authority.shutdown()
    }
}
