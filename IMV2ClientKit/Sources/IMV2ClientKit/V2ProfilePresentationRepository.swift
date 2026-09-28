import Foundation
import IMV2Core

public struct V2ProfilePresentationBatch: Sendable {
    public let presentations: [V2ProfileViewLookupKey: V2AuthorizedProfilePresentation]
    public let unavailable: Set<V2ProfileViewLookupKey>
    public let avatars: [V2ProfileViewLookupKey: V2ResourceAvatarAccess]
    public let retryable: Set<V2ProfileViewLookupKey>
    public let serverNow: Date
    public init(presentations: [V2ProfileViewLookupKey: V2AuthorizedProfilePresentation], unavailable: Set<V2ProfileViewLookupKey>, serverNow: Date, avatars: [V2ProfileViewLookupKey: V2ResourceAvatarAccess] = [:], retryable: Set<V2ProfileViewLookupKey> = []) {
        self.presentations = presentations; self.unavailable = unavailable; self.serverNow = serverNow; self.avatars = avatars; self.retryable = retryable
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
    fileprivate let activation: V2ProfilePageActivation
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
    private struct Access {
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
        var interests: Set<V2ProfileViewLookupKey> = []
        var visibleRows: [V2ProfileViewLookupKey: Set<UUID>] = [:]
        var invalidationRevisions: [V2ProfileViewLookupKey: UUID] = [:]
        var grants: [V2ProfileViewLookupKey: Grant] = [:]
        var observerID: UUID?
        var observer: AsyncStream<Void>.Continuation?
    }
    private struct RevisionFloor {
        let profile: V2ProfileRevision, visibility: V2ProfileRevision
        let context: UInt64, observedAt: Int64
        let groupMember: V2GroupMemberPresentation?
        let contactAlias: V2ContactAlias?
        init(_ value: V2AuthorizedProfilePresentation, previous: RevisionFloor? = nil) {
            profile = value.view.revision; visibility = value.view.visibilityRevision
            context = value.lease.contextRevision; observedAt = value.lease.observedAtUnixMilliseconds
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
    }
    private struct Waiter {
        let activation: V2ProfilePageActivation
        let continuation: CheckedContinuation<V2AuthorizedProfilePresentation?, Error>
    }
    private struct Demand {
        let id = UUID()
        var priority: Priority
        var waiters: [UUID: Waiter]
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
        let entry: V2ReceivedAuthorPresentationEntry
        let access: Access?
        let expires: ContinuousClock.Instant
        let observed: ContinuousClock.Instant
        let cost: Int
    }
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
    private var binding: V2ProfileAuthorBinding?
    private var candidates: [V2ProfileViewLookupKey: Candidate] = [:]
    private var candidateBytes = 0
    private var visibleRows = 0
    private var authorNotBefore: ContinuousClock.Instant?
    private var bytes = 0
    private var closed = false
    private let maximumEntries = 2_000
    private let maximumBytes = 2 * 1_024 * 1_024

    public init(actorUserID: UserID, deviceID: DeviceID, reader: any V2ProfilePresentationReading,
                nicknameRevisions: (@Sendable (Set<V2ProfileViewLookupKey>) async throws -> [V2ProfileViewLookupKey: UInt64])? = nil,
                aliasRevisions: (@Sendable (Set<V2ProfileViewLookupKey>) async throws -> [V2ProfileViewLookupKey: UInt64])? = nil) {
        self.actorUserID = actorUserID; self.deviceID = deviceID; self.reader = reader
        self.nicknameRevisions = nicknameRevisions
        self.aliasRevisions = aliasRevisions
        retryJitter = { Double.random(in: 0.1...0.5) }
    }
    init(actorUserID: UserID, deviceID: DeviceID, reader: any V2ProfilePresentationReading,
         retryJitter: @escaping @Sendable () -> TimeInterval) {
        self.actorUserID = actorUserID; self.deviceID = deviceID; self.reader = reader; self.retryJitter = retryJitter
        nicknameRevisions = nil; aliasRevisions = nil
    }
    public func activate() -> V2ProfilePageActivation {
        activate(tracksVisibleRows: false)
    }
    /// Shared by a foreground chat page. Reads require a retained visible row.
    public func activateVisiblePage() -> V2ProfilePageActivation {
        activate(tracksVisibleRows: true)
    }
    private func activate(tracksVisibleRows: Bool) -> V2ProfilePageActivation {
        let token = V2ProfilePageActivation(id: UUID(), epoch: epoch)
        if !closed, activations.count < 256 { activations[token.id] = .init(started: clock.now, tracksVisibleRows: tracksVisibleRows) }
        return token
    }
    public func deactivate(_ activation: V2ProfilePageActivation) {
        guard activation.epoch == epoch else { return }
        if binding?.activation == activation { binding = nil; clearCandidates() }
        if let removed = activations.removeValue(forKey: activation.id) {
            visibleRows -= removed.visibleRows.values.reduce(0) { $0 + $1.count }
            removed.observer?.finish()
        }
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
        for activation in activations.values { activation.observer?.finish() }
        epoch = UUID(); binding = nil; clearCandidates(); visibleRows = 0; authorNotBefore = nil
        activations.removeAll(); access.removeAll(); states.removeAll(); negative.removeAll(); bytes = 0
        removeWaiters { _ in true }
        mergeTask?.cancel(); mergeTask = nil; mergeID = nil
        for flight in tasks.values { flight.task.cancel() }
    }
    public func close() async {
        closed = true; endAllActivations()
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
    public func retainVisibleInterest(for key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation) throws -> V2ProfileVisibleInterest {
        try Task.checkCancellation(); try requireActive(activation)
        guard activations[activation.id]?.tracksVisibleRows == true else { throw V2ProfilePresentationError.inactive }
        guard visibleRows < 512 else { throw V2ProfilePresentationError.overloaded }
        try registerInterest(key, activation: activation)
        let token = V2ProfileVisibleInterest(id: UUID(), activation: activation, key: key)
        activations[activation.id]?.visibleRows[key, default: []].insert(token.id)
        visibleRows += 1
        return token
    }
    public func releaseVisibleInterest(_ token: V2ProfileVisibleInterest) {
        let activation = token.activation, key = token.key
        guard activation.epoch == epoch,
              activations[activation.id]?.visibleRows[key]?.remove(token.id) != nil else { return }
        visibleRows -= 1
        guard activations[activation.id]?.visibleRows[key]?.isEmpty == true else { return }
        activations[activation.id]?.visibleRows.removeValue(forKey: key)
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
            avatar: avatarIsLive ? value.avatar : nil, avatarDeadline: avatarIsLive ? value.avatarDeadline : nil)
    }
    public func cachedPresentation(for key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation) async -> V2AuthorizedProfilePresentation? {
        await cachedSnapshot(for: key, activation: activation)?.presentation
    }
    public func authorizationDeadline(for key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation) async -> ContinuousClock.Instant? {
        await cachedSnapshot(for: key, activation: activation)?.deadline
    }
    public func avatarAccess(for key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation) async -> V2ResourceAvatarAccess? {
        await cachedSnapshot(for: key, activation: activation)?.avatar
    }

    public func presentation(for key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation, priority: Priority = .visible) async throws -> V2AuthorizedProfilePresentation? {
        try Task.checkCancellation()
        if activations[activation.id]?.tracksVisibleRows == true,
           activations[activation.id]?.visibleRows[key]?.isEmpty != false { throw V2ProfilePresentationError.inactive }
        try registerInterest(key, activation: activation)
        try await refreshPresentationFloors([key])
        try Task.checkCancellation(); try requireActive(activation)
        promoteCandidate(key, activation: activation)
        if let cached = currentSnapshot(for: key, activation: activation)?.presentation { return cached }
        if let until = negative[key], until > clock.now { return nil }
        if let until = states[key]?.retryUntil, until > clock.now { throw V2ProfilePresentationError.throttled(retryAfter: seconds(until)) }
        if let throttled = throttlingError() { throw throttled }
        guard (demand[key] != nil || demand.count < 256),
              demand.values.reduce(0, { $0 + $1.waiters.count }) < 512 else { throw V2ProfilePresentationError.overloaded }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                var item = demand[key] ?? Demand(priority: priority, waiters: [:])
                if priority.rawValue < item.priority.rawValue { item.priority = priority }
                item.waiters[waiter] = Waiter(activation: activation, continuation: continuation)
                demand[key] = item; schedule()
            }
        } onCancel: { Task { await self.cancelWaiter(waiter, key: key) } }
    }

    /// The page activates before the connection creates its nonce. Visible-page
    /// candidates remain memory-only and cannot authorize a different page.
    public func bindAuthorView(_ view: V2AuthorPresentationView, activation: V2ProfilePageActivation) throws -> V2ProfileAuthorBinding {
        try Task.checkCancellation(); try requireActive(activation)
        guard let active = activations[activation.id], active.started <= view.started, view.renewBy > clock.now else {
            throw V2ProfilePresentationError.inactive
        }
        let next = V2ProfileAuthorBinding(id: UUID(), activation: activation, view: view)
        if let previous = binding {
            if previous.activation == activation && previous.view.roomID == view.roomID {
                for key in active.grants.keys where active.grants[key]?.authorBindingID == previous.id {
                    activations[activation.id]?.grants[key]?.authorBindingID = next.id
                }
            } else { unbindAuthorView(previous) }
        }
        clearCandidates(); binding = next; return next
    }
    public func unbindAuthorView(_ ending: V2ProfileAuthorBinding) {
        guard binding == ending else { return }
        clearCandidates(); binding = nil
        for (key, grant) in activations[ending.activation.id]?.grants ?? [:] where grant.authorBindingID == ending.id {
            activations[ending.activation.id]?.grants.removeValue(forKey: key)
            notify(key, activationID: ending.activation.id)
        }
        evictUnreferencedAccess()
    }

    /// Deltas retain receiver-created monotonic deadlines. In-flight HTTP success
    /// cannot overwrite an accepted delta. An explicit denial from an overlapping
    /// read fails closed and blocks this older nonce until a causally newer view.
    public func ingest(_ delta: V2ReceivedAuthorPresentationDelta, binding expected: V2ProfileAuthorBinding) async throws {
        try Task.checkCancellation()
        try requireActive(expected.activation)
        guard binding == expected, delta.view == expected.view, expected.view.renewBy > clock.now else {
            throw V2ProfilePresentationError.inactive
        }
        guard delta.entries.count <= V2AuthorPresentationDelta.maximumEntries else { throw V2ProfilePresentationError.invalidResponse }
        var prepared: [V2ProfileViewLookupKey: Access] = [:]
        var seen = Set<V2ProfileViewLookupKey>()
        // Validate the entire frame before making any visible mutation.
        for entry in delta.entries {
            let key = entry.key
            guard seen.insert(key).inserted, key.context == .room(expected.view.roomID) else { throw V2ProfilePresentationError.invalidResponse }
            if case .presentation(let value, let avatar, let deadline, let byteDeadline) = entry {
                try validate(value, key: key)
                guard deadline <= expected.view.started + .milliseconds(V2PresentationAccessLease.maximumLifetimeMilliseconds),
                      avatar == nil || (avatar?.mediaID == value.view.avatar?.mediaID && byteDeadline != nil),
                      byteDeadline.map({ $0 <= deadline }) ?? (avatar == nil) else { throw V2ProfilePresentationError.invalidResponse }
                if deadline > clock.now {
                    let usableAvatar = byteDeadline.map { $0 > clock.now } == true ? avatar : nil
                    prepared[key] = try makeAccess(value, deadline: deadline, avatar: usableAvatar, avatarDeadline: usableAvatar == nil ? nil : byteDeadline)
                }
            }
        }
        let floors = try await refreshPresentationFloors(seen)
        try Task.checkCancellation(); try requireActive(expected.activation)
        guard binding == expected, expected.view.renewBy > clock.now else { throw V2ProfilePresentationError.inactive }
        let interests = activations[expected.activation.id]?.interests ?? []
        pruneCandidates()
        for entry in delta.entries {
            let key = entry.key
            if case .presentation(let value, _, _, _) = entry,
               (!meetsNicknameFloor(value, minimum: floors.nicknames[key] ?? 0) || !meetsAliasFloor(value, minimum: floors.aliases[key] ?? 0)) { continue }
            if interests.contains(key) {
                removeCandidate(key)
                applyAuthorEntry(entry, access: prepared[key], binding: expected)
            } else if activations[expected.activation.id]?.tracksVisibleRows == true {
                stageCandidate(entry, access: prepared[key], binding: expected)
            }
        }
        cancelUnusedFlights()
    }

    private func authorCanGrant(_ key: V2ProfileViewLookupKey, binding expected: V2ProfileAuthorBinding) -> Bool {
        (authorNotBefore.map { expected.view.started > $0 } ?? true)
            && (states[key]?.deniedAt.map { expected.view.started > $0 } ?? true)
    }
    private func applyAuthorEntry(_ entry: V2ReceivedAuthorPresentationEntry, access value: Access?, binding expected: V2ProfileAuthorBinding) {
        let key = entry.key
        guard let state = states[key] else { return }
        switch entry {
        case .presentation(let presentation, _, _, _):
            guard authorCanGrant(key, binding: expected), let value, value.deadline > clock.now,
                  isNotOlder(presentation, than: state.floor), meetsNicknameFloor(presentation, minimum: state.nicknameRevisionFloor), meetsAliasFloor(presentation, minimum: state.aliasRevisionFloor) else { return }
            let newlyGranted = activations[expected.activation.id]?.grants[key] == nil
            let hasWaiter = demand[key]?.waiters.values.contains { $0.activation == expected.activation } == true
            install(value, key: key)
            let floor = RevisionFloor(presentation, previous: states[key]?.floor)
            states[key]?.valueID = UUID(); states[key]?.floor = floor; states[key]?.retryUntil = nil
            negative.removeValue(forKey: key)
            activations[expected.activation.id]?.grants[key] = .init(authorBindingID: expected.id)
            complete(key, activation: expected.activation, result: .success(presentation))
            if newlyGranted && !hasWaiter { notify(key, activationID: expected.activation.id) }
        case .unavailable(_, let until):
            if until > clock.now { deny(key, until: min(until, clock.now + .seconds(30))) }
        case .retryable(_, let notBefore):
            guard notBefore > clock.now else { return }
            let until = min(notBefore, clock.now + .seconds(60))
            states[key]?.retryUntil = max(state.retryUntil ?? until, until)
            complete(key, activation: expected.activation, result: .failure(V2ProfilePresentationError.throttled(retryAfter: seconds(until))))
        }
    }
    private func stageCandidate(_ entry: V2ReceivedAuthorPresentationEntry, access value: Access?, binding expected: V2ProfileAuthorBinding) {
        let key = entry.key
        var deadline = min(clock.now + .seconds(5), expected.view.renewBy)
        switch entry {
        case .presentation(let presentation, _, _, _):
            guard let value, authorCanGrant(key, binding: expected),
                  isNotOlder(presentation, than: states[key]?.floor),
                  meetsNicknameFloor(presentation, minimum: states[key]?.nicknameRevisionFloor ?? 0),
                  meetsAliasFloor(presentation, minimum: states[key]?.aliasRevisionFloor ?? 0),
                  isNotOlder(presentation, than: candidates[key]?.access.map { RevisionFloor($0.presentation) }) else { return }
            if case .unavailable? = candidates[key]?.entry { return }
            deadline = min(deadline, value.deadline)
        case .unavailable(_, let until):
            guard until > clock.now else { return }
            deadline = min(deadline, until)
            if states[key] != nil { deny(key, until: min(until, clock.now + .seconds(30))) }
        case .retryable(_, let notBefore): deadline = min(deadline, notBefore)
        }
        guard deadline > clock.now else { return }
        let cost = value?.bytes ?? ((try? JSONEncoder().encode(key).count).map { $0 + 128 } ?? 262_145)
        guard cost <= 256 * 1_024 else { return }
        removeCandidate(key)
        while candidates.count >= 64 || candidateBytes > 256 * 1_024 - cost {
            guard let oldest = candidates.min(by: { $0.value.expires < $1.value.expires }) else { break }
            removeCandidate(oldest.key)
        }
        candidates[key] = .init(bindingID: expected.id, entry: entry, access: value,
            expires: deadline, observed: clock.now, cost: cost)
        candidateBytes += cost
    }
    private func promoteCandidate(_ key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation) {
        pruneCandidates()
        guard let candidate = candidates[key], let binding, binding.activation == activation,
              binding.id == candidate.bindingID, binding.view.renewBy > clock.now else { return }
        removeCandidate(key)
        applyAuthorEntry(candidate.entry, access: candidate.access, binding: binding)
    }
    private func removeCandidate(_ key: V2ProfileViewLookupKey) {
        guard let value = candidates.removeValue(forKey: key) else { return }
        candidateBytes -= value.cost
        if case .unavailable = value.entry { fenceUntrackedAuthor(key, at: value.observed) }
    }
    private func pruneCandidates() {
        for key in Array(candidates.keys) where candidates[key]!.expires <= clock.now { removeCandidate(key) }
    }
    private func clearCandidates() { for key in Array(candidates.keys) { removeCandidate(key) } }
    private func fenceUntrackedAuthor(_ key: V2ProfileViewLookupKey, at instant: ContinuousClock.Instant) {
        guard let binding, key.context == .room(binding.view.roomID) else { return }
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
        guard !closed, mergeTask == nil, tasks.count < 2, throttlingError() == nil,
              demand.keys.contains(where: { !inFlight.contains($0) }) else { return }
        let id = UUID(); mergeID = id
        mergeTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(32))
                guard self.mergeID == id else { return }
                self.mergeID = nil; self.mergeTask = nil; self.launchBatch()
            } catch {
                if self.mergeID == id { self.mergeID = nil; self.mergeTask = nil }
            }
        }
    }
    private func launchBatch() {
        guard !closed else { return }
        if let throttled = throttlingError() {
            for key in Array(demand.keys) where !inFlight.contains(key) { complete(key, result: .failure(throttled)) }
            return
        }
        var rooms = Set<V2ProfileViewContext>(), directUsers = Set<UserID>()
        let keys = demand.keys.filter { !inFlight.contains($0) }.sorted { (demand[$0]?.priority.rawValue ?? 1) < (demand[$1]?.priority.rawValue ?? 1) }.filter { key in
            if key.context.authorizationRoomID != nil {
                if !rooms.contains(key.context) && rooms.count + directUsers.count >= 8 { return false }
                rooms.insert(key.context)
            } else if key.context == .directConversation {
                if !directUsers.contains(key.userID) && rooms.count + directUsers.count >= 8 { return false }
                directUsers.insert(key.userID)
            }
            return true
        }.prefix(100)
        guard !keys.isEmpty, tasks.count < 2 else { return }
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
            for (key, value) in batch.presentations {
                try validate(value, key: key)
                _ = try V2ProfilePresentationBatchResponse(serverNowUnixMilliseconds: serverNow,
                    results: [.presentation(value, avatar: batch.avatars[key])])
                let deadline = started + .milliseconds(value.lease.validUntilUnixMilliseconds - serverNow)
                let avatarDeadline = batch.avatars[key].map { started + .milliseconds($0.plan.expiresAtUnixMilliseconds - serverNow) }
                let avatar = avatarDeadline.map { $0 > clock.now } == true ? batch.avatars[key] : nil
                if deadline > clock.now { prepared[key] = try makeAccess(value, deadline: deadline, avatar: avatar, avatarDeadline: avatar == nil ? nil : avatarDeadline) }
            }
            for read in reads {
                let key = read.key
                guard states[key]?.identity == read.stateID else { continue }
                if batch.unavailable.contains(key) {
                    // Denial never restores access. Only still-live original
                    // activations make this old HTTP observation relevant.
                    if read.activations.contains(where: { $0.epoch == epoch && activations[$0.id]?.interests.contains(key) == true }) {
                        deny(key, until: started + .seconds(30))
                    }
                    continue
                }
                guard demand[key]?.id == read.demandID else { continue }
                guard states[key]?.valueID == read.valueID else { continue }
                if let entry = prepared[key], isNotOlder(entry.presentation, than: states[key]?.floor),
                   meetsNicknameFloor(entry.presentation, minimum: states[key]?.nicknameRevisionFloor ?? 0),
                   meetsAliasFloor(entry.presentation, minimum: states[key]?.aliasRevisionFloor ?? 0) {
                    let floor = RevisionFloor(entry.presentation, previous: states[key]?.floor)
                    install(entry, key: key); states[key]?.floor = floor; negative.removeValue(forKey: key)
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
    private func install(_ entry: Access, key: V2ProfileViewLookupKey) {
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
    private func deny(_ key: V2ProfileViewLookupKey, until: ContinuousClock.Instant) {
        removeAccess(key); revokeGrants(key)
        if negative.count >= maximumEntries { negative.removeValue(forKey: negative.keys.first!) }
        negative[key] = until
        states[key]?.valueID = UUID(); states[key]?.deniedAt = clock.now; states[key]?.retryUntil = nil
        complete(key, result: .success(nil))
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
    }
    public func diagnostics() -> Diagnostics {
        .init(activations: activations.count, trackedKeys: states.count, pendingKeys: demand.count,
              waitingConsumers: demand.values.reduce(0) { $0 + $1.waiters.count }, inFlight: tasks.count, cachedBytes: bytes,
              visibleRows: visibleRows, bufferedAuthorEntries: candidates.count, bufferedAuthorBytes: candidateBytes)
    }
}

private extension V2ReceivedAuthorPresentationEntry {
    var key: V2ProfileViewLookupKey {
        switch self {
        case .presentation(let value, _, _, _): value.lease.key
        case .unavailable(let key, _), .retryable(let key, _): key
        }
    }
}
