import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

/// 资料控制事实和房间事实来自各自权威域。只签发有界许可，不持久化每个观察者的 grant。
public struct V2ResourceProfilePresentationService: Sendable {
    private let controlReads: any V2ProfileControlReading
    private let authorization: V2ActorRoomMediaAuthorizationPort
    private let avatars: @Sendable ([MediaID: Date]) async throws -> [MediaID: V2ResourceAvatarAccess]
    private let admission = V2ProfilePresentationAdmission()
    public let readDiagnostics = V2ProfilePresentationReadDiagnostics()

    package init(controlReads: any V2ProfileControlReading,
         avatars: @escaping @Sendable ([MediaID: Date]) async throws -> [MediaID: V2ResourceAvatarAccess],
         authorization: V2ActorRoomMediaAuthorizationPort) {
        self.controlReads = controlReads; self.avatars = avatars; self.authorization = authorization
    }

    public func read(_ request: V2ProfilePresentationBatchRequest, actorUserID: UserID,
                     deviceID: DeviceID) async throws -> V2ProfilePresentationBatchResponse {
        let values = try await readMany([.init(request: request, actorUserID: actorUserID, deviceID: deviceID)])
        return try values[0].get()
    }

    /// One bounded operation shares control reads and avatar preparation across
    /// recipients. Results keep input order, including independently failed or
    /// revoked devices. There is no complete service invocation per recipient.
    public func readMany(_ inputs: [V2ProfilePresentationReadRequest]) async throws -> [Result<V2ProfilePresentationBatchResponse, any Error>] {
        guard !inputs.isEmpty, inputs.count <= 100,
              inputs.reduce(0, { $0 + $1.request.keys.count }) <= 100 else { throw V2ProfileViewReadError.invalidRequest }
        for input in inputs {
            try V2ProfileControlRequest(keys: input.request.keys, actor: input.actorUserID, device: input.deviceID).validate()
            guard input.request.keys.allSatisfy({ $0.context.authorizationRoomID?.uuidValue != nil || $0.context.authorizationRoomID == nil })
            else { throw V2ProfileViewReadError.invalidRequest }
        }
        let instant = ContinuousClock.now
        let live = inputs.filter { $0.deadline > instant }
        guard let lastDeadline = live.map(\.deadline).max() else { throw V2ProfileControlBatchError.deadlineExceeded }
        let deadline = min(instant + .seconds(10), lastDeadline)
        let devices = live.map(\.deviceID)
        guard try await admission.enter(devices) else { throw V2ResourceProviderError.throttled(retryAfter: 1) }
        do {
            let results = try await readAdmitted(inputs, deadline: deadline)
            await admission.leave(devices)
            return results
        } catch { await admission.leave(devices); throw error }
    }

    /// The room query supplies candidates, not a display grant. Never copy its
    /// nickname text into the response; every result is reread through the same
    /// control/room authorization and lease fences as explicit profile lookups.
    public func readGroupNicknames(roomID: RoomID, afterUserID: UserID?, limit: Int,
        actorUserID: UserID, deviceID: DeviceID,
        candidates: @Sendable () async throws -> V2GroupNicknamePage) async throws -> V2GroupNicknamePresentationPageResponse {
        guard roomID.uuidValue != nil, afterUserID == nil || afterUserID?.uuidValue != nil,
              actorUserID.uuidValue != nil, deviceID.uuidValue != nil,
              (1...V2ProfileViewLookupLimits.maximumKeys).contains(limit)
        else { throw V2ProfileViewReadError.invalidRequest }
        guard try await admission.enter(deviceID) else { throw V2ResourceProviderError.throttled(retryAfter: 1) }
        let deadline = ContinuousClock.now + .seconds(10)
        do {
            try Task.checkCancellation()
            let page = try await candidates()
            try await admission.requireOpen()
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw V2ProfileControlBatchError.deadlineExceeded }
            let users = page.values.map(\.userID)
            guard users.count <= limit,
                  page.values.allSatisfy({ $0.roomID == roomID && $0.userID.uuidValue != nil }),
                  users.allSatisfy({ afterUserID == nil || $0.rawValue > afterUserID!.rawValue }),
                  zip(users, users.dropFirst()).allSatisfy({ $0.rawValue < $1.rawValue }),
                  page.nextCursor == nil || (users.count == limit && page.nextCursor == users.last)
            else { throw V2ProfilePresentationError.corruptPersistenceState }
            let batch: V2ProfilePresentationBatchResponse
            if users.isEmpty {
                // Even an empty directory response must respect a device revoked
                // while its room query was suspended. No self-profile is returned.
                _ = try await controlReads.read(.init(keys: [.init(userID: actorUserID, context: .relationship)],
                    actor: actorUserID, device: deviceID), deadline: deadline)
                batch = try .init(serverNowUnixMilliseconds: Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down)), results: [])
            } else {
                batch = try await readAdmitted(.init(keys: users.map { .init(userID: $0, context: .room(roomID)) }),
                    actorUserID: actorUserID, deviceID: deviceID, deadline: deadline, includeAvatars: false)
            }
            try await admission.requireOpen()
            let response = try V2GroupNicknamePresentationPageResponse(roomID: roomID, batch: batch, nextCursor: page.nextCursor)
            await admission.leave(deviceID)
            return response
        } catch {
            await admission.leave(deviceID)
            throw error
        }
    }

    /// Stop admission, drain control queries, then wait for readers already in
    /// room authorization or provider signing before their dependencies close.
    public func close() async {
        await admission.stop()
        await controlReads.close()
        await admission.waitForIdle()
    }

    /// 导入源必须仍是当前头像及获准变体。复制前和发布前各复核一次；调用方负责精确对象 hold。
    public func authorizeAvatarImport(key: V2ProfileViewLookupKey, mediaID: MediaID,
        variantID: ResourceVariantID, actorUserID: UserID, deviceID: DeviceID) async throws -> V2AuthorizedProfilePresentation {
        let response = try await read(.init(keys: [key]), actorUserID: actorUserID, deviceID: deviceID)
        guard case .presentation(let value, let access) = response.results.first,
              value.view.avatar?.mediaID == mediaID, access?.mediaID == mediaID, access?.variantID == variantID
        else { throw V2MediaStoreError.downloadNotAuthorized }
        return value
    }

    private func readAdmitted(_ request: V2ProfilePresentationBatchRequest, actorUserID: UserID,
                              deviceID: DeviceID, deadline: ContinuousClock.Instant,
                              includeAvatars: Bool = true) async throws -> V2ProfilePresentationBatchResponse {
        let values = try await readAdmitted([.init(request: request, actorUserID: actorUserID, deviceID: deviceID, deadline: deadline)],
                                           deadline: deadline, includeAvatars: includeAvatars)
        return try values[0].get()
    }

    /// Shared I/O may serve later callers after an earlier caller expires.
    /// Keep the original ordinal and cutoff for each recipient, and do not
    /// submit that recipient to another control pass after its cutoff.
    private func readLiveControl(_ inputs: [V2ProfilePresentationReadRequest], deadline: ContinuousClock.Instant) async throws
        -> [Result<V2ProfileControlSnapshot, any Error>] {
        try Task.checkCancellation()
        let instant = ContinuousClock.now
        let indices = inputs.indices.filter { instant < min(deadline, inputs[$0].deadline) }
        var values = [Result<V2ProfileControlSnapshot, any Error>](repeating: .failure(V2ProfileControlBatchError.deadlineExceeded),
            count: inputs.count)
        guard !indices.isEmpty else { return values }
        let queries = indices.map { index in
            V2ProfileControlRequest(keys: inputs[index].request.keys, actor: inputs[index].actorUserID, device: inputs[index].deviceID)
        }
        let readDeadline = min(deadline, indices.map { inputs[$0].deadline }.max()!)
        let loaded = try await controlReads.readMany(queries, deadline: readDeadline)
        guard loaded.count == indices.count else { throw V2ProfileControlBatchError.corruptResult }
        for (ordinal, index) in indices.enumerated() where .now < min(deadline, inputs[index].deadline) {
            values[index] = loaded[ordinal]
        }
        return values
    }

    private func readAdmitted(_ inputs: [V2ProfilePresentationReadRequest], deadline: ContinuousClock.Instant,
                              includeAvatars: Bool = true) async throws -> [Result<V2ProfilePresentationBatchResponse, any Error>] {
        let initial = try await readDiagnostics.measure(.initialControl) {
            try await readLiveControl(inputs, deadline: deadline)
        }
        guard initial.count == inputs.count else { throw V2ProfileControlBatchError.corruptResult }
        try await admission.requireOpen()
        var requests: [V2ProfileRoomScope: V2ActorProfileVisibilityBatchWire] = [:]
        var scopeDeadlines: [V2ProfileRoomScope: ContinuousClock.Instant] = [:]
        var keyRooms: [[V2ProfileViewLookupKey: V2ProfileRoomScope]] = []
        for (index, input) in inputs.enumerated() {
            var scopes: [V2ProfileViewLookupKey: V2ProfileRoomScope] = [:]
            if input.deadline > .now, case .success(let snapshot) = initial[index] {
                guard snapshot.rows.count == input.request.keys.count else { throw V2ProfileControlBatchError.corruptResult }
                for (key, row) in zip(input.request.keys, snapshot.rows) {
                    let room: RoomID
                    let kind: V2ActorProfileVisibilityBatchWire.RoomKind
                    switch key.context {
                    case .relationship: continue
                    case .room(let id): room = id; kind = .memberRoom
                    case .groupJoinReview(let id): room = id; kind = .groupJoinReview
                    case .directConversation:
                        guard let id = row.directRoomID else { continue }
                        room = try .init(id.uuidString); kind = .direct
                    }
                    let scope = V2ProfileRoomScope(actor: input.actorUserID, roomID: room, kind: kind)
                    scopes[key] = scope
                    scopeDeadlines[scope] = max(scopeDeadlines[scope] ?? input.deadline, input.deadline)
                    let targets = Array(Set((requests[scope]?.targetUserIDs ?? []) + [key.userID])).sorted { $0.rawValue < $1.rawValue }
                    requests[scope] = .init(roomID: room, actorUserID: input.actorUserID, roomKind: kind, targetUserIDs: targets)
                }
            }
            keyRooms.append(scopes)
        }
        let roomRequests = requests, roomDeadlines = scopeDeadlines
        var proofs = await readDiagnostics.measure(.initialRoom) {
            await capture(roomRequests, scopeDeadlines: roomDeadlines, deadline: deadline)
        }
        let final = try await readDiagnostics.measure(.finalControl) {
            try await readLiveControl(inputs, deadline: deadline)
        }
        guard final.count == inputs.count else { throw V2ProfileControlBatchError.corruptResult }
        var entries: [Result<[V2ProfilePresentationBatchEntry], any Error>] = []
        var avatarRequests: [MediaID: Date] = [:]
        for (index, input) in inputs.enumerated() {
            do {
                let before = try initial[index].get(), after = try final[index].get()
                guard before.rows.count == input.request.keys.count, after.rows.count == input.request.keys.count
                else { throw V2ProfileControlBatchError.corruptResult }
                let result = try presentations(input, initial: before, final: after, keyRooms: keyRooms[index], proofs: proofs,
                    deadline: min(deadline, input.deadline))
                if includeAvatars {
                    for entry in result {
                        guard case .presentation(let value, _) = entry, let media = value.view.avatar?.mediaID else { continue }
                        let expiry = min(value.lease.validUntil, value.lease.observedAt.addingTimeInterval(120))
                        avatarRequests[media] = min(avatarRequests[media] ?? expiry, expiry)
                    }
                }
                entries.append(.success(result))
            } catch { entries.append(.failure(error)) }
        }
        try await admission.requireOpen()
        let avatarAccess: [MediaID: V2ResourceAvatarAccess]
        do {
            let requestedAvatars = avatarRequests
            avatarAccess = requestedAvatars.isEmpty ? [:] : try await readDiagnostics.measure(.avatar) {
                try await avatars(requestedAvatars)
            }
        }
        catch is CancellationError { throw CancellationError() }
        catch { avatarAccess = [:] }
        let delivered = try await readDiagnostics.measure(.deliveryControl) {
            try await readLiveControl(inputs, deadline: deadline)
        }
        guard delivered.count == inputs.count else { throw V2ProfileControlBatchError.corruptResult }
        // Signing can suspend. Check both authorities again without keeping SQL
        // locks across provider I/O. Room actors coalesce these bounded queries.
        let liveScopes = Set(inputs.indices.filter { inputs[$0].deadline > .now }.flatMap { keyRooms[$0].values })
        let rechecks = requests.filter {
            guard liveScopes.contains($0.key), case .allowed? = proofs[$0.key] else { return false }
            return true
        }
        let checks = await readDiagnostics.measure(.deliveryRoom) {
            await capture(rechecks, scopeDeadlines: roomDeadlines, deadline: deadline)
        }
        for (scope, proof) in proofs {
            guard liveScopes.contains(scope), case .allowed(let before) = proof else { continue }
            guard case .allowed(let after) = checks[scope] else {
                readDiagnostics.record(.roomRecheckUnavailable); proofs[scope] = .retryable; continue
            }
            guard Self.sameRoomFacts(before, after) else {
                readDiagnostics.record(.roomFactsChanged); proofs[scope] = .retryable; continue
            }
        }
        try await admission.requireOpen()
        let now = Date(), milliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        return inputs.enumerated().map { index, input in
            do {
                guard .now < min(deadline, input.deadline) else {
                    readDiagnostics.record(.workExpired, count: input.request.keys.count)
                    throw V2ProfileControlBatchError.deadlineExceeded
                }
                let values = try entries[index].get(), before = try final[index].get(), after = try delivered[index].get()
                guard after.rows.count == input.request.keys.count else { throw V2ProfileControlBatchError.corruptResult }
                let checked = values.enumerated().map { ordinal, entry -> V2ProfilePresentationBatchEntry in
                    guard before.rows[ordinal].sameAuthorizationFacts(as: after.rows[ordinal]),
                          after.controlSequence >= before.controlSequence,
                          after.deviceExpiresAt > now else {
                        readDiagnostics.record(.controlFactsChanged); return .retryable(entry.key)
                    }
                    guard ContinuousClock.now < min(deadline, input.deadline) else { readDiagnostics.record(.workExpired); return .retryable(entry.key) }
                    if let room = keyRooms[index][entry.key] {
                        guard case .allowed = proofs[room] else { return .retryable(entry.key) }
                    }
                    guard case .presentation(let value, _) = entry else { return entry }
                    guard value.lease.validUntil <= after.deviceExpiresAt, value.lease.validUntil > now,
                          value.lease.observedAt <= now else { readDiagnostics.record(.leaseExpired); return .retryable(entry.key) }
                    var avatar = includeAvatars ? value.view.avatar.flatMap { avatarAccess[$0.mediaID] } : nil
                    if avatar?.plan.map({ $0.expiresAt <= now }) == true { avatar = avatar?.withoutDownloadPlan() }
                    return .presentation(value, avatar: avatar)
                }
                for entry in checked {
                    switch entry {
                    case .presentation: readDiagnostics.record(.presentation)
                    case .unavailable: readDiagnostics.record(.denial)
                    case .retryable: readDiagnostics.record(.retryable)
                    }
                }
                return .success(try .init(serverNowUnixMilliseconds: milliseconds, results: checked))
            } catch { return .failure(error) }
        }
    }

    private func capture(_ requests: [V2ProfileRoomScope: V2ActorProfileVisibilityBatchWire],
                         scopeDeadlines: [V2ProfileRoomScope: ContinuousClock.Instant],
                         deadline: ContinuousClock.Instant) async -> [V2ProfileRoomScope: V2ProfileRoomProof] {
        // One bounded invocation per room carries all its real viewers. Keep
        // the cross-room window bounded too; cancellation drains actual I/O.
        let rooms = Dictionary(grouping: requests.map { $0 }, by: { $0.value.roomID })
        return await withTaskGroup(of: [(V2ProfileRoomScope, V2ProfileRoomProof)].self) { group in
            var remaining = rooms.values.makeIterator()
            for _ in 0..<min(16, rooms.count) {
                guard !Task.isCancelled, ContinuousClock.now < deadline,
                      let room = remaining.next() else { break }
                group.addTask { await captureRoom(room, scopeDeadlines: scopeDeadlines, deadline: deadline) }
            }
            var result: [V2ProfileRoomScope: V2ProfileRoomProof] = [:]
            while let proofs = await group.next() {
                for (scope, proof) in proofs { result[scope] = proof }
                if !Task.isCancelled, ContinuousClock.now < deadline,
                   let room = remaining.next() {
                    group.addTask { await captureRoom(room, scopeDeadlines: scopeDeadlines, deadline: deadline) }
                }
            }
            return result
        }
    }

    private func captureRoom(_ entries: [(key: V2ProfileRoomScope, value: V2ActorProfileVisibilityBatchWire)],
                             scopeDeadlines: [V2ProfileRoomScope: ContinuousClock.Instant],
                             deadline: ContinuousClock.Instant) async -> [(V2ProfileRoomScope, V2ProfileRoomProof)] {
        // Cross-room work can wait behind the sixteen-call window. Recheck
        // eligibility at actual dispatch, not just when building the cohort.
        let instant = ContinuousClock.now
        let live = entries.filter { instant < min(deadline, scopeDeadlines[$0.key] ?? instant) }
        if live.count < entries.count { readDiagnostics.record(.workExpired, count: entries.count - live.count) }
        guard let first = live.first else { return [] }
        let readDeadline = min(deadline, live.compactMap { scopeDeadlines[$0.key] }.max()!)
        do {
            try Task.checkCancellation()
            guard ContinuousClock.now < readDeadline else {
                readDiagnostics.record(.workExpired, count: live.count)
                return live.map { ($0.key, .retryable) }
            }
            let proofs: [V2ActorProfileVisibilityBatchSnapshotWire?] = try await readDiagnostics.measure(.roomRPC) {
                if live.count == 1 { return [try await authorization.captureProfiles(first.value, deadline: readDeadline)] }
                return try await authorization.captureProfiles(.init(roomID: first.value.roomID,
                    requests: live.map(\.value)), deadline: readDeadline).map(Optional.some)
            }
            return zip(live, proofs).map { entry, proof in
                if let proof { return (entry.key, .allowed(proof)) }
                readDiagnostics.record(.roomUnavailable)
                return (entry.key, .unavailable)
            }
        } catch {
            let outcome: V2ProfilePresentationReadDiagnostics.Outcome
            switch error {
            case is CancellationError: outcome = .roomCancelled
            case V2RoomCallFailure.notAccepted(let reason), V2RoomCallFailure.rolledBack(let reason):
                switch reason {
                case .deadlineExceeded: outcome = .roomDeadline
                case .overloaded, .roomCapacityExhausted: outcome = .roomOverloaded
                case .cancelled: outcome = .roomCancelled
                case .staleActivation, .notReady, .retired, .authorityLost: outcome = .roomOwnershipChanged
                case .unavailable: outcome = .roomDependencyUnavailable
                case .notFound, .forbidden, .invalidRequest, .unsupportedVersion, .idempotencyConflict:
                    outcome = .roomRejected
                }
            default: outcome = .roomFailure
            }
            // Finite, aggregate categories only. These observations never
            // change the recipient result or retain error text or identities.
            readDiagnostics.record(outcome, count: live.count)
            return live.map { ($0.key, .retryable) }
        }
    }

    private static func sameRoomFacts(_ a: V2ActorProfileVisibilityBatchSnapshotWire, _ b: V2ActorProfileVisibilityBatchSnapshotWire) -> Bool {
        a.activation == b.activation && a.membershipRevision == b.membershipRevision && a.permissionRevision == b.permissionRevision
            && Set(a.visibleTargetUserIDs) == Set(b.visibleTargetUserIDs)
            && a.groupMembers.sorted { $0.userID.rawValue < $1.userID.rawValue } == b.groupMembers.sorted { $0.userID.rawValue < $1.userID.rawValue }
    }

    private func presentations(_ input: V2ProfilePresentationReadRequest, initial: V2ProfileControlSnapshot,
                               final: V2ProfileControlSnapshot, keyRooms: [V2ProfileViewLookupKey: V2ProfileRoomScope],
                               proofs: [V2ProfileRoomScope: V2ProfileRoomProof], deadline: ContinuousClock.Instant) throws -> [V2ProfilePresentationBatchEntry] {
        try input.request.keys.enumerated().map { index, key in
            try Task.checkCancellation()
            let before = initial.rows[index], after = final.rows[index]
            guard before.sameAuthorizationFacts(as: after), final.controlSequence >= initial.controlSequence else {
                readDiagnostics.record(.controlFactsChanged); return .retryable(key)
            }
            var observed = min(initial.observedAt, final.observedAt), expiry = min(initial.deviceExpiresAt, final.deviceExpiresAt)
            var roomID: RoomID?, membership: UInt64 = 0, permission: UInt64 = 0
            var visible = after.view != nil
            var member: V2GroupMemberPresentation?
            switch key.context {
            case .relationship:
                visible = visible && after.relationshipAllowed
            case .directConversation, .room, .groupJoinReview:
                if let room = keyRooms[key] {
                    switch proofs[room] {
                    case .allowed(let proof):
                        if case .directConversation = key.context {
                            guard after.directShardID == proof.activation.owner.shardID, after.directRouteEpoch == proof.activation.owner.epoch else { return .retryable(key) }
                        }
                        roomID = room.roomID
                        membership = UInt64(proof.membershipRevision); permission = UInt64(proof.permissionRevision)
                        visible = visible && proof.visibleTargetUserIDs.contains(key.userID)
                        observed = min(observed, proof.observedAt); expiry = min(expiry, proof.activationExpiresAt)
                        if visible, after.view?.state == .active, case .room = key.context {
                            member = try proof.groupMembers.first { $0.userID == key.userID }?.domain()
                        }
                    // A versionless room answer cannot order a denial against
                    // earlier grants. Keep it transient until fresh facts exist.
                    case .unavailable, .retryable, nil: return .retryable(key)
                    }
                } else {
                    guard case .directConversation = key.context, after.directRoomID == nil else { return .retryable(key) }
                    visible = false
                }
            }
            expiry = min(expiry, observed.addingTimeInterval(300))
            guard ContinuousClock.now < deadline else { readDiagnostics.record(.workExpired); return .retryable(key) }
            guard expiry > Date() else { readDiagnostics.record(.leaseExpired); return .retryable(key) }
            let version = try V2PresentationAuthorityVersion(controlSequence: final.controlSequence, roomID: roomID,
                membershipRevision: membership, permissionRevision: permission)
            guard visible, let view = after.view else { return .unavailable(try .init(key: key, authorityVersion: version)) }
            let lease = try V2PresentationAccessLease(actorUserID: input.actorUserID, deviceID: input.deviceID, key: key,
                profileRevision: view.revision, visibilityRevision: view.visibilityRevision, contextRevision: membership,
                authorityVersion: version, observedAt: observed, validUntil: expiry)
            return .presentation(try .init(view: view, lease: lease, groupMember: member, contactAlias: after.contactAlias), avatar: nil)
        }
    }


}

actor V2ProfilePresentationAdmission {
    private var active: [DeviceID: Int] = [:]
    private var count = 0
    private var closed = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    func enter(_ device: DeviceID) throws -> Bool { try enter([device]) }
    func enter(_ devices: [DeviceID]) throws -> Bool {
        try requireOpen()
        let additions = Dictionary(grouping: devices, by: { $0 }).mapValues(\.count)
        guard count + devices.count <= 512, additions.allSatisfy({ active[$0.key, default: 0] + $0.value <= 2 }) else { return false }
        count += devices.count
        for (device, amount) in additions { active[device, default: 0] += amount }
        return true
    }
    func leave(_ devices: [DeviceID]) { for device in devices { leave(device) } }
    func leave(_ device: DeviceID) {
        count -= 1
        if let remaining = active[device], remaining > 1 { active[device] = remaining - 1 }
        else { active.removeValue(forKey: device) }
        if count == 0 {
            for waiter in idleWaiters { waiter.resume() }
            idleWaiters.removeAll()
        }
    }
    func requireOpen() throws { if closed { throw V2ProfileControlBatchError.closed } }
    func stop() { closed = true }
    func waitForIdle() async {
        if count != 0 { await withCheckedContinuation { idleWaiters.append($0) } }
    }
}

private enum V2ProfileRoomProof: Sendable {
    case allowed(V2ActorProfileVisibilityBatchSnapshotWire), unavailable, retryable
}

private struct V2ProfileRoomScope: Hashable, Sendable {
    let actor: UserID
    let roomID: RoomID
    let kind: V2ActorProfileVisibilityBatchWire.RoomKind
}
