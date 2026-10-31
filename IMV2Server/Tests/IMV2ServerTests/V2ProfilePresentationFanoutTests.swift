import Foundation
import IMV2Core
import IMV2ActorContracts
import Testing
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts

@Suite(.serialized)
struct V2ProfilePresentationFanoutTests {
    @Test("room failure categories preserve retryable results for every cohort recipient",
          arguments: [
            (V2RoomCallFailure.notAccepted(.deadlineExceeded), V2ProfilePresentationReadDiagnostics.Outcome.roomDeadline),
            (.rolledBack(.deadlineExceeded), .roomDeadline),
            (.notAccepted(.overloaded), .roomOverloaded),
            (.notAccepted(.roomCapacityExhausted), .roomOverloaded),
            (.notAccepted(.cancelled), .roomCancelled),
            (.rolledBack(.cancelled), .roomCancelled),
            (.notAccepted(.staleActivation), .roomOwnershipChanged),
            (.notAccepted(.notReady), .roomOwnershipChanged),
            (.notAccepted(.retired), .roomOwnershipChanged),
            (.rolledBack(.authorityLost), .roomOwnershipChanged),
            (.rolledBack(.unavailable), .roomDependencyUnavailable),
            (.notAccepted(.notFound), .roomRejected),
            (.notAccepted(.forbidden), .roomRejected),
            (.notAccepted(.invalidRequest), .roomRejected),
            (.notAccepted(.unsupportedVersion), .roomRejected),
            (.notAccepted(.idempotencyConflict), .roomRejected),
            (.outcomeUnknown, .roomFailure)
          ])
    func roomFailureCategories(failure: V2RoomCallFailure, outcome: V2ProfilePresentationReadDiagnostics.Outcome) async throws {
        try await checkRoomFailure(failure, outcome: outcome)
    }

    @Test("local cancellation of room work remains distinct from an unknown dependency failure")
    func roomCancellationCategory() async throws {
        try await checkRoomFailure(CancellationError(), outcome: .roomCancelled)
    }

    private func checkRoomFailure(_ error: any Error, outcome: V2ProfilePresentationReadDiagnostics.Outcome) async throws {
        let room = RoomID(uuid: UUID()), target = UserID(uuid: UUID())
        let inputs = try (0..<100).map { _ in
            V2ProfilePresentationReadRequest(request: try .init(keys: [.init(userID: target, context: .room(room))]),
                actorUserID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()))
        }
        let service = V2ResourceProfilePresentationService(controlReads: VersionedControl(denied: false, changed: false),
            avatars: { _ in [:] }, authorization: .init { _, _ in throw error })
        do {
            let values = try await service.readMany(inputs)
            #expect(values.count == inputs.count)
            for (input, value) in zip(inputs, values) {
                #expect(try value.get().results == [.retryable(input.request.keys[0])])
            }
            let snapshot = service.readDiagnostics.snapshot()
            #expect(snapshot.outcomes[outcome] == 100)
            #expect(snapshot.outcomes[.retryable] == 100)
            #expect(snapshot.stages[.roomRPC]?.calls == 1)
            #expect(snapshot.stages[.roomRPC]?.failures == 1)
        } catch { await service.close(); throw error }
        await service.close()
    }

    @Test("room work that expires behind the concurrency window never starts a late RPC")
    func queuedRoomDeadlines() async throws {
        let target = UserID(uuid: UUID()), gate = RoomCallGate()
        let earlyDeadline = ContinuousClock.now + .milliseconds(200)
        let lateDeadline = ContinuousClock.now + .seconds(3)
        let rooms = (0..<18).map { _ in RoomID(uuid: UUID()) }
        let inputs = try rooms.enumerated().map { index, room in
            V2ProfilePresentationReadRequest(request: try .init(keys: [.init(userID: target, context: .room(room))]),
                actorUserID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), deadline: index == 17 ? lateDeadline : earlyDeadline)
        }
        let service = V2ResourceProfilePresentationService(controlReads: VersionedControl(denied: false, changed: false),
            avatars: { _ in [:] }, authorization: .init { query, _ in try await gate.query(query) })
        let read = Task { try await service.readMany(inputs) }
        do {
            while await gate.active < 16 {
                guard .now < lateDeadline else { throw CancellationError() }
                await Task.yield()
            }
            let firstRooms = await gate.rooms
            #expect(firstRooms.count == 16)
            try await ContinuousClock().sleep(until: earlyDeadline + .milliseconds(30))
            await gate.release()
            let values = try await read.value
            #expect(values.count == inputs.count)
            for value in values.dropLast() {
                #expect(throws: V2ProfileControlBatchError.deadlineExceeded) { try value.get() }
            }
            #expect(try values[17].get().results == [.retryable(inputs[17].request.keys[0])])
            #expect(await gate.rooms == firstRooms.union([rooms[17]]))
            #expect(await gate.calls == firstRooms.count + (firstRooms.contains(rooms[17]) ? 0 : 1))
            #expect(await gate.active == 0)
            await service.close()
        } catch {
            read.cancel(); await gate.release(); _ = await read.result; await service.close(); throw error
        }
    }

    @Test("an expired recipient is excluded from later authority passes without failing its live peer",
          arguments: [0, 1, 2, 3], [false, true])
    func individualDeadlines(expiryPass: Int, roomScoped: Bool) async throws {
        let instant = ContinuousClock.now
        let earlyDeadline = instant + .milliseconds(expiryPass > 0 ? 100 : -100)
        let lateDeadline = instant + .seconds(2)
        let control = ExpiringRecipientControl(holdUntil: earlyDeadline + .milliseconds(30), holdOnPass: expiryPass)
        let target = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let authority = try CohortRoomAuthority(room: room)
        let inputs = try [earlyDeadline, lateDeadline].map { deadline in
            V2ProfilePresentationReadRequest(request: try .init(keys: [.init(userID: target,
                context: roomScoped ? .room(room) : .relationship)]),
                actorUserID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), deadline: deadline)
        }
        let service = V2ResourceProfilePresentationService(controlReads: control, avatars: { _ in [:] },
            authorization: .init { query, _ in try await authority.query(query) })
        do {
            let values = try await service.readMany(inputs)
            #expect(values.count == 2)
            #expect(throws: V2ProfileControlBatchError.deadlineExceeded) { try values[0].get() }
            guard case .presentation(let value, _) = try values[1].get().results.first else {
                Issue.record("live recipient lost its presentation"); await service.close(); return
            }
            #expect(value.lease.actorUserID == inputs[1].actorUserID)
            #expect(value.lease.deviceID == inputs[1].deviceID)
            let expectedDevices = (1...3).map { pass in pass <= expiryPass ? inputs.map(\.deviceID) : [inputs[1].deviceID] }
            #expect(await control.devices == expectedDevices)
            #expect(await control.deadlines == [lateDeadline, lateDeadline, lateDeadline])
            if roomScoped {
                let firstViewers = expiryPass >= 2 ? Set(inputs.map(\.actorUserID)) : Set([inputs[1].actorUserID])
                #expect(await authority.viewerBatches == [firstViewers, Set([inputs[1].actorUserID])])
            } else { #expect(await authority.calls == 0) }
        } catch { await service.close(); throw error }
        await service.close()
    }

    @Test("100 room viewers use two authority calls while retaining recipient identities")
    func roomRecipientsShareCalls() async throws {
        let room = RoomID(uuid: UUID()), target = UserID(uuid: UUID())
        let control = VersionedControl(denied: false, changed: false)
        let authority = try CohortRoomAuthority(room: room)
        let inputs = try (0..<100).map { _ in
            V2ProfilePresentationReadRequest(request: try .init(keys: [.init(userID: target, context: .room(room))]),
                actorUserID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()))
        }
        let service = V2ResourceProfilePresentationService(controlReads: control, avatars: { _ in [:] },
            authorization: .init { query, _ in try await authority.query(query) })
        do {
            let values = try await service.readMany(inputs)
            #expect(values.count == inputs.count)
            for (input, result) in zip(inputs, values) {
                guard case .presentation(let value, _) = try result.get().results.first else {
                    Issue.record("missing room presentation"); continue
                }
                #expect(value.lease.actorUserID == input.actorUserID)
                #expect(value.lease.deviceID == input.deviceID)
            }
            let calls = await authority.calls
            #expect(calls == 2)
            #expect(await authority.viewers == Set(inputs.map(\.actorUserID)))
            #expect(service.readDiagnostics.snapshot().stages[.roomRPC]?.calls == 2)
        } catch { await service.close(); throw error }
        await service.close()
    }

    @Test("a batch bounds cross-room calls and cancellation does not start remaining rooms", arguments: [false, true])
    func boundedRoomCalls(cancel: Bool) async throws {
        let target = UserID(uuid: UUID())
        let control = VersionedControl(denied: false, changed: false), gate = RoomCallGate()
        let inputs = try (0..<100).map { _ in
            V2ProfilePresentationReadRequest(request: try .init(keys: [.init(userID: target, context: .room(.init(uuid: UUID())))]),
                actorUserID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()))
        }
        let service = V2ResourceProfilePresentationService(controlReads: control, avatars: { _ in [:] },
            authorization: .init { query, _ in try await gate.query(query) })
        let read = Task { try await service.readMany(inputs) }
        do {
            let deadline = ContinuousClock.now + .seconds(3)
            while await gate.active < 16 {
                guard ContinuousClock.now < deadline else { throw CancellationError() }
                await Task.yield()
            }
            try await Task.sleep(for: .milliseconds(50))
            #expect(await gate.active == 16)
            #expect(await gate.peak <= 16)
            if cancel { read.cancel() }
            await gate.release()
            let result = await read.result
            if cancel { #expect(await gate.calls == 16) }
            else {
                #expect(try result.get().count == 100)
                #expect(await gate.calls == 100)
            }
            #expect(await gate.active == 0)
        } catch {
            read.cancel(); await gate.release(); _ = await read.result
            await service.close(); throw error
        }
        await service.close()
    }

    @Test("cancelling a 100-viewer cohort keeps shutdown waiting for the actual room call")
    func cohortCancellationDrains() async throws {
        let room = RoomID(uuid: UUID()), target = UserID(uuid: UUID()), gate = RoomCallGate()
        let inputs = try (0..<100).map { _ in
            V2ProfilePresentationReadRequest(request: try .init(keys: [.init(userID: target, context: .room(room))]),
                actorUserID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()))
        }
        let service = V2ResourceProfilePresentationService(
            controlReads: VersionedControl(denied: false, changed: false), avatars: { _ in [:] },
            authorization: .init { query, _ in try await gate.query(query) })
        let read = Task { try await service.readMany(inputs) }
        var closing: Task<Void, Never>?
        do {
            let deadline = ContinuousClock.now + .seconds(3)
            while await gate.active == 0 {
                guard ContinuousClock.now < deadline else { throw CancellationError() }
                await Task.yield()
            }
            read.cancel()
            closing = Task { await service.close(); await gate.recordServiceClosed() }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(50))
            #expect(await gate.active == 1)
            #expect(await gate.calls == 1)
            #expect(await !gate.serviceClosed)
            await gate.release()
            _ = await read.result
            await closing?.value
            #expect(await gate.active == 0)
            #expect(await gate.calls == 1)
            #expect(await gate.serviceClosed)
        } catch {
            read.cancel(); await gate.release(); _ = await read.result
            await closing?.value
            await service.close(); throw error
        }
    }

    @Test("all-expired batches do no authority work; live batches keep the latest original deadline", arguments: [false, true])
    func callerDeadline(expired: Bool) async throws {
        let control = VersionedControl(denied: false, changed: false)
        let service = V2ResourceProfilePresentationService(controlReads: control, avatars: { _ in [:] },
            authorization: .init { _, _ in Issue.record("No room authority in relationship scope"); return .notVisible })
        let deadline = ContinuousClock.now + .seconds(expired ? -1 : 1)
        let target = UserID(uuid: UUID())
        let requests = try [deadline + .seconds(1), deadline].map { budget in
            V2ProfilePresentationReadRequest(request: try .init(keys: [.init(userID: target, context: .relationship)]),
                actorUserID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), deadline: budget)
        }
        do {
            if expired {
                await #expect(throws: V2ProfileControlBatchError.deadlineExceeded) { try await service.readMany(requests) }
                #expect(await control.passes == 0)
            } else {
                let results = try await service.readMany(requests)
                #expect(results.count == 2)
                #expect(await control.deadlines == [deadline + .seconds(1), deadline + .seconds(1), deadline + .seconds(1)])
            }
        } catch { await service.close(); throw error }
        await service.close()
    }

    @Test("grants and denials both recheck ABA revisions; unrelated journal progress does not invalidate stable facts",
          arguments: [false, true], [false, true])
    func versionedRechecks(denied: Bool, changed: Bool) async throws {
        let control = VersionedControl(denied: denied, changed: changed)
        let key = V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .relationship)
        let service = V2ResourceProfilePresentationService(controlReads: control, avatars: { _ in [:] },
            authorization: .init { _, _ in Issue.record("No room authority in relationship scope"); return .notVisible })
        let response = try await service.read(.init(keys: [key]), actorUserID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()))
        if changed { #expect(response.results == [.retryable(key)]) }
        else if denied {
            guard case .unavailable(let value) = response.results[0] else { throw CancellationError() }
            #expect(value.key == key && value.authorityVersion.controlSequence == 2)
        } else {
            guard case .presentation(let value, _) = response.results[0] else { throw CancellationError() }
            #expect(value.lease.authorityVersion.controlSequence == 2)
        }
        #expect(await control.passes == 3)
        await service.close()
    }

    @Test("one hundred recipients share three control passes and one avatar preparation")
    func batchPhases() async throws {
        let target = UserID(uuid: UUID()), media = MediaID(uuid: UUID())
        let inputs = try (0..<100).map { _ in
            V2ProfilePresentationReadRequest(request: try .init(keys: [.init(userID: target, context: .relationship)]),
                                            actorUserID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()))
        }
        let control = FanoutControl(target: target, media: media, deniedDevice: inputs[37].deviceID)
        let avatars = AvatarPreparation()
        let service = V2ResourceProfilePresentationService(controlReads: control, avatars: { await avatars.prepare($0) },
            authorization: .init { _, _ in Issue.record("relationship reads must not call room authority"); return .notVisible })
        let result = try await service.readMany(inputs)
        #expect(result.count == 100)
        for (index, value) in result.enumerated() {
            if index == 37 { #expect(throws: V2MediaStoreError.downloadNotAuthorized) { _ = try value.get() }; continue }
            guard case .presentation(let presentation, _) = try value.get().results.first else { Issue.record("missing presentation"); continue }
            #expect(presentation.lease.actorUserID == inputs[index].actorUserID)
            #expect(presentation.lease.deviceID == inputs[index].deviceID)
            #expect(presentation.contactAlias?.ownerUserID == inputs[index].actorUserID)
        }
        #expect(await control.batchSizes == [100, 100, 100])
        #expect(await avatars.calls == 1)
        #expect(await avatars.keys == [media])
        await service.close()
    }
}

private actor ExpiringRecipientControl: V2ProfileControlReading {
    let holdUntil: ContinuousClock.Instant
    let holdOnPass: Int
    let content = VersionedControl(denied: false, changed: false)
    var devices: [[DeviceID]] = []
    var deadlines: [ContinuousClock.Instant] = []
    init(holdUntil: ContinuousClock.Instant, holdOnPass: Int) { self.holdUntil = holdUntil; self.holdOnPass = holdOnPass }
    func readMany(_ requests: [V2ProfileControlRequest], deadline: ContinuousClock.Instant) async throws -> [Result<V2ProfileControlSnapshot, any Error>] {
        devices.append(requests.map(\.device)); deadlines.append(deadline)
        if devices.count == holdOnPass { try await ContinuousClock().sleep(until: holdUntil) }
        try Task.checkCancellation()
        guard .now < deadline else { throw V2ProfileControlBatchError.deadlineExceeded }
        return try await content.readMany(requests, deadline: deadline)
    }
    func close() async { await content.close() }
}

private actor CohortRoomAuthority {
    let token: V2RoomActivationToken
    var calls = 0
    var viewers: Set<UserID> = []
    var viewerBatches: [Set<UserID>] = []
    init(room: RoomID) throws {
        token = .init(roomID: room, owner: try .init(shardID: "profile-cohort", epoch: 0),
            activationEpoch: try .init(1), host: .init(hostID: .init(uuid: UUID()), incarnationID: UUID()))
    }
    func query(_ query: V2RoomMediaAuthorizationQuery) throws -> V2RoomMediaAuthorizationResult {
        calls += 1
        let now = Date()
        func proof(_ request: V2ActorProfileVisibilityBatchWire) -> V2ActorProfileVisibilityBatchSnapshotWire {
            viewers.insert(request.actorUserID)
            return .init(request: request, activation: token, membershipRevision: 1,
                visibleTargetUserIDs: request.targetUserIDs, observedAt: now, activationExpiresAt: now.addingTimeInterval(30))
        }
        switch query {
        case .profileVisibilityBatch(let request):
            viewerBatches.append([request.actorUserID]); return .profilesVisible(proof(request))
        case .profileVisibilityCohort(let request):
            viewerBatches.append(Set(request.requests.map(\.actorUserID)))
            return .profilesVisibleCohort(request.requests.map(proof))
        default: throw CancellationError()
        }
    }
}

private actor RoomCallGate {
    var active = 0, peak = 0, calls = 0
    var rooms: Set<RoomID> = []
    var serviceClosed = false
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func query(_ query: V2RoomMediaAuthorizationQuery) async throws -> V2RoomMediaAuthorizationResult {
        switch query {
        case .profileVisibilityBatch(let request): rooms.insert(request.roomID)
        case .profileVisibilityCohort(let request): rooms.insert(request.roomID)
        default: throw CancellationError()
        }
        calls += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        if !open { await withCheckedContinuation { waiters.append($0) } }
        try Task.checkCancellation()
        return .notVisible
    }
    func release() {
        open = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
    func recordServiceClosed() { serviceClosed = true }
}

private actor VersionedControl: V2ProfileControlReading {
    let denied: Bool, changed: Bool
    var passes: UInt64 = 0
    var deadlines: [ContinuousClock.Instant] = []
    init(denied: Bool, changed: Bool) { self.denied = denied; self.changed = changed }
    func readMany(_ requests: [V2ProfileControlRequest], deadline: ContinuousClock.Instant) throws -> [Result<V2ProfileControlSnapshot, any Error>] {
        passes += 1
        deadlines.append(deadline)
        return try requests.map { input in
            let revision = try #require(V2ProfileRevision(rawValue: 1)), user = input.keys[0].userID
            let view = try V2ProfileView(userID: user, publicIdentity: .init(userID: user,
                handle: .init("author"), displayName: "Author", accountKind: .regular), avatar: nil, state: .active,
                revision: revision, visibilityRevision: revision)
            let row = V2ProfileControlFacts(view: denied ? nil : view, directRoomID: nil, directRouteEpoch: nil,
                directShardID: nil, relationshipAllowed: true, relationshipUpdatedAt: nil,
                outgoingBlockRevision: changed && passes == 3 ? 2 : 0)
            return .success(.init(rows: [row], observedAt: Date(), deviceExpiresAt: Date().addingTimeInterval(60), controlSequence: passes))
        }
    }
    func close() {}
}

private actor AvatarPreparation {
    var calls = 0
    var keys: Set<MediaID> = []
    func prepare(_ requests: [MediaID: Date]) -> [MediaID: V2ResourceAvatarAccess] {
        calls += 1; keys.formUnion(requests.keys); return [:]
    }
}

private actor FanoutControl: V2ProfileControlReading {
    let target: UserID, media: MediaID, deniedDevice: DeviceID
    var batchSizes: [Int] = []
    init(target: UserID, media: MediaID, deniedDevice: DeviceID) { self.target = target; self.media = media; self.deniedDevice = deniedDevice }
    func readMany(_ requests: [V2ProfileControlRequest], deadline: ContinuousClock.Instant) throws -> [Result<V2ProfileControlSnapshot, any Error>] {
        batchSizes.append(requests.count)
        return try requests.map { request in
            if request.device == deniedDevice { return .failure(V2MediaStoreError.downloadNotAuthorized) }
            let revision = try #require(V2ProfileRevision(rawValue: 1))
            let view = try V2ProfileView(userID: target,
                publicIdentity: .init(userID: target, handle: .init("author"), displayName: "Shared", accountKind: .regular),
                avatar: .init(mediaID: media), state: .active, revision: revision, visibilityRevision: revision)
            let row = V2ProfileControlFacts(view: view, directRoomID: nil, directRouteEpoch: nil, directShardID: nil,
                relationshipAllowed: true, relationshipUpdatedAt: nil,
                contactAlias: try .init(ownerUserID: request.actor, targetUserID: target, remarkName: request.actor.rawValue, revision: revision))
            return .success(.init(rows: [row], observedAt: Date(), deviceExpiresAt: Date().addingTimeInterval(600)))
        }
    }
    func close() {}
}
