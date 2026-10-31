import IMV2ActorContracts
import IMV2ServerContracts
import Foundation
import IMV2Core

/// Owned, best-effort work after message delivery. `offer` never awaits a
/// profile authority or a transport. Queries and writes own bounded task slots.
/// The composition root must close this owner before its readers/transports.
public actor V2AuthorPresentationDispatcher {
    public nonisolated let readDiagnostics = V2ProfilePresentationReadDiagnostics()
    public struct Configuration: Sendable {
        public let maximumConnections, maximumPendingKeys, maximumPendingKeysPerConnection: Int
        public let maximumPendingBytes, maximumReads, maximumWrites, maximumOutputBytes: Int
        public let maximumHintsPerConnection, maximumHintBytes: Int
        public let mergeDelay, lifetime: Duration

        public init(maximumConnections: Int = 10_000, maximumPendingKeys: Int = 128,
                    maximumPendingKeysPerConnection: Int = 128, maximumPendingBytes: Int = 256 * 1_024,
                    maximumReads: Int = 4, maximumWrites: Int = 4, maximumOutputBytes: Int = 256 * 1_024,
                    maximumHintsPerConnection: Int = 128, maximumHintBytes: Int = 96 * 1_024 * 1_024,
                    mergeDelay: Duration = .milliseconds(2), lifetime: Duration = .milliseconds(500)) throws {
            guard (1...10_000).contains(maximumConnections), (1...1_024).contains(maximumPendingKeys),
                  (1...128).contains(maximumPendingKeysPerConnection), maximumPendingKeysPerConnection <= maximumPendingKeys,
                  (256...262_144).contains(maximumPendingBytes), (1...4).contains(maximumReads),
                  (1...4).contains(maximumWrites), (32_768...262_144).contains(maximumOutputBytes),
                  (1...128).contains(maximumHintsPerConnection), (1_024...134_217_728).contains(maximumHintBytes),
                  mergeDelay >= .zero, mergeDelay <= .milliseconds(5), lifetime > mergeDelay,
                  lifetime <= .milliseconds(500) else { throw V2ResourceProviderError.configurationInvalid }
            self.maximumConnections = maximumConnections; self.maximumPendingKeys = maximumPendingKeys
            self.maximumPendingKeysPerConnection = maximumPendingKeysPerConnection; self.maximumPendingBytes = maximumPendingBytes
            self.maximumReads = maximumReads; self.maximumWrites = maximumWrites; self.maximumOutputBytes = maximumOutputBytes
            // Capacity target: 10,000 connections × eight visible authors.
            // Conservative accounting currently charges 944 bytes per room
            // hint (~72 MiB total); 96 MiB leaves bounded headroom. This is a
            // retained-state budget, not a measurement of process RSS.
            self.maximumHintsPerConnection = maximumHintsPerConnection; self.maximumHintBytes = maximumHintBytes
            self.mergeDelay = mergeDelay; self.lifetime = lifetime
        }
    }

    public struct Statistics: Sendable {
        public let connections, pendingKeys, pendingBytes, reading, writing, outputBytes, hintBytes: Int
        public let rejectedOffers, expiredJobs, suppressedEntries, suppressedReads, deliveredFrames: Int
        public let visibleInterests: Int
    }
    public typealias BatchRead = @Sendable ([V2ProfilePresentationReadRequest]) async throws -> [Result<V2ProfilePresentationBatchResponse, any Error>]
    /// Must recheck the current transport generation, session, deadline and
    /// complete frame byte budget at actual enqueue. `enqueued` means enqueued,
    /// not acknowledged by the client. A dropped delta is recovered via HTTP.
    public typealias Send = @Sendable (Data, ContinuousClock.Instant) async -> V2AuthorPresentationWriteResult

    private struct Connection {
        let streamID: UUID; let identity: V2AuthenticatedConnection; let send: Send
        var viewID: UUID?; var viewGeneration: UUID?; var messageRoomIDs: Set<RoomID> = []
        var viewDeadline: ContinuousClock.Instant?
        var sequence: UInt64 = 0
        var pending: [V2ProfileViewLookupKey] = []
        var costs: [V2ProfileViewLookupKey: Int] = [:]
        var readyAt: ContinuousClock.Instant = .now
        var queuedAt: ContinuousClock.Instant = .now
        var deadline: ContinuousClock.Instant = .now
        var activeKeys: Set<V2ProfileViewLookupKey> = []
        var hints: [V2ProfileViewLookupKey: Hint] = [:]
        var interestSequence: UInt64 = 0
        var visibleKeys: Set<V2ProfileViewLookupKey> = []
        var refresh: [V2ProfileViewLookupKey: Refresh] = [:]
        var versions: [V2ProfileViewLookupKey: Versions] = [:]
        // Direct-conversation keys identify a target, not the resolved room.
        // Keep the authorized room observation for permission invalidations.
        var authorityRooms: [V2ProfileViewLookupKey: RoomID] = [:]
        var observedRooms: Set<RoomID> {
            messageRoomIDs.union(visibleKeys.compactMap { $0.context.authorizationRoomID }).union(authorityRooms.values)
        }
    }
    private struct Versions {
        var profile: UInt64 = 0, alias: UInt64 = 0, nickname: UInt64 = 0, relationship: UInt64 = 0
        var outgoingBlock: UInt64 = 0, incomingBlock: UInt64 = 0
    }
    private struct Refresh {
        let id = UUID()
        var retryAt: ContinuousClock.Instant = .now
        var delivery: RefreshDelivery?
    }
    private struct RefreshDelivery {
        let sequence: UInt64
        var acknowledged = false
        var written = false
    }
    private struct Hint {
        let fingerprint: V2AuthorPresentationFingerprint; var deadline: ContinuousClock.Instant; let bytes: Int
        let offeredAt: ContinuousClock.Instant
        let sequence: UInt64
        var acknowledged = false
        var written = false
        var touched: ContinuousClock.Instant
    }
    private struct Job: Sendable {
        let id: UUID; let connectionID: UUID; let streamID: UUID; let viewID: UUID; let viewGeneration: UUID
        let identity: V2AuthenticatedConnection; let keys: [V2ProfileViewLookupKey]
        let started: ContinuousClock.Instant; let deadline: ContinuousClock.Instant
        let refreshIDs: [V2ProfileViewLookupKey: UUID]
    }
    private struct ReadFlight {
        let jobs: [Job]; let task: Task<Void, Never>; let timer: Task<Void, Never>
        var expiredJobIDs: Set<UUID> = []
        var completedJobs = 0
    }
    private struct Flight {
        let job: Job; let task: Task<Void, Never>; let timer: Task<Void, Never>
    }
    private struct Output {
        let job: Job; let bytes: Data; let hints: [V2ProfileViewLookupKey: Hint]
        let sequence: UInt64
        let refreshReceipts: [V2ProfileViewLookupKey: UUID]
        let byteCost: Int
        let queuedAt = ContinuousClock.now
        var readyAt = ContinuousClock.now
        var retries = 0
        init(job: Job, bytes: Data, hints: [V2ProfileViewLookupKey: Hint], sequence: UInt64,
             refreshReceipts: [V2ProfileViewLookupKey: UUID]) {
            self.job = job; self.bytes = bytes; self.hints = hints
            self.sequence = sequence; self.refreshReceipts = refreshReceipts
            self.byteCost = bytes.count + (V2AuthorPresentationDelta.maximumFrameBytes - V2AuthorPresentationDelta.maximumEncodedBytes)
                + hints.values.reduce(0) { $0 + $1.bytes }
                + refreshReceipts.keys.reduce(0) { $0 + V2ActorPayloadBudget.retainedBytes(of: $1) + 32 }
        }
    }
    private let configuration: Configuration
    private let readBatch: BatchRead
    private let now: @Sendable () -> Date
    private var connections: [UUID: Connection] = [:]
    private var registeredStreams: Set<UUID> = []
    private var viewers: [UserID: Set<UUID>] = [:]
    // At most maximumConnections * maximumAuthors memberships. Only this actor
    // mutates both sides; expired views are excluded even before their cleanup.
    private var watchers: [UserID: Set<UUID>] = [:]
    private var roomViews: [RoomID: Set<UUID>] = [:]
    private var refreshReady: [UUID] = []
    private var refreshQueued: Set<UUID> = []
    private var ready: [UUID] = []
    // A lower bound on queued deadlines. Removing work may leave this early,
    // but admission always lowers it before scheduling. A full pipeline then
    // needs no queue scan for every incoming viewer or completion callback.
    private var pendingExpiry: ContinuousClock.Instant?
    private var activeStreams: Set<UUID> = []
    private var reads: [UUID: ReadFlight] = [:]
    private var writes: [UUID: Flight] = [:]
    private var outputs: [Output] = []
    private var timer: Task<Void, Never>?
    private var timerID: UUID?
    private var timerDeadline: ContinuousClock.Instant?
    private var closed = false
    private var pendingKeys = 0, pendingBytes = 0, outputBytes = 0, hintBytes = 0
    private var rejectedOffers = 0, expiredJobs = 0, suppressedEntries = 0, suppressedReads = 0, deliveredFrames = 0
    private var sourceFreshUntil: ContinuousClock.Instant?

    public init(configuration: Configuration, readBatch: @escaping BatchRead,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.configuration = configuration; self.readBatch = readBatch; self.now = now
    }

    /// Called only after authentication and feature negotiation. A stream ID
    /// changes on every registration, including replacement of an old socket.
    public func register(connectionID: UUID, identity: V2AuthenticatedConnection, streamID: UUID = UUID(), send: @escaping Send) throws -> UUID {
        guard !closed, connections[connectionID] == nil, connections.count < configuration.maximumConnections,
              identity.userID.uuidValue != nil, identity.deviceID.uuidValue != nil else {
            throw V2ResourceProviderError.throttled(retryAfter: 1)
        }
        guard registeredStreams.insert(streamID).inserted else {
            throw V2ResourceProviderError.throttled(retryAfter: 1)
        }
        connections[connectionID] = .init(streamID: streamID, identity: identity, send: send)
        viewers[identity.userID, default: []].insert(connectionID)
        return streamID
    }

    /// Starts only on the authenticated, negotiated connection. Message-room
    /// hints are accepted only after their ordinary delivery authorization;
    /// every visible key still goes through the recipient-specific read port.
    @discardableResult
    public func activateView(connectionID: UUID, start: V2AuthorPresentationStart) -> Bool {
        guard !closed, let current = connections[connectionID], current.streamID == start.streamID else { return false }
        let rooms = Set(start.messageRoomIDs)
        if current.viewID == start.viewID {
            return current.messageRoomIDs == rooms && current.viewDeadline.map { $0 > .now } == true
        }
        clearView(connectionID: connectionID)
        connections[connectionID]?.viewID = start.viewID
        connections[connectionID]?.viewGeneration = UUID()
        connections[connectionID]?.messageRoomIDs = rooms
        connections[connectionID]?.viewDeadline = .now + .milliseconds(V2AuthorPresentationDelta.maximumViewAgeMilliseconds)
        for room in rooms { roomViews[room, default: []].insert(connectionID) }
        return true
    }

    public func deactivateView(connectionID: UUID, viewID: UUID) {
        guard connections[connectionID]?.viewID == viewID else { return }
        clearView(connectionID: connectionID)
        drain()
    }

    private func clearView(connectionID: UUID) {
        guard var connection = connections[connectionID] else { return }
        removeRoomViews(connection.observedRooms, connectionID: connectionID)
        removeWatchers(Set(connection.visibleKeys.map(\.userID)), connectionID: connectionID)
        connection.visibleKeys.removeAll(); connection.interestSequence = 0
        connection.refresh.removeAll(); connection.versions.removeAll(); connection.authorityRooms.removeAll(); removeRefreshQueue(connectionID)
        pendingKeys -= connection.pending.count; pendingBytes -= connection.costs.values.reduce(0, +)
        hintBytes -= connection.hints.values.reduce(0) { $0 + $1.bytes }
        connection.pending.removeAll(); connection.costs.removeAll(); connection.hints.removeAll()
        connection.viewID = nil; connection.viewGeneration = nil; connection.messageRoomIDs.removeAll(); connection.viewDeadline = nil; connection.activeKeys.removeAll()
        connections[connectionID] = connection; ready.removeAll { $0 == connectionID }
        let discarded = outputs.filter { $0.job.streamID == connection.streamID }
        outputs.removeAll { $0.job.streamID == connection.streamID }
        for output in discarded { outputBytes -= output.byteCost; release(output.job) }
        cancelRetiredReads()
        for flight in writes.values where flight.job.streamID == connection.streamID {
            flight.task.cancel()
        }
    }

    /// Input authors must come from messages actually authorized for this
    /// recipient. Confirmed, live entries under an actively observed interest
    /// may avoid a read; all other keys pass through the authority reader.
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
        guard roomID.uuidValue != nil, authors.allSatisfy({ $0.uuidValue != nil }),
              connections[connectionID]?.messageRoomIDs.contains(roomID) == true else {
            rejectedOffers += 1; return false
        }
        return enqueue(connectionID: connectionID,
            keys: authors.map { .init(userID: $0, context: .room(roomID)) }, deadline: deadline)
    }

    private func enqueue(connectionID: UUID, keys: [V2ProfileViewLookupKey],
                         deadline: ContinuousClock.Instant?, drainAfterAdmission: Bool = true) -> Bool {
        guard !closed, (1...V2AuthorPresentationInterests.maximumAuthors).contains(keys.count),
              var connection = connections[connectionID], connection.viewID != nil,
              let viewDeadline = connection.viewDeadline, viewDeadline > .now else {
            rejectedOffers += 1; return false
        }
        var additions: [(V2ProfileViewLookupKey, Int)] = []
        var seen: Set<V2ProfileViewLookupKey> = []
        for key in keys where seen.insert(key).inserted {
            guard connection.costs[key] == nil, !connection.activeKeys.contains(key) else { continue }
            if suppressKnown(key, in: &connection, at: .now) { continue }
            let cost = V2ActorPayloadBudget.retainedBytes(of: key)
            additions.append((key, cost))
        }
        guard !additions.isEmpty else { connections[connectionID] = connection; return true }
        let cost = additions.reduce(0) { $0 + $1.1 }
        guard connection.pending.count + additions.count <= configuration.maximumPendingKeysPerConnection,
              pendingKeys + additions.count <= configuration.maximumPendingKeys,
              pendingBytes <= configuration.maximumPendingBytes - cost else { rejectedOffers += 1; return false }
        for (key, hint) in connection.hints where hint.deadline <= .now {
            connection.hints.removeValue(forKey: key); hintBytes -= hint.bytes
        }
        if !additions.isEmpty && connection.pending.isEmpty {
            connection.queuedAt = .now
            connection.readyAt = .now + configuration.mergeDelay
            connection.deadline = min(.now + configuration.lifetime, viewDeadline, deadline ?? viewDeadline)
            ready.append(connectionID)
        }
        if let deadline { connection.deadline = min(connection.deadline, deadline) }
        for (key, bytes) in additions { connection.pending.append(key); connection.costs[key] = bytes }
        pendingKeys += additions.count; pendingBytes += cost
        connections[connectionID] = connection
        pendingExpiry = min(pendingExpiry ?? connection.deadline, connection.deadline)
        if drainAfterAdmission { drain() }
        return true
    }

    public func unregister(connectionID: UUID) {
        guard let removed = connections.removeValue(forKey: connectionID) else { return }
        removeRoomViews(removed.observedRooms, connectionID: connectionID)
        registeredStreams.remove(removed.streamID)
        viewers[removed.identity.userID]?.remove(connectionID)
        if viewers[removed.identity.userID]?.isEmpty == true { viewers.removeValue(forKey: removed.identity.userID) }
        removeRefreshQueue(connectionID)
        removeWatchers(Set(removed.visibleKeys.map(\.userID)), connectionID: connectionID)
        pendingKeys -= removed.pending.count; pendingBytes -= removed.costs.values.reduce(0, +)
        hintBytes -= removed.hints.values.reduce(0) { $0 + $1.bytes }
        ready.removeAll { $0 == connectionID }
        let discarded = outputs.filter { $0.job.streamID == removed.streamID }
        outputs.removeAll { $0.job.streamID == removed.streamID }
        for output in discarded { outputBytes -= output.byteCost; release(output.job) }
        cancelRetiredReads()
        for flight in writes.values where flight.job.streamID == removed.streamID {
            flight.task.cancel()
        }
        // Active work retains its global slot until the dependency returns.
        drain()
    }

    /// An exact receipt cannot acknowledge missing sequences, a replacement
    /// page or another socket. A receipt racing the writer is remembered but
    /// cannot suppress anything until that write also completes successfully.
    public func acknowledge(connectionID: UUID, receipt: V2AuthorPresentationReceipt) {
        guard !closed, var connection = connections[connectionID],
              connection.streamID == receipt.streamID, connection.viewID == receipt.viewID,
              connection.viewDeadline.map({ $0 > .now }) == true else { return }
        let refreshCount = connection.refresh.count
        for key in receipt.keys {
            if var refresh = connection.refresh[key], var delivery = refresh.delivery,
               delivery.sequence == receipt.sequence {
                delivery.acknowledged = true; refresh.delivery = delivery
                connection.refresh[key] = delivery.written ? nil : refresh
            }
            guard var hint = connection.hints[key], hint.sequence == receipt.sequence,
                  hint.deadline > .now else { continue }
            hint.acknowledged = true
            // Preparation precedes the client's retention measurement. Anchoring
            // its reported remaining duration here expires no later than the
            // client, even when the ACK itself is delayed or duplicated.
            hint.deadline = min(hint.deadline, hint.offeredAt + .milliseconds(receipt.minimumRemainingMilliseconds))
            connection.hints[key] = hint
        }
        connections[connectionID] = connection
        if connection.refresh.isEmpty { removeRefreshQueue(connectionID) }
        if connection.refresh.count < refreshCount { drain() }
    }

    /// Complete replacement, not an additive request. Registration precedes
    /// the initial authority read, so a change consumer can see the interest
    /// while that read is suspended. Interest alone confers no access.
    @discardableResult
    public func replaceVisibleInterests(connectionID: UUID, interests: V2AuthorPresentationInterests) -> Bool {
        guard !closed, var connection = connections[connectionID],
              connection.streamID == interests.streamID, connection.viewID == interests.viewID,
              connection.viewDeadline.map({ $0 > .now }) == true,
              interests.sequence > connection.interestSequence else { return false }
        let keys = Set(interests.keys)
        let previousRooms = connection.observedRooms
        let removed = connection.visibleKeys.subtracting(keys)
        let added = keys.subtracting(connection.visibleKeys)
        // The reverse index is per user, but ownership and invalidation are
        // per complete key. Removing one context must retain other contexts.
        let oldAuthors = Set(connection.visibleKeys.map(\.userID))
        let newAuthors = Set(keys.map(\.userID))
        removeWatchers(oldAuthors.subtracting(newAuthors), connectionID: connectionID)
        for author in newAuthors.subtracting(oldAuthors) { watchers[author, default: []].insert(connectionID) }
        connection.visibleKeys = keys; connection.interestSequence = interests.sequence
        connection.authorityRooms = connection.authorityRooms.filter { keys.contains($0.key) }
        removeRoomViews(previousRooms.subtracting(connection.observedRooms), connectionID: connectionID)
        for room in connection.observedRooms.subtracting(previousRooms) { roomViews[room, default: []].insert(connectionID) }
        for key in removed {
            connection.refresh.removeValue(forKey: key)
            connection.versions.removeValue(forKey: key)
            if let hint = connection.hints.removeValue(forKey: key) { hintBytes -= hint.bytes }
            if let cost = connection.costs.removeValue(forKey: key) {
                connection.pending.removeAll { $0 == key }; pendingKeys -= 1; pendingBytes -= cost
            }
        }
        for key in added { connection.refresh[key] = .init() }
        connections[connectionID] = connection
        if !connection.refresh.isEmpty { enqueueRefresh(connectionID) }
        else { removeRefreshQueue(connectionID) }
        if connection.pending.isEmpty { ready.removeAll { $0 == connectionID } }
        if !added.isEmpty {
            // Admission failure keeps the interest registered. The ordinary
            // bounded client recovery remains available for the initial value.
            _ = enqueue(connectionID: connectionID, keys: Array(added), deadline: nil, drainAfterAdmission: false)
        }
        drain()
        return true
    }

    public struct VisibleSubscription: Sendable {
        public let connectionID: UUID
        public let streamID: UUID
        public let viewID: UUID
        public let keys: Set<V2ProfileViewLookupKey>
    }

    /// A bounded reverse index for change delivery, never a source of profile
    /// authorization. Consumers still use the recipient-specific read port.
    public func visibleSubscriptions(for author: UserID) -> [VisibleSubscription] {
        (watchers[author] ?? []).compactMap { id in
            guard let connection = connections[id],
                  let view = connection.viewID, connection.viewDeadline.map({ $0 > .now }) == true else { return nil }
            return .init(connectionID: id, streamID: connection.streamID, viewID: view, keys: connection.visibleKeys.filter { $0.userID == author })
        }
    }

    private func removeWatchers(_ authors: Set<UserID>, connectionID: UUID) {
        for author in authors {
            watchers[author]?.remove(connectionID)
            if watchers[author]?.isEmpty == true { watchers.removeValue(forKey: author) }
        }
    }

    /// A source revision invalidates both compression and reads that began
    /// before this change. The obligation stays until the client applies it.
    public func profileDidChange(_ change: V2AuthorProfileChange) {
        switch change.scope {
        case .publicProfile(let user):
            for id in watchers[user] ?? [] { invalidate(id, author: user, revision: change.revision, field: \.profile) }
        case .contactAlias(let owner, let target):
            // Private remarks affect only the owner's devices, in each of
            // their visible contexts. Never fan out to the remarked user.
            for id in viewers[owner] ?? [] { invalidate(id, author: target, revision: change.revision, field: \.alias) }
        case .relationship(let first, let second):
            for id in viewers[first] ?? [] { invalidate(id, author: second, revision: change.revision, field: \.relationship) }
            for id in viewers[second] ?? [] { invalidate(id, author: first, revision: change.revision, field: \.relationship) }
        case .userBlock(let actor, let target):
            for id in viewers[actor] ?? [] { invalidate(id, author: target, revision: change.revision, field: \.outgoingBlock) }
            for id in viewers[target] ?? [] { invalidate(id, author: actor, revision: change.revision, field: \.incomingBlock) }
        }
    }

    private func invalidate(_ id: UUID, author: UserID, revision: UInt64,
                            field: WritableKeyPath<Versions, UInt64>, context: V2ProfileViewContext? = nil) {
        guard var connection = connections[id], connection.viewDeadline.map({ $0 > .now }) == true else { return }
        var invalidated = false
        for key in connection.visibleKeys where key.userID == author && (context == nil || key.context == context) {
            var versions = connection.versions[key] ?? .init()
            // Pending message hints cannot consume invalidations. Permission
            // revisions never use content hints as evidence of current authority.
            let hint = connection.hints[key]
            let installed = hint.map { $0.acknowledged && $0.written && $0.deadline > .now } == true
            var known = versions[keyPath: field]
            if installed, let hint {
                if field == \.profile { known = max(known, hint.fingerprint.profileRevision) }
                if field == \.alias { known = max(known, hint.fingerprint.aliasRevision) }
                if field == \.nickname { known = max(known, hint.fingerprint.nicknameRevision) }
            }
            guard revision > known else { continue }
            versions[keyPath: field] = revision
            connection.versions[key] = versions
            if let old = connection.hints.removeValue(forKey: key) { hintBytes -= old.bytes }
            connection.refresh[key] = .init(); invalidated = true
        }
        guard invalidated else { return }
        connections[id] = connection; enqueueRefresh(id)
    }

    public func groupNicknameDidChange(_ change: V2AuthorGroupNicknameChange) {
        for id in watchers[change.userID] ?? [] {
            invalidate(id, author: change.userID, revision: change.revision,
                       field: \.nickname, context: .room(change.roomID))
        }
    }

    private func removeRoomViews(_ rooms: Set<RoomID>, connectionID: UUID) {
        for room in rooms {
            roomViews[room]?.remove(connectionID)
            if roomViews[room]?.isEmpty == true { roomViews.removeValue(forKey: room) }
        }
    }

    public func resetVisibleProfiles(roomID: RoomID? = nil) {
        let selected = roomID.map { Array(roomViews[$0] ?? []) } ?? Array(connections.keys)
        for id in selected {
            guard var connection = connections[id],
                  connection.viewDeadline.map({ $0 > .now }) == true else { continue }
            for key in connection.visibleKeys where roomID == nil || key.context.authorizationRoomID == roomID || connection.authorityRooms[key] == roomID {
                if let old = connection.hints.removeValue(forKey: key) { hintBytes -= old.bytes }
                connection.refresh[key] = .init()
            }
            connections[id] = connection
            if !connection.refresh.isEmpty { enqueueRefresh(id) }
        }
    }

    /// One process-owned feed worker calls this periodically, including after
    /// source failures. Round-robin admission never creates one task per viewer.
    public func retryVisibleProfiles(limit: Int = 1_000, at instant: ContinuousClock.Instant = .now) {
        guard !closed, (1...1_000).contains(limit) else { return }
        admitVisibleProfiles(limit: limit, at: instant)
        drain()
    }

    private func admitVisibleProfiles(limit: Int, at instant: ContinuousClock.Instant) {
        // Admit the whole bounded slice before scheduling it. Scanning the
        // pending/output queues for every viewer monopolizes this actor and
        // prevents already-running reads, writes and ACKs from completing.
        let selected = Array(refreshReady.prefix(limit))
        refreshReady.removeFirst(selected.count)
        for id in selected {
            refreshQueued.remove(id)
            guard let connection = connections[id],
                  connection.viewDeadline.map({ $0 > .now }) == true else { continue }
            // This slice shares one admission budget. Once it is full, leave
            // later viewers eligible for the next round instead of treating
            // a request that never started as a one-second read failure.
            if pendingKeys >= configuration.maximumPendingKeys || pendingBytes >= configuration.maximumPendingBytes {
                enqueueRefresh(id); continue
            }
            let keys = connection.refresh.filter { key, refresh in
                return refresh.retryAt <= instant && !connection.activeKeys.contains(key) && connection.costs[key] == nil
            }.keys.sorted { $0.userID.rawValue < $1.userID.rawValue }
            if !keys.isEmpty, !enqueue(connectionID: id, keys: Array(keys), deadline: nil, drainAfterAdmission: false) {
                for key in keys { connections[id]?.refresh[key]?.retryAt = instant + .milliseconds(100) }
            }
            if connections[id]?.refresh.isEmpty == false { enqueueRefresh(id) }
        }
    }

    private func enqueueRefresh(_ id: UUID) {
        if refreshQueued.insert(id).inserted { refreshReady.append(id) }
    }
    private func removeRefreshQueue(_ id: UUID) {
        if refreshQueued.remove(id) != nil { refreshReady.removeAll { $0 == id } }
    }

    public func statistics() -> Statistics {
        .init(connections: connections.count, pendingKeys: pendingKeys, pendingBytes: pendingBytes,
              reading: reads.count, writing: writes.count, outputBytes: outputBytes, hintBytes: hintBytes,
              rejectedOffers: rejectedOffers, expiredJobs: expiredJobs,
              suppressedEntries: suppressedEntries, suppressedReads: suppressedReads, deliveredFrames: deliveredFrames,
              visibleInterests: connections.values.reduce(0) { $0 + $1.visibleKeys.count })
    }

    public func close() async {
        closed = true; timer?.cancel(); timer = nil; timerID = nil; timerDeadline = nil
        connections.removeAll(); registeredStreams.removeAll(); viewers.removeAll(); watchers.removeAll(); roomViews.removeAll(); ready.removeAll()
        refreshReady.removeAll(); refreshQueued.removeAll()
        activeStreams.removeAll()
        outputBytes -= outputs.reduce(0) { $0 + $1.byteCost }; outputs.removeAll()
        pendingKeys = 0; pendingBytes = 0; hintBytes = 0
        pendingExpiry = nil
        let tasks = reads.values.map(\.task) + writes.values.map(\.task)
        for timer in reads.values.map(\.timer) + writes.values.map(\.timer) { timer.cancel() }
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    // The feed owner only marks caught-up after applying every event through
    // the observed head. A stalled, failed or backlogged source disables skips.
    func profileSourceCaughtUp() { sourceFreshUntil = .now + .seconds(1) }
    func profileSourceUnavailable() { sourceFreshUntil = nil }

    private func suppressKnown(_ key: V2ProfileViewLookupKey, in connection: inout Connection,
                               at instant: ContinuousClock.Instant) -> Bool {
        guard sourceFreshUntil.map({ $0 > instant }) == true,
              connection.visibleKeys.contains(key), connection.refresh[key] == nil,
              var hint = connection.hints[key], hint.acknowledged, hint.written, hint.deadline > instant else { return false }
        hint.touched = instant; connection.hints[key] = hint
        suppressedEntries += 1; suppressedReads += 1
        return true
    }

    private func drain() {
        guard !closed else { return }
        let instant = ContinuousClock.now
        if pendingExpiry.map({ $0 <= instant }) == true {
            pendingExpiry = nil
            for id in ready {
                guard var connection = connections[id], !connection.pending.isEmpty else { continue }
                if connection.deadline > instant {
                    pendingExpiry = min(pendingExpiry ?? connection.deadline, connection.deadline)
                    continue
                }
                readDiagnostics.recordElapsed(.dispatchQueue, started: connection.queuedAt, failed: true)
                pendingKeys -= connection.pending.count; pendingBytes -= connection.costs.values.reduce(0, +)
                connection.pending.removeAll(); connection.costs.removeAll(); connections[id] = connection
                expiredJobs += 1
            }
            ready.removeAll { connections[$0]?.pending.isEmpty != false }
        }
        // The change feed's poll is a recovery timer, not a throughput clock.
        // Refill deferred initial/changed interests when pipeline capacity is
        // released, retaining the same pending/read/output limits. Otherwise
        // 128 pending keys per 100 ms poll caps all viewers at 1,280 keys/s,
        // so multi-author cold starts expire even when the socket is writable.
        while canStartRead {
            if pendingKeys < max(1, configuration.maximumPendingKeys / 2) {
                // Refill between batches as well as on completion. Looking
                // past the bounded active window and pending queue avoids
                // treating those same viewers as the only available work.
                // Admission still obeys the original key and byte budgets.
                admitVisibleProfiles(limit: min(1_000, configuration.maximumPendingKeys + 200), at: instant)
            }
            // The earliest eligible request opens this merge window. Include
            // newer requests already queued when it opens, instead of sending
            // the old tail alone while newly admitted keys wait another window.
            guard ready.contains(where: { id in
                guard let connection = connections[id] else { return false }
                return !activeStreams.contains(connection.streamID) && connection.readyAt <= instant
            }) else { break }
            var jobs: [Job] = []
            // Batches contain at most one hundred entries. At most two hundred
            // recipients may be reading, queued for output or writing together;
            // do not refill read slots independently of the socket backlog.
            var remaining = min(100, 200 - activeStreams.count)
            while remaining > 0, let index = ready.firstIndex(where: { id in
                guard let connection = connections[id] else { return false }
                return !activeStreams.contains(connection.streamID)
            }) {
                let id = ready.remove(at: index)
                guard var connection = connections[id] else { continue }
                for key in connection.pending where suppressKnown(key, in: &connection, at: instant) {
                    connection.pending.removeAll { $0 == key }
                    pendingBytes -= connection.costs.removeValue(forKey: key) ?? 0; pendingKeys -= 1
                }
                connections[id] = connection
                guard !connection.pending.isEmpty else { continue }
                readDiagnostics.recordElapsed(.dispatchQueue, started: connection.queuedAt)
                let keys = V2ProfilePresentationBatchRequest.selectKeys(
                    from: connection.pending,
                    maximumKeys: min(remaining, V2AuthorPresentationDelta.maximumEntries))
                let selected = Set(keys)
                connection.pending.removeAll { selected.contains($0) }
                for key in keys { pendingBytes -= connection.costs.removeValue(forKey: key) ?? 0 }
                pendingKeys -= keys.count; connection.activeKeys = selected
                // Pending keys and active keys already prevent duplicate
                // admission. A dependency retry interval starts only when a
                // read claims its slot; expiry while merely queued must not
                // leave an unread visible author cooling down for a second.
                for key in keys {
                    if let retryAt = connection.refresh[key]?.retryAt {
                        connection.refresh[key]?.retryAt = max(retryAt, instant + .seconds(1))
                    }
                }
                connections[id] = connection
                if !connection.pending.isEmpty { ready.append(id) }
                jobs.append(.init(id: UUID(), connectionID: id, streamID: connection.streamID, viewID: connection.viewID!, viewGeneration: connection.viewGeneration!, identity: connection.identity,
                                  keys: keys, started: instant, deadline: connection.deadline,
                                  refreshIDs: Dictionary(uniqueKeysWithValues: keys.compactMap { key in
                                      connection.refresh[key].map { (key, $0.id) }
                                  })))
                activeStreams.insert(connection.streamID)
                remaining -= keys.count
            }
            guard !jobs.isEmpty else { break }
            let batchID = UUID(), selectedJobs = jobs, reader = readBatch, diagnostics = readDiagnostics
            // A shared operation belongs to every live recipient. Each job
            // still keeps its original delivery cutoff; an earlier peer must
            // not cancel work while another recipient can use the result.
            let deadline = jobs.map(\.deadline).max()!
            let task = Task { [weak self] in
                diagnostics.recordElapsed(.dispatchTask, started: instant)
                let result: Result<[Result<V2ProfilePresentationBatchResponse, any Error>], any Error>
                do {
                    try Task.checkCancellation()
                    let inputs = try selectedJobs.map { job in
                        V2ProfilePresentationReadRequest(request: try .init(keys: job.keys), actorUserID: job.identity.userID,
                            deviceID: job.identity.deviceID, deadline: job.deadline)
                    }
                    result = .success(try await reader(inputs))
                } catch { result = .failure(error) }
                await self?.finishBatch(batchID, jobs: selectedJobs, result: result)
            }
            let timer = Task { [weak self] in
                do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                await self?.expireBatch(batchID)
            }
            reads[batchID] = .init(jobs: selectedJobs, task: task, timer: timer)
        }
        while writes.count < configuration.maximumWrites,
              let index = outputs.firstIndex(where: { $0.readyAt <= .now || $0.job.deadline <= .now }) {
            let output = outputs.remove(at: index), job = output.job
            // Output bytes remain charged while a non-cooperative writer owns them.
            guard job.deadline > .now, let connection = connections[job.connectionID],
                  connection.streamID == job.streamID, connection.viewID == job.viewID, connection.viewGeneration == job.viewGeneration,
                  output.refreshReceipts.allSatisfy({ connection.refresh[$0.key]?.id == $0.value }) else {
                outputBytes -= output.byteCost; release(job); continue
            }
            let sender = connection.send, diagnostics = readDiagnostics
            let task = Task { [weak self] in
                diagnostics.recordElapsed(.dispatchWriteQueue, started: output.queuedAt)
                let started = ContinuousClock.now
                let result: V2AuthorPresentationWriteResult
                if Task.isCancelled || job.deadline <= .now { result = .discarded }
                else { result = await sender(output.bytes, job.deadline) }
                diagnostics.recordElapsed(.dispatchWrite, started: started, failed: result != .enqueued)
                await self?.finishWrite(output, result: result)
            }
            writes[job.id] = .init(job: job, task: task, timer: watchdog(job))
        }
        if pendingKeys == 0 { pendingExpiry = nil }
        var wake: ContinuousClock.Instant?
        if canStartRead {
            wake = ready.compactMap { id -> ContinuousClock.Instant? in
                guard let connection = connections[id] else { return nil }
                return activeStreams.contains(connection.streamID)
                    ? connection.deadline : min(connection.readyAt, connection.deadline)
            }.min()
        } else { wake = pendingExpiry }
        if writes.count < configuration.maximumWrites,
           let outputWake = outputs.map({ min($0.readyAt, $0.job.deadline) }).min() {
            wake = min(wake ?? outputWake, outputWake)
        }
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
        // Refill at half the recipient window so each completed socket does
        // not trigger a separate authority read while a full batch drains.
        return activeStreams.count <= 100 && reads.count < configuration.maximumReads
            && outputBytes <= configuration.maximumOutputBytes - reservation
    }
    private func watchdog(_ job: Job) -> Task<Void, Never> {
        Task { [weak self] in
            do { try await ContinuousClock().sleep(until: job.deadline) } catch { return }
            await self?.expire(job)
        }
    }
    private func expire(_ job: Job) {
        guard let flight = writes[job.id] else { return }
        expiredJobs += 1; flight.task.cancel()
    }
    private func release(_ job: Job) {
        activeStreams.remove(job.streamID)
        if connections[job.connectionID]?.streamID == job.streamID, connections[job.connectionID]?.viewGeneration == job.viewGeneration { connections[job.connectionID]?.activeKeys.removeAll() }
    }

    private func cancelRetiredReads() {
        for flight in reads.values where flight.jobs.dropFirst(flight.completedJobs).allSatisfy({ job in
            job.deadline <= .now || connections[job.connectionID]?.streamID != job.streamID
                || connections[job.connectionID]?.viewGeneration != job.viewGeneration
        }) { flight.task.cancel() }
    }

    private func expireBatch(_ id: UUID) {
        guard let flight = reads[id] else { return }
        for job in flight.jobs.dropFirst(flight.completedJobs) { recordExpiredRead(id, job: job) }
        flight.task.cancel()
    }

    private func recordExpiredRead(_ id: UUID, job: Job) {
        guard job.deadline <= .now else { return }
        if reads[id]?.expiredJobIDs.insert(job.id).inserted == true { expiredJobs += 1 }
    }

    private func finishBatch(_ id: UUID, jobs: [Job], result: Result<[Result<V2ProfilePresentationBatchResponse, any Error>], any Error>) async {
        // Keep this bounded read flight charged until its returned results have
        // been consumed. A full output queue must not discard a whole batch and
        // immediately start the same authority reads again. The existing flight
        // watchdog still bounds the wait, including non-cooperative writers.
        let reserve = min(configuration.maximumOutputBytes, 2 * V2AuthorPresentationDelta.maximumEncodedBytes)
        var fingerprints = V2AuthorPresentationFingerprint.Batch()
        for (index, job) in jobs.enumerated() {
            while !closed, !Task.isCancelled, job.deadline > .now,
                  outputBytes > configuration.maximumOutputBytes - reserve {
                do { try await Task.sleep(for: .milliseconds(1)) } catch { break }
            }
            recordExpiredRead(id, job: job)
            switch result {
            case .success(let values) where values.count == jobs.count:
                finishRead(job, result: values[index], fingerprints: &fingerprints)
            case .success: finishRead(job, result: .failure(V2ProfileControlBatchError.corruptResult), fingerprints: &fingerprints)
            case .failure(let error): finishRead(job, result: .failure(error), fingerprints: &fingerprints)
            }
            reads[id]?.completedJobs = index + 1
            drain()
            if index % 8 == 7 { await Task.yield() }
        }
        reads.removeValue(forKey: id)?.timer.cancel()
        drain()
    }

    private func finishRead(_ job: Job, result: Result<V2ProfilePresentationBatchResponse, any Error>,
                            fingerprints: inout V2AuthorPresentationFingerprint.Batch) {
        let started = ContinuousClock.now
        defer { readDiagnostics.recordElapsed(.dispatchEncode, started: started) }
        guard !closed, !Task.isCancelled, job.deadline > .now, var connection = connections[job.connectionID],
              connection.streamID == job.streamID, connection.viewID == job.viewID, connection.viewGeneration == job.viewGeneration else { release(job); return }
        do {
            let preparedAt = ContinuousClock.now
            guard let viewDeadline = connection.viewDeadline else { throw V2ResourceValidationError.invalidPresentationLease }
            let viewStarted = viewDeadline - .milliseconds(V2AuthorPresentationDelta.maximumViewAgeMilliseconds)
            let age = viewStarted.duration(to: preparedAt).components
            let serverViewAge = age.seconds * 1_000 + age.attoseconds / 1_000_000_000_000_000
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
                // A removed interest also retires its already-started read.
                // Only ordinary message supplements may have no refresh ID.
                if let started = job.refreshIDs[item.key],
                   connection.refresh[item.key]?.id != started { continue }
                if let refresh = connection.refresh[item.key] {
                    guard job.refreshIDs[item.key] == refresh.id else { continue }
                }
                if case .presentation(let value, _) = item, let floor = connection.versions[item.key] {
                    guard value.view.revision.rawValue >= floor.profile,
                          value.view.state != .active || ((value.contactAlias?.revision.rawValue ?? 0) >= floor.alias
                              && (value.groupMember?.revision.rawValue ?? 0) >= floor.nickname) else { continue }
                }
                if connection.visibleKeys.contains(item.key) {
                    switch item {
                    case .presentation(let value, _): connection.authorityRooms[item.key] = value.lease.authorityVersion.roomID
                    case .unavailable(let denial): connection.authorityRooms[item.key] = denial.authorityVersion.roomID
                    case .retryable: break
                    }
                }
                var candidate = item
                if case .presentation(let value, let avatar) = item {
                    let expiry = value.lease.validUntilUnixMilliseconds
                    if expiry <= serverNow { candidate = .retryable(item.key) }
                    else {
                        let prepared = try fingerprints.prepare(value, avatar: avatar)
                        let fingerprint = prepared.fingerprint
                        if var old = connection.hints[item.key], old.acknowledged, old.written,
                           old.deadline > .now, old.fingerprint == fingerprint {
                            old.touched = .now; connection.hints[item.key] = old
                            connection.refresh.removeValue(forKey: item.key)
                            suppressedEntries += 1; continue
                        }
                        // The ACK will narrow this server lease to the actual
                        // client retention interval; no hint is usable before it.
                        let hintLifetime = expiry - serverNow
                        if hintLifetime > 0 {
                            newHints[item.key] = .init(fingerprint: fingerprint,
                                deadline: min(viewDeadline, preparedAt + .milliseconds(hintLifetime)),
                                // Charge fixed hint bookkeeping and dictionary
                                // storage as well as the digest and lookup key.
                                bytes: prepared.retainedBytes,
                                offeredAt: preparedAt, sequence: sequence, touched: preparedAt)
                        }
                    }
                } else if case .unavailable = item, let old = connection.hints.removeValue(forKey: item.key) {
                    hintBytes -= old.bytes
                }
                selected.append(candidate)
            }
            // Normal viewport batches fit in one frame. Validate/encode that
            // batch once instead of encoding every growing prefix (quadratic
            // in the number of authors). Oversized batches retain the bounded
            // partial-result behavior and never remember untransmitted hints.
            var selectedDelta: V2AuthorPresentationDelta?
            if !selected.isEmpty {
                selectedDelta = try? delta(job, sequence: sequence, results: selected,
                    serverNow: serverNow, serverViewAge: serverViewAge, retryAfter: retryAfter)
            }
            if selectedDelta == nil, !selected.isEmpty {
                let candidates = selected; selected.removeAll(keepingCapacity: true)
                for item in candidates {
                    var candidate = item
                    var next = try? delta(job, sequence: sequence, results: selected + [candidate],
                        serverNow: serverNow, serverViewAge: serverViewAge, retryAfter: retryAfter)
                    if next == nil {
                        candidate = .retryable(item.key); newHints.removeValue(forKey: item.key)
                        next = try? delta(job, sequence: sequence, results: selected + [candidate],
                            serverNow: serverNow, serverViewAge: serverViewAge, retryAfter: retryAfter)
                    }
                    if let next { selected.append(candidate); selectedDelta = next }
                    else { newHints.removeValue(forKey: item.key) }
                }
            }
            let previousRooms = connections[job.connectionID]?.observedRooms ?? []
            removeRoomViews(previousRooms.subtracting(connection.observedRooms), connectionID: job.connectionID)
            for room in connection.observedRooms.subtracting(previousRooms) { roomViews[room, default: []].insert(job.connectionID) }
            connections[job.connectionID] = connection
            if connection.refresh.isEmpty { removeRefreshQueue(job.connectionID) }
            guard let selectedDelta else { release(job); return }
            let bytes = try selectedDelta.encoded()
            let receipts = Dictionary(uniqueKeysWithValues: selected.compactMap { item -> (V2ProfileViewLookupKey, UUID)? in
                if case .retryable = item { return nil }
                return connection.refresh[item.key].map { (item.key, $0.id) }
            })
            let output = Output(job: job, bytes: bytes, hints: newHints, sequence: sequence, refreshReceipts: receipts)
            guard outputBytes <= configuration.maximumOutputBytes - output.byteCost else { release(job); return }
            connections[job.connectionID]?.sequence = sequence
            for (key, id) in receipts where connections[job.connectionID]?.refresh[key]?.id == id {
                connections[job.connectionID]?.refresh[key]?.delivery = .init(sequence: sequence)
                connections[job.connectionID]?.refresh[key]?.retryAt = .now + .seconds(1)
            }
            stageHints(newHints, connectionID: job.connectionID)
            outputBytes += output.byteCost; outputs.append(output)
        } catch { release(job) }
    }

    private func delta(_ job: Job, sequence: UInt64, results: [V2ProfilePresentationBatchEntry],
                       serverNow: Int64, serverViewAge: Int64, retryAfter: Int64) throws -> V2AuthorPresentationDelta {
        let retryable = results.contains { if case .retryable = $0 { true } else { false } }
        return try .init(streamID: job.streamID, viewID: job.viewID, sequence: sequence, actorUserID: job.identity.userID,
            deviceID: job.identity.deviceID, serverViewAgeMilliseconds: serverViewAge,
            batch: .init(serverNowUnixMilliseconds: serverNow, results: results),
            retryAfterMilliseconds: retryable ? retryAfter : nil)
    }

    private func finishWrite(_ output: Output, result: V2AuthorPresentationWriteResult) {
        let job = output.job
        writes.removeValue(forKey: job.id)?.timer.cancel()
        if result == .temporarilyUnavailable, !closed, !Task.isCancelled, output.retries < 4,
           let connection = connections[job.connectionID], connection.streamID == job.streamID,
           connection.viewID == job.viewID, connection.viewGeneration == job.viewGeneration,
           output.refreshReceipts.allSatisfy({ connection.refresh[$0.key]?.id == $0.value }) {
            let readyAt = ContinuousClock.now + .milliseconds(10 << output.retries)
            if readyAt < job.deadline {
                // Keep the same bytes, sequence, lease timestamps, active key
                // and output charge. A deferred write owns no I/O task slot;
                // healthy sockets can pass it in this existing bounded queue.
                var retry = output; retry.readyAt = readyAt; retry.retries += 1
                outputs.append(retry); readDiagnostics.record(.writeDeferred)
                drain(); return
            }
        }
        // close discards queued bytes, but in-flight writers retain their accounting.
        outputBytes -= output.byteCost
        if !closed, var connection = connections[job.connectionID],
           connection.streamID == job.streamID, connection.viewID == job.viewID, connection.viewGeneration == job.viewGeneration {
            let delivered = !Task.isCancelled && result == .enqueued && job.deadline > .now
            if delivered { deliveredFrames += 1 }
            for (key, id) in output.refreshReceipts {
                guard var refresh = connection.refresh[key], refresh.id == id,
                      var delivery = refresh.delivery, delivery.sequence == output.sequence else { continue }
                delivery.written = delivered
                refresh.delivery = delivered ? delivery : nil
                connection.refresh[key] = delivered && delivery.acknowledged ? nil : refresh
            }
            for key in output.hints.keys {
                guard var hint = connection.hints[key], hint.sequence == output.sequence else { continue }
                if delivered, hint.deadline > .now {
                    hint.written = true; connection.hints[key] = hint
                } else {
                    connection.hints.removeValue(forKey: key); hintBytes -= hint.bytes
                }
            }
            connections[job.connectionID] = connection
            if connection.refresh.isEmpty { removeRefreshQueue(job.connectionID) }
        }
        release(job); drain()
    }

    private func stageHints(_ hints: [V2ProfileViewLookupKey: Hint], connectionID: UUID) {
        guard var connection = connections[connectionID] else { return }
        for (key, hint) in hints {
            if let old = connection.hints.removeValue(forKey: key) { hintBytes -= old.bytes }
            while connection.hints.count >= configuration.maximumHintsPerConnection {
                guard let oldest = connection.hints.min(by: { $0.value.touched < $1.value.touched }) else { break }
                connection.hints.removeValue(forKey: oldest.key); hintBytes -= oldest.value.bytes
            }
            if hintBytes <= configuration.maximumHintBytes - hint.bytes {
                connection.hints[key] = hint; hintBytes += hint.bytes
            }
        }
        connections[connectionID] = connection
    }
}
