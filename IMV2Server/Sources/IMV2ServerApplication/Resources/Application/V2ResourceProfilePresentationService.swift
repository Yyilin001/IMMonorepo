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

    package init(controlReads: any V2ProfileControlReading,
         avatars: @escaping @Sendable ([MediaID: Date]) async throws -> [MediaID: V2ResourceAvatarAccess],
         authorization: V2ActorRoomMediaAuthorizationPort) {
        self.controlReads = controlReads; self.avatars = avatars; self.authorization = authorization
    }

    public func read(_ request: V2ProfilePresentationBatchRequest, actorUserID: UserID,
                     deviceID: DeviceID) async throws -> V2ProfilePresentationBatchResponse {
        guard request.keys.allSatisfy({ key in
            guard key.userID.uuidValue != nil else { return false }
            if let room = key.context.authorizationRoomID { return room.uuidValue != nil }
            return true
        }) else { throw V2ProfileViewReadError.invalidRequest }
        guard try await admission.enter(deviceID) else { throw V2ResourceProviderError.throttled(retryAfter: 1) }
        do {
            let response = try await readAdmitted(request, actorUserID: actorUserID, deviceID: deviceID,
                deadline: .now + .seconds(10))
            await admission.leave(deviceID)
            return response
        } catch {
            await admission.leave(deviceID)
            throw error
        }
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
        let initial = try await controlReads.read(.init(keys: request.keys, actor: actorUserID, device: deviceID), deadline: deadline)
        try await admission.requireOpen()
        var roomRequests: [V2ProfileRoomScope: V2ActorProfileVisibilityBatchWire] = [:]
        var keyRooms: [V2ProfileViewLookupKey: V2ProfileRoomScope] = [:]
        for (key, row) in zip(request.keys, initial.rows) where row.view != nil {
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
            let scope = V2ProfileRoomScope(roomID: room, kind: kind)
            keyRooms[key] = scope
            let previous = roomRequests[scope]
            guard previous == nil || previous?.roomKind == kind else {
                throw V2ProfileViewReadError.invalidRequest
            }
            let targets = Array(Set((previous?.targetUserIDs ?? []) + [key.userID])).sorted { $0.rawValue < $1.rawValue }
            roomRequests[scope] = .init(roomID: room, actorUserID: actorUserID, roomKind: kind, targetUserIDs: targets)
        }
        // At most four of the request's eight room contexts run at once.
        let requests = roomRequests.values.sorted { $0.roomID.rawValue < $1.roomID.rawValue }
        var proofs: [V2ProfileRoomScope: V2ProfileRoomProof] = [:]
        for start in stride(from: 0, to: requests.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(requests[start..<min(start + 4, requests.count)])
            let captured = await withTaskGroup(of: (V2ProfileRoomScope, V2ProfileRoomProof).self) { group in
                for query in batch {
                    group.addTask {
                        let scope = V2ProfileRoomScope(roomID: query.roomID, kind: query.roomKind)
                        do {
                            guard ContinuousClock.now < deadline else { return (scope, .retryable) }
                            if let proof = try await authorization.captureProfiles(query, deadline: deadline) {
                                return (scope, .allowed(proof))
                            }
                            return (scope, .unavailable)
                        } catch { return (scope, .retryable) }
                    }
                }
                var results: [(V2ProfileRoomScope, V2ProfileRoomProof)] = []
                for await result in group { results.append(result) }
                return results
            }
            for (room, proof) in captured { proofs[room] = proof }
        }
        let final = try await controlReads.read(.init(keys: request.keys, actor: actorUserID, device: deviceID), deadline: deadline)

        var results: [V2ProfilePresentationBatchEntry] = []
        var avatarRequests: [MediaID: Date] = [:]
        for (index, key) in request.keys.enumerated() {
            try Task.checkCancellation()
            let before = initial.rows[index], after = final.rows[index]
            guard let view = after.view else { results.append(.unavailable(key)); continue }
            guard before.sameAuthorizationFacts(as: after) else { results.append(.retryable(key)); continue }
            var observedAt = min(initial.observedAt, final.observedAt)
            var expiresAt = min(initial.deviceExpiresAt, final.deviceExpiresAt)
            var contextRevision: UInt64 = 0
            var groupMember: V2GroupMemberPresentation?
            switch key.context {
            case .relationship:
                guard after.relationshipAllowed else { results.append(.unavailable(key)); continue }
            case .directConversation, .room, .groupJoinReview:
                guard let room = keyRooms[key] else { results.append(.unavailable(key)); continue }
                switch proofs[room] {
                case .allowed(let proof):
                    guard proof.visibleTargetUserIDs.contains(key.userID) else { results.append(.unavailable(key)); continue }
                    if case .directConversation = key.context {
                        guard after.directShardID == proof.activation.owner.shardID,
                              after.directRouteEpoch == proof.activation.owner.epoch else { results.append(.retryable(key)); continue }
                    }
                    observedAt = min(observedAt, proof.observedAt)
                    expiresAt = min(expiresAt, proof.activationExpiresAt)
                    contextRevision = UInt64(proof.membershipRevision)
                    if view.state == .active, case .room = key.context {
                        groupMember = try proof.groupMembers.first(where: { $0.userID == key.userID })?.domain()
                    }
                case .unavailable: results.append(.unavailable(key)); continue
                case .retryable, nil: results.append(.retryable(key)); continue
                }
            }
            expiresAt = min(expiresAt, observedAt.addingTimeInterval(300))
            guard expiresAt > Date(), ContinuousClock.now < deadline else { results.append(.retryable(key)); continue }
            let lease = try V2PresentationAccessLease(actorUserID: actorUserID, deviceID: deviceID, key: key,
                profileRevision: view.revision, visibilityRevision: view.visibilityRevision,
                contextRevision: contextRevision, observedAt: observedAt, validUntil: expiresAt)
            if includeAvatars, let reference = view.avatar {
                let accessExpiry = min(expiresAt, observedAt.addingTimeInterval(120))
                avatarRequests[reference.mediaID] = min(avatarRequests[reference.mediaID] ?? accessExpiry, accessExpiry)
            }
            results.append(.presentation(try .init(view: view, lease: lease, groupMember: groupMember, contactAlias: after.contactAlias), avatar: nil))
        }
        try await admission.requireOpen()
        do {
            let access = try await avatars(avatarRequests)
            results = results.map { entry in
                guard case .presentation(let value, _) = entry else { return entry }
                return .presentation(value, avatar: value.view.avatar.flatMap { access[$0.mediaID] })
            }
        } catch {
            // A provider outage is never cached as an authorization denial.
            results = results.map { entry in
                guard case .presentation(let value, _) = entry, value.view.avatar != nil else { return entry }
                return .retryable(entry.key)
            }
        }
        let deliveredControl = try await controlReads.read(.init(keys: request.keys, actor: actorUserID, device: deviceID), deadline: deadline)
        // Provider signing can suspend. Recheck both authorities after it returns; never hold SQL locks over provider I/O.
        let allowed = proofs.compactMap { room, proof -> (V2ProfileRoomScope, V2ActorProfileVisibilityBatchSnapshotWire)? in
            if case .allowed(let snapshot) = proof { return (room, snapshot) }
            return nil
        }
        for start in stride(from: 0, to: allowed.count, by: 4) {
            try await admission.requireOpen()
            let batch = Array(allowed[start..<min(start + 4, allowed.count)])
            let rechecks = await withTaskGroup(of: (V2ProfileRoomScope, Bool).self) { group in
                for (room, proof) in batch {
                    group.addTask {
                        do {
                            guard ContinuousClock.now < deadline else { return (room, false) }
                            return (room, try await authorization.recheckProfiles(proof, deadline: deadline))
                        } catch { return (room, false) }
                    }
                }
                var results: [(V2ProfileRoomScope, Bool)] = []
                for await result in group { results.append(result) }
                return results
            }
            for (room, matches) in rechecks where !matches { proofs[room] = .retryable }
        }

        let now = Date()
        let nowMS = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        // Slow signing cannot return already expired leases or extend their original observation time.
        results = results.enumerated().map { index, value in
            guard case .presentation(let presentation, let avatar) = value else { return value }
            guard final.rows[index].sameAuthorizationFacts(as: deliveredControl.rows[index]),
                  presentation.lease.validUntil <= deliveredControl.deviceExpiresAt,
                  ContinuousClock.now < deadline else { return .retryable(value.key) }
            if let room = keyRooms[value.key] {
                guard case .allowed = proofs[room] else { return .retryable(value.key) }
            }
            guard presentation.lease.observedAtUnixMilliseconds <= nowMS,
                  presentation.lease.validUntilUnixMilliseconds > nowMS,
                  avatar.map({ $0.plan.expiresAtUnixMilliseconds > nowMS }) ?? true else { return .retryable(value.key) }
            return value
        }
        return try .init(serverNowUnixMilliseconds: nowMS, results: results)
    }


}

actor V2ProfilePresentationAdmission {
    private var active: [DeviceID: Int] = [:]
    private var count = 0
    private var closed = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    func enter(_ device: DeviceID) throws -> Bool {
        try requireOpen()
        guard count < 64, active[device, default: 0] < 2 else { return false }
        count += 1; active[device, default: 0] += 1; return true
    }
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
    let roomID: RoomID
    let kind: V2ActorProfileVisibilityBatchWire.RoomKind
}
