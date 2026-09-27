import Foundation
import IMV2Core

/// Owned, best-effort work after message delivery. `offer` never awaits a
/// profile authority or a transport. Queries and writes own bounded task slots.
/// The composition root must close this owner before its readers/transports.
public actor V2AuthorPresentationDispatcher {
    public struct Configuration: Sendable {
        public let maximumConnections, maximumPendingKeys, maximumPendingKeysPerConnection: Int
        public let maximumPendingBytes, maximumReads, maximumWrites, maximumOutputBytes: Int
        public let maximumHintsPerConnection, maximumHintBytes: Int
        public let mergeDelay, lifetime: Duration

        public init(maximumConnections: Int = 10_000, maximumPendingKeys: Int = 1_024,
                    maximumPendingKeysPerConnection: Int = 128, maximumPendingBytes: Int = 256 * 1_024,
                    maximumReads: Int = 4, maximumWrites: Int = 4, maximumOutputBytes: Int = 256 * 1_024,
                    maximumHintsPerConnection: Int = 128, maximumHintBytes: Int = 2 * 1_024 * 1_024,
                    mergeDelay: Duration = .milliseconds(2), lifetime: Duration = .milliseconds(500)) throws {
            guard (1...10_000).contains(maximumConnections), (1...1_024).contains(maximumPendingKeys),
                  (1...128).contains(maximumPendingKeysPerConnection), maximumPendingKeysPerConnection <= maximumPendingKeys,
                  (256...262_144).contains(maximumPendingBytes), (1...4).contains(maximumReads),
                  (1...4).contains(maximumWrites), (32_768...262_144).contains(maximumOutputBytes),
                  (1...128).contains(maximumHintsPerConnection), (1_024...2_097_152).contains(maximumHintBytes),
                  mergeDelay >= .zero, mergeDelay <= .milliseconds(5), lifetime > mergeDelay,
                  lifetime <= .milliseconds(500) else { throw V2ResourceProviderError.configurationInvalid }
            self.maximumConnections = maximumConnections; self.maximumPendingKeys = maximumPendingKeys
            self.maximumPendingKeysPerConnection = maximumPendingKeysPerConnection; self.maximumPendingBytes = maximumPendingBytes
            self.maximumReads = maximumReads; self.maximumWrites = maximumWrites; self.maximumOutputBytes = maximumOutputBytes
            self.maximumHintsPerConnection = maximumHintsPerConnection; self.maximumHintBytes = maximumHintBytes
            self.mergeDelay = mergeDelay; self.lifetime = lifetime
        }
    }

    public struct Statistics: Sendable {
        public let connections, pendingKeys, pendingBytes, reading, writing, outputBytes, hintBytes: Int
        public let rejectedOffers, expiredJobs, suppressedEntries, deliveredFrames: Int
    }
    public typealias Read = @Sendable (V2ProfilePresentationBatchRequest, V2AuthenticatedConnection) async throws -> V2ProfilePresentationBatchResponse
    /// Must recheck the current transport generation, session, deadline and
    /// complete frame byte budget at actual enqueue. `true` means enqueued,
    /// not acknowledged by the client. A dropped delta is recovered via HTTP.
    public typealias Send = @Sendable (Data, ContinuousClock.Instant) async -> Bool

    private struct Connection {
        let streamID: UUID; let identity: V2AuthenticatedConnection; let send: Send
        var viewID: UUID?; var roomID: RoomID?
        var viewDeadline: ContinuousClock.Instant?
        var sequence: UInt64 = 0
        var pending: [V2ProfileViewLookupKey] = []
        var costs: [V2ProfileViewLookupKey: Int] = [:]
        var readyAt: ContinuousClock.Instant = .now
        var deadline: ContinuousClock.Instant = .now
        var activeKeys: Set<V2ProfileViewLookupKey> = []
        var hints: [V2ProfileViewLookupKey: Hint] = [:]
    }
    private struct Hint {
        let fingerprint: Data; let deadline: ContinuousClock.Instant; let bytes: Int
        var touched: ContinuousClock.Instant
    }
    private struct Job: Sendable {
        let id: UUID; let connectionID: UUID; let streamID: UUID; let viewID: UUID
        let identity: V2AuthenticatedConnection; let keys: [V2ProfileViewLookupKey]
        let started: ContinuousClock.Instant; let deadline: ContinuousClock.Instant
    }
    private struct Flight {
        let job: Job; let task: Task<Void, Never>; let timer: Task<Void, Never>
    }
    private struct Output {
        let job: Job; let bytes: Data; let hints: [V2ProfileViewLookupKey: Hint]
        var byteCost: Int { bytes.count + (V2AuthorPresentationDelta.maximumFrameBytes - V2AuthorPresentationDelta.maximumEncodedBytes) + hints.values.reduce(0) { $0 + $1.bytes } }
    }
    private struct Fingerprint: Encodable {
        let view: V2ProfileView; let contextRevision: UInt64
        let groupMember: V2GroupMemberPresentation?
        let mediaID: MediaID?; let variantID: ResourceVariantID?; let version: Int64?; let checksum: V2ResourceChecksum?
    }

    private let configuration: Configuration
    private let read: Read
    private let now: @Sendable () -> Date
    private var connections: [UUID: Connection] = [:]
    private var ready: [UUID] = []
    private var activeStreams: Set<UUID> = []
    private var reads: [UUID: Flight] = [:], writes: [UUID: Flight] = [:]
    private var outputs: [Output] = []
    private var timer: Task<Void, Never>?
    private var timerID: UUID?
    private var timerDeadline: ContinuousClock.Instant?
    private var closed = false
    private var pendingKeys = 0, pendingBytes = 0, outputBytes = 0, hintBytes = 0
    private var rejectedOffers = 0, expiredJobs = 0, suppressedEntries = 0, deliveredFrames = 0

    public init(configuration: Configuration, read: @escaping Read,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.configuration = configuration; self.read = read; self.now = now
    }

    /// Called only after authentication and feature negotiation. A stream ID
    /// changes on every registration, including replacement of an old socket.
    public func register(connectionID: UUID, identity: V2AuthenticatedConnection, streamID: UUID = UUID(), send: @escaping Send) throws -> UUID {
        guard !closed, connections[connectionID] == nil, connections.count < configuration.maximumConnections,
              identity.userID.uuidValue != nil, identity.deviceID.uuidValue != nil else {
            throw V2ResourceProviderError.throttled(retryAfter: 1)
        }
        guard !connections.values.contains(where: { $0.streamID == streamID }) else {
            throw V2ResourceProviderError.throttled(retryAfter: 1)
        }
        connections[connectionID] = .init(streamID: streamID, identity: identity, send: send)
        return streamID
    }

    /// Invoke only after the normal foreground subscription authorization.
    /// Leaving, re-entering or replacing a page invalidates all older deltas,
    /// even if the account, room and socket have stayed the same.
    @discardableResult
    public func activateView(connectionID: UUID, roomID: RoomID, viewID: UUID) -> Bool {
        guard !closed, roomID.uuidValue != nil, let current = connections[connectionID] else { return false }
        if current.viewID == viewID {
            return current.roomID == roomID && current.viewDeadline.map { $0 > .now } == true
        }
        clearView(connectionID: connectionID)
        connections[connectionID]?.viewID = viewID; connections[connectionID]?.roomID = roomID
        connections[connectionID]?.viewDeadline = .now + .milliseconds(V2AuthorPresentationDelta.maximumViewAgeMilliseconds)
        return true
    }

    public func deactivateView(connectionID: UUID, viewID: UUID) {
        guard connections[connectionID]?.viewID == viewID else { return }
        clearView(connectionID: connectionID)
        drain()
    }

    private func clearView(connectionID: UUID) {
        guard var connection = connections[connectionID] else { return }
        pendingKeys -= connection.pending.count; pendingBytes -= connection.costs.values.reduce(0, +)
        hintBytes -= connection.hints.values.reduce(0) { $0 + $1.bytes }
        connection.pending.removeAll(); connection.costs.removeAll(); connection.hints.removeAll()
        connection.viewID = nil; connection.roomID = nil; connection.viewDeadline = nil; connection.activeKeys.removeAll()
        connections[connectionID] = connection; ready.removeAll { $0 == connectionID }
        let discarded = outputs.filter { $0.job.streamID == connection.streamID }
        outputs.removeAll { $0.job.streamID == connection.streamID }
        for output in discarded { outputBytes -= output.byteCost; release(output.job) }
        for flight in Array(reads.values) + Array(writes.values) where flight.job.streamID == connection.streamID {
            flight.task.cancel()
        }
    }

    /// Input authors must come from messages actually authorized for this
    /// recipient. This method performs no authorization; the reader does so
    /// again for every selected key, even when a compression hint exists.
    @discardableResult
    public func offer(connectionID: UUID, roomID: RoomID, authors: [UserID]) -> Bool {
        offerCurrent(connectionID: connectionID, roomID: roomID, authors: authors, deadline: nil)
    }

    /// A queued delivery observation belongs to the view selected when it was
    /// enqueued, never a later page on the same socket. Waiting also consumes
    /// the existing supplement lifetime instead of starting another full one.
    @discardableResult
    func offer(connectionID: UUID, roomID: RoomID, viewID: UUID, authors: [UserID],
               deadline: ContinuousClock.Instant) -> Bool {
        guard connections[connectionID]?.viewID == viewID, deadline > .now else {
            rejectedOffers += 1; return false
        }
        return offerCurrent(connectionID: connectionID, roomID: roomID, authors: authors, deadline: deadline)
    }

    private func offerCurrent(connectionID: UUID, roomID: RoomID, authors: [UserID],
                              deadline: ContinuousClock.Instant?) -> Bool {
        guard !closed, roomID.uuidValue != nil, (1...128).contains(authors.count),
              authors.allSatisfy({ $0.uuidValue != nil }), var connection = connections[connectionID],
              connection.roomID == roomID, connection.viewID != nil,
              let viewDeadline = connection.viewDeadline, viewDeadline > .now else {
            rejectedOffers += 1; return false
        }
        var additions: [(V2ProfileViewLookupKey, Int)] = []
        var seen: Set<UserID> = []
        for author in authors where seen.insert(author).inserted {
            let key = V2ProfileViewLookupKey(userID: author, context: .room(roomID))
            guard connection.costs[key] == nil, !connection.activeKeys.contains(key) else { continue }
            guard let cost = try? JSONEncoder().encode(key).count else { rejectedOffers += 1; return false }
            additions.append((key, cost))
        }
        guard !additions.isEmpty else { return true }
        let cost = additions.reduce(0) { $0 + $1.1 }
        guard connection.pending.count + additions.count <= configuration.maximumPendingKeysPerConnection,
              pendingKeys + additions.count <= configuration.maximumPendingKeys,
              pendingBytes <= configuration.maximumPendingBytes - cost else { rejectedOffers += 1; return false }
        for (key, hint) in connection.hints where hint.deadline <= .now {
            connection.hints.removeValue(forKey: key); hintBytes -= hint.bytes
        }
        if !additions.isEmpty && connection.pending.isEmpty {
            connection.readyAt = .now + configuration.mergeDelay
            connection.deadline = min(.now + configuration.lifetime, viewDeadline, deadline ?? viewDeadline)
            ready.append(connectionID)
        }
        if let deadline { connection.deadline = min(connection.deadline, deadline) }
        for (key, bytes) in additions { connection.pending.append(key); connection.costs[key] = bytes }
        pendingKeys += additions.count; pendingBytes += cost
        connections[connectionID] = connection
        drain()
        return true
    }

    public func unregister(connectionID: UUID) {
        guard let removed = connections.removeValue(forKey: connectionID) else { return }
        pendingKeys -= removed.pending.count; pendingBytes -= removed.costs.values.reduce(0, +)
        hintBytes -= removed.hints.values.reduce(0) { $0 + $1.bytes }
        ready.removeAll { $0 == connectionID }
        let discarded = outputs.filter { $0.job.streamID == removed.streamID }
        outputs.removeAll { $0.job.streamID == removed.streamID }
        for output in discarded { outputBytes -= output.byteCost; release(output.job) }
        for flight in Array(reads.values) + Array(writes.values) where flight.job.streamID == removed.streamID {
            flight.task.cancel()
        }
        // Active work retains its global slot until the dependency returns.
        drain()
    }

    public func statistics() -> Statistics {
        .init(connections: connections.count, pendingKeys: pendingKeys, pendingBytes: pendingBytes,
              reading: reads.count, writing: writes.count, outputBytes: outputBytes, hintBytes: hintBytes,
              rejectedOffers: rejectedOffers, expiredJobs: expiredJobs,
              suppressedEntries: suppressedEntries, deliveredFrames: deliveredFrames)
    }

    public func close() async {
        closed = true; timer?.cancel(); timer = nil; timerID = nil; timerDeadline = nil
        connections.removeAll(); ready.removeAll()
        activeStreams.removeAll()
        outputBytes -= outputs.reduce(0) { $0 + $1.byteCost }; outputs.removeAll()
        pendingKeys = 0; pendingBytes = 0; hintBytes = 0
        let running = Array(reads.values) + Array(writes.values)
        for flight in running { flight.timer.cancel(); flight.task.cancel() }
        for flight in running { await flight.task.value }
    }

    private func drain() {
        guard !closed else { return }
        let instant = ContinuousClock.now
        for id in ready {
            guard var connection = connections[id], connection.deadline <= instant else { continue }
            pendingKeys -= connection.pending.count; pendingBytes -= connection.costs.values.reduce(0, +)
            connection.pending.removeAll(); connection.costs.removeAll(); connections[id] = connection
            expiredJobs += 1
        }
        ready.removeAll { connections[$0]?.pending.isEmpty != false }
        while canStartRead,
              let index = ready.firstIndex(where: { id in
                  guard let connection = connections[id] else { return false }
                  return !activeStreams.contains(connection.streamID) && connection.readyAt <= instant
              }) {
            let id = ready.remove(at: index)
            guard var connection = connections[id], let first = connection.pending.first else { continue }
            let keys = Array(connection.pending.filter { $0.context == first.context }.prefix(V2AuthorPresentationDelta.maximumEntries))
            let selected = Set(keys)
            connection.pending.removeAll { selected.contains($0) }
            for key in keys { pendingBytes -= connection.costs.removeValue(forKey: key) ?? 0 }
            pendingKeys -= keys.count; connection.activeKeys = selected
            connections[id] = connection
            if !connection.pending.isEmpty { ready.append(id) }
            let job = Job(id: UUID(), connectionID: id, streamID: connection.streamID, viewID: connection.viewID!, identity: connection.identity,
                          keys: keys, started: instant, deadline: connection.deadline)
            activeStreams.insert(job.streamID)
            let reader = read
            let task = Task { [weak self] in
                let result: Result<V2ProfilePresentationBatchResponse, any Error>
                do {
                    try Task.checkCancellation()
                    result = .success(try await reader(.init(keys: keys), job.identity))
                }
                catch { result = .failure(error) }
                await self?.finishRead(job, result: result)
            }
            reads[job.id] = .init(job: job, task: task, timer: watchdog(job, reading: true))
        }
        while writes.count < configuration.maximumWrites, !outputs.isEmpty {
            let output = outputs.removeFirst(), job = output.job
            // Output bytes remain charged while a non-cooperative writer owns them.
            guard job.deadline > .now, let connection = connections[job.connectionID],
                  connection.streamID == job.streamID, connection.viewID == job.viewID else {
                outputBytes -= output.byteCost; release(job); continue
            }
            let sender = connection.send
            let task = Task { [weak self] in
                let accepted: Bool
                if Task.isCancelled || job.deadline <= .now { accepted = false }
                else { accepted = await sender(output.bytes, job.deadline) }
                await self?.finishWrite(output, accepted: accepted)
            }
            writes[job.id] = .init(job: job, task: task, timer: watchdog(job, reading: false))
        }
        let wake = ready.compactMap { id -> ContinuousClock.Instant? in
            guard let connection = connections[id] else { return nil }
            if canStartRead && !activeStreams.contains(connection.streamID) {
                return min(connection.readyAt, connection.deadline)
            }
            return connection.deadline
        }.min()
        scheduleWake(wake)
    }

    private func scheduleWake(_ wake: ContinuousClock.Instant?) {
        // A burst that leaves the earliest boundary unchanged must not create
        // and cancel a new sleeper for every recipient offer.
        guard timerDeadline != wake else { return }
        timer?.cancel(); timer = nil; timerID = nil; timerDeadline = wake
        if let wake {
            let id = UUID(); timerID = id
            timer = Task { [weak self] in
                do { try await ContinuousClock().sleep(until: wake) } catch { return }
                await self?.wake(id)
            }
        }
    }

    private func wake(_ id: UUID) {
        guard timerID == id else { return }
        timer = nil; timerID = nil; timerDeadline = nil
        drain()
    }
    private var canStartRead: Bool {
        let reservation = min(configuration.maximumOutputBytes, 2 * V2AuthorPresentationDelta.maximumEncodedBytes)
        return reads.count < configuration.maximumReads && outputBytes <= configuration.maximumOutputBytes - reservation
    }
    private func watchdog(_ job: Job, reading: Bool) -> Task<Void, Never> {
        Task { [weak self] in
            do { try await ContinuousClock().sleep(until: job.deadline) } catch { return }
            await self?.expire(job, reading: reading)
        }
    }
    private func expire(_ job: Job, reading: Bool) {
        let flight = reading ? reads[job.id] : writes[job.id]
        guard let flight else { return }
        expiredJobs += 1; flight.task.cancel()
    }
    private func release(_ job: Job) {
        activeStreams.remove(job.streamID)
        if connections[job.connectionID]?.streamID == job.streamID { connections[job.connectionID]?.activeKeys.removeAll() }
    }

    private func finishRead(_ job: Job, result: Result<V2ProfilePresentationBatchResponse, any Error>) {
        reads.removeValue(forKey: job.id)?.timer.cancel()
        guard !closed, !Task.isCancelled, job.deadline > .now, var connection = connections[job.connectionID],
              connection.streamID == job.streamID, connection.viewID == job.viewID else { release(job); drain(); return }
        do {
            let rawNow = (now().timeIntervalSince1970 * 1_000).rounded(.down)
            guard rawNow.isFinite, rawNow >= 0, rawNow < Double(Int64.max) else {
                throw V2ResourceValidationError.invalidPresentationLease
            }
            let serverNow = Int64(rawNow)
            let response: V2ProfilePresentationBatchResponse
            let retryAfter: Int64
            switch result {
            case .success(let value): response = value; retryAfter = 1_000
            case .failure(let error):
                if case .throttled(let seconds) = error as? V2ResourceProviderError {
                    retryAfter = Int64(seconds.isFinite ? min(60, max(1, seconds.rounded(.up))) : 1) * 1_000
                } else { retryAfter = 1_000 }
                response = try .init(serverNowUnixMilliseconds: serverNow, results: job.keys.map { .retryable($0) })
            }
            guard Set(response.results.map(\.key)) == Set(job.keys), connection.sequence < UInt64(Int64.max),
                  response.serverNowUnixMilliseconds <= serverNow else { throw V2ResourceValidationError.invalidPresentationLease }
            // Validate the entire recipient binding before selecting or suppressing any entry.
            for item in response.results {
                if case .presentation(let value, _) = item {
                    guard value.lease.actorUserID == job.identity.userID, value.lease.deviceID == job.identity.deviceID else {
                        throw V2ResourceValidationError.invalidPresentationLease
                    }
                }
            }
            let sequence = connection.sequence + 1
            var selected: [V2ProfilePresentationBatchEntry] = [], newHints: [V2ProfileViewLookupKey: Hint] = [:]
            for item in response.results {
                var candidate = item
                if case .presentation(let value, let avatar) = item {
                    let expiry = min(value.lease.validUntilUnixMilliseconds, avatar?.plan.expiresAtUnixMilliseconds ?? Int64.max)
                    if expiry <= serverNow { candidate = .retryable(item.key) }
                    else {
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                        let fingerprint = try encoder.encode(Fingerprint(view: value.view, contextRevision: value.lease.contextRevision,
                            groupMember: value.groupMember,
                            mediaID: avatar?.mediaID, variantID: avatar?.variantID, version: avatar?.version, checksum: avatar?.checksum))
                        if var old = connection.hints[item.key], old.deadline > .now, old.fingerprint == fingerprint {
                            old.touched = .now; connection.hints[item.key] = old
                            suppressedEntries += 1; continue
                        }
                        // The receiver deducts its entire view age. Suppression
                        // must expire no later than that conservative client
                        // deadline, even when the server lease remains valid.
                        let hintLifetime = expiry - serverNow - V2AuthorPresentationDelta.maximumViewAgeMilliseconds
                        if hintLifetime > 0 {
                            newHints[item.key] = .init(fingerprint: fingerprint,
                                deadline: .now + .milliseconds(hintLifetime),
                                bytes: fingerprint.count + (try JSONEncoder().encode(item.key).count), touched: .now)
                        }
                    }
                } else if case .unavailable = item, let old = connection.hints.removeValue(forKey: item.key) {
                    hintBytes -= old.bytes
                }
                if (try? delta(job, sequence: sequence, results: selected + [candidate], serverNow: serverNow, retryAfter: retryAfter)) == nil {
                    candidate = .retryable(item.key); newHints.removeValue(forKey: item.key)
                }
                if (try? delta(job, sequence: sequence, results: selected + [candidate], serverNow: serverNow, retryAfter: retryAfter)) != nil {
                    selected.append(candidate)
                } else { newHints.removeValue(forKey: item.key) }
            }
            connections[job.connectionID] = connection
            guard !selected.isEmpty else { release(job); drain(); return }
            let bytes = try delta(job, sequence: sequence, results: selected, serverNow: serverNow, retryAfter: retryAfter).encoded()
            let output = Output(job: job, bytes: bytes, hints: newHints)
            guard outputBytes <= configuration.maximumOutputBytes - output.byteCost else { release(job); drain(); return }
            connections[job.connectionID]?.sequence = sequence
            outputBytes += output.byteCost; outputs.append(output)
        } catch { release(job) }
        drain()
    }

    private func delta(_ job: Job, sequence: UInt64, results: [V2ProfilePresentationBatchEntry],
                       serverNow: Int64, retryAfter: Int64) throws -> V2AuthorPresentationDelta {
        guard case .room(let room) = job.keys[0].context else { throw V2ResourceValidationError.invalidPresentationLease }
        let retryable = results.contains { if case .retryable = $0 { true } else { false } }
        return try .init(streamID: job.streamID, viewID: job.viewID, sequence: sequence, actorUserID: job.identity.userID,
            deviceID: job.identity.deviceID, roomID: room,
            batch: .init(serverNowUnixMilliseconds: serverNow, results: results),
            retryAfterMilliseconds: retryable ? retryAfter : nil)
    }

    private func finishWrite(_ output: Output, accepted: Bool) {
        let job = output.job
        writes.removeValue(forKey: job.id)?.timer.cancel()
        // close discards queued bytes, but in-flight writers retain their accounting.
        outputBytes -= output.byteCost
        if !closed, !Task.isCancelled, accepted, job.deadline > .now, var connection = connections[job.connectionID],
           connection.streamID == job.streamID, connection.viewID == job.viewID {
            deliveredFrames += 1
            for (key, hint) in output.hints where hint.deadline > .now {
                if let old = connection.hints.removeValue(forKey: key) { hintBytes -= old.bytes }
                while connection.hints.count >= configuration.maximumHintsPerConnection {
                    guard let oldest = connection.hints.min(by: { $0.value.touched < $1.value.touched }) else { break }
                    connection.hints.removeValue(forKey: oldest.key); hintBytes -= oldest.value.bytes
                }
                // Global compression metadata is optional: do not evict other
                // connections or allocate beyond the node's byte budget.
                if hintBytes <= configuration.maximumHintBytes - hint.bytes {
                    connection.hints[key] = hint; hintBytes += hint.bytes
                }
            }
            connections[job.connectionID] = connection
        }
        release(job); drain()
    }
}
