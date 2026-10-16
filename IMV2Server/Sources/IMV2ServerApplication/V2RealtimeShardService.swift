import Foundation
import HashTreeCollections
import IMV2ActorContracts
import IMV2ServerContracts

/// One ordinary actor per installed partition; no subscription SQL or business
/// room activation. The outer service only selects the already installed actor.
public actor V2RealtimeShardService: V2RealtimeShardServing {
    public typealias Sender = @Sendable (V2GatewayRealtimeDescriptor, V2RealtimeBatch) async throws -> V2RealtimeAcceptance
    private var partitions: [Int: V2RealtimeSubscriptionPartition] = [:]
    private var highestEpoch: [Int: Int64] = [:]
    private var retiredTokens: [Int: V2RealtimeShardToken] = [:]
    private let qualification: V2ActorServiceQualification
    private let metrics: V2ActorRealtimeMetrics?
    private let budget: V2RealtimeIndexBudget
    private let delivery: V2RealtimeShardDelivery
    private var closed = false
    private var controlCalls = 0
    private var shutdownTask: Task<Void, Never>?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var durablePublications = 0
    private var transientPublications = 0
    public init(maximumInterests: Int = 200_000, maximumBytes: Int = 64 * 1_024 * 1_024,
                qualification: V2ActorServiceQualification = .standalone(), metrics: V2ActorRealtimeMetrics? = nil, send: @escaping Sender) {
        precondition(maximumInterests > 0 && maximumBytes > 0)
        self.qualification = qualification; self.metrics = metrics
        budget = .init(maximumItems: maximumInterests, maximumBytes: maximumBytes)
        delivery = .init(send: send, metrics: metrics)
    }
    public func install(token: V2RealtimeShardToken, deadline: ContinuousClock.Instant, qualificationGeneration: UUID? = nil) async {
        guard let proof = qualification.snapshot(), qualificationGeneration == nil || qualificationGeneration == proof.generation else { return }
        guard !closed, (0..<256).contains(token.partitionID), token.epoch > 0, deadline > .now else { return }
        guard token.epoch >= highestEpoch[token.partitionID, default: 0], retiredTokens[token.partitionID] != token else { return }
        if let old = partitions[token.partitionID] {
            if await old.extend(token: token, deadline: deadline, qualificationGeneration: proof.generation) {
                guard qualification.snapshot()?.generation == proof.generation else { return }
                return
            }
            guard partitions[token.partitionID] === old, token.epoch > old.token.epoch else { return }
            partitions.removeValue(forKey: token.partitionID)
            await old.retire()
        }
        guard qualification.snapshot()?.generation == proof.generation, !closed, partitions[token.partitionID] == nil,
              highestEpoch[token.partitionID] == nil || token.epoch > highestEpoch[token.partitionID, default: 0] else { return }
        highestEpoch[token.partitionID] = token.epoch
        metrics?.partitionInstalled(token)
        partitions[token.partitionID] = .init(token: token, deadline: deadline, qualification: qualification, qualificationGeneration: proof.generation, budget: budget, delivery: delivery, metrics: metrics)
    }
    public func retire(token: V2RealtimeShardToken) async {
        guard let old = partitions[token.partitionID], old.token == token else { return }
        retiredTokens[token.partitionID] = token
        partitions.removeValue(forKey: token.partitionID); await old.retire()
    }
    public func control(_ request: V2RealtimeShardControlRequest) async throws -> V2RealtimeShardControlReply {
        guard !closed, let partition = partitions[request.token.partitionID] else {
            return .init(appliedRevision: 0, remainingSessionMilliseconds: 0, status: unavailable(request.token))
        }
        guard controlCalls < 8 else { metrics?.shardCapacityRejected(.controlGlobal); return .init(appliedRevision: 0, remainingSessionMilliseconds: 0, status: .overloaded) }
        controlCalls += 1; defer { controlCalls -= 1; resumeDrain() }
        return try await partition.control(request)
    }
    public func publish(_ request: V2RealtimeShardPublishRequest) async throws -> V2RealtimeShardPublishReply {
        guard !closed, let partition = partitions[request.token.partitionID] else { return unavailable(request.token) == .notInstalled ? .notInstalled : .retiredEpoch }
        let persistent = request.topic.kind == .roomEvents || request.topic.kind == .userSync
        guard persistent ? durablePublications < 8 : transientPublications < 4 else { metrics?.shardCapacityRejected(persistent ? .durablePublications : .transientPublications); return .overloaded }
        if persistent { durablePublications += 1 } else { transientPublications += 1 }
        defer { if persistent { durablePublications -= 1 } else { transientPublications -= 1 }; resumeDrain() }
        do { return try await partition.publish(request) }
        catch is V2RealtimePublicationBackpressure {
            // The partition has settled every recipient before throwing. Carry
            // proven capacity rejection through the existing signed reply,
            // rather than losing its type in a generic remote error envelope.
            return .overloaded
        }
    }
    /// Reads the installed index only; no SQL, snapshot grants or new interests.
    public func journalRecipients(partitionID: Int) async -> [V2RealtimeJournalRecipient] {
        guard !closed, let partition = partitions[partitionID] else { return [] }
        let result = await partition.journalRecipients()
        guard !closed, partitions[partitionID] === partition else { return [] }
        return result
    }
    public func journalRecipientIsCurrent(_ recipient: V2RealtimeJournalRecipient) async -> Bool {
        guard !closed, let partition = partitions[recipient.token.partitionID], partition.token == recipient.token else { return false }
        let current = await partition.journalRecipientIsCurrent(recipient)
        return current && !closed && partitions[recipient.token.partitionID] === partition
    }
    private func unavailable(_ token: V2RealtimeShardToken) -> V2RealtimeShardControlReply.Status {
        if retiredTokens[token.partitionID] == token || token.epoch <= highestEpoch[token.partitionID, default: 0] { return .retiredEpoch }
        return .notInstalled
    }
    /// Requests an authoritative lease epoch rollover; never discards old
    /// session watermarks locally. The controller must retire/withdraw this
    /// installation before releasing its exact lease and claiming a new epoch.
    public func partitionsNeedingRollover() async -> Set<Int> {
        guard !closed else { return [] }
        let selected = partitions
        var result: Set<Int> = []
        for (id, partition) in selected {
            if await partition.needsRollover(), !closed, partitions[id] === partition { result.insert(id) }
        }
        return result
    }
    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        closed = true
        let task = Task { await self.drain() }; shutdownTask = task; await task.value
    }
    private func drain() async {
        let old = Array(partitions.values); partitions.removeAll()
        for partition in old { await partition.retire() }
        await delivery.shutdown()
        if controlCalls + durablePublications + transientPublications > 0 {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
    }
    private func resumeDrain() {
        if controlCalls + durablePublications + transientPublications == 0 {
            let old = drainWaiters; drainWaiters.removeAll(); for waiter in old { waiter.resume() }
        }
    }
}

private actor V2RealtimeSubscriptionPartition {
    nonisolated let token: V2RealtimeShardToken
    private nonisolated let qualification: V2ActorServiceQualification
    private nonisolated let qualificationGeneration: UUID
    private var deadline: ContinuousClock.Instant
    private let budget: V2RealtimeIndexBudget
    private let delivery: V2RealtimeShardDelivery
    private let metrics: V2ActorRealtimeMetrics?
    private struct Staging {
        let id: UUID; let total: Int; let digest: Data; let base: Int64; let next: Int64
        var chunks: [Int: [V2RealtimeShardInterest]] = [:]
        var fingerprints: [Int: Data] = [:]
        var items = 0; var bytes = 0
    }
    private final class Session {
        var wire: V2RealtimeShardSession
        var revision: Int64 = 0
        var fingerprint = Data()
        var deadline: ContinuousClock.Instant
        var interests: TreeDictionary<V2RealtimeTopicKey, Int64> = [:]
        var staging: Staging?
        var closed = false
        var descriptorBytes = 0
        var interestBytes = 0
        init(wire: V2RealtimeShardSession, deadline: ContinuousClock.Instant, descriptorBytes: Int) {
            self.wire = wire; self.deadline = deadline; self.descriptorBytes = descriptorBytes
        }
    }
    // Incarnation and generation watermarks survive close/expiry until this
    // partition epoch retires. Payload memory is reclaimed on expiry; at most
    // 256 lightweight identity tombstones remain, then new identities fail closed.
    // Reusing their slots requires a newer partition epoch or trusted revocation.
    private var sessions: [V2GatewayRealtimeIdentity: Session] = [:]
    private var index: [V2RealtimeTopicKey: Set<V2GatewayRealtimeIdentity>] = [:]
    private var retainedBindings = 0
    private var retired = false
    private var rolloverRequested = false
    init(token: V2RealtimeShardToken, deadline: ContinuousClock.Instant,
         qualification: V2ActorServiceQualification, qualificationGeneration: UUID, budget: V2RealtimeIndexBudget, delivery: V2RealtimeShardDelivery, metrics: V2ActorRealtimeMetrics?) {
        self.qualification = qualification; self.qualificationGeneration = qualificationGeneration
        self.token = token; self.deadline = deadline; self.budget = budget; self.delivery = delivery; self.metrics = metrics
    }
    func needsRollover() -> Bool { rolloverRequested && valid(token) }
    func extend(token: V2RealtimeShardToken, deadline: ContinuousClock.Instant, qualificationGeneration: UUID) -> Bool {
        guard self.qualificationGeneration == qualificationGeneration, valid(token) else { return false }
        self.deadline = max(self.deadline, deadline); return true
    }
    private func valid(_ requested: V2RealtimeShardToken) -> Bool { !retired && requested == token && deadline > .now && qualification.snapshot()?.generation == qualificationGeneration }
    private func reply(_ session: Session?, _ status: V2RealtimeShardControlReply.Status) -> V2RealtimeShardControlReply {
        let remaining = session.map { min(deadline, $0.deadline) } ?? ContinuousClock.now
        let duration = ContinuousClock.now.duration(to: remaining).components
        let milliseconds = max(0, duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
        return .init(appliedRevision: session?.revision ?? 0, remainingSessionMilliseconds: milliseconds, status: status)
    }
    private func release(_ session: Session) {
        budget.release(items: session.interests.count + (session.staging?.items ?? 0),
            bytes: session.interestBytes + (session.staging?.bytes ?? 0) + session.descriptorBytes)
    }
    /// Closed sessions retain only identity/generation/revision/fingerprint.
    /// Actor references and staged/installed topics share the process byte cap
    /// while active, and are released before leaving a tombstone.
    private func tombstone(_ session: Session) -> Session {
        let compact = session
        compact.wire = .init(gateway: .init(identity: session.wire.gateway.identity, endpointReference: Data(), address: "", port: 0),
            sessionID: session.wire.sessionID, sessionGeneration: session.wire.sessionGeneration)
        compact.interests = [:]; compact.staging = nil; compact.closed = true; compact.descriptorBytes = 0; compact.interestBytes = 0
        return compact
    }
    private func rejection(_ requested: V2RealtimeShardToken) -> V2RealtimeShardControlReply.Status? {
        if requested.host != token.host { return .retiredIncarnation }
        if !valid(requested) { return .retiredEpoch }
        return nil
    }
    private func reclaimExpiredSessions() {
        let now = ContinuousClock.now
        for (identity, var session) in sessions where !session.closed && session.deadline <= now {
            release(session); removeFromIndex(session)
            session = tombstone(session)
            sessions[identity] = session
        }
    }
    private func validInitialSnapshot(_ mutation: V2RealtimeShardMutation) -> Bool {
        guard case .snapshotChunk(_, let index, let total, let digest, let interests) = mutation else { return false }
        return (1...782).contains(total) && (0..<total).contains(index) && interests.count <= 128 && digest.count == 32
            && (total != 1 || (try? V2RealtimeShardFingerprint.snapshot(interests)) == digest)
            && interests.allSatisfy { $0.key.partitionID() == token.partitionID && !$0.key.id.isEmpty
                && $0.key.id.utf8.count <= 128 && $0.interestGeneration > 0 }
            && Set(interests.map(\.key)).count == interests.count
    }
    private func reportRetainedLoad() {
        // O(1) observation. Binding deltas follow the existing index mutation;
        // metrics never scan sessions/interests per control/publication call.
        // Retained payload is distinct from deadline-qualified Ready authority.
        metrics?.partitionRetainedLoad(token, bindings: retainedBindings, topics: index.count)
    }
    func control(_ request: V2RealtimeShardControlRequest) throws -> V2RealtimeShardControlReply {
        defer { reportRetainedLoad() }
        if let status = rejection(request.token) { return reply(nil, status) }
        reclaimExpiredSessions()
        let renewal: Bool
        if case .renew = request.mutation { renewal = true } else { renewal = false }
        guard request.session.sessionGeneration > 0,
              renewal ? (request.baseRevision == 0 && request.nextRevision == 0)
                      : (request.baseRevision >= 0 && request.baseRevision < Int64.max && request.nextRevision == request.baseRevision + 1),
              request.payloadFingerprint == (try V2RealtimeShardFingerprint.control(token: request.token,
                  session: request.session, baseRevision: request.baseRevision,
                  nextRevision: request.nextRevision, mutation: request.mutation)) else { throw V2RealtimeDirectoryError.invalidInput }
        try request.session.gateway.validate()
        let identity = request.session.gateway.identity
        if renewal {
            // Authenticated heartbeat is independent of subscription revisions.
            // It cannot create/revive a session or discard an in-progress snapshot.
            guard let current = sessions[identity], !current.closed, current.deadline > .now,
                  current.wire == request.session else { return reply(sessions[identity], .requiresSnapshot) }
            current.deadline = min(deadline, .now + .seconds(30))
            sessions[identity] = current
            return reply(current, .applied)
        }
        var session = sessions[identity]
        if let old = session, old.closed
            ? (old.wire.sessionID != request.session.sessionID || old.wire.sessionGeneration != request.session.sessionGeneration)
            : old.wire != request.session {
            guard request.session.sessionGeneration > old.wire.sessionGeneration else { return reply(old, .requiresSnapshot) }
            guard validInitialSnapshot(request.mutation), request.baseRevision == 0 else { return reply(old, .requiresSnapshot) }
            release(old); removeFromIndex(old); sessions[identity] = tombstone(old); session = nil
        }
        if session == nil {
            guard request.baseRevision == 0, validInitialSnapshot(request.mutation) else { return reply(nil, .requiresSnapshot) }
            if sessions[identity] == nil && sessions.count >= 256 {
                rolloverRequested = true
                return reply(nil, .overloaded)
            }
            guard sessions.values.filter({ !$0.closed && $0.deadline > .now }).count < 64 || sessions[identity] != nil else { return reply(nil, .overloaded) }
            let descriptor = request.session.gateway
            let bytes = descriptor.endpointReference.count + descriptor.address.utf8.count
                + identity.nodeID.utf8.count + identity.serviceID.utf8.count + 256
            guard budget.reserve(items: 0, bytes: bytes) else { return reply(sessions[identity], .overloaded) }
            session = .init(wire: request.session, deadline: min(deadline, .now + .seconds(30)), descriptorBytes: bytes)
        }
        var current = session!
        if current.deadline <= .now && !current.closed {
            release(current); removeFromIndex(current); current = tombstone(current)
        }
        sessions[identity] = current
        if request.nextRevision == current.revision {
            return reply(current, current.fingerprint == request.payloadFingerprint ? .applied : .requiresSnapshot)
        }
        guard !current.closed else { sessions[identity] = current; return reply(current, .requiresSnapshot) }
        guard request.baseRevision == current.revision else { return reply(current, .requiresSnapshot) }
        switch request.mutation {
        case .delta(let changes):
            guard !changes.isEmpty, changes.count <= 128, current.staging == nil else { return reply(current, .requiresSnapshot) }
            var keys: Set<V2RealtimeTopicKey> = []
            var updates: [(V2RealtimeTopicKey, Int64?)] = []
            var itemDelta = 0, byteDelta = 0
            for change in changes {
                let key: V2RealtimeTopicKey; let generation: Int64
                switch change {
                case .upsert(let interest): key = interest.key; generation = interest.interestGeneration
                case .remove(let removed, let value): key = removed; generation = value
                }
                guard key.partitionID() == token.partitionID, !key.id.isEmpty, key.id.utf8.count <= 128,
                      generation > 0, keys.insert(key).inserted else { return reply(current, .requiresSnapshot) }
                let previous = current.interests[key]
                switch change {
                case .upsert:
                    updates.append((key, generation))
                    if previous == nil { itemDelta += 1; byteDelta += key.id.utf8.count + 192 }
                case .remove:
                    if previous == generation {
                        updates.append((key, nil)); itemDelta -= 1; byteDelta -= key.id.utf8.count + 192
                    }
                }
            }
            // Validate and reserve the complete delta before mutating any state.
            guard budget.reserve(items: max(0, itemDelta), bytes: max(0, byteDelta)) else { return reply(current, .overloaded) }
            budget.release(items: max(0, -itemDelta), bytes: max(0, -byteDelta))
            for (key, generation) in updates {
                current.interests[key] = generation
                if generation != nil { index[key, default: []].insert(identity) }
                else {
                    index[key]?.remove(identity)
                    if index[key]?.isEmpty == true { index.removeValue(forKey: key) }
                }
            }
            current.interestBytes += byteDelta; retainedBindings += itemDelta
        case .snapshotChunk(let id, let index, let total, let digest, let interests):
            guard (1...782).contains(total), (0..<total).contains(index), interests.count <= 128, digest.count == 32,
                  interests.allSatisfy({ $0.key.partitionID() == token.partitionID && !$0.key.id.isEmpty && $0.key.id.utf8.count <= 128 && $0.interestGeneration > 0 }),
                  Set(interests.map(\.key)).count == interests.count else { return reply(current, .requiresSnapshot) }
            var stage = current.staging ?? Staging(id: id, total: total, digest: digest, base: request.baseRevision, next: request.nextRevision)
            guard stage.id == id, stage.total == total, stage.digest == digest,
                  stage.base == request.baseRevision, stage.next == request.nextRevision else { return reply(current, .requiresSnapshot) }
            if let fingerprint = stage.fingerprints[index] {
                return reply(current, fingerprint == request.payloadFingerprint ? .applied : .requiresSnapshot)
            }
            let bytes = interests.reduce(0) { $0 + V2RealtimeIndexBudget.bytes($1) } + 192 // chunk/fingerprint metadata
            guard budget.reserve(items: interests.count, bytes: bytes) else { return reply(current, .overloaded) }
            stage.chunks[index] = interests; stage.fingerprints[index] = request.payloadFingerprint
            stage.items += interests.count; stage.bytes += bytes
            current.staging = stage
            if stage.chunks.count < total { sessions[identity] = current; return reply(current, .applied) }
            let all = (0..<total).flatMap { stage.chunks[$0] ?? [] }
            guard Set(all.map(\.key)).count == all.count, try V2RealtimeShardFingerprint.snapshot(all) == digest else {
                budget.release(items: stage.items, bytes: stage.bytes); current.staging = nil
                sessions[identity] = current; return reply(current, .requiresSnapshot)
            }
            let oldBytes = current.interestBytes
            let installedBytes = all.reduce(0) { $0 + V2RealtimeIndexBudget.bytes($1) }
            budget.release(items: current.interests.count, bytes: oldBytes + stage.bytes - installedBytes)
            removeFromIndex(current)
            current.interests = TreeDictionary(uniqueKeysWithValues: all.map { ($0.key, $0.interestGeneration) })
            current.interestBytes = installedBytes
            retainedBindings += current.interests.count
            for key in current.interests.keys { self.index[key, default: []].insert(identity) }
            current.staging = nil
        case .renew: throw V2RealtimeDirectoryError.invalidInput // handled before revision mutation
        case .close:
            release(current); removeFromIndex(current); current = tombstone(current)
        }
        current.revision = request.nextRevision; current.fingerprint = request.payloadFingerprint
        current.deadline = min(deadline, .now + .seconds(30)); sessions[identity] = current
        return reply(current, .applied)
    }
    private func removeFromIndex(_ session: Session) {
        retainedBindings -= session.interests.count
        for key in session.interests.keys {
            index[key]?.remove(session.wire.gateway.identity)
            if index[key]?.isEmpty == true { index.removeValue(forKey: key) }
        }
    }
    func publish(_ request: V2RealtimeShardPublishRequest) async throws -> V2RealtimeShardPublishReply {
        if let status = rejection(request.token) { return status == .retiredIncarnation ? .retiredIncarnation : .retiredEpoch }
        guard V2RealtimeTopicKey(request.topic).partitionID() == token.partitionID else { throw V2RealtimeDirectoryError.invalidInput }
        reclaimExpiredSessions()
        let validation = V2RealtimeDelivery(topic: request.topic, partitionID: token.partitionID, partitionEpoch: token.epoch,
            sessionID: UUID(), interestGeneration: 1, gatewayIncarnation: token.host.incarnationID, payload: request.payload)
        try V2RealtimeBatch(recipient: token.host, deliveries: [validation]).validate()
        metrics?.partitionPublicationStarted(token.partitionID)
        defer { reportRetainedLoad(); metrics?.partitionPublicationSettled(token.partitionID) }
        let key = V2RealtimeTopicKey(request.topic)
        var recipients: [(V2RealtimeShardSession, Int64)] = []
        for identity in index[key] ?? [] {
            guard var session = sessions[identity] else { continue }
            if !session.closed && session.deadline <= .now {
                release(session); removeFromIndex(session); session = tombstone(session); sessions[identity] = session
            }
            if !session.closed, let generation = session.interests[key] { recipients.append((session.wire, generation)) }
        }
        metrics?.publicationRecipients(kind: request.topic.kind, count: recipients.count)
        guard !recipients.isEmpty else { return .noSubscribers }
        let result = try await delivery.publish(token: token, topic: request.topic, payload: request.payload, recipients: recipients, qualification: qualification, qualificationGeneration: qualificationGeneration)
        guard valid(request.token) else { return .retiredEpoch }
        return result
    }
    func journalRecipients() -> [V2RealtimeJournalRecipient] {
        guard valid(token) else { return [] }
        reclaimExpiredSessions()
        var result: [V2RealtimeJournalRecipient] = []
        for session in sessions.values where !session.closed && session.deadline > .now && session.staging == nil && session.revision > 0 {
            result.append(.init(token: token, session: session.wire, interestGeneration: session.revision,
                                interests: session.interests, deadline: min(deadline, session.deadline)))
        }
        return result
    }
    func journalRecipientIsCurrent(_ recipient: V2RealtimeJournalRecipient) -> Bool {
        guard valid(recipient.token), let session = sessions[recipient.session.gateway.identity],
              !session.closed, session.deadline > .now, session.staging == nil, session.wire == recipient.session else { return false }
        return session.revision == recipient.interestGeneration && session.interests == recipient.interests
    }
    func retire() { guard !retired else { return }; retired = true; for session in sessions.values { release(session) }; sessions.removeAll(); index.removeAll(); retainedBindings = 0; metrics?.partitionRetired(token) }
}

/// Shared across all local partitions. Topic×Gateway lanes serialize actual
/// delivery and drain before slot release. Control/publication use other gates.
private actor V2RealtimeShardDelivery {
    typealias Sender = V2RealtimeShardService.Sender
    private struct Key: Hashable { let topic: V2RealtimeTopicKey; let peer: V2GatewayRealtimeIdentity }
    private struct Job { let qualification: V2ActorServiceQualification; let qualificationGeneration: UUID; let descriptor: V2GatewayRealtimeDescriptor; var batch: V2RealtimeBatch; var continuations: [CheckedContinuation<V2RealtimeAcceptance, any Error>] }
    private var lanes: [Key: [Job]] = [:]
    private var peers: [V2GatewayRealtimeIdentity: Int] = [:]
    private var workers: [Key: Task<Void, Never>] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    private let send: Sender
    private let metrics: V2ActorRealtimeMetrics?
    // One source of truth for the existing business worker/feeder bound.
    private static let maximumConcurrentDeliveries = 16
    private let observationOwner: UUID?
    init(send: @escaping Sender, metrics: V2ActorRealtimeMetrics?) {
        self.send = send; self.metrics = metrics
        observationOwner = metrics?.registerDeliveryObservationOwner(capacity: Self.maximumConcurrentDeliveries)
    }
    func publish(token: V2RealtimeShardToken, topic: V2RealtimeTopic, payload: V2RealtimePayload,
                 recipients: [(V2RealtimeShardSession, Int64)], qualification: V2ActorServiceQualification, qualificationGeneration: UUID) async throws -> V2RealtimeShardPublishReply {
        var degraded = false
        var failure: (any Error)?
        await withTaskGroup(of: Result<V2RealtimeAcceptance, any Error>.self) { group in
            var iterator = recipients.makeIterator()
            func add(_ recipient: (V2RealtimeShardSession, Int64)) {
                group.addTask {
                    do { return .success(try await self.enqueue(token: token, topic: topic, payload: payload, recipient: recipient, qualification: qualification, qualificationGeneration: qualificationGeneration)) }
                    catch { return .failure(error) }
                }
            }
            for _ in 0..<min(Self.maximumConcurrentDeliveries, recipients.count) { if let recipient = iterator.next() { add(recipient) } }
            while let result = await group.next() {
                switch result {
                case .success(let accepted): degraded = degraded || accepted == .acceptedAsWatermark
                case .failure(let error):
                    if failure == nil || (failure is V2RealtimePublicationBackpressure && !(error is V2RealtimePublicationBackpressure)) { failure = error }
                }
                if let next = iterator.next() { add(next) }
            }
        }
        if let failure { throw failure }
        return degraded ? .acceptedAsWatermark : .accepted
    }
    private func enqueue(token: V2RealtimeShardToken, topic: V2RealtimeTopic, payload: V2RealtimePayload,
                         recipient: (V2RealtimeShardSession, Int64), qualification: V2ActorServiceQualification, qualificationGeneration: UUID) async throws -> V2RealtimeAcceptance {
        guard qualification.snapshot()?.generation == qualificationGeneration else { throw V2RealtimeInterestCoordinator.Failure.stale }
        guard !closed else { throw V2RealtimeInterestCoordinator.Failure.closed }
        let (session, generation) = recipient
        let key = Key(topic: .init(topic), peer: session.gateway.identity)
        let ordered: V2RealtimePayload
        if case .roomEvents(let events) = payload { ordered = .roomEvents(events.sorted { $0.roomSequence < $1.roomSequence }) }
        else { ordered = payload }
        let delivery = V2RealtimeDelivery(topic: topic, partitionID: token.partitionID, partitionEpoch: token.epoch,
            sessionID: session.sessionID, interestGeneration: generation, gatewayIncarnation: session.gateway.identity.incarnationID, payload: ordered)
        let batch = V2RealtimeBatch(recipient: key.peer, deliveries: [delivery])
        try batch.validate()
        if lanes[key] == nil {
            guard workers.count < Self.maximumConcurrentDeliveries else { metrics?.shardCapacityRejected(.deliveryGlobal); throw V2RealtimePublicationBackpressure.globalRPCs }
            if topic.kind == .roomTyping || topic.kind == .userPresence {
                guard workers.keys.filter({ $0.topic.kind == .roomTyping || $0.topic.kind == .userPresence }).count < 4 else { metrics?.shardCapacityRejected(.deliveryActivity); throw V2RealtimePublicationBackpressure.globalRPCs }
            }
            guard peers[key.peer, default: 0] < 2 else { metrics?.shardCapacityRejected(.deliveryPeer); throw V2RealtimePublicationBackpressure.peerRPCs }
            lanes[key] = []; peers[key.peer, default: 0] += 1
        }
        guard lanes[key, default: []].reduce(0, { $0 + $1.continuations.count }) < 8 else { metrics?.shardCapacityRejected(.deliveryLane); throw V2RealtimePublicationBackpressure.receiverQueue }
        return try await withCheckedThrowingContinuation { continuation in
            if case .roomWake(let room, let high) = ordered,
               var jobs = lanes[key], let last = jobs.last,
               last.qualificationGeneration == qualificationGeneration,
               let prior = last.batch.deliveries.first, prior.sessionID == delivery.sessionID,
               prior.interestGeneration == delivery.interestGeneration, prior.topic == delivery.topic,
               case .roomWake(_, let previous) = prior.payload {
                let merged = V2RealtimeDelivery(topic: topic, partitionID: token.partitionID, partitionEpoch: token.epoch,
                    sessionID: session.sessionID, interestGeneration: generation, gatewayIncarnation: session.gateway.identity.incarnationID,
                    payload: .roomWake(roomID: room, highWatermark: max(high, previous)))
                jobs[jobs.count - 1].batch = .init(batchID: last.batch.batchID, recipient: key.peer, deliveries: [merged])
                jobs[jobs.count - 1].continuations.append(continuation); lanes[key] = jobs
            } else {
                lanes[key, default: []].append(.init(qualification: qualification, qualificationGeneration: qualificationGeneration, descriptor: session.gateway, batch: batch, continuations: [continuation]))
            }
            if workers[key] == nil { workers[key] = Task { await self.run(key) } }
        }
    }
    private func run(_ key: Key) async {
        while var jobs = lanes[key], !jobs.isEmpty {
            let job = jobs.removeFirst(); lanes[key] = jobs
            let result: Result<V2RealtimeAcceptance, any Error>
            do {
                guard job.qualification.snapshot()?.generation == job.qualificationGeneration else { throw V2RealtimeInterestCoordinator.Failure.stale }
                let observation = observationOwner.flatMap { metrics?.deliveryTargetStarted(owner: $0, kind: key.topic.kind) }
                defer {
                    if let owner = observationOwner, let observation { metrics?.deliveryTargetSettled(owner: owner, id: observation) }
                }
                let accepted = try await send(job.descriptor, job.batch)
                if accepted.wasAccepted { result = .success(accepted) }
                else if accepted == .overloaded { metrics?.shardCapacityRejected(.receiverQueue); result = .failure(V2RealtimePublicationBackpressure.receiverQueue) }
                else { result = .failure(V2RealtimeInterestCoordinator.Failure.stale) }
            } catch { result = .failure(error) }
            for continuation in job.continuations { continuation.resume(with: result) }
        }
        lanes.removeValue(forKey: key); workers.removeValue(forKey: key)
        peers[key.peer, default: 0] -= 1; if peers[key.peer] == 0 { peers.removeValue(forKey: key.peer) }
        if workers.isEmpty { let old = waiters; waiters.removeAll(); for waiter in old { waiter.resume() } }
    }
    func shutdown() async {
        closed = true
        if !workers.isEmpty { await withCheckedContinuation { waiters.append($0) } }
        if let observationOwner { metrics?.retireDeliveryObservationOwner(observationOwner) }
    }
}
