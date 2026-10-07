import Foundation
import Synchronization
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import Testing
@testable import IMV2ServerGateway

@Suite("Recovery coordinator authority boundaries")
struct V2RealtimeRecoveryCoordinatorTests {
    @Test("SQL lowercase user topic finds its canonical authenticated account scope")
    func accountScopeTopicIndexNormalizesIncomingUUID() throws {
        let index = V2RealtimeScopeGenerations()
        let user = try UserID("EED841A8-28BD-5C9D-8BDC-896DAEDCF9A3"), connection = UUID()
        let scope = V2RealtimeRecoveryKey(connection: connection, kind: .userSync, id: user.rawValue)
        index[scope] = 7
        let incoming = V2RealtimeTopicKey(kind: .userSync, id: user.rawValue)
        #expect(index.matching(kind: .userSync, id: incoming.id) == [scope])
        #expect(index.matching(kind: .userSync, id: user.rawValue) == [scope])
        #expect(index.matching(kind: .roomEvents, id: incoming.id).isEmpty)
        #expect(index.removeConnection(connection) == [scope])
        #expect(index.matching(kind: .userSync, id: incoming.id).isEmpty)
        let opaque = V2RealtimeRecoveryKey(connection: connection, kind: .userSync, id: "Opaque-User")
        index[opaque] = 8
        #expect(index.matching(kind: .userSync, id: "opaque-user").isEmpty)
    }

    @Test("four presence observation waits use query roots while typing control progresses")
    func presencePreparationDoesNotOccupyControl() async throws {
        let coordinator = V2RealtimeRecoveryCoordinator()
        let broker = RecoveryPresenceStageBroker(), observations = RecoveryPresencePreparationGate()
        await coordinator.configureLiveActivity(broker)
        coordinator.configurePorts(.init(preparePresence: { _, _, _ in
            try await observations.prepare()
        }, compensateScope: { _, _, _, _ in }))
        for index in 0..<4 {
            let connection = try makeContext(lifecycle: UInt64(100 + index))
            coordinator.installConnection(connection)
            await coordinator.beginScopeRecovery(connection: connection.handle.connectionID,
                kind: .userPresence, id: UserID(uuid: UUID()).rawValue)
            try await waitForInterest { await observations.held == index + 1 }
        }
        let blocked = await coordinator.realtimeRecoverySnapshot()
        #expect(blocked.queryRoots == 4)
        #expect(blocked.control == 0)
        // The Presence owner reports real SQL separately; joining its preparation
        // port must never fabricate a room permission provider attempt.
        let typingReady = Mutex(0)
        let typingFixture: (V2RealtimeRecoveryConnectionContext, V2DeviceConnectionRegistry)
        do {
            typingFixture = try await makeAuthenticatedTypingContext { write in
                let version = UInt8(IMV2ProtocolVersion.current)
                var decoder = V2FrameDecoder(limits: try! .init(maximumPayloadBytes: 4096, acceptedVersions: [version]))
                guard let frame = try? decoder.append(write.bytes).first,
                      let envelope = try? V2ServerProtobufFrameCodec.decode(frame) else { return false }
                let accepted = write.enqueueIfCurrent({})
                if accepted, case .realtimeCoverage(let coverage)? = envelope.body,
                   coverage.scope == .typing, coverage.state == .ready {
                    typingReady.withLock { $0 += 1 }
                }
                return accepted
            }
        } catch {
            await observations.release()
            await coordinator.shutdown()
            throw error
        }
        let (typing, typingRegistry) = typingFixture
        let typingRoom = RoomID(uuid: UUID()), owner = try V2RoomDataOwner(shardID: "rooms", epoch: 1)
        let typingTopic = V2RealtimeTopic(kind: .roomTyping, id: typingRoom.rawValue, owner: owner)
        let typingConfirmation = V2RealtimeCoverageConfirmation(token: .init(
            partitionID: V2RealtimeTopicKey(typingTopic).partitionID(),
            host: .init(nodeID: "fixture", serviceID: "fixture", incarnationID: UUID()), epoch: 1, leaseToken: UUID()),
            sessionID: UUID(), interestGeneration: 1, highWatermark: 0, deadline: .now + .seconds(30))
        await coordinator.configureCoverage(current: { kind, id in
            kind == .roomTyping && id == typingRoom.rawValue ? typingConfirmation : nil
        }, confirms: { kind, id, value in
            kind == .roomTyping && id == typingRoom.rawValue
                && value.token == typingConfirmation.token && value.sessionID == typingConfirmation.sessionID
                && value.interestGeneration == typingConfirmation.interestGeneration
        })
        coordinator.installConnection(typing)
        await coordinator.beginScopeRecovery(connection: typing.handle.connectionID,
            kind: .roomTyping, id: typingRoom.rawValue)
        do {
            try await waitForInterest(diagnostics: {
                let state = await coordinator.realtimeRecoverySnapshot()
                let admission = await coordinator.schedulingAdmissionSnapshot()
                return "typing state=\(state), admission=\(admission)"
            }) {
                let snapshot = await coordinator.realtimeRecoverySnapshot()
                let typingActivations = await broker.typingActivations
                return typingActivations == 1 && typingReady.withLock({ $0 }) == 1 && snapshot.interest == 0
                    && snapshot.control == 0 && snapshot.queued == 0 && snapshot.queryRoots == 4
            }
        } catch {
            await observations.release()
            await coordinator.shutdown()
            await typing.handle.stream.closeForAccountRecovery()
            await typingRegistry.shutdownRealtimeRecovery()
            throw error
        }
        #expect(typingReady.withLock { $0 } == 1)
        let progressed = await coordinator.realtimeRecoverySnapshot()
        #expect(progressed.actual == 4)
        #expect(progressed.positions <= 1024)
        #expect(await observations.held == 4)
        await observations.release()
        await coordinator.shutdown()
        #expect(await coordinator.realtimeRecoverySnapshot().actual == 0)
        await typing.handle.stream.closeForAccountRecovery()
        await typingRegistry.shutdownRealtimeRecovery()
    }

    @Test("four cold typing interest waits do not occupy warm presence query slots")
    func warmQueryProgressesWithFourColdInterestWaits() async throws {
        let coordinator = V2RealtimeRecoveryCoordinator()
        let warm = RoomID(uuid: UUID()), cold = (0..<4).map { _ in RoomID(uuid: UUID()) }
        let interests = RecoveryStageInterestGate(gated: Set(cold)), queries = RecoveryStageQueries()
        await coordinator.configureLiveActivity(interests)
        let (warmConnection, registry) = try await makeAuthenticatedTypingContext { write in write.enqueueIfCurrent {} }
        let target = try UserID(warm.rawValue)
        let owner = try V2RoomDataOwner(shardID: "rooms", epoch: 1)
        let topic = V2RealtimeTopic(kind: .userPresence, id: target.rawValue, owner: owner)
        let confirmation = V2RealtimeCoverageConfirmation(token: .init(partitionID: V2RealtimeTopicKey(topic).partitionID(),
            host: .init(nodeID: "fixture", serviceID: "fixture", incarnationID: UUID()), epoch: 1, leaseToken: UUID()),
            sessionID: UUID(), interestGeneration: 1, highWatermark: 0, deadline: .now + .seconds(30))
        await coordinator.configureCoverage(current: { _, _ in confirmation }, confirms: { _, _, _ in true })
        coordinator.configurePorts(.init(preparePresence: { key, lifecycle, generation in
            guard key.connection == warmConnection.handle.connectionID, key.id == target.rawValue else {
                throw RecoveryTicketTestFailure.timeout
            }
            await queries.record(room: warm)
            return .init(connection: key.connection, lifecycle: lifecycle, generation: generation,
                request: .init(roomID: warm, viewerUserID: warmConnection.handle.identity.userID, targetUserID: target),
                stream: warmConnection.handle.stream,
                state: .init(roomID: warm, targetUserID: target, isOnline: true, expiresAt: Date().addingTimeInterval(30)),
                deadline: .now + .seconds(30))
        }, compensateScope: { _, _, _, _ in }))
        coordinator.installConnection(warmConnection)
        do {
            await coordinator.beginScopeRecovery(connection: warmConnection.handle.connectionID, kind: topic.kind, id: topic.id)
            try await waitForInterest { await queries.count(for: warm) == 1 }
            for (index, room) in cold.enumerated() {
                let connection = try makeContext(lifecycle: UInt64(62 + index))
                coordinator.installConnection(connection)
                await coordinator.beginScopeRecovery(connection: connection.handle.connectionID, kind: .roomTyping, id: room.rawValue)
                try await waitForInterest { await interests.held == index + 1 }
            }
            let blocked = await coordinator.realtimeRecoverySnapshot()
            #expect(blocked.interest == 4 && blocked.positions <= 1024)
            await coordinator.invalidateRealtimeCoverage(topics: [topic], registeredThrough: .now)
            try await waitForInterest { await queries.count(for: warm) >= 2 }
            #expect(await interests.held == 4)
            #expect(await queries.coldReads(cold) == 0)
            let progressed = await coordinator.realtimeRecoverySnapshot()
            #expect(progressed.interest == 4 && progressed.queryRoots <= 4)
            #expect(progressed.control <= 4 && progressed.positions <= 1024)
        } catch {
            await interests.release(); await coordinator.shutdown()
            await warmConnection.handle.stream.closeForAccountRecovery(); await registry.shutdownRealtimeRecovery()
            throw error
        }
        await interests.release(); await coordinator.shutdown()
        #expect(await coordinator.realtimeRecoverySnapshot().actual == 0)
        await warmConnection.handle.stream.closeForAccountRecovery(); await registry.shutdownRealtimeRecovery()
    }

    @Test("one device's exact release preserves another device's typing interest")
    func exactMultiDeviceInterestRelease() async throws {
        let coordinator = V2RealtimeRecoveryCoordinator()
        let interests = RecoveryTicketGatedInterests(pauseActivation: false)
        await coordinator.configureLiveActivity(interests)
        let first = try makeContext(lifecycle: 41), second = try makeContext(lifecycle: 42)
        coordinator.installConnection(first); coordinator.installConnection(second)
        let room = RoomID(uuid: UUID())
        let firstKey = V2RealtimeRecoveryKey(connection: first.handle.connectionID, kind: .roomTyping, id: room.rawValue)
        let secondKey = V2RealtimeRecoveryKey(connection: second.handle.connectionID, kind: .roomTyping, id: room.rawValue)
        await coordinator.beginScopeRecovery(connection: firstKey.connection, kind: firstKey.kind, id: firstKey.id)
        try await waitForInterest { await interests.activations >= 1 }
        await coordinator.beginScopeRecovery(connection: secondKey.connection, kind: secondKey.kind, id: secondKey.id)
        try await waitForInterest {
            let ownership = await coordinator.realtimeInterestSnapshot()
            let recovery = await coordinator.realtimeRecoverySnapshot()
            return ownership.owners == 2 && recovery.actual == 0
        }
        #expect(await interests.activations == 1)
        let generation = try #require(coordinator.generation(for: firstKey))
        #expect(coordinator.revokeScope(firstKey, generation: generation))
        await coordinator.endScope(connection: firstKey.connection, kind: firstKey.kind, id: firstKey.id,
            stream: first.handle.stream, expectedGeneration: generation)
        try await waitForInterest {
            let snapshot = await coordinator.realtimeInterestSnapshot()
            return snapshot.owners == 1 && snapshot.retainedReleases == 0
        }
        #expect(await interests.deactivations == 0)
        #expect(await interests.active.contains(room))
        await coordinator.shutdown()
        #expect(await interests.active.isEmpty)
    }

    @Test("closing before a delayed activation returns transfers exact cleanup ownership")
    func delayedActivationCompensatesAfterActualJoin() async throws {
        let coordinator = V2RealtimeRecoveryCoordinator()
        let interests = RecoveryTicketGatedInterests(pauseActivation: true)
        await coordinator.configureLiveActivity(interests)
        let fixture = try makeContext(lifecycle: 51)
        coordinator.installConnection(fixture)
        let room = RoomID(uuid: UUID())
        let key = V2RealtimeRecoveryKey(connection: fixture.handle.connectionID, kind: .roomTyping, id: room.rawValue)
        await coordinator.beginScopeRecovery(connection: key.connection, kind: key.kind, id: key.id)
        try await waitForInterest { await interests.activationHeld }
        let revoked = coordinator.revokeConnection(key.connection, lifecycle: 51)
        // Detach returns after bounded ownership transfer, before the old I/O.
        await coordinator.detachConnection(key.connection, revokedScopes: revoked)
        #expect(await coordinator.realtimeInterestSnapshot().owners == 0)
        #expect(await interests.deactivations == 0)
        #expect(await interests.activationHeld)
        await interests.releaseActivation()
        try await waitForInterest {
            let snapshot = await coordinator.realtimeInterestSnapshot()
            return snapshot.retainedReleases == 0 && snapshot.actualReleases == 0
        }
        #expect(await interests.deactivations == 1)
        #expect(await interests.active.isEmpty)
        await coordinator.shutdown()
    }

    private func waitForInterest(diagnostics: (@Sendable () async -> String)? = nil,
        line: Int = #line, _ predicate: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else {
                let detail = await diagnostics?() ?? ""
                Issue.record("interest wait timed out at call line \(line): \(detail)")
                throw RecoveryTicketTestFailure.timeout
            }
            await Task.yield()
        }
    }

    @Test("an explicit presence denial discards a concurrently cached proof and queries again")
    func presenceDenialFailsClosed() async throws {
        let coordinator = V2RealtimeRecoveryCoordinator()
        let denied = RecoveryDeniedPresencePreparationGate()
        await coordinator.configureLiveActivity(RecoveryPresenceStageBroker())
        coordinator.configurePorts(.init(preparePresence: { _, _, _ in
            try await denied.prepare()
        }, compensateScope: { _, _, _, _ in }))
        let fixture = try makeContext(lifecycle: 300)
        coordinator.installConnection(fixture)
        let target = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let key = V2RealtimeRecoveryKey(connection: fixture.handle.connectionID, kind: .userPresence, id: target.rawValue)
        await coordinator.beginScopeRecovery(connection: key.connection, kind: key.kind, id: key.id)
        try await waitForInterest { await denied.held }
        let generation = try #require(coordinator.generation(for: key))
        let request = V2PresenceObservationRequest(roomID: room, viewerUserID: fixture.handle.identity.userID, targetUserID: target)
        let deadline = ContinuousClock.now + .seconds(30)
        await coordinator.recordPreparedPresence(.init(connection: key.connection, lifecycle: 300, generation: generation,
            request: request, stream: fixture.handle.stream,
            state: .init(roomID: room, targetUserID: target, isOnline: true, expiresAt: Date().addingTimeInterval(30)),
            deadline: deadline))
        let cached = await coordinator.preparedPresence(key, lifecycle: 300, generation: generation)
        #expect(cached?.deadline == deadline)
        await denied.release()
        try await waitForInterest {
            await coordinator.preparedPresence(key, lifecycle: 300, generation: generation) == nil
        }
        // No new input: original retry timer must perform another permission
        // preparation instead of turning the old cached result into Ready.
        try await waitForInterest { await denied.calls >= 2 }
        #expect(coordinator.generation(for: key) == generation)
        #expect(await coordinator.realtimeRecoverySnapshot().positions <= 1024)
        await coordinator.shutdown()
    }

    @Test("presence proof reuse preserves the original deadline and rejects stale callers")
    func presenceProofOwnership() async throws {
        let coordinator = V2RealtimeRecoveryCoordinator()
        let fixture = try makeContext(lifecycle: 90)
        coordinator.installConnection(fixture)
        let target = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let key = V2RealtimeRecoveryKey(connection: fixture.handle.connectionID, kind: .userPresence, id: target.rawValue)
        await coordinator.beginScopeRecovery(connection: key.connection, kind: key.kind, id: key.id)
        let generation = try #require(coordinator.generation(for: key))
        let request = V2PresenceObservationRequest(roomID: room, viewerUserID: fixture.handle.identity.userID, targetUserID: target)
        let deadline = ContinuousClock.now + .seconds(20)
        let proof = V2PreparedPresenceHandoff(connection: key.connection, lifecycle: 90, generation: generation,
            request: request, stream: fixture.handle.stream,
            state: .init(roomID: room, targetUserID: target, isOnline: true, expiresAt: Date().addingTimeInterval(30)),
            deadline: deadline)
        await coordinator.recordPreparedPresence(proof)
        let stale = await coordinator.preparedPresence(key, lifecycle: 89, generation: generation)
        #expect(stale == nil)
        let retained = await coordinator.preparedPresence(key, lifecycle: 90, generation: generation)
        #expect(retained?.deadline == deadline)
        _ = coordinator.revokeScope(key, generation: generation)
        let revoked = await coordinator.preparedPresence(key, lifecycle: 90, generation: generation)
        #expect(revoked == nil)
        await coordinator.shutdown()
    }

    @Test("generic recovery refuses room scopes owned by signed subscription delivery")
    func roomScopesCannotEnterGenericRecovery() async throws {
        let coordinator = V2RealtimeRecoveryCoordinator()
        let fixture = try makeContext(lifecycle: 40)
        coordinator.installConnection(fixture)
        let key = V2RealtimeRecoveryKey(connection: fixture.handle.connectionID,
            kind: .roomEvents, id: UUID().uuidString.lowercased())
        #expect(coordinator.requestScope(key, lifecycle: 40) == nil)
        await coordinator.beginScopeRecovery(connection: key.connection, kind: key.kind,
            id: key.id, scopeGeneration: 41, lifecycle: 40)
        #expect(coordinator.generation(for: key) == nil)
        let state = await coordinator.realtimeRecoverySnapshot()
        #expect(state.actual == 0)
        await coordinator.shutdown()
    }

    @Test("connection revocation invalidates captured enqueue permits before actor cleanup")
    func synchronousConnectionRevocation() async throws {
        let coordinator = V2RealtimeRecoveryCoordinator()
        let fixture = try makeContext(lifecycle: 40)
        coordinator.installConnection(fixture)
        let key = V2RealtimeRecoveryKey(connection: fixture.handle.connectionID,
            kind: .roomTyping, id: UUID().uuidString.lowercased())
        await coordinator.beginScopeRecovery(connection: key.connection, kind: key.kind, id: key.id)
        let generation = try #require(coordinator.generation(for: key))
        #expect(generation > fixture.handle.lifecycle)
        let permit = coordinator.recoveryWritePermit(key, generation: generation)
        let enqueueAllowed1 = permit({})
        #expect(enqueueAllowed1)

        // A stale close has no authority over the current connection.
        #expect(coordinator.revokeConnection(key.connection, lifecycle: 39).isEmpty)
        let enqueueAllowed2 = permit({})
        #expect(enqueueAllowed2)
        let revoked = coordinator.revokeConnection(key.connection, lifecycle: 40)
        #expect(revoked == [key])
        let enqueueAllowed3 = !permit({})
        #expect(enqueueAllowed3)
        #expect(coordinator.generation(for: key) == nil)
        await coordinator.detachConnection(key.connection, revokedScopes: revoked)
        await coordinator.shutdown()
    }

    @Test("live Ready permit rejection counters preserve generation, coverage and shutdown fences")
    func readyPermitRejectionReasons() async throws {
        let coordinator = V2RealtimeRecoveryCoordinator()
        let actualReady = Mutex(0)
        let (fixture, registry) = try await makeAuthenticatedTypingContext { write in
            let version = UInt8(IMV2ProtocolVersion.current)
            var decoder = V2FrameDecoder(limits: try! .init(maximumPayloadBytes: 4096, acceptedVersions: [version]))
            guard let frame = try? decoder.append(write.bytes).first,
                  let envelope = try? V2ServerProtobufFrameCodec.decode(frame) else { return false }
            let accepted = write.enqueueIfCurrent({})
            if accepted, case .realtimeCoverage(let coverage)? = envelope.body,
               coverage.scope == .typing, coverage.state == .ready {
                actualReady.withLock { $0 += 1 }
            }
            return accepted
        }
        func cleanup() async {
            await coordinator.shutdown()
            await fixture.handle.stream.closeForAccountRecovery()
            await registry.shutdownRealtimeRecovery()
        }
        let room = RoomID(uuid: UUID()), owner = try V2RoomDataOwner(shardID: "rooms", epoch: 1)
        let topic = V2RealtimeTopic(kind: .roomTyping, id: room.rawValue, owner: owner)
        let key = V2RealtimeRecoveryKey(connection: fixture.handle.connectionID, kind: topic.kind, id: topic.id)
        let confirmation = V2RealtimeCoverageConfirmation(token: .init(
            partitionID: V2RealtimeTopicKey(topic).partitionID(),
            host: .init(nodeID: "fixture", serviceID: "fixture", incarnationID: UUID()), epoch: 1, leaseToken: UUID()),
            sessionID: UUID(), interestGeneration: 1, highWatermark: 0, deadline: .now + .seconds(30))
        await coordinator.configureLiveActivity(RecoveryTicketGatedInterests(pauseActivation: false))
        await coordinator.configureCoverage(current: { kind, id in
            kind == .roomTyping && id == room.rawValue ? confirmation : nil
        }, confirms: { _, _, value in
            value.token == confirmation.token && value.sessionID == confirmation.sessionID
                && value.interestGeneration == confirmation.interestGeneration
        })
        coordinator.installConnection(fixture)
        do {
            await coordinator.beginScopeRecovery(connection: key.connection, kind: key.kind, id: key.id)
            // A projection or a retained H is not a Recovering/Ready receipt. Wait
            // for the authenticated stream's actual scoped enqueue to establish it.
            try await waitForInterest {
                let settled = await coordinator.realtimeRecoverySnapshot()
                return actualReady.withLock { $0 } == 1 && settled.actual == 0
                    && settled.positions == 0 && settled.desired == 0
            }
            let generation = try #require(coordinator.generation(for: key))
            let writes = Mutex(0)
            let enqueue: @Sendable () -> Void = { writes.withLock { $0 += 1 } }
            let deadline = ContinuousClock.now + .seconds(30)
            let ready = coordinator.readyWritePermit(key, generation: generation, head: 0, authorizationDeadline: deadline)
            let accepted = ready(enqueue)
            #expect(accepted)
            #expect(writes.withLock { $0 } == 1)
            let stale = coordinator.readyWritePermit(key, generation: generation + 1, head: 0, authorizationDeadline: deadline)(enqueue)
            #expect(!stale)
            let expired = coordinator.readyWritePermit(key, generation: generation, head: 0,
                authorizationDeadline: .now - .seconds(1))(enqueue)
            #expect(!expired)
            let presence = V2RealtimeRecoveryKey(connection: key.connection, kind: .userPresence,
                id: UserID(uuid: UUID()).rawValue)
            let presenceGeneration = try #require(coordinator.requestScope(presence, lifecycle: fixture.handle.lifecycle))
            await coordinator.recordScopeRetention(presence, lifecycle: fixture.handle.lifecycle,
                generation: presenceGeneration, highWatermark: 0, observedPresence: false)
            let unobserved = coordinator.readyWritePermit(presence, generation: presenceGeneration,
                head: 0, authorizationDeadline: deadline)(enqueue)
            #expect(!unobserved)
            coordinator.revokeAllWrites()
            let closed = ready(enqueue)
            #expect(!closed)
            let counters = coordinator.schedulingTelemetrySnapshot().readyRejections
            #expect(counters[.generationInvalid] == 1)
            #expect(counters[.permissionExpired] == 1)
            #expect(counters[.closed] == 1)
            #expect(counters[.coverageChanged] == 1)
            #expect(writes.withLock { $0 } == 1)
            // Ordinary notification permits do not fabricate a Ready rejection.
            let ordinary = coordinator.recoveryWritePermit(key, generation: generation)(enqueue)
            #expect(!ordinary)
            #expect(coordinator.schedulingTelemetrySnapshot().readyRejections == counters)
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    @Test("shutdown write revocation is persistent for already captured and future permits")
    func persistentShutdownFence() async throws {
        let coordinator = V2RealtimeRecoveryCoordinator()
        let fixture = try makeContext(lifecycle: 99)
        coordinator.installConnection(fixture)
        let key = V2RealtimeRecoveryKey(connection: fixture.handle.connectionID,
            kind: .roomTyping, id: UUID().uuidString.lowercased())
        await coordinator.beginScopeRecovery(connection: key.connection, kind: key.kind, id: key.id)
        let generation = try #require(coordinator.generation(for: key))
        let original = coordinator.recoveryWritePermit(key, generation: generation)
        let enqueueAllowed4 = original({})
        #expect(enqueueAllowed4)
        coordinator.revokeAllWrites()
        let enqueueAllowed5 = !original({})
        #expect(enqueueAllowed5)
        let enqueueAllowed6 = !coordinator.recoveryWritePermit(key, generation: generation)({})
        #expect(enqueueAllowed6)
        await coordinator.shutdown()
    }

    @Test("a reordered old scope transition cannot replace or end its successor")
    func reorderedScopeIntent() async throws {
        let coordinator = V2RealtimeRecoveryCoordinator()
        let fixture = try makeContext(lifecycle: 12)
        coordinator.installConnection(fixture)
        let key = V2RealtimeRecoveryKey(connection: fixture.handle.connectionID,
            kind: .roomTyping, id: UUID().uuidString.lowercased())
        let old = try #require(coordinator.requestScope(key, lifecycle: 12))
        #expect(coordinator.revokeScope(key, generation: old))
        let successor = try #require(coordinator.requestScope(key, lifecycle: 12))
        await coordinator.beginScopeRecovery(connection: key.connection, kind: key.kind, id: key.id,
            scopeGeneration: successor, lifecycle: 12)
        // Deliberately deliver stale transitions after the new transition.
        await coordinator.beginScopeRecovery(connection: key.connection, kind: key.kind, id: key.id,
            scopeGeneration: old, lifecycle: 12)
        await coordinator.endScope(connection: key.connection, kind: key.kind, id: key.id,
            stream: fixture.handle.stream, expectedGeneration: old)
        #expect(coordinator.generation(for: key) == successor)
        let enqueueAllowed7 = coordinator.recoveryWritePermit(key, generation: successor)({})
        #expect(enqueueAllowed7)
        let enqueueAllowed8 = !coordinator.recoveryWritePermit(key, generation: old)({})
        #expect(enqueueAllowed8)
        await coordinator.shutdown()
    }

    private func makeAuthenticatedTypingContext(
        writer: @escaping @Sendable (V2GatewayScopedNotificationWrite) async -> Bool
    ) async throws -> (V2RealtimeRecoveryConnectionContext, V2DeviceConnectionRegistry) {
        let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), connection = UUID()
        let registry = V2DeviceConnectionRegistry()
        let version = UInt8(IMV2ProtocolVersion.current)
        let limits = try V2FrameLimits(maximumPayloadBytes: 4096, acceptedVersions: [0, version])
        let stream = V2GatewayByteStream(frameLimits: limits,
            session: .init(limits: try .init(maximumInFlightRequests: 1),
                authenticator: RecoveryBoundaryAuthenticator(user: user), capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: RecoveryBoundaryHandler(), connectionID: connection, registry: registry)
        do {
            try #require(await stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
                scopedNotificationWriter: writer))
            var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello.deviceID = device.rawValue
            hello.clientHello.supportedProtocolVersions = [UInt32(version)]
            hello.clientHello.supportedCapabilityProfiles = ["base"]
            _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0), limits: limits))
            var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
            auth.authenticate.accessToken = "fixture"; auth.authenticate.deviceID = device.rawValue
            _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(auth, frameVersion: version), limits: limits))
        } catch {
            await stream.closeForAccountRecovery()
            await registry.shutdownRealtimeRecovery()
            throw error
        }
        return (.init(handle: .init(connectionID: connection, lifecycle: 110,
            identity: .init(userID: user, deviceID: device, capabilityProfile: "base"), stream: stream),
            accountScope: nil), registry)
    }

    private func makeContext(lifecycle: UInt64) throws -> V2RealtimeRecoveryConnectionContext {
        let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), connection = UUID()
        let registry = V2DeviceConnectionRegistry()
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4096, acceptedVersions: [0, 1]),
            session: .init(limits: try .init(maximumInFlightRequests: 1),
                authenticator: RecoveryBoundaryAuthenticator(user: user), capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: RecoveryBoundaryHandler(), registry: registry)
        return .init(handle: .init(connectionID: connection, lifecycle: lifecycle,
            identity: .init(userID: user, deviceID: device, capabilityProfile: "base"), stream: stream),
            accountScope: nil)
    }
}

private struct RecoveryBoundaryAuthenticator: V2GatewayAuthenticator {
    let user: UserID
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) async throws -> V2GatewayAuthentication {
        .init(userID: user, expiresAt: nil)
    }
}
private struct RecoveryBoundaryHandler: V2GatewayCommandHandler {
    func handle(envelope _: IMV2Envelope, identity _: V2AuthenticatedConnection) async throws -> IMV2Envelope { .init() }
}

private enum RecoveryTicketTestFailure: Error { case timeout }
private actor RecoveryTicketGatedInterests: V2LiveActivityInterestManaging, V2LiveActivityPublishing {
    private let pauseActivation: Bool
    private var activationGate: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var activations = 0
    private(set) var deactivations = 0
    private(set) var activationHeld = false
    private(set) var active: Set<RoomID> = []
    init(pauseActivation: Bool) { self.pauseActivation = pauseActivation }
    func activate(roomID: RoomID) async {
        activations += 1
        if pauseActivation && !released {
            activationHeld = true
            await withCheckedContinuation { activationGate = $0 }
        }
        active.insert(roomID)
    }
    func deactivate(roomID: RoomID) { deactivations += 1; active.remove(roomID) }
    func activateTyping(roomID: RoomID) async { await activate(roomID: roomID) }
    func deactivateTyping(roomID: RoomID) { deactivate(roomID: roomID) }
    func activatePresence(targetUserID _: UserID) throws { throw CancellationError() }
    func deactivatePresence(targetUserID _: UserID) {}
    func publishPresence(targetUserID _: UserID, isOnline _: Bool, expiresAt _: Date) {}
    func publishTyping(_: V2TypingState) {}
    func releaseActivation() { released = true; activationGate?.resume(); activationGate = nil }
}

private actor RecoveryStageQueries {
    private var calls: [RoomID: Int] = [:]
    func record(room: RoomID) { calls[room, default: 0] += 1 }
    func count(for room: RoomID) -> Int { calls[room, default: 0] }
    func coldReads(_ rooms: [RoomID]) -> Int { rooms.reduce(0) { $0 + calls[$1, default: 0] } }
}
private actor RecoveryStageInterestGate: V2LiveActivityInterestManaging, V2LiveActivityPublishing {
    let gated: Set<RoomID>
    private var continuations: [RoomID: CheckedContinuation<Void, Never>] = [:]
    private var released = false
    var held: Int { continuations.count }
    init(gated: Set<RoomID>) { self.gated = gated }
    func activatePresence(targetUserID _: UserID) {}
    func deactivatePresence(targetUserID _: UserID) {}
    func activateTyping(roomID: RoomID) async { await activate(roomIDs: [roomID]) }
    func deactivateTyping(roomID _: RoomID) {}
    func publishPresence(targetUserID _: UserID, isOnline _: Bool, expiresAt _: Date) {}
    func publishTyping(_: V2TypingState) {}
    private func activate(roomIDs: [RoomID]) async {
        for room in roomIDs where gated.contains(room) && !released {
            await withCheckedContinuation { continuations[room] = $0 }
        }
    }
    func release() {
        released = true
        let waiting = continuations.values; continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

private actor RecoveryPresencePreparationGate {
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var released = false
    var held: Int { gates.count }
    func prepare() async throws -> V2PreparedPresenceHandoff {
        if !released { await withCheckedContinuation { gates.append($0) } }
        throw RecoveryTicketTestFailure.timeout
    }
    func release() {
        released = true
        let pending = gates; gates.removeAll()
        for gate in pending { gate.resume() }
    }
}
private actor RecoveryPresenceStageBroker: V2LiveActivityInterestManaging, V2LiveActivityPublishing {
    private(set) var typingActivations = 0
    func activatePresence(targetUserID _: UserID) {}
    func deactivatePresence(targetUserID _: UserID) {}
    func activateTyping(roomID _: RoomID) { typingActivations += 1 }
    func deactivateTyping(roomID _: RoomID) {}
    func publishPresence(targetUserID _: UserID, isOnline _: Bool, expiresAt _: Date) {}
    func publishTyping(_ state: V2TypingState) {}
}




private actor RecoveryDeniedPresencePreparationGate {
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var held = false
    private(set) var calls = 0
    func prepare() async throws -> V2PreparedPresenceHandoff {
        calls += 1
        if calls == 1 { held = true; await withCheckedContinuation { gate = $0 } }
        throw V2PresenceRefreshCoordinator.Failure.denied
    }
    func release() { gate?.resume(); gate = nil }
}
