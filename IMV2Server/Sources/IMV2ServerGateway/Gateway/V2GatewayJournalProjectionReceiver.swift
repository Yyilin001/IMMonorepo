import Foundation
import Synchronization
import IMV2Core
import IMV2ActorContracts

/// Trusted composition installs ownership and snapshot witnesses here. An RPC
/// can consume that authority, but cannot create or renew it. Lock order is
/// receiver -> shared projection; neither callback may await or reenter either.
public final class V2GatewayJournalProjectionReceiver: V2RealtimeJournalProjectionHandler, Sendable {
    private struct Binding: Sendable {
        let serviceID: String
        let fence: V2RealtimeJournalProjectionFence
        let deadline: ContinuousClock.Instant
        let rooms: Set<RoomID>
        let viewers: Set<UserID>
        let current: @Sendable () -> Bool
        var snapshot: V2RealtimeJournalProjectionBatch?
        var userControlFloors: [UserID: UInt64] = [:]
        var requiredUserControls: [UserID: UInt64] = [:]
    }
    private struct State: Sendable {
        var bindings: [V2RealtimeJournalSource: Binding] = [:]
        var authenticationSources: Set<String>?
        var authenticationByUser: [UserID: V2RealtimeJournalSource] = [:]
        var closed = false
    }
    private let state = Mutex(State())
    public let projection: V2RealtimeJournalSharedProjection
    private let maximumBindings: Int
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(projection: V2RealtimeJournalSharedProjection, maximumBindings: Int = 256,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        precondition(maximumBindings > 0)
        self.projection = projection; self.maximumBindings = maximumBindings; self.now = now
    }

    /// The composition root supplies aliases for the actual authentication DB.
    /// Once enabled, every body write also requires live auth-control coverage.
    @discardableResult
    public func configureAuthenticationSources(_ aliases: Set<String>) -> Bool {
        state.withLock { value in
            guard !value.closed, value.bindings.isEmpty, value.authenticationSources == nil,
                  !aliases.isEmpty, aliases.count <= 256 else { return false }
            value.authenticationSources = aliases
            return true
        }
    }

    /// Deadline is a conservative local monotonic bound obtained by the lease
    /// observer, never calculated from the publisher's wire wall-clock expiry.
    @discardableResult
    public func install(source: V2RealtimeJournalSource, serviceID: String,
                        fence: V2RealtimeJournalProjectionFence, deadline: ContinuousClock.Instant,
                        rooms: Set<RoomID>, viewers: Set<UserID>,
                        current: @escaping @Sendable () -> Bool = { true }) -> Bool {
        state.withLock { value in
            guard !value.closed, deadline > now(), current() else { return false }
            let predecessors = value.bindings.keys.filter {
                $0 != source && $0.sourceID == source.sourceID && $0.partitionID == source.partitionID
            }
            for predecessor in predecessors {
                value.bindings.removeValue(forKey: predecessor)
                projection.remove(source: predecessor)
            }
            guard !value.closed, deadline > now(),
                  value.bindings[source] != nil || value.bindings.count < maximumBindings else { return false }
            if let old = value.bindings[source], old.deadline <= now() { projection.invalidate(source: source) }
            guard projection.requireSnapshot(source: source, fence: fence, expectedRooms: rooms,
                                             requestedViewers: viewers) else { return false }
            let old = value.bindings[source]
            let retained = old.flatMap {
                $0.deadline > now() && $0.serviceID == serviceID && $0.fence.sameGeneration(as: fence)
                    && $0.rooms == rooms && $0.viewers == viewers ? $0.snapshot : nil
            }
            value.bindings[source] = Binding(serviceID: serviceID, fence: fence, deadline: deadline,
                                            rooms: rooms, viewers: viewers, current: current, snapshot: retained,
                                            userControlFloors: old?.userControlFloors ?? [:],
                                            requiredUserControls: old?.requiredUserControls ?? [:])
            return true
        }
    }

    /// Only a locally verified authoritative read can pre-authorize these exact
    /// grants and cut. A remote sender cannot substitute a different snapshot.
    @discardableResult
    public func authorizeSnapshot(_ batch: V2RealtimeJournalProjectionBatch) -> Bool {
        state.withLock { value in
            guard !value.closed, var binding = value.bindings[batch.source], binding.deadline > now(), binding.current(),
                  binding.fence.sameGeneration(as: batch.fence),
                  case .snapshot(let cut, let rooms) = batch.payload, cut >= 0,
                  Set(rooms.map(\.roomID)) == binding.rooms,
                  rooms.count == binding.rooms.count,
                  rooms.allSatisfy({ Set($0.viewerMembershipRevisions.keys).isSubset(of: binding.viewers) }) else { return false }
            binding.snapshot = batch; value.bindings[batch.source] = binding
            return true
        }
    }

    public func applyJournalProjection(_ batch: V2RealtimeJournalProjectionBatch,
                                       authenticatedServiceID: String) -> V2RealtimeJournalProjectionResult {
        state.withLock { value in
            guard !value.closed, var binding = value.bindings[batch.source],
                  binding.serviceID == authenticatedServiceID else { return .stale }
            let installedFence = binding.fence, installedDeadline = binding.deadline
            let installedCurrent = binding.current
            let current: @Sendable (V2RealtimeJournalSource, V2RealtimeJournalProjectionFence) -> Bool = { source, fence in
                source == batch.source && installedFence.sameGeneration(as: fence) && installedDeadline > self.now() && installedCurrent()
            }
            guard current(batch.source, batch.fence) else { return .stale }
            switch batch.payload {
            case .changes:
                if case .changes(_, _, let entries) = batch.payload {
                    for entry in entries {
                        if case .userControlInvalidation(let user, let version, _, _) = entry.change {
                            guard version > 0, version <= UInt64(Int64.max),
                                  binding.requiredUserControls[user] != nil || binding.requiredUserControls.count < 4096 else {
                                projection.invalidate(source: batch.source); return .invalid
                            }
                            binding.requiredUserControls[user] = max(binding.requiredUserControls[user] ?? 0, version)
                        }
                    }
                    value.bindings[batch.source] = binding
                }
                guard binding.requiredUserControls.allSatisfy({ user, version in
                    (binding.userControlFloors[user] ?? 0) >= version
                }) else {
                    projection.invalidate(source: batch.source)
                    return .snapshotRequired
                }
                let floors = binding.userControlFloors
                return projection.apply(batch, userControlInstalled: { user, version in
                    floors[user].map { $0 >= version } ?? false
                }, isCurrent: current)
            case .heads:
                return projection.applyHeads(batch, isCurrent: current)
            case .baseline(let minimumCut):
                guard binding.requiredUserControls.allSatisfy({ user, version in (binding.userControlFloors[user] ?? 0) >= version }) else { return .snapshotRequired }
                guard minimumCut >= 0, let cut = projection.controlCheckpoint(source: batch.source, isCurrent: current),
                      cut >= minimumCut else { return .snapshotRequired }
                return .applied(.init(batchID: batch.batchID, source: batch.source, fence: batch.fence,
                                     appliedThrough: cut, snapshotInstalled: true))
            case .snapshot(let cut, _):
                guard binding.requiredUserControls.allSatisfy({ user, version in (binding.userControlFloors[user] ?? 0) >= version }) else { return .snapshotRequired }
                guard binding.snapshot == batch else { return .stale }
                let authorizedSnapshot = binding.snapshot
                return projection.installAuthoritativeSnapshot(batch, expectedCut: cut,
                    authorizesSnapshot: { $0 == authorizedSnapshot }, isCurrent: current)
            }
        }
    }

    /// Trusted user/device snapshot application must finish before these floors
    /// can cover a remote invalidation. A room snapshot alone never covers it.
    @discardableResult
    public func installUserControlFloors(source: V2RealtimeJournalSource,
                                        fence: V2RealtimeJournalProjectionFence,
                                        versions: [UserID: UInt64], isAuthenticationSource: Bool = false) -> Bool {
        state.withLock { value in
            guard !value.closed, var binding = value.bindings[source],
                  binding.deadline > now(), binding.current(), binding.fence.sameGeneration(as: fence),
                  versions.count <= 4096, versions.values.allSatisfy({ $0 <= UInt64(Int64.max) }),
                  versions.allSatisfy({ user, version in version >= (binding.userControlFloors[user] ?? 0) }) else { return false }
            if isAuthenticationSource {
                guard value.authenticationSources?.contains(source.sourceID) == true,
                      versions.keys.allSatisfy({ user in
                          V2RealtimeTopicKey(kind: .userSync, id: user.rawValue).partitionID() == source.partitionID
                      }) else { return false }
            }
            // Trusted cold snapshots enumerate current local users completely.
            // Forget departed users so process history cannot consume capacity.
            let departedUsers = Set(binding.userControlFloors.keys).subtracting(versions.keys)
            binding.userControlFloors = versions
            binding.requiredUserControls = binding.requiredUserControls.filter { versions[$0.key] != nil }
            value.bindings[source] = binding
            if isAuthenticationSource {
                for user in departedUsers where value.authenticationByUser[user] == source {
                    value.authenticationByUser.removeValue(forKey: user)
                }
                for user in versions.keys { value.authenticationByUser[user] = source }
            }
            return true
        }
    }

    public func authenticationBinding(userID: UserID)
        -> (source: V2RealtimeJournalSource, fence: V2RealtimeJournalProjectionFence,
            deadline: ContinuousClock.Instant, controlVersion: UInt64)? {
        state.withLock { value in
            guard !value.closed, let source = value.authenticationByUser[userID],
                  let binding = value.bindings[source], authenticationCurrent(userID, in: value),
                  let version = binding.userControlFloors[userID] else { return nil }
            return (source, binding.fence, binding.deadline, version)
        }
    }

    public func enqueueUserAuthorized(userID: UserID,
                                      expectedSource: V2RealtimeJournalSource,
                                      expectedFence: V2RealtimeJournalProjectionFence,
                                      enqueue: @Sendable () -> Void) -> Bool {
        state.withLock { value in
            guard !value.closed, value.authenticationByUser[userID] == expectedSource,
                  let binding = value.bindings[expectedSource], binding.fence.sameGeneration(as: expectedFence),
                  authenticationCurrent(userID, in: value) else { return false }
            enqueue()
            return true
        }
    }

    private func authenticationCurrent(_ userID: UserID, in value: State) -> Bool {
        guard let source = value.authenticationByUser[userID], let authentication = value.bindings[source],
              authentication.deadline > now(), authentication.current(),
              authentication.userControlFloors[userID] != nil,
              authentication.requiredUserControls.allSatisfy({ user, version in
                  (authentication.userControlFloors[user] ?? 0) >= version
              }), projection.controlCheckpoint(source: source, isCurrent: { _, fence in
                  authentication.fence.sameGeneration(as: fence)
              }) != nil else { return false }
        return true
    }

    /// Perform only the actual synchronous socket enqueue in this callback.
    /// Authorization changes and owner/session retirement use the same lock.
    public func enqueueAuthorized(roomID: RoomID, userID: UserID, memberRevision: UInt64?,
                                  expectedSource: V2RealtimeJournalSource? = nil,
                                  expectedFence: V2RealtimeJournalProjectionFence? = nil,
                                  enqueue: @Sendable () -> Void) -> Bool {
        state.withLock { value in
            guard !value.closed else { return false }
            if value.authenticationSources != nil {
                guard authenticationCurrent(userID, in: value) else { return false }
            }
            let bindings = value.bindings
            return projection.withAuthorizedRoom(roomID, userID: userID, expectedMemberRevision: memberRevision,
                isCurrent: { source, fence in
                    guard let binding = bindings[source] else { return false }
                    if expectedSource != nil || expectedFence != nil {
                        guard expectedSource == source, let expectedFence,
                              expectedFence.sameGeneration(as: fence) else { return false }
                    }
                    return binding.fence.sameGeneration(as: fence) && binding.deadline > self.now() && binding.current()
                }, enqueue: enqueue)
        }
    }

    public func captureRoom(_ roomID: RoomID)
        -> (source: V2RealtimeJournalSource, fence: V2RealtimeJournalProjectionFence, room: V2RealtimeJournalRoomAuthorization)? {
        state.withLock { value in
            guard !value.closed else { return nil }
            let bindings = value.bindings
            return projection.roomSnapshot(roomID, isCurrent: { source, fence in
                guard let binding = bindings[source] else { return false }
                return binding.fence.sameGeneration(as: fence) && binding.deadline > self.now() && binding.current()
            })
        }
    }

    public func currentRoom(_ roomID: RoomID) -> V2RealtimeJournalRoomAuthorization? { captureRoom(roomID)?.room }

    public func bindingSnapshot(source: V2RealtimeJournalSource)
        -> (fence: V2RealtimeJournalProjectionFence, deadline: ContinuousClock.Instant)? {
        state.withLock { value in
            guard !value.closed, let binding = value.bindings[source], binding.deadline > now(), binding.current(),
                  projection.controlCheckpoint(source: source, isCurrent: { _, fence in
                    binding.fence.sameGeneration(as: fence)
                  }) != nil else { return nil }
            return (binding.fence, binding.deadline)
        }
    }

    /// Request preparation may reuse a live source generation even while user
    /// floors/checkpoint are blocked. This never grants auth or delivery; the
    /// shared actual recovery must revalidate the database publisher generation.
    public func recoveryBindingSnapshot(source: V2RealtimeJournalSource)
        -> (fence: V2RealtimeJournalProjectionFence, deadline: ContinuousClock.Instant)? {
        state.withLock { value in
            guard !value.closed, let binding = value.bindings[source], binding.deadline > now(), binding.current() else { return nil }
            return (binding.fence, binding.deadline)
        }
    }

    /// A previously installed trusted control baseline can satisfy a duplicate
    /// repair only while its exact generation, deadline and checkpoint are live.
    public enum RecoveryCheckpointFailure: String, Error, CaseIterable, Sendable {
        case invalidCut, closed, missingBinding, expired, coverageChanged, generationChanged
        case pendingUserControls, missingCheckpoint, checkpointBehind
    }

    public func recoveryCheckpoint(source: V2RealtimeJournalSource,
                                   fence: V2RealtimeJournalProjectionFence, minimumCut: Int64) -> Int64? {
        if case .success(let cut) = assessedRecoveryCheckpoint(source: source, fence: fence, minimumCut: minimumCut) { return cut }
        return nil
    }

    /// The diagnostic result uses the same lock and checks as authorization;
    /// it does not re-read the receiver or grant any additional authority.
    public func assessedRecoveryCheckpoint(source: V2RealtimeJournalSource,
        fence: V2RealtimeJournalProjectionFence, minimumCut: Int64) -> Result<Int64, RecoveryCheckpointFailure> {
        state.withLock { value in
            guard minimumCut >= 0 else { return .failure(.invalidCut) }
            guard !value.closed else { return .failure(.closed) }
            guard let binding = value.bindings[source] else { return .failure(.missingBinding) }
            guard binding.deadline > now() else { return .failure(.expired) }
            guard binding.current() else { return .failure(.coverageChanged) }
            guard binding.fence.sameGeneration(as: fence) else { return .failure(.generationChanged) }
            guard binding.requiredUserControls.allSatisfy({ user, version in
                binding.userControlFloors[user, default: 0] >= version
            }) else { return .failure(.pendingUserControls) }
            guard let cut = projection.controlCheckpoint(source: source, isCurrent: { _, installed in
                binding.fence.sameGeneration(as: installed)
            }) else { return .failure(.missingCheckpoint) }
            guard cut >= minimumCut else { return .failure(.checkpointBehind) }
            return .success(cut)
        }
    }

    /// A blocked projection can retain its previously verified floors. This is
    /// only a prerequisite for trusted contiguous replay + selected DB reads;
    /// it does not grant delivery or revive an expired/replaced binding.
    public func retainsRecoveryFloors(source: V2RealtimeJournalSource,
                                     fence: V2RealtimeJournalProjectionFence,
                                     versions: [UserID: UInt64]) -> Bool {
        state.withLock { value in
            guard !value.closed, let binding = value.bindings[source], binding.deadline > now(),
                  binding.current(), binding.fence.sameGeneration(as: fence) else { return false }
            return versions.allSatisfy { user, version in binding.userControlFloors[user].map { $0 >= version } ?? false }
        }
    }

    /// Locally retained floors across a subscription revision. The caller must
    /// independently prove the new route/source, replay every intervening control,
    /// and freshly read every new connection lifecycle. This grants no authority.
    public func retainsConnectionBaseline(source: V2RealtimeJournalSource,
        fence: V2RealtimeJournalProjectionFence, versions: [UserID: UInt64]) -> Bool {
        state.withLock { value in
            guard !value.closed, let binding = value.bindings[source], binding.deadline > now(),
                  binding.fence.sameAuthority(as: fence) else { return false }
            return versions.allSatisfy { user, version in binding.userControlFloors[user].map { $0 >= version } ?? false }
        }
    }

    /// Called only after trusted source and routing observers confirmed this
    /// exact generation. An expired binding always requires a fresh baseline.
    @discardableResult
    public func renew(source: V2RealtimeJournalSource, serviceID: String,
                      fence: V2RealtimeJournalProjectionFence, deadline: ContinuousClock.Instant,
                      current: @escaping @Sendable () -> Bool) -> Bool {
        state.withLock { value in
            guard !value.closed, let old = value.bindings[source], old.deadline > now(), old.current(),
                  deadline > now(), current(), old.serviceID == serviceID, old.fence.sameGeneration(as: fence),
                  old.requiredUserControls.allSatisfy({ user, version in (old.userControlFloors[user] ?? 0) >= version }),
                  projection.controlCheckpoint(source: source, isCurrent: { _, installed in
                    installed.sameGeneration(as: fence)
                  }) != nil else { return false }
            value.bindings[source] = Binding(serviceID: serviceID, fence: fence, deadline: deadline,
                rooms: old.rooms, viewers: old.viewers, current: current, snapshot: old.snapshot,
                userControlFloors: old.userControlFloors, requiredUserControls: old.requiredUserControls)
            return true
        }
    }

    public func retire(source: V2RealtimeJournalSource) {
        state.withLock { value in
            value.bindings.removeValue(forKey: source)
            projection.remove(source: source)
        }
    }

    public func retire(source: V2RealtimeJournalSource, fence: V2RealtimeJournalProjectionFence) {
        state.withLock { value in
            guard value.bindings[source]?.fence.sameGeneration(as: fence) == true else { return }
            value.bindings.removeValue(forKey: source)
            projection.remove(source: source)
        }
    }
    public func shutdown() {
        state.withLock { value in
            value.closed = true
            for source in value.bindings.keys { projection.remove(source: source) }
            value.bindings.removeAll()
            value.authenticationByUser.removeAll()
        }
    }
}
