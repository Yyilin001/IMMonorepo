import Foundation
import IMV2Core

public struct V2ProfilePresentationBatch: Sendable {
    public let presentations: [V2ProfileViewLookupKey: V2AuthorizedProfilePresentation]
    public let denials: [V2ProfileViewLookupKey: V2PresentationAuthorityVersion]
    public var unavailable: Set<V2ProfileViewLookupKey> { Set(denials.keys) }
    public let avatars: [V2ProfileViewLookupKey: V2ResourceAvatarAccess]
    public let retryable: Set<V2ProfileViewLookupKey>
    public let serverNow: Date
    public init(presentations: [V2ProfileViewLookupKey: V2AuthorizedProfilePresentation], denials: [V2ProfileViewLookupKey: V2PresentationAuthorityVersion], serverNow: Date, avatars: [V2ProfileViewLookupKey: V2ResourceAvatarAccess] = [:], retryable: Set<V2ProfileViewLookupKey> = []) {
        self.presentations = presentations; self.denials = denials; self.serverNow = serverNow; self.avatars = avatars; self.retryable = retryable
    }
}
public protocol V2ProfilePresentationReading: Sendable {
    func readPresentations(_ keys: [V2ProfileViewLookupKey]) async throws -> V2ProfilePresentationBatch
}
public struct V2ProfilePageActivation: Hashable, Sendable {
    fileprivate let id: UUID
    fileprivate let epoch: UUID
}
/// A visible row borrows its page's activation. Only the final row for a key
/// removes its interest; releasing an old token cannot affect a replacement.
public struct V2ProfileVisibleInterest: Hashable, Sendable {
    fileprivate let id: UUID
    fileprivate let activation: V2ProfilePageActivation
    public let key: V2ProfileViewLookupKey
}
public enum V2ProfilePresentationError: Error, Equatable, Sendable {
    case inactive, overloaded, invalidResponse, staleResponse, throttled(retryAfter: TimeInterval)
}

/// Binds one foreground page to a nonce created after that page activated.
/// It conveys no server authority by itself and cannot survive invalidation.
public struct V2ProfileAuthorBinding: Equatable, Sendable {
    fileprivate let id: UUID
    fileprivate let activations: Set<V2ProfilePageActivation>
    public let view: V2AuthorPresentationView
}

/// One atomic read of memory-only access. Consumers keep these deadlines and
/// revalidate the exact presentation/resource after asynchronous image work.
public struct V2ProfilePresentationSnapshot: Sendable {
    public let presentation: V2AuthorizedProfilePresentation
    public let deadline: ContinuousClock.Instant
    public let avatar: V2ResourceAvatarAccess?
    public let avatarDeadline: ContinuousClock.Instant?
}

/// Complete-context authorization cache. HTTP flights own their original demand
/// identities until actual completion; a pushed value never releases an I/O slot.
public actor V2ProfilePresentationRepository {
    public enum Priority: Int, Sendable { case visible = 0, prefetch = 1 }
    public enum DeliveryPreference: Equatable, Sendable { case http, authorStream }
    private enum ReadPolicy { case cached, refreshAvatar(replacing: V2ResourceAvatarAccess?) }
    private struct Access: Equatable {
        let presentation: V2AuthorizedProfilePresentation
        let deadline: ContinuousClock.Instant
        let bytes: Int
        let avatar: V2ResourceAvatarAccess?
        let avatarDeadline: ContinuousClock.Instant?
    }
    private struct Grant { var authorBindingID: UUID? }
    private struct Activation {
        let started: ContinuousClock.Instant
        var tracksVisibleRows = false
        var expectsAuthorDelivery = false
        var interests: Set<V2ProfileViewLookupKey> = []
        var visibleRows: [V2ProfileViewLookupKey: Set<UUID>] = [:]
        var invalidationRevisions: [V2ProfileViewLookupKey: UUID] = [:]
        var grants: [V2ProfileViewLookupKey: Grant] = [:]
        var observerID: UUID?
        var observer: AsyncStream<Void>.Continuation?
        var visibleObserverID: UUID?
        var visibleObserver: AsyncStream<Void>.Continuation?
    }
    private struct RevisionFloor {
        let profile: V2ProfileRevision, visibility: V2ProfileRevision
        let context: UInt64, observedAt: Int64
        let authority: V2PresentationAuthorityVersion
        let groupMember: V2GroupMemberPresentation?
        let contactAlias: V2ContactAlias?
        init(_ value: V2AuthorizedProfilePresentation, previous: RevisionFloor? = nil) {
            profile = value.view.revision; visibility = value.view.visibilityRevision
            context = value.lease.contextRevision; observedAt = value.lease.observedAtUnixMilliseconds
            authority = value.lease.authorityVersion
            // A hidden profile must omit nickname content, but that omission
            // must not erase a version already observed in this context.
            groupMember = value.view.state == .active ? value.groupMember : previous?.groupMember
            contactAlias = value.view.state == .active ? value.contactAlias : previous?.contactAlias
        }
    }
    private struct KeyState {
        let identity = UUID()
        var valueID = UUID()
        var deniedAt: ContinuousClock.Instant?
        var floor: RevisionFloor?
        var nicknameRevisionFloor: UInt64 = 0
        var aliasRevisionFloor: UInt64 = 0
        var retryUntil: ContinuousClock.Instant?
        var avatarRefreshNotBefore: ContinuousClock.Instant?
    }
    private struct Waiter {
        let activation: V2ProfilePageActivation
        let continuation: CheckedContinuation<V2AuthorizedProfilePresentation?, Error>
    }
    private struct Demand {
        let id = UUID()
        var priority: Priority
        var waiters: [UUID: Waiter]
        let authorFallbackAt: ContinuousClock.Instant
        var waitsForAuthor: Bool
    }
    private struct ReadKey: Sendable {
        let key: V2ProfileViewLookupKey
        let demandID: UUID
        let stateID: UUID
        let valueID: UUID
        let activations: Set<V2ProfilePageActivation>
    }
    private struct Flight {
        let keys: [ReadKey]
        let task: Task<Void, Never>
    }
    private struct Candidate {
        let bindingID: UUID
        var pendingActivations: Set<V2ProfilePageActivation>
        let entry: V2ReceivedAuthorPresentationEntry
        let access: Access?
        let expires: ContinuousClock.Instant
        let observed: ContinuousClock.Instant
        let cost: Int
    }
    private var localDisplayJournal: V2LocalProfileDisplayJournal?
    private var localDisplays: [V2ProfileViewLookupKey: V2LocalProfileDisplay] = [:]
    private var localBasics: [UserID: V2LocalProfileDisplayBasics] = [:]
    private var locallyDeniedKeys: Set<V2ProfileViewLookupKey> = []
    private var locallyDeniedUsers: Set<UserID> = []
    private var displayObservers: [UUID: AsyncStream<V2LocalProfileDisplaySnapshot>.Continuation] = [:]
    private let actorUserID: UserID
    private let deviceID: DeviceID
    private let reader: any V2ProfilePresentationReading
    private let aliasRevisions: (@Sendable (Set<V2ProfileViewLookupKey>) async throws -> [V2ProfileViewLookupKey: UInt64])?
    private let nicknameRevisions: (@Sendable (Set<V2ProfileViewLookupKey>) async throws -> [V2ProfileViewLookupKey: UInt64])?
    private let clock = ContinuousClock()
    private let retryJitter: @Sendable () -> TimeInterval
    private var throttleUntil: ContinuousClock.Instant?
    private var epoch = UUID()
    private var activations: [UUID: Activation] = [:]
    private var states: [V2ProfileViewLookupKey: KeyState] = [:]
    private var access: [V2ProfileViewLookupKey: Access] = [:]
    private var negative: [V2ProfileViewLookupKey: ContinuousClock.Instant] = [:]
    private var demand: [V2ProfileViewLookupKey: Demand] = [:]
    private var inFlight: Set<V2ProfileViewLookupKey> = []
    private var tasks: [UUID: Flight] = [:]
    private var mergeTask: Task<Void, Never>?
    private var mergeID: UUID?
    private var mergeDeadline: ContinuousClock.Instant?
    private var binding: V2ProfileAuthorBinding?
    private var retiredAuthorPages: Set<V2ProfilePageActivation> = []
    // Keep the nonce's original page set after unbinding as well: dropping a
    // binding must not make that nonce reusable to authorize a different page.
    private var lastBoundView: (view: V2AuthorPresentationView, pages: Set<V2ProfilePageActivation>)?
    private var candidates: [V2ProfileViewLookupKey: Candidate] = [:]
    private var candidateBytes = 0
    private var visibleRows = 0
    private var cachedVisibleRows: [UUID: (token: V2ProfileVisibleInterest, retainedAt: ContinuousClock.Instant)] = [:]
    private var authorNotBefore: ContinuousClock.Instant?
    private var authorDenials: [V2ProfileViewLookupKey: V2PresentationAuthorityVersion] = [:]
    private var bytes = 0
    private var closed = false
    private let maximumEntries = 2_000
    private let maximumBytes = 2 * 1_024 * 1_024

    public init(actorUserID: UserID, deviceID: DeviceID, reader: any V2ProfilePresentationReading,
                nicknameRevisions: (@Sendable (Set<V2ProfileViewLookupKey>) async throws -> [V2ProfileViewLookupKey: UInt64])? = nil,
                aliasRevisions: (@Sendable (Set<V2ProfileViewLookupKey>) async throws -> [V2ProfileViewLookupKey: UInt64])? = nil,
                localDisplayJournal: V2LocalProfileDisplayJournal? = nil) {
        self.actorUserID = actorUserID; self.deviceID = deviceID; self.reader = reader
        self.nicknameRevisions = nicknameRevisions
        self.aliasRevisions = aliasRevisions
        self.localDisplayJournal = localDisplayJournal
        retryJitter = { Double.random(in: 0.1...0.5) }
    }
    init(actorUserID: UserID, deviceID: DeviceID, reader: any V2ProfilePresentationReading,
         retryJitter: @escaping @Sendable () -> TimeInterval) {
        self.actorUserID = actorUserID; self.deviceID = deviceID; self.reader = reader; self.retryJitter = retryJitter
        nicknameRevisions = nil; aliasRevisions = nil
    }
    /// Restored before publishing the signed-in UI. Expiring server grants and
    /// account-local display facts deliberately have different lifetimes.
    public func restoreLocalDisplay() throws -> V2LocalProfileDisplaySnapshot {
        guard !closed else { throw V2ProfilePresentationError.inactive }
        if let localDisplayJournal {
            let value = try localDisplayJournal.load()
            localDisplays = value.records; localBasics = value.basics; locallyDeniedKeys = value.deniedKeys; locallyDeniedUsers = value.deniedUsers
        }
        let snapshot = localDisplaySnapshot()
        for observer in displayObservers.values { observer.yield(snapshot) }
        return snapshot
    }
    public func localDisplayUpdates() throws -> AsyncStream<V2LocalProfileDisplaySnapshot> {
        guard !closed else { throw V2ProfilePresentationError.inactive }
        guard displayObservers.count < 8 else { throw V2ProfilePresentationError.overloaded }
        let id = UUID(), stream = AsyncStream<V2LocalProfileDisplaySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream.continuation.onTermination = { [weak self] _ in Task { await self?.removeDisplayObserver(id) } }
        displayObservers[id] = stream.continuation; stream.continuation.yield(localDisplaySnapshot())
        return stream.stream
    }
    private func removeDisplayObserver(_ id: UUID) { displayObservers[id] = nil }
    private func localDisplaySnapshot() -> V2LocalProfileDisplaySnapshot {
        .init(records: localDisplays, deniedKeys: locallyDeniedKeys, deniedUsers: locallyDeniedUsers, basics: localBasics)
    }
    private func publishLocalDisplay() {
        let value = localDisplaySnapshot()
        for observer in displayObservers.values { observer.yield(value) }
    }
    private func saveLocalDisplay(_ presentation: V2AuthorizedProfilePresentation) throws {
        let key = presentation.lease.key
        guard let value = V2LocalProfileDisplay(presentation) else {
            try denyLocalDisplay(key, globally: true); return
        }
        if let previous = localDisplays[key], !value.supersedes(previous) { return }
        let basic = try localDisplayJournal?.save(value) ?? V2LocalProfileDisplayBasics(value, previous: localBasics[key.userID])
        localBasics[key.userID] = basic
        if localBasics.count > 2000, let oldest = localBasics.keys.first { localBasics[oldest] = nil }
        localDisplays[key] = value; locallyDeniedKeys.remove(key); locallyDeniedUsers.remove(key.userID)
        if localDisplays.count > 2000, let oldest = localDisplays.min(by: { $0.value.observedAt < $1.value.observedAt })?.key {
            localDisplays[oldest] = nil
        }
        publishLocalDisplay()
    }
    private func denyLocalDisplay(_ key: V2ProfileViewLookupKey, globally: Bool = false) throws {
        // Persist denial before publishing removal. Resource/lease invalidation
        // is separate; renewal and ordinary content invalidation keep old facts.
        try localDisplayJournal?.deny(key, globally: globally)
        if globally {
            localDisplays = localDisplays.filter { $0.key.userID != key.userID }
            localBasics[key.userID] = nil
            locallyDeniedUsers.insert(key.userID)
        } else { localDisplays[key] = nil; locallyDeniedKeys.insert(key) }
        publishLocalDisplay()
    }

    public func activate() -> V2ProfilePageActivation {
        activate(tracksVisibleRows: false)
    }
    /// Shared by a foreground page. Reads require a retained visible row.
    /// Declare an intended author stream before exposing the activation to UI
    /// reads; starting its coordinator in another task can race the HTTP batch.
    /// This preference grants no access and keeps the ordinary bounded fallback.
    public func activateVisiblePage(delivery: DeliveryPreference = .http) -> V2ProfilePageActivation {
        activate(tracksVisibleRows: true, delivery: delivery)
    }
    private func activate(tracksVisibleRows: Bool, delivery: DeliveryPreference = .http) -> V2ProfilePageActivation {
        let token = V2ProfilePageActivation(id: UUID(), epoch: epoch)
        if !closed, activations.count < 256 {
            activations[token.id] = .init(started: clock.now, tracksVisibleRows: tracksVisibleRows,
                expectsAuthorDelivery: delivery == .authorStream)
        }
        return token
    }
    public func deactivate(_ activation: V2ProfilePageActivation) {
        guard activation.epoch == epoch else { return }
        if let removed = activations.removeValue(forKey: activation.id) {
            visibleRows -= removed.visibleRows.values.reduce(0) { $0 + $1.count }
            cachedVisibleRows = cachedVisibleRows.filter { $0.value.token.activation != activation }
            removed.observer?.finish()
            removed.visibleObserver?.finish()
        }
        if let binding, liveActivations(in: binding).isEmpty { self.binding = nil; clearCandidates() }
        pruneCandidates()
        removeWaiters { $0.activation == activation }
        evictUnreferencedAccess()
    }
    public func invalidate(_ keys: Set<V2ProfileViewLookupKey>) {
        invalidate(keys, fenceAuthorView: true)
    }

    /// A committed own-field edit invalidates tracked presentations; it never
    /// constructs or extends another user's display authorization from a receipt.
    public func invalidateEditedName(_ target: V2NameTarget) {
        let tracked = Set(states.keys).union(access.keys).union(candidates.keys).union(demand.keys)
        let keys = tracked.filter { key in
            switch target {
            case .contact(let user): return key.userID == user
            case .group(let room): return key.userID == actorUserID && key.context == .room(room)
            }
        }
        invalidate(Set(keys), fenceAuthorView: true)
    }

    private func invalidate(_ keys: Set<V2ProfileViewLookupKey>, fenceAuthorView: Bool) {
        for key in keys {
            removeCandidate(key)
            removeAccess(key); negative.removeValue(forKey: key)
            if states[key] != nil {
                // Always fence old HTTP. A content-only nickname floor still lets
                // the current nonce deliver the required version; existing privacy
                // denials keep their own observation fence.
                let floor = states[key]?.floor
                let nicknameFloor = states[key]?.nicknameRevisionFloor ?? 0
                let aliasFloor = states[key]?.aliasRevisionFloor ?? 0
                let deniedAt = fenceAuthorView ? clock.now : states[key]?.deniedAt
                states[key] = .init(deniedAt: deniedAt, floor: floor, nicknameRevisionFloor: nicknameFloor, aliasRevisionFloor: aliasFloor)
            } else if fenceAuthorView { fenceUntrackedAuthor(key, at: clock.now) }
            revokeGrants(key, includeInterests: true)
            complete(key, result: .failure(V2ProfilePresentationError.inactive))
        }
        cancelUnusedFlights()
    }

    /// Projection notifications are hints: read durable floors only for the bounded
    /// set already tracked by this account, and notify only authors whose content is stale.
    public func refreshNicknameInvalidations() async throws {
        let capturedEpoch = epoch
        let keys = Set(states.keys).union(candidates.keys)
        do { try await refreshPresentationFloors(keys) }
        catch {
            if !closed, capturedEpoch == epoch { invalidate(keys) }
            throw error
        }
    }

    @discardableResult
    private func refreshNicknameFloors(_ keys: Set<V2ProfileViewLookupKey>) async throws -> [V2ProfileViewLookupKey: UInt64] {
        guard let nicknameRevisions, !keys.isEmpty else { return [:] }
        guard !closed, keys.count <= 2_064 else { throw V2ProfilePresentationError.inactive }
        let capturedEpoch = epoch
        let values = try await nicknameRevisions(keys)
        guard !closed, capturedEpoch == epoch else { throw V2ProfilePresentationError.inactive }
        guard Set(values.keys) == keys, values.values.allSatisfy({ $0 <= UInt64(Int64.max) }) else {
            throw V2ProfilePresentationError.invalidResponse
        }
        var stale = Set<V2ProfileViewLookupKey>()
        for (key, revision) in values {
            let minimum = max(revision, states[key]?.nicknameRevisionFloor ?? 0)
            states[key]?.nicknameRevisionFloor = minimum
            if let candidate = candidates[key]?.access, !meetsNicknameFloor(candidate.presentation, minimum: minimum) {
                removeCandidate(key)
            }
            if let cached = access[key], !meetsNicknameFloor(cached.presentation, minimum: minimum) { stale.insert(key) }
        }
        invalidate(stale, fenceAuthorView: false)
        return values
    }

    public func refreshAliasInvalidations() async throws {
        let capturedEpoch = epoch
        let keys = Set(states.keys).union(candidates.keys)
        do { try await refreshPresentationFloors(keys) }
        catch {
            if !closed, capturedEpoch == epoch { invalidate(keys) }
            throw error
        }
    }

    @discardableResult
    private func refreshPresentationFloors(_ keys: Set<V2ProfileViewLookupKey>) async throws -> (nicknames: [V2ProfileViewLookupKey: UInt64], aliases: [V2ProfileViewLookupKey: UInt64]) {
        let nicknames = try await refreshNicknameFloors(keys)
        guard let aliasRevisions, !keys.isEmpty else { return (nicknames, [:]) }
        guard !closed, keys.count <= 2_064 else { throw V2ProfilePresentationError.inactive }
        let capturedEpoch = epoch
        let values = try await aliasRevisions(keys)
        guard !closed, capturedEpoch == epoch else { throw V2ProfilePresentationError.inactive }
        guard Set(values.keys) == keys, values.values.allSatisfy({ $0 <= UInt64(Int64.max) }) else {
            throw V2ProfilePresentationError.invalidResponse
        }
        var stale = Set<V2ProfileViewLookupKey>()
        for (key, revision) in values {
            let minimum = max(revision, states[key]?.aliasRevisionFloor ?? 0)
            states[key]?.aliasRevisionFloor = minimum
            if let candidate = candidates[key]?.access, !meetsAliasFloor(candidate.presentation, minimum: minimum) {
                removeCandidate(key)
            }
            if let cached = access[key], !meetsAliasFloor(cached.presentation, minimum: minimum) { stale.insert(key) }
        }
        invalidate(stale, fenceAuthorView: false)
        return (nicknames, values)
    }

    private func meetsAliasFloor(_ value: V2AuthorizedProfilePresentation, minimum: UInt64) -> Bool {
        value.view.state != .active || (value.contactAlias?.revision.rawValue ?? 0) >= minimum
    }
    private func meetsNicknameFloor(_ value: V2AuthorizedProfilePresentation, minimum: UInt64) -> Bool {
        value.view.state != .active || (value.groupMember?.revision.rawValue ?? 0) >= minimum
    }
    public func endAllActivations() {
        for activation in activations.values {
            activation.observer?.finish(); activation.visibleObserver?.finish()
        }
        epoch = UUID(); binding = nil; lastBoundView = nil; retiredAuthorPages.removeAll(); clearCandidates(); visibleRows = 0; cachedVisibleRows.removeAll(); authorNotBefore = nil; authorDenials.removeAll()
        activations.removeAll(); access.removeAll(); states.removeAll(); negative.removeAll(); bytes = 0
        removeWaiters { _ in true }
        mergeTask?.cancel(); mergeTask = nil; mergeID = nil; mergeDeadline = nil
        for flight in tasks.values { flight.task.cancel() }
    }
    public func close() async {
        closed = true; endAllActivations()
        localDisplays.removeAll(); localBasics.removeAll(); locallyDeniedKeys.removeAll(); locallyDeniedUsers.removeAll()
        for observer in displayObservers.values { observer.finish() }; displayObservers.removeAll()
        let running = Array(tasks.values)
        for flight in running { await flight.task.value }
    }

    /// Subscribe before reading. One bounded observer per activation; old stream
    /// termination cannot remove its replacement.
    public func invalidations(for activation: V2ProfilePageActivation) throws -> AsyncStream<Void> {
        try requireActive(activation)
        activations[activation.id]?.observer?.finish()
        let id = UUID(), stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream.continuation.onTermination = { [weak self] _ in
            Task { await self?.stopObserving(activation, id: id) }
        }
        activations[activation.id]?.observerID = id; activations[activation.id]?.observer = stream.continuation
        return stream.stream
    }
    private func stopObserving(_ activation: V2ProfilePageActivation, id: UUID) {
        guard activation.epoch == epoch, activations[activation.id]?.observerID == id else { return }
        activations[activation.id]?.observer = nil; activations[activation.id]?.observerID = nil
    }
    private func requireActive(_ activation: V2ProfilePageActivation) throws {
        guard !closed, activation.epoch == epoch, activations[activation.id] != nil else { throw V2ProfilePresentationError.inactive }
    }

    /// Independent of invalidation observers used by the UI. Subscribe and
    /// enqueue the initial signal atomically; consumers read a complete latest
    /// snapshot, so coalescing signals never loses a remove or an add.
    public func visibleAuthorChanges(for activation: V2ProfilePageActivation) throws -> AsyncStream<Void> {
        try requireActive(activation)
        activations[activation.id]?.visibleObserver?.finish()
        let id = UUID(), pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeVisibleObserver(activation, id: id) }
        }
        activations[activation.id]?.visibleObserverID = id
        activations[activation.id]?.visibleObserver = pair.continuation
        pair.continuation.yield(())
        return pair.stream
    }

    private func removeVisibleObserver(_ activation: V2ProfilePageActivation, id: UUID) {
        guard activation.epoch == epoch, activations[activation.id]?.visibleObserverID == id else { return }
        activations[activation.id]?.visibleObserverID = nil
        activations[activation.id]?.visibleObserver = nil
    }

    /// Complete lookup identity for all bound pages. The transport applies its
    /// connection-level interest admission limit separately from read batching.
    public func visibleProfileKeys(for pages: Set<V2ProfilePageActivation>) throws -> [V2ProfileViewLookupKey] {
        var keys = Set<V2ProfileViewLookupKey>()
        for page in pages {
            try requireActive(page)
            keys.formUnion(activations[page.id]?.visibleRows.keys ?? Dictionary<V2ProfileViewLookupKey, Set<UUID>>().keys)
        }
        return keys.sorted { Self.authorKeyOrder($0) < Self.authorKeyOrder($1) }
    }
    private static func authorKeyOrder(_ key: V2ProfileViewLookupKey) -> String {
        let scope: String
        switch key.context {
        case .relationship: scope = "0"
        case .directConversation: scope = "1"
        case .room(let room): scope = "2" + room.rawValue
        case .groupJoinReview(let room): scope = "3" + room.rawValue
        }
        return scope + ":" + key.userID.rawValue
    }

    public func visibleAuthorIDs(for activation: V2ProfilePageActivation, roomID: RoomID) throws -> [UserID] {
        try requireActive(activation)
        let keys = activations[activation.id]?.visibleRows.keys ?? Dictionary<V2ProfileViewLookupKey, Set<UUID>>().keys
        return keys.filter { $0.context == .room(roomID) }.map(\.userID).sorted { $0.rawValue < $1.rawValue }
    }

    public func retainVisibleInterest(for key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation) throws -> V2ProfileVisibleInterest {
        try retainVisibleInterest(for: key, activation: activation, cached: false)
    }

    /// An offscreen snapshot may retain a best-effort subscription, but must
    /// yield its budget to actual visible rows on any page of this account.
    public func retainCachedVisibleInterest(for key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation) throws -> V2ProfileVisibleInterest {
        try retainVisibleInterest(for: key, activation: activation, cached: true)
    }

    private func retainVisibleInterest(for key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation, cached: Bool) throws -> V2ProfileVisibleInterest {
        try Task.checkCancellation(); try requireActive(activation)
        guard activations[activation.id]?.tracksVisibleRows == true else { throw V2ProfilePresentationError.inactive }
        if !cached { makeRoomForVisibleInterest(key) }
        let visibleKeys = activations.values.reduce(into: Set<V2ProfileViewLookupKey>()) { $0.formUnion($1.visibleRows.keys) }
        guard visibleKeys.contains(key) || visibleKeys.count < V2AuthorPresentationInterests.maximumAuthors else {
            throw V2ProfilePresentationError.overloaded
        }
        guard visibleRows < 512,
              activations[activation.id]?.visibleRows[key] != nil ||
                (activations[activation.id]?.visibleRows.count ?? 0) < V2AuthorPresentationInterests.maximumAuthors else {
            throw V2ProfilePresentationError.overloaded
        }
        try registerInterest(key, activation: activation)
        let token = V2ProfileVisibleInterest(id: UUID(), activation: activation, key: key)
        if cached { cachedVisibleRows[token.id] = (token, clock.now) }
        activations[activation.id]?.visibleRows[key, default: []].insert(token.id)
        visibleRows += 1
        if activations[activation.id]?.visibleRows[key]?.count == 1 {
            activations[activation.id]?.visibleObserver?.yield(())
        }
        return token
    }

    private func makeRoomForVisibleInterest(_ key: V2ProfileViewLookupKey) {
        while !cachedVisibleRows.isEmpty {
            let keys = activations.values.reduce(into: Set<V2ProfileViewLookupKey>()) { $0.formUnion($1.visibleRows.keys) }
            let needsKey = !keys.contains(key) && keys.count >= V2AuthorPresentationInterests.maximumAuthors
            guard needsKey || visibleRows >= 512 else { return }
            let cached = cachedVisibleRows.values.sorted { $0.retainedAt < $1.retainedAt }
            if needsKey {
                guard let victim = cached.first(where: { candidate in
                    activations.values.allSatisfy { page in
                        (page.visibleRows[candidate.token.key] ?? []).allSatisfy { cachedVisibleRows[$0] != nil }
                    }
                })?.token.key else { return }
                for entry in cached where entry.token.key == victim { releaseVisibleInterest(entry.token) }
            } else if let victim = cached.first { releaseVisibleInterest(victim.token) }
        }
    }
    public func releaseVisibleInterest(_ token: V2ProfileVisibleInterest) {
        let activation = token.activation, key = token.key
        guard activation.epoch == epoch,
              activations[activation.id]?.visibleRows[key]?.remove(token.id) != nil else { return }
        cachedVisibleRows.removeValue(forKey: token.id)
        visibleRows -= 1
        guard activations[activation.id]?.visibleRows[key]?.isEmpty == true else { return }
        activations[activation.id]?.visibleRows.removeValue(forKey: key)
        activations[activation.id]?.visibleObserver?.yield(())
        activations[activation.id]?.interests.remove(key)
        activations[activation.id]?.invalidationRevisions.removeValue(forKey: key)
        complete(key, activation: activation, result: .failure(CancellationError()))
        cancelUnusedFlights(); evictUnreferencedAccess()
    }
    /// Complete bounded snapshot, so coalescing Void notifications cannot lose
    /// an invalidation for one key while a different key changes next.
    public func invalidationRevisions(for activation: V2ProfilePageActivation) throws -> [V2ProfileViewLookupKey: UUID] {
        try requireActive(activation)
        return activations[activation.id]?.invalidationRevisions ?? [:]
    }
    private func registerInterest(_ key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation) throws {
        try requireActive(activation)
        guard let active = activations[activation.id] else { throw V2ProfilePresentationError.inactive }
        if states[key] == nil, states.count >= maximumEntries { evictUnusedGrant() }
        guard (active.interests.contains(key) || active.interests.count < 256),
              states[key] != nil || states.count < maximumEntries else { throw V2ProfilePresentationError.overloaded }
        activations[activation.id]?.interests.insert(key)
        if states[key] == nil { states[key] = .init() }
    }

    public func cachedSnapshot(for key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation) async -> V2ProfilePresentationSnapshot? {
        guard activation.epoch == epoch, activations[activation.id]?.grants[key] != nil, access[key] != nil else { return nil }
        do { try await refreshPresentationFloors([key]) }
        catch { if activation.epoch == epoch { invalidate([key]) }; return nil }
        return currentSnapshot(for: key, activation: activation)
    }
    private func currentSnapshot(for key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation) -> V2ProfilePresentationSnapshot? {
        guard !closed, activation.epoch == epoch, activations[activation.id]?.grants[key] != nil,
              activations[activation.id]?.tracksVisibleRows != true || activations[activation.id]?.interests.contains(key) == true,
              let value = access[key], value.deadline > clock.now else { return nil }
        let avatarIsLive = value.avatarDeadline.map { $0 > clock.now } ?? false
        return .init(presentation: value.presentation, deadline: value.deadline,
            avatar: avatarIsLive ? value.avatar : value.avatar?.withoutDownloadPlan(), avatarDeadline: avatarIsLive ? value.avatarDeadline : nil)
    }
    public func cachedPresentation(for key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation) async -> V2AuthorizedProfilePresentation? {
        await cachedSnapshot(for: key, activation: activation)?.presentation
    }
    public func authorizationDeadline(for key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation) async -> ContinuousClock.Instant? {
        await cachedSnapshot(for: key, activation: activation)?.deadline
    }
    public func avatarReadGrant(for key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation) async -> V2AvatarReadGrant? {
        guard let snapshot = await cachedSnapshot(for: key, activation: activation), let avatar = snapshot.avatar,
              let valueID = states[key]?.valueID else { return nil }
        return .init(avatar: avatar, home: .account(key.userID), deadline: snapshot.deadline,
            downloadDeadline: snapshot.avatarDeadline) { [weak self] in
                guard let self else { return false }
                return await self.validateAvatarRead(key, activation: activation, valueID: valueID, avatar: avatar)
            }
    }

    private func validateAvatarRead(_ key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation,
                                   valueID: UUID, avatar: V2ResourceAvatarAccess) async -> Bool {
        guard let current = await cachedSnapshot(for: key, activation: activation),
              states[key]?.valueID == valueID else { return false }
        return current.avatar?.hasSameContent(as: avatar) == true
    }

    public func presentation(for key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation, priority: Priority = .visible) async throws -> V2AuthorizedProfilePresentation? {
        try await readPresentation(for: key, activation: activation, priority: priority, policy: .cached)
    }

    /// Refreshes through the same bounded, authorized batch queue. Existing
    /// display grants remain valid until their own deadline or a real denial.
    public func refreshAvatarReadGrant(for key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation,
                                      replacing avatar: V2ResourceAvatarAccess?) async throws -> V2AvatarReadGrant? {
        _ = try await readPresentation(for: key, activation: activation, priority: .visible, policy: .refreshAvatar(replacing: avatar))
        return await avatarReadGrant(for: key, activation: activation)
    }

    private func readPresentation(for key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation,
                                  priority: Priority, policy: ReadPolicy) async throws -> V2AuthorizedProfilePresentation? {
        try Task.checkCancellation()
        if activations[activation.id]?.tracksVisibleRows == true,
           activations[activation.id]?.visibleRows[key]?.isEmpty != false { throw V2ProfilePresentationError.inactive }
        try registerInterest(key, activation: activation)
        try await refreshPresentationFloors([key])
        try Task.checkCancellation(); try requireActive(activation)
        try promoteCandidate(key, activation: activation)
        if let cached = currentSnapshot(for: key, activation: activation) {
            switch policy {
            case .cached: return cached.presentation
            case .refreshAvatar(let previous):
                let sameContent = previous.flatMap { old in cached.avatar.map { $0.hasSameContent(as: old) } } ?? false
                // Merely stripping an expired URL is not a completed refresh.
                if cached.presentation.view.avatar == nil ||
                    (cached.avatar != previous && (!sameContent || cached.avatar?.plan != nil)) { return cached.presentation }
            }
        }
        if let until = negative[key], until > clock.now { return nil }
        if let until = states[key]?.retryUntil, until > clock.now { throw V2ProfilePresentationError.throttled(retryAfter: seconds(until)) }
        if let throttled = throttlingError() { throw throttled }
        guard (demand[key] != nil || demand.count < 256),
              demand.values.reduce(0, { $0 + $1.waiters.count }) < 512 else { throw V2ProfilePresentationError.overloaded }
        if case .refreshAvatar = policy, demand[key] == nil {
            if let until = states[key]?.avatarRefreshNotBefore, until > clock.now {
                throw V2ProfilePresentationError.throttled(retryAfter: seconds(until))
            }
            states[key]?.avatarRefreshNotBefore = clock.now + .seconds(2 + retryJitter())
        }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let proposedJitter = retryJitter()
                let jitter = proposedJitter.isFinite ? min(0.5, max(0, proposedJitter)) : 0.25
                var item = demand[key] ?? Demand(priority: priority, waiters: [:],
                    authorFallbackAt: clock.now + .seconds(2 + jitter), waitsForAuthor: true)
                if case .refreshAvatar = policy { item.waitsForAuthor = false }
                if priority.rawValue < item.priority.rawValue { item.priority = priority }
                item.waiters[waiter] = Waiter(activation: activation, continuation: continuation)
                demand[key] = item; schedule()
            }
        } onCancel: { Task { await self.cancelWaiter(waiter, key: key) } }
    }

    /// Every participating page activates before the connection creates its
    /// nonce. Joining a later page requires a fresh nonce and a new binding.
    public func bindAuthorView(_ view: V2AuthorPresentationView, activation: V2ProfilePageActivation) throws -> V2ProfileAuthorBinding {
        try bindAuthorView(view, activations: [activation])
    }

    /// The page coordinator declares its incoming stream before awaiting room
    /// subscription I/O. A demand's deadline is fixed when it starts; reconnects
    /// and nonce renewal cannot postpone its HTTP fallback indefinitely.
    func expectAuthorDelivery(for page: V2ProfilePageActivation) throws {
        try requireActive(page)
        activations[page.id]?.expectsAuthorDelivery = true
    }

    func endAuthorDelivery(for page: V2ProfilePageActivation) {
        activations[page.id]?.expectsAuthorDelivery = false
        schedule()
    }

    public func bindAuthorView(_ view: V2AuthorPresentationView,
                               activations pages: Set<V2ProfilePageActivation>) throws -> V2ProfileAuthorBinding {
        try Task.checkCancellation()
        guard !pages.isEmpty, pages.count <= 256, view.renewBy > clock.now else { throw V2ProfilePresentationError.inactive }
        for page in pages {
            try requireActive(page)
            guard let active = activations[page.id], active.started <= view.started else { throw V2ProfilePresentationError.inactive }
        }
        if let previous = lastBoundView {
            if previous.view == view {
                guard pages.isSubset(of: previous.pages), pages.isDisjoint(with: retiredAuthorPages) else { throw V2ProfilePresentationError.inactive }
            } else {
                guard view.started > previous.view.started else { throw V2ProfilePresentationError.inactive }
            }
        }
        let next = V2ProfileAuthorBinding(id: UUID(), activations: pages, view: view)
        if let previous = binding {
            // An unchanged page may retain an already-issued display lease
            // during nonce renewal. Newly joined pages receive no copied grant.
            for page in previous.activations {
                for (key, grant) in activations[page.id]?.grants ?? [:] where grant.authorBindingID == previous.id {
                    if pages.contains(page) {
                        activations[page.id]?.grants[key]?.authorBindingID = next.id
                    } else {
                        activations[page.id]?.grants.removeValue(forKey: key)
                        notify(key, activationID: page.id)
                    }
                }
            }
        }
        clearCandidates(); binding = next; lastBoundView = (view, pages); retiredAuthorPages.removeAll()
        evictUnreferencedAccess(); return next
    }

    public func unbindAuthorView(_ ending: V2ProfileAuthorBinding) {
        guard binding == ending else { return }
        clearCandidates(); binding = nil
        for page in ending.activations {
            for (key, grant) in activations[page.id]?.grants ?? [:] where grant.authorBindingID == ending.id {
                activations[page.id]?.grants.removeValue(forKey: key)
                notify(key, activationID: page.id)
            }
        }
        evictUnreferencedAccess()
        schedule()
    }

    /// Retire one page before its socket work drains. Other pages retain their
    /// independently issued grants and HTTP ownership is left to the caller.
    public func detachAuthorPage(_ page: V2ProfilePageActivation) {
        guard let binding, binding.activations.contains(page) else { return }
        retiredAuthorPages.insert(page)
        for (key, grant) in activations[page.id]?.grants ?? [:] where grant.authorBindingID == binding.id {
            activations[page.id]?.grants.removeValue(forKey: key)
            notify(key, activationID: page.id)
        }
        pruneCandidates(); evictUnreferencedAccess()
        schedule()
    }

    private func liveActivations(in binding: V2ProfileAuthorBinding) -> Set<V2ProfilePageActivation> {
        binding.activations.filter { $0.epoch == epoch && activations[$0.id] != nil && !retiredAuthorPages.contains($0) }
    }

    /// Deltas retain receiver-created monotonic deadlines. In-flight HTTP success
    /// cannot overwrite an accepted delta. Versioned denials retain a floor
    /// across transports; only a newer authority observation can restore access.
    @discardableResult
    public func ingest(_ delta: V2ReceivedAuthorPresentationDelta, binding expected: V2ProfileAuthorBinding) async throws -> V2AuthorPresentationReceipt? {
        try Task.checkCancellation()
        guard !liveActivations(in: expected).isEmpty, binding == expected, delta.view == expected.view, expected.view.renewBy > clock.now else {
            throw V2ProfilePresentationError.inactive
        }
        guard delta.sequence > 0, delta.sequence <= UInt64(Int64.max),
              delta.entries.count <= V2AuthorPresentationDelta.maximumEntries else { throw V2ProfilePresentationError.invalidResponse }
        var prepared: [V2ProfileViewLookupKey: Access] = [:]
        var seen = Set<V2ProfileViewLookupKey>()
        // Validate the entire frame before making any visible mutation.
        for entry in delta.entries {
            let key = entry.key
            guard seen.insert(key).inserted, key.userID.uuidValue != nil,
                  key.context.authorizationRoomID.map({ $0.uuidValue != nil }) ?? true else { throw V2ProfilePresentationError.invalidResponse }
            if case .presentation(let value, let avatar, let deadline, let byteDeadline) = entry {
                try validate(value, key: key)
                guard deadline <= expected.view.renewBy + .milliseconds(V2PresentationAccessLease.maximumLifetimeMilliseconds),
                      avatar == nil || avatar?.mediaID == value.view.avatar?.mediaID,
                      (avatar?.plan != nil) == (byteDeadline != nil),
                      byteDeadline.map({ $0 <= deadline }) ?? true else { throw V2ProfilePresentationError.invalidResponse }
                if deadline > clock.now {
                    let usableAvatar = byteDeadline.map { $0 > clock.now } == true ? avatar : avatar?.withoutDownloadPlan()
                    prepared[key] = try makeAccess(value, deadline: deadline, avatar: usableAvatar, avatarDeadline: usableAvatar?.plan == nil ? nil : byteDeadline)
                }
            }
        }
        let floors = try await refreshPresentationFloors(seen)
        try Task.checkCancellation()
        let pages = liveActivations(in: expected)
        guard !pages.isEmpty, binding == expected, expected.view.renewBy > clock.now else { throw V2ProfilePresentationError.inactive }
        let interests = pages.reduce(into: Set<V2ProfileViewLookupKey>()) { $0.formUnion(activations[$1.id]?.interests ?? []) }
        pruneCandidates()
        for entry in delta.entries {
            let key = entry.key
            if case .presentation(let value, _, _, _) = entry,
               (!meetsNicknameFloor(value, minimum: floors.nicknames[key] ?? 0) || !meetsAliasFloor(value, minimum: floors.aliases[key] ?? 0)) { continue }
            let interested = pages.filter { activations[$0.id]?.interests.contains(key) == true }
            let pending = pages.subtracting(interested).filter { activations[$0.id]?.tracksVisibleRows == true }
            if !interested.isEmpty {
                try applyAuthorEntry(entry, access: prepared[key], binding: expected, pages: interested)
            }
            if !pending.isEmpty {
                try stageCandidate(entry, access: prepared[key], binding: expected, pages: pending)
            } else { removeCandidate(key) }
        }
        cancelUnusedFlights()
        // Staged candidates may be discarded before a row becomes visible. Only
        // acknowledge a still-live presentation or denial actually installed in
        // this page. Rejected, obsolete and expired entries remain recoverable.
        let receiptAt = clock.now
        let retained = delta.entries.compactMap { entry -> (V2ProfileViewLookupKey, ContinuousClock.Instant)? in
            if case .unavailable(_, let until) = entry {
                guard interests.contains(entry.key), let deniedUntil = negative[entry.key],
                      min(until, deniedUntil) > receiptAt else { return nil }
                return (entry.key, min(until, deniedUntil))
            }
            guard case .presentation(let value, _, _, _) = entry,
                  pages.contains(where: { activations[$0.id]?.grants[entry.key]?.authorBindingID == expected.id }),
                  let stored = access[entry.key], stored.deadline > clock.now,
                  stored.presentation == value else { return nil }
            return (entry.key, stored.deadline)
        }
        guard let minimum = retained.map({ $0.1 }).min() else { return nil }
        let remaining = receiptAt.duration(to: minimum).components
        let milliseconds = min(V2PresentationAccessLease.maximumLifetimeMilliseconds,
            max(0, remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000))
        return try .init(streamID: delta.view.streamID, viewID: delta.view.viewID,
                         sequence: delta.sequence, keys: retained.map { $0.0 },
                         minimumRemainingMilliseconds: milliseconds)
    }

    private func authorityCanGrant(_ version: V2PresentationAuthorityVersion, for key: V2ProfileViewLookupKey) -> Bool {
        (states[key]?.floor.map { version.isAtLeast($0.authority) } ?? true)
            && (authorDenials[key].map { version.isAtLeast($0) && version != $0 } ?? true)
    }
    private func authorCanGrant(_ key: V2ProfileViewLookupKey, binding expected: V2ProfileAuthorBinding,
                                version: V2PresentationAuthorityVersion) -> Bool {
        (authorNotBefore.map { expected.view.started > $0 } ?? true)
            && (states[key]?.deniedAt.map { expected.view.started > $0 } ?? true)
            && authorityCanGrant(version, for: key)
    }
    private func applyAuthorEntry(_ entry: V2ReceivedAuthorPresentationEntry, access value: Access?, binding expected: V2ProfileAuthorBinding,
                                  pages: Set<V2ProfilePageActivation>, promoting: Bool = false) throws {
        let key = entry.key
        guard let state = states[key] else { return }
        switch entry {
        case .presentation(let presentation, _, _, _):
            guard authorCanGrant(key, binding: expected, version: presentation.lease.authorityVersion), let value, value.deadline > clock.now,
                  isNotOlder(presentation, than: state.floor), meetsNicknameFloor(presentation, minimum: state.nicknameRevisionFloor), meetsAliasFloor(presentation, minimum: state.aliasRevisionFloor) else { return }
            let changed = access[key] != value
            if changed {
                try install(value, key: key)
            }
            // A newly received observation fences older HTTP work even when
            // its bytes are identical. A second page promoting that same
            // observation only receives its own grant; existing reads survive.
            if changed || !promoting { states[key]?.valueID = UUID() }
            let floor = RevisionFloor(presentation, previous: states[key]?.floor)
            states[key]?.floor = floor; states[key]?.retryUntil = nil
            negative.removeValue(forKey: key)
            authorDenials.removeValue(forKey: key)
            for page in pages {
                let newlyGranted = activations[page.id]?.grants[key] == nil
                let hasWaiter = demand[key]?.waiters.values.contains { $0.activation == page } == true
                activations[page.id]?.grants[key] = .init(authorBindingID: expected.id)
                complete(key, activation: page, result: .success(presentation))
                if newlyGranted && !hasWaiter { notify(key, activationID: page.id) }
            }
        case .unavailable(let denial, let until):
            if until > clock.now { try deny(key, version: denial.authorityVersion, until: min(until, clock.now + .seconds(30))) }
        case .retryable(_, let notBefore):
            guard notBefore > clock.now else { return }
            let until = min(notBefore, clock.now + .seconds(60))
            states[key]?.retryUntil = max(state.retryUntil ?? until, until)
            for page in pages {
                complete(key, activation: page, result: .failure(V2ProfilePresentationError.throttled(retryAfter: seconds(until))))
            }
        }
    }
    private func stageCandidate(_ entry: V2ReceivedAuthorPresentationEntry, access value: Access?, binding expected: V2ProfileAuthorBinding, pages: Set<V2ProfilePageActivation>) throws {
        let key = entry.key
        var deadline = min(clock.now + .seconds(5), expected.view.renewBy)
        switch entry {
        case .presentation(let presentation, _, _, _):
            guard let value, authorCanGrant(key, binding: expected, version: presentation.lease.authorityVersion),
                  isNotOlder(presentation, than: states[key]?.floor),
                  meetsNicknameFloor(presentation, minimum: states[key]?.nicknameRevisionFloor ?? 0),
                  meetsAliasFloor(presentation, minimum: states[key]?.aliasRevisionFloor ?? 0),
                  isNotOlder(presentation, than: candidates[key]?.access.map { RevisionFloor($0.presentation) }) else { return }
            deadline = min(deadline, value.deadline)
        case .unavailable(let denial, let until):
            guard until > clock.now else { return }
            deadline = min(deadline, until)
            if states[key] != nil {
                guard try deny(key, version: denial.authorityVersion, until: min(until, clock.now + .seconds(30))) else { return }
            }
            else if !(try recordDenial(key, version: denial.authorityVersion)) { return }
        case .retryable(_, let notBefore): deadline = min(deadline, notBefore)
        }
        guard deadline > clock.now else { return }
        let cost = (value?.bytes ?? ((try? JSONEncoder().encode(key).count).map { $0 + 128 } ?? 262_145)) + pages.count * 64
        guard cost <= 256 * 1_024 else { return }
        removeCandidate(key)
        while candidates.count >= 64 || candidateBytes > 256 * 1_024 - cost {
            guard let oldest = candidates.min(by: { $0.value.expires < $1.value.expires }) else { break }
            removeCandidate(oldest.key)
        }
        candidates[key] = .init(bindingID: expected.id, pendingActivations: pages, entry: entry, access: value,
            expires: deadline, observed: clock.now, cost: cost)
        candidateBytes += cost
    }
    private func promoteCandidate(_ key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation) throws {
        pruneCandidates()
        guard let candidate = candidates[key], candidate.pendingActivations.contains(activation),
              let binding, liveActivations(in: binding).contains(activation),
              binding.id == candidate.bindingID, binding.view.renewBy > clock.now else { return }
        candidates[key]?.pendingActivations.remove(activation)
        if candidates[key]?.pendingActivations.isEmpty == true { removeCandidate(key) }
        try applyAuthorEntry(candidate.entry, access: candidate.access, binding: binding, pages: [activation], promoting: true)
    }
    private func removeCandidate(_ key: V2ProfileViewLookupKey) {
        guard let value = candidates.removeValue(forKey: key) else { return }
        candidateBytes -= value.cost
    }
    private func pruneCandidates() {
        for key in Array(candidates.keys) {
            guard let candidate = candidates[key] else { continue }
            let pending = candidate.pendingActivations.filter { $0.epoch == epoch && activations[$0.id] != nil && !retiredAuthorPages.contains($0) }
            if candidate.expires <= clock.now || pending.isEmpty { removeCandidate(key) }
            else { candidates[key]?.pendingActivations = pending }
        }
    }
    private func clearCandidates() { for key in Array(candidates.keys) { removeCandidate(key) } }
    private func fenceUntrackedAuthor(_ key: V2ProfileViewLookupKey, at instant: ContinuousClock.Instant) {
        guard binding != nil else { return }
        authorNotBefore = max(authorNotBefore ?? instant, instant)
    }

    private func cancelWaiter(_ id: UUID, key: V2ProfileViewLookupKey) {
        guard let waiter = demand[key]?.waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if demand[key]?.waiters.isEmpty == true { demand.removeValue(forKey: key) }
        cancelUnusedFlights()
    }
    private func removeWaiters(where predicate: (Waiter) -> Bool) {
        for key in Array(demand.keys) {
            for (id, waiter) in demand[key]?.waiters ?? [:] where predicate(waiter) { cancelWaiter(id, key: key) }
        }
    }
    private func cancelUnusedFlights() {
        for flight in tasks.values where !flight.keys.contains(where: { demand[$0.key]?.id == $0.demandID }) { flight.task.cancel() }
    }
    private func schedule() {
        guard !closed, tasks.count < 2, throttlingError() == nil else { return }
        let now = clock.now
        guard let earliest = demand.filter({ !inFlight.contains($0.key) }).map({ _, item in
            waitsForAuthor(item, now: now) ? item.authorFallbackAt : now
        }).min() else { return }
        let deadline = max(now + .milliseconds(32), earliest)
        if mergeTask != nil, let mergeDeadline, mergeDeadline <= deadline { return }
        mergeTask?.cancel()
        let id = UUID(); mergeID = id
        mergeDeadline = deadline
        mergeTask = Task {
            do {
                try await clock.sleep(until: deadline)
                guard self.mergeID == id else { return }
                self.mergeID = nil; self.mergeTask = nil; self.mergeDeadline = nil; self.launchBatch()
            } catch {
                if self.mergeID == id { self.mergeID = nil; self.mergeTask = nil; self.mergeDeadline = nil }
            }
        }
    }
    private func waitsForAuthor(_ item: Demand, now: ContinuousClock.Instant) -> Bool {
        item.waitsForAuthor && item.authorFallbackAt > now && !item.waiters.isEmpty && item.waiters.values.allSatisfy { waiter in
            if activations[waiter.activation.id]?.expectsAuthorDelivery == true { return true }
            guard let binding else { return false }
            return binding.activations.contains(waiter.activation) && binding.view.renewBy > now
                && !retiredAuthorPages.contains(waiter.activation)
        }
    }
    private func launchBatch() {
        guard !closed else { return }
        if let throttled = throttlingError() {
            for key in Array(demand.keys) where !inFlight.contains(key) { complete(key, result: .failure(throttled)) }
            return
        }
        let ordered = demand.keys.filter { !inFlight.contains($0) && demand[$0].map { !waitsForAuthor($0, now: clock.now) } == true }.sorted {
            (demand[$0]?.priority.rawValue ?? 1) < (demand[$1]?.priority.rawValue ?? 1)
        }
        let keys = V2ProfilePresentationBatchRequest.selectKeys(from: ordered)
        guard !keys.isEmpty else { schedule(); return }
        guard tasks.count < 2 else { return }
        let selected = keys.compactMap { key -> ReadKey? in
            guard let item = demand[key], let state = states[key] else { return nil }
            return .init(key: key, demandID: item.id, stateID: state.identity, valueID: state.valueID,
                         activations: Set(item.waiters.values.map(\.activation)))
        }
        let batchID = UUID(), batchEpoch = epoch, started = clock.now
        inFlight.formUnion(keys)
        let task = Task {
            let response: Result<V2ProfilePresentationBatch, Error>
            do {
                let batch = try await reader.readPresentations(selected.map(\.key))
                if batchEpoch == epoch, !closed { try await refreshPresentationFloors(Set(selected.map(\.key))) }
                response = .success(batch)
            }
            catch { response = .failure(error) }
            // Even a cancelled, non-cooperative read can report an explicit
            // denial or account 429. Generation/demand fences decide its scope.
            self.finish(selected, response: response, epoch: batchEpoch, started: started, batchID: batchID)
        }
        tasks[batchID] = .init(keys: selected, task: task); schedule()
    }
    private func finish(_ reads: [ReadKey], response: Result<V2ProfilePresentationBatch, Error>, epoch batchEpoch: UUID, started: ContinuousClock.Instant, batchID: UUID) {
        defer { tasks.removeValue(forKey: batchID); inFlight.subtract(reads.map(\.key)); schedule() }
        if case .failure(let error) = response, case .throttled(let retryAfter) = error as? V2ProfilePresentationError {
            applyThrottling(retryAfter, failedReads: reads); return
        }
        guard batchEpoch == epoch, !closed else { return }
        do {
            let batch = try response.get(), keys = Set(reads.map(\.key))
            guard Set(batch.presentations.keys).union(batch.unavailable).union(batch.retryable) == keys,
                  Set(batch.presentations.keys).isDisjoint(with: batch.unavailable),
                  Set(batch.presentations.keys).isDisjoint(with: batch.retryable), batch.unavailable.isDisjoint(with: batch.retryable),
                  Set(batch.avatars.keys).isSubset(of: Set(batch.presentations.keys)),
                  let serverNow = Int64(exactly: (batch.serverNow.timeIntervalSince1970 * 1_000).rounded(.towardZero)) else {
                throw V2ProfilePresentationError.invalidResponse
            }
            var prepared: [V2ProfileViewLookupKey: Access] = [:]
            for (key, version) in batch.denials { _ = try V2PresentationDenial(key: key, authorityVersion: version) }
            for (key, value) in batch.presentations {
                try validate(value, key: key)
                _ = try V2ProfilePresentationBatchResponse(serverNowUnixMilliseconds: serverNow,
                    results: [.presentation(value, avatar: batch.avatars[key])])
                let deadline = started + .milliseconds(value.lease.validUntilUnixMilliseconds - serverNow)
                let avatarDeadline = batch.avatars[key]?.plan.map { started + .milliseconds($0.expiresAtUnixMilliseconds - serverNow) }
                let avatar = avatarDeadline.map { $0 > clock.now } == true ? batch.avatars[key] : batch.avatars[key]?.withoutDownloadPlan()
                if deadline > clock.now { prepared[key] = try makeAccess(value, deadline: deadline, avatar: avatar, avatarDeadline: avatar?.plan == nil ? nil : avatarDeadline) }
            }
            for read in reads {
                let key = read.key
                guard states[key]?.identity == read.stateID else { continue }
                if let version = batch.denials[key] {
                    // Denial never restores access. Only still-live original
                    // activations make this old HTTP observation relevant.
                    if read.activations.contains(where: { $0.epoch == epoch && activations[$0.id]?.interests.contains(key) == true }) {
                        if try !deny(key, version: version, until: started + .seconds(30)), demand[key]?.id == read.demandID {
                            complete(key, result: .failure(V2ProfilePresentationError.staleResponse))
                        }
                    }
                    continue
                }
                guard demand[key]?.id == read.demandID else { continue }
                guard states[key]?.valueID == read.valueID else { continue }
                if let entry = prepared[key], isNotOlder(entry.presentation, than: states[key]?.floor),
                   authorityCanGrant(entry.presentation.lease.authorityVersion, for: key),
                   meetsNicknameFloor(entry.presentation, minimum: states[key]?.nicknameRevisionFloor ?? 0),
                   meetsAliasFloor(entry.presentation, minimum: states[key]?.aliasRevisionFloor ?? 0) {
                    let floor = RevisionFloor(entry.presentation, previous: states[key]?.floor)
                    try install(entry, key: key); states[key]?.floor = floor; negative.removeValue(forKey: key)
                    authorDenials.removeValue(forKey: key)
                    for activation in read.activations where activation.epoch == epoch && activations[activation.id] != nil {
                        activations[activation.id]?.grants[key] = .init(authorBindingID: nil)
                        complete(key, activation: activation, result: .success(entry.presentation))
                    }
                } else if batch.retryable.contains(key) {
                    complete(key, result: .failure(V2ProfilePresentationError.overloaded))
                } else { complete(key, result: .failure(V2ProfilePresentationError.staleResponse)) }
            }
        } catch {
            for read in reads where demand[read.key]?.id == read.demandID && states[read.key]?.identity == read.stateID {
                if error as? V2ClientMediaTransferError == .authorizationUnavailable {
                    invalidate([read.key]); continue
                }
                complete(read.key, result: .failure(error))
            }
        }
    }

    private func validate(_ value: V2AuthorizedProfilePresentation, key: V2ProfileViewLookupKey) throws {
        guard value.lease.actorUserID == actorUserID, value.lease.deviceID == deviceID, value.lease.key == key else {
            throw V2ProfilePresentationError.invalidResponse
        }
    }
    private func isNotOlder(_ value: V2AuthorizedProfilePresentation, than floor: RevisionFloor?) -> Bool {
        guard let floor else { return true }
        let nicknameRevision = value.groupMember?.revision.rawValue ?? 0
        let previousNicknameRevision = floor.groupMember?.revision.rawValue ?? 0
        let nicknameMatches = value.view.state != .active || nicknameRevision > previousNicknameRevision
            || (nicknameRevision == previousNicknameRevision && value.groupMember == floor.groupMember)
        let aliasRevision = value.contactAlias?.revision.rawValue ?? 0
        let previousAliasRevision = floor.contactAlias?.revision.rawValue ?? 0
        let aliasMatches = value.view.state != .active || aliasRevision > previousAliasRevision
            || (aliasRevision == previousAliasRevision && value.contactAlias == floor.contactAlias)
        return value.view.revision >= floor.profile && value.view.visibilityRevision >= floor.visibility
            && value.lease.authorityVersion.isAtLeast(floor.authority)
            && value.lease.contextRevision >= floor.context
            && nicknameMatches && aliasMatches
            && value.lease.observedAtUnixMilliseconds >= floor.observedAt
    }
    private func makeAccess(_ value: V2AuthorizedProfilePresentation, deadline: ContinuousClock.Instant,
                            avatar: V2ResourceAvatarAccess?, avatarDeadline: ContinuousClock.Instant?) throws -> Access {
        let cost = try JSONEncoder().encode(value).count + JSONEncoder().encode(avatar).count
        guard cost <= maximumBytes else { throw V2ProfilePresentationError.overloaded }
        return .init(presentation: value, deadline: deadline, bytes: cost, avatar: avatar, avatarDeadline: avatarDeadline)
    }
    private func install(_ entry: Access, key: V2ProfileViewLookupKey) throws {
        try saveLocalDisplay(entry.presentation)
        let previous = access[key]
        removeAccess(key)
        while access.count >= maximumEntries || bytes > maximumBytes - entry.bytes {
            guard let oldest = access.min(by: { $0.value.deadline < $1.value.deadline }) else { break }
            removeAccess(oldest.key); revokeGrants(oldest.key)
        }
        access[key] = entry; bytes += entry.bytes
        if let previous {
            let contentChanged = previous.presentation.view != entry.presentation.view
                || previous.presentation.groupMember != entry.presentation.groupMember
                || previous.presentation.contactAlias != entry.presentation.contactAlias
                || previous.presentation.lease.contextRevision != entry.presentation.lease.contextRevision
                || previous.avatar?.mediaID != entry.avatar?.mediaID || previous.avatar?.variantID != entry.avatar?.variantID
                || previous.avatar?.version != entry.avatar?.version || previous.avatar?.checksum != entry.avatar?.checksum
                || previous.avatar?.byteCount != entry.avatar?.byteCount
            // Rotating a signed URL or extending the same lease must not start
            // an HTTP refresh cascade across rows. A shorter lease must hide old
            // snapshots even when every visible field stayed identical.
            if contentChanged || entry.deadline < previous.deadline {
                for id in activations.keys where activations[id]?.grants[key] != nil { notify(key, activationID: id) }
            }
        }
    }
    private func removeAccess(_ key: V2ProfileViewLookupKey) {
        if let old = access.removeValue(forKey: key) { bytes -= old.bytes }
    }
    private func revokeGrants(_ key: V2ProfileViewLookupKey, includeInterests: Bool = false) {
        for id in activations.keys {
            let hadAccess = activations[id]?.grants.removeValue(forKey: key) != nil
            if hadAccess || (includeInterests && activations[id]?.interests.contains(key) == true) {
                notify(key, activationID: id)
            }
        }
    }
    private func notify(_ key: V2ProfileViewLookupKey, activationID: UUID) {
        guard activations[activationID]?.interests.contains(key) == true else { return }
        activations[activationID]?.invalidationRevisions[key] = UUID()
        activations[activationID]?.observer?.yield(())
    }
    @discardableResult
    private func recordDenial(_ key: V2ProfileViewLookupKey, version: V2PresentationAuthorityVersion) throws -> Bool {
        _ = try V2PresentationDenial(key: key, authorityVersion: version)
        let grants = [states[key]?.floor?.authority, candidates[key]?.access?.presentation.lease.authorityVersion].compactMap { $0 }
        // A candidate for one page may coexist with a newer HTTP grant for
        // another. Neither can hide the other's authority floor.
        if grants.contains(where: { $0.isAtLeast(version) && $0 != version }) { return false }
        var floor = version
        for grant in grants { floor = try floor.merged(with: grant) }
        if let old = authorDenials[key] { floor = try floor.merged(with: old) }
        if authorDenials[key] == nil, authorDenials.count >= maximumEntries {
            // Preserve a conservative causal fence when the bounded tombstone
            // budget is exhausted. A fresh page can establish a new observation.
            if let evicted = authorDenials.keys.first {
                fenceUntrackedAuthor(evicted, at: clock.now); authorDenials.removeValue(forKey: evicted)
            }
        }
        authorDenials[key] = floor
        return true
    }
    @discardableResult
    private func deny(_ key: V2ProfileViewLookupKey, version: V2PresentationAuthorityVersion, until: ContinuousClock.Instant) throws -> Bool {
        guard try recordDenial(key, version: version) else { return false }
        try denyLocalDisplay(key)
        removeAccess(key); revokeGrants(key)
        if negative.count >= maximumEntries { negative.removeValue(forKey: negative.keys.first!) }
        negative[key] = until
        states[key]?.valueID = UUID(); states[key]?.retryUntil = nil
        complete(key, result: .success(nil))
        return true
    }
    private func applyThrottling(_ retryAfter: TimeInterval, failedReads: [ReadKey]) {
        let base = retryAfter.isFinite ? min(315_576_000, max(1, retryAfter)) : 1
        let proposedJitter = retryJitter(), jitter = proposedJitter.isFinite ? min(1, max(0, proposedJitter)) : 0.25
        let proposed = clock.now + .seconds(base + jitter)
        throttleUntil = max(throttleUntil ?? proposed, proposed)
        let failure = throttlingError() ?? .throttled(retryAfter: base + jitter)
        let ids = Dictionary(uniqueKeysWithValues: failedReads.map { ($0.key, $0.demandID) })
        for key in Array(demand.keys) {
            let currentID = demand[key]?.id
            let actuallyReading = tasks.values.contains { flight in
                flight.keys.contains { $0.key == key && $0.demandID == currentID }
            }
            if ids[key] == currentID || !actuallyReading { complete(key, result: .failure(failure)) }
        }
    }
    private func seconds(_ until: ContinuousClock.Instant) -> TimeInterval {
        let remaining = clock.now.duration(to: until).components
        return max(0, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
    }
    private func throttlingError() -> V2ProfilePresentationError? {
        guard let until = throttleUntil, until > clock.now else { throttleUntil = nil; return nil }
        return .throttled(retryAfter: seconds(until))
    }
    private func complete(_ key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation? = nil,
                          result: Result<V2AuthorizedProfilePresentation?, Error>) {
        guard var item = demand[key] else { return }
        let completed = item.waiters.filter { activation == nil || $0.value.activation == activation }
        for id in completed.keys { item.waiters.removeValue(forKey: id) }
        demand[key] = item.waiters.isEmpty ? nil : item
        for waiter in completed.values {
            guard waiter.activation.epoch == epoch, activations[waiter.activation.id] != nil else {
                waiter.continuation.resume(throwing: V2ProfilePresentationError.inactive); continue
            }
            waiter.continuation.resume(with: result)
        }
    }
    private func evictUnreferencedAccess() {
        for key in Array(access.keys) where access[key]!.deadline <= clock.now {
            removeAccess(key); revokeGrants(key)
        }
        let granted = activations.values.reduce(into: Set<V2ProfileViewLookupKey>()) { $0.formUnion($1.grants.keys) }
        let interested = activations.values.reduce(into: Set<V2ProfileViewLookupKey>()) { $0.formUnion($1.interests) }
        for key in Array(access.keys) where !granted.contains(key) { removeAccess(key) }
        for key in Array(states.keys) where !interested.contains(key) && !granted.contains(key) {
            if let denied = states[key]?.deniedAt { fenceUntrackedAuthor(key, at: denied) }
            states.removeValue(forKey: key)
        }
    }
    private func evictUnusedGrant() {
        evictUnreferencedAccess()
        guard states.count >= maximumEntries else { return }
        let interested = activations.values.reduce(into: Set<V2ProfileViewLookupKey>()) { $0.formUnion($1.interests) }
        if let oldest = access.filter({ !interested.contains($0.key) }).min(by: { $0.value.deadline < $1.value.deadline }) {
            removeAccess(oldest.key); revokeGrants(oldest.key); states.removeValue(forKey: oldest.key)
        }
    }
    public struct Diagnostics: Sendable {
        public let activations: Int, trackedKeys: Int, pendingKeys: Int, waitingConsumers: Int, inFlight: Int, cachedBytes: Int
        public let visibleRows: Int, bufferedAuthorEntries: Int, bufferedAuthorBytes: Int
        public let authorityDenials: Int
    }
    public func diagnostics() -> Diagnostics {
        .init(activations: activations.count, trackedKeys: states.count, pendingKeys: demand.count,
              waitingConsumers: demand.values.reduce(0) { $0 + $1.waiters.count }, inFlight: tasks.count, cachedBytes: bytes,
              visibleRows: visibleRows, bufferedAuthorEntries: candidates.count, bufferedAuthorBytes: candidateBytes,
              authorityDenials: authorDenials.count)
    }
}

private extension V2ReceivedAuthorPresentationEntry {
    var key: V2ProfileViewLookupKey {
        switch self {
        case .presentation(let value, _, _, _): value.lease.key
        case .unavailable(let denial, _): denial.key
        case .retryable(let key, _): key
        }
    }
}
