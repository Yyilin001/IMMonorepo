@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import Synchronization
import IMV2Core
import IMV2ActorContracts
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing
@testable import IMV2ServerGateway

@Suite("V2 device connection registry reentrancy")
struct V2DeviceConnectionRegistryReentrancyTests {
    @Test("unregister during presence refresh removes the late database lease")
    func compensatesLatePresenceRefresh() async throws {
        let registry = V2DeviceConnectionRegistry()
        let leases = SuspendedPresenceLeases()
        await registry.configureLivePresenceLeases(leases)
        let identity = try identityFixture()
        let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000d03")!
        let stream = try streamFixture()

        let registration = Task {
            try await registry.register(stream, connectionID: connectionID, identity: identity, publicationSuppressed: false)
        }
        await leases.waitUntilRefreshStarts()
        await registry.unregister(connectionID: connectionID)
        await leases.resumeRefresh()
        _ = try await registration.value

        #expect(await registry.connectionMetricsSnapshot().activeConnections == 0)
        #expect(await leases.activeConnectionIDs().isEmpty)
    }

    @Test("privacy publication cannot hold a successful local authentication")
    func privacyPublicationDoesNotBlockRegistration() async throws {
        let registry = V2DeviceConnectionRegistry()
        let leases = SuspendedPreferencePresenceLeases()
        await registry.configureLivePresenceLeases(leases)
        let identity = try identityFixture()
        let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000d07")!
        let stream = try streamFixture()

        let registration = Task {
            try await registry.register(
                stream,
                connectionID: connectionID,
                identity: identity, publicationSuppressed: false
            )
        }
        #expect(try await registration.value)
        await leases.waitUntilPreferenceLookupStarts()
        await registry.unregister(connectionID: connectionID)
        await leases.resumePreferenceLookup()

        await registry.shutdownRealtimeRecovery()
        #expect(await registry.connectionMetricsSnapshot().activeConnections == 0)
        #expect(await leases.activeConnectionIDs().isEmpty)
    }

    @Test("unregister while broker activation is suspended leaves no phantom subscription")
    func compensatesLateSubscriptionActivation() async throws {
        let registry = V2DeviceConnectionRegistry()
        let broker = SuspendedLiveActivityBroker()
        await registry.configureLiveActivityBroker(broker)
        let identity = try identityFixture()
        let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000d04")!
        let roomID = try RoomID("00000000-0000-0000-0000-000000000d05")
        let target = try UserID("00000000-0000-0000-0000-000000000d06")
        let stream = try streamFixture()
        try await registry.register(stream, connectionID: connectionID, identity: identity, publicationSuppressed: false)

        let subscription = Task {
            await registry.subscribePresence(
                stream,
                connectionID: connectionID,
                roomID: roomID,
                targetUserID: target
            )
        }
        await broker.waitUntilPresenceActivationStarts()
        await registry.unregister(connectionID: connectionID)
        await broker.resumePresenceActivation()
        await subscription.value
        await registry.shutdownRealtimeRecovery()

        #expect(await registry.connectionMetricsSnapshot().activeConnections == 0)
        #expect(await broker.activePresenceTargets().isEmpty)
        #expect(await registry.transientMutationTokenCount() == 0)
    }

    @Test("connection churn does not retain transient mutation generations")
    func connectionChurnClearsMutationTokens() async throws {
        let registry = V2DeviceConnectionRegistry()
        let identity = try identityFixture()
        let stream = try streamFixture()

        for index in 0..<256 {
            let connectionID = UUID(
                uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index / 256), UInt8(index % 256))
            )
            try await registry.register(stream, connectionID: connectionID, identity: identity, publicationSuppressed: false)
            await registry.unregister(connectionID: connectionID)
        }

        #expect(await registry.connectionMetricsSnapshot().activeConnections == 0)
        #expect(await registry.transientMutationTokenCount() == 0)
    }

    @Test("authentication replies own bounded recovery and shutdown drains submitted interest work")
    func authenticationRecoveryIsBoundedAndDrained() async throws {
        let registry = V2DeviceConnectionRegistry(connectionAdmissionPolicy: .init(
            maximumConnectionsPerDevice: 8, maximumConnectionsPerUser: 8))
        let probe = GatedAccountSyncInterests()
        let shared = V2SharedGroupEventWakeInterests(underlying: probe)
        await registry.configureUserSyncInterests(shared)
        let identity = try identityFixture(), stream = try streamFixture()
        let syncRoom = try RoomID(identity.userID.rawValue)
        let connections = (0..<5).map { _ in UUID() }
        for connection in connections {
            #expect(try await registry.register(stream, connectionID: connection,
                identity: identity, publicationSuppressed: true))
        }
        #expect(await probe.activations == 0)
        #expect(await registry.realtimeRecoverySnapshot().actual == 0)
        for connection in connections { await registry.authenticationResponseWritten(connectionID: connection) }
        await probe.waitUntilStarted()
        #expect(await registry.realtimeRecoverySnapshot().actual == 4)
        #expect(await registry.realtimeRecoverySnapshot().queued == 1)
        #expect(await probe.activations == 1)
        let removal = Task { await registry.unregister(connectionID: connections[0]) }
        let deadline = ContinuousClock.now + .seconds(2)
        while await registry.connectionMetricsSnapshot().activeConnections == 5 {
            guard ContinuousClock.now < deadline else { throw RegistryRecoveryTestFailure.timeout }
            await Task.yield()
        }
        let shutdown = Task { await registry.shutdownRealtimeRecovery() }
        let repeatedShutdown = Task { await registry.shutdownRealtimeRecovery() }
        // The four submitted waiters retain their actual work until the shared
        // installation settles, even though one connection is already removed.
        #expect(await registry.realtimeRecoverySnapshot().actual == 4)
        await probe.release()
        await removal.value; await shutdown.value; await repeatedShutdown.value
        #expect(await registry.realtimeRecoverySnapshot().actual == 0)
        #expect(await registry.realtimeRecoverySnapshot().desired == 0)
        #expect(await probe.activations >= 1)
        #expect(await shared.interestedScopes(roomID: syncRoom).isEmpty)
        for connection in connections.dropFirst() { await registry.unregister(connectionID: connection) }
        await shared.shutdown()
    }

    @Test("unchanged heartbeat leases do not perform cross-node presence publication")
    func heartbeatDoesNotPublishUnchangedPresence() async throws {
        let registry = V2DeviceConnectionRegistry()
        let leases = SuspendedPresenceLeases(), broker = SuspendedLiveActivityBroker()
        await registry.configureLivePresenceLeases(leases)
        await registry.configureLiveActivityBroker(broker)
        let identity = try identityFixture(), stream = try streamFixture(), connection = UUID()
        let registration = Task { try await registry.register(stream, connectionID: connection,
            identity: identity, publicationSuppressed: false) }
        await leases.waitUntilRefreshStarts(); await leases.resumeRefresh()
        #expect(try await registration.value)
        let deadline = ContinuousClock.now + .seconds(2)
        while await broker.publications == 0 {
            guard ContinuousClock.now < deadline else { throw RegistryRecoveryTestFailure.timeout }
            await Task.yield()
        }
        let first = await broker.publications
        for _ in 0..<8 { #expect(await registry.refreshLivePresence(connectionID: connection)) }
        #expect(await broker.publications == first)
        await registry.unregister(connectionID: connection)
        await registry.shutdownRealtimeRecovery(); await registry.finishLivePresenceRenewals()
    }

    @Test("heartbeats acknowledge local liveness while an actual renewal remains blocked")
    func heartbeatDoesNotWaitForAuthority() async throws {
        let registry = V2DeviceConnectionRegistry(livePresenceRenewalConfiguration: .init(maximumBatchSize: 1, maximumDelay: .zero))
        let leases = GatedHeartbeatLeases(leaseSeconds: 0.9)
        await registry.configureLivePresenceLeases(leases)
        let identity = try identityFixture(), connection = UUID(), stream = try streamFixture()
        #expect(try await registry.register(stream, connectionID: connection, identity: identity, publicationSuppressed: true))
        let before = await registry.presenceLeaseSnapshot(connectionID: connection).deadline
        for _ in 0..<8 { #expect(await registry.refreshLivePresence(connectionID: connection)) }
        let renewAt = try #require(await registry.presenceLeaseSnapshot(connectionID: connection).renewAt)
        #expect(ContinuousClock.now < renewAt)
        #expect(await leases.actualCalls == 0)
        do { try await leases.waitForStart() }
        catch { await leases.release(); await registry.finishLivePresenceRenewals(); throw error }
        for _ in 0..<8 { #expect(await registry.refreshLivePresence(connectionID: connection)) }
        #expect(await registry.presenceLeaseSnapshot(connectionID: connection).deadline == before)
        #expect(await leases.actualCalls == 1)
        let finished = RegistryHeartbeatDrainResult()
        let shutdown = Task { await registry.finishLivePresenceRenewals(); finished.mark() }
        let repeated = Task { await registry.finishLivePresenceRenewals() }
        await Task.yield()
        #expect(!finished.completed)
        await leases.release()
        await shutdown.value; await repeated.value
        await registry.unregister(connectionID: connection)
    }

    @Test("online projection expiry preserves a live connection and unknown SQL cannot revoke it")
    func presenceExpiryDoesNotRevokeAuthenticatedConnection() async throws {
        let registry = V2DeviceConnectionRegistry(livePresenceRenewalConfiguration: .init(maximumBatchSize: 1, maximumDelay: .zero))
        let leases = GatedHeartbeatLeases(leaseSeconds: 0.5, unknown: true)
        await registry.configureLivePresenceLeases(leases)
        let identity = try identityFixture(), connection = UUID(), stream = try streamFixture()
        #expect(try await registry.register(stream, connectionID: connection, identity: identity, publicationSuppressed: true))
        let expiry = try #require(await registry.presenceLeaseSnapshot(connectionID: connection).deadline)
        #expect(await registry.refreshLivePresence(connectionID: connection))
        do { try await leases.waitForStart() }
        catch { await leases.release(); await registry.finishLivePresenceRenewals(); throw error }
        try await ContinuousClock().sleep(until: expiry + .milliseconds(10))
        #expect(await registry.connectionMetricsSnapshot().activeConnections == 1)
        #expect(await registry.refreshLivePresence(connectionID: connection))
        #expect(stream.connectionAllowsDispatch())
        await leases.release()
        let bound = ContinuousClock.now + .seconds(2)
        while await registry.presenceLeaseSnapshot(connectionID: connection).renewing {
            guard ContinuousClock.now < bound else { throw RegistryRecoveryTestFailure.timeout }
            await Task.yield()
        }
        #expect(await registry.connectionMetricsSnapshot().activeConnections == 1)
        #expect(stream.connectionAllowsDispatch())
        await registry.unregister(connectionID: connection)
        #expect(!stream.connectionAllowsDispatch())
        await registry.finishLivePresenceRenewals()
    }

    @Test("successful renewal covers its submission without chasing heartbeats received during SQL")
    func heartbeatRenewalWaitsForNextConfirmedWindow() async throws {
        let registry = V2DeviceConnectionRegistry(livePresenceRenewalConfiguration: .init(maximumBatchSize: 1, maximumDelay: .zero))
        let leases = GatedHeartbeatLeases(leaseSeconds: 0.9)
        await registry.configureLivePresenceLeases(leases)
        let identity = try identityFixture(), connection = UUID(), stream = try streamFixture()
        #expect(try await registry.register(stream, connectionID: connection, identity: identity, publicationSuppressed: true))
        #expect(await registry.refreshLivePresence(connectionID: connection))
        do { try await leases.waitForStart() }
        catch { await leases.release(); await registry.finishLivePresenceRenewals(); throw error }
        for _ in 0..<8 { #expect(await registry.refreshLivePresence(connectionID: connection)) }
        let before = await registry.presenceLeaseSnapshot(connectionID: connection).deadline
        await leases.release()
        let bound = ContinuousClock.now + .seconds(2)
        while await registry.presenceLeaseSnapshot(connectionID: connection).renewing {
            guard ContinuousClock.now < bound else {
                await registry.finishLivePresenceRenewals(); throw RegistryRecoveryTestFailure.timeout
            }
            await Task.yield()
        }
        let after = await registry.presenceLeaseSnapshot(connectionID: connection)
        let oldDeadline = try #require(before), newDeadline = try #require(after.deadline)
        let nextRenewal = try #require(after.renewAt)
        #expect(newDeadline > oldDeadline)
        #expect(nextRenewal > ContinuousClock.now)
        for _ in 0..<8 { #expect(await registry.refreshLivePresence(connectionID: connection)) }
        #expect(await leases.actualCalls == 1)
        await registry.unregister(connectionID: connection)
        await registry.finishLivePresenceRenewals()
    }

    @Test("an idle online projection expires without renewing or owning connection timeout")
    func idleProjectionDoesNotRenewOrCloseConnection() async throws {
        let registry = V2DeviceConnectionRegistry(livePresenceRenewalConfiguration: .init(maximumBatchSize: 1, maximumDelay: .zero))
        let leases = GatedHeartbeatLeases(leaseSeconds: 0.03)
        await registry.configureLivePresenceLeases(leases)
        let identity = try identityFixture(), connection = UUID(), stream = try streamFixture()
        #expect(try await registry.register(stream, connectionID: connection, identity: identity, publicationSuppressed: true))
        let expiry = try #require(await registry.presenceLeaseSnapshot(connectionID: connection).deadline)
        try await ContinuousClock().sleep(until: expiry + .milliseconds(1))
        #expect(await leases.actualCalls == 0)
        #expect(await registry.connectionMetricsSnapshot().activeConnections == 1)
        #expect(stream.connectionAllowsDispatch())
        await registry.unregister(connectionID: connection)
        await registry.finishLivePresenceRenewals()
    }

    @Test("presence batch shares same authorization key, rejects stale scope and isolates denied viewer")
    func presenceBatchSharesKeyAndFencesScopes() async throws {
        let registry = V2DeviceConnectionRegistry(connectionAdmissionPolicy: .init(
            maximumConnectionsPerDevice: 8, maximumConnectionsPerUser: 8))
        let viewer = try identityFixture().userID
        let deniedViewer = UserID(uuid: UUID()), target = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let reader = GatedRegistryPresenceReader(deniedViewer: deniedViewer)
        await registry.configurePresenceReader(reader)
        let recorders = (0..<3).map { RegistryPresenceRecorder(pauseWrites: $0 == 1) }
        var connections: [UUID] = []
        for index in 0..<3 {
            let user = index == 2 ? deniedViewer : viewer
            let identity = V2AuthenticatedConnection(userID: user, deviceID: .init(uuid: UUID()), capabilityProfile: "base")
            let connection = UUID(), recorder = recorders[index]
            let session = V2GatewaySession(limits: try .init(maximumInFlightRequests: 1),
                authenticator: RegistryPresenceAuthenticator(user: user), capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission())
            let version = UInt8(IMV2ProtocolVersion.current)
            let limits = try V2FrameLimits(maximumPayloadBytes: 4096, acceptedVersions: [0, version])
            let stream = V2GatewayByteStream(frameLimits: limits,
                session: session, handler: RegistryReentrancyCommandHandler(), connectionID: connection, registry: registry)
            #expect(await stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { await recorder.record($0) },
                scopedNotificationWriter: { await recorder.recordScoped($0) }))
            var hello = IMV2Envelope(); hello.requestID = 1
            hello.clientHello.deviceID = identity.deviceID.rawValue
            hello.clientHello.supportedProtocolVersions = [UInt32(version)]
            hello.clientHello.supportedCapabilityProfiles = ["base"]
            _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0), limits: limits))
            var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
            auth.authenticate.accessToken = "fixture"; auth.authenticate.deviceID = identity.deviceID.rawValue
            _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(auth, frameVersion: version), limits: limits))
            await registry.subscribePresence(stream, connectionID: connection, roomID: room, targetUserID: target)
            connections.append(connection)
        }
        let refresh = Task { await registry.refreshAllObservedPresence() }
        let deadline = ContinuousClock.now + .seconds(2)
        while await reader.batchCalls == 0 {
            guard ContinuousClock.now < deadline else { throw RegistryRecoveryTestFailure.timeout }
            await Task.yield()
        }
        #expect(await reader.lastKeys.count == 2)
        #expect(await reader.scalarCalls == 0)
        await reader.release()
        // Model the actual socket owner paused before EL enqueue. The scope
        // changes after the Registry continuation and ByteStream pre-checks.
        let dispatchDeadline = ContinuousClock.now + .seconds(2)
        while !(await recorders[1].writeHeld) {
            guard ContinuousClock.now < dispatchDeadline else { throw RegistryRecoveryTestFailure.timeout }
            await Task.yield()
        }
        await registry.unregister(connectionID: connections[1])
        await recorders[1].releaseWrite()
        await refresh.value
        #expect(await reader.batchCalls == 1)
        #expect(await recorders[0].presenceFrames == 1)
        #expect(await recorders[1].presenceFrames == 0)
        #expect(await recorders[2].presenceFrames == 0)
        await registry.shutdownRealtimeRecovery()
        for connection in [connections[0], connections[2]] { await registry.unregister(connectionID: connection) }
    }

    @Test(arguments: [false, true])
    func shutdownRevokesLateReadyEnqueue(retireConnection: Bool) async throws {
        let registry = V2DeviceConnectionRegistry(connectionAdmissionPolicy: .init(
            maximumConnectionsPerDevice: 8, maximumConnectionsPerUser: 8))
        let user = try identityFixture().userID, room = RoomID(uuid: UUID())
        let owner = try V2RoomDataOwner(shardID: "rooms", epoch: 1), target = UserID(uuid: UUID())
        let topic = V2RealtimeTopic(kind: .userPresence, id: target.rawValue, owner: owner)
        let head: UInt64 = 0
        let wireScope: IMV2RealtimeCoverage.Scope = .presence
        let reader = GatedRegistryPresenceReader(deniedViewer: UserID(uuid: UUID()))
        let broker = GatedRegistryRecoveryPresenceInterests()
        await reader.release(); await broker.release()
        await registry.configurePresenceReader(reader)
        await registry.configureLiveActivityBroker(broker)
        let confirmation = V2RealtimeCoverageConfirmation(token: .init(partitionID: V2RealtimeTopicKey(topic).partitionID(),
            host: .init(nodeID: "host", serviceID: "host", incarnationID: UUID()), epoch: 1, leaseToken: UUID()),
            sessionID: UUID(), interestGeneration: 1, highWatermark: head, deadline: .now + .seconds(30))
        await registry.configureRealtimeCoverageValidation(current: { kind, id in
            kind == topic.kind && id == topic.id ? confirmation : nil
        }, confirms: { kind, id, value in kind == topic.kind && id == topic.id && value.token == confirmation.token && value.sessionID == confirmation.sessionID
                && value.interestGeneration == confirmation.interestGeneration && value.highWatermark == confirmation.highWatermark })
        let slow = ScopedRecoveryRecorder(blockHint: false, scope: wireScope, blockReady: true)
        var streams: [V2GatewayByteStream] = [], connections: [UUID] = []
        let version = UInt8(IMV2ProtocolVersion.current)
        for recorder in [slow] {
            let connection = UUID(), device = DeviceID(uuid: UUID())
            let session = V2GatewaySession(limits: try .init(maximumInFlightRequests: 1),
                authenticator: RegistryPresenceAuthenticator(user: user), capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission())
            let stream = V2GatewayByteStream(frameLimits: try .init(maximumPayloadBytes: 4096, acceptedVersions: [0, version]),
                session: session, handler: RegistryReentrancyCommandHandler(), connectionID: connection, registry: registry)
            #expect(await stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
                scopedNotificationWriter: { await recorder.record($0) }))
            var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello.deviceID = device.rawValue
            hello.clientHello.supportedProtocolVersions = [UInt32(version)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
            _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0),
                limits: .init(maximumPayloadBytes: 4096, acceptedVersions: [0, version])))
            var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
            auth.authenticate.accessToken = "fixture"; auth.authenticate.deviceID = device.rawValue
            _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(auth, frameVersion: version),
                limits: .init(maximumPayloadBytes: 4096, acceptedVersions: [0, version])))
            await registry.subscribePresence(stream, connectionID: connection, roomID: room, targetUserID: target)
            streams.append(stream); connections.append(connection)
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await slow.readyHeld), ContinuousClock.now < deadline { await Task.yield() }
        guard await slow.readyHeld else {
            await slow.releaseReady(); await registry.shutdownRealtimeRecovery()
            Issue.record("Ready handoff did not reach its controlled gate"); return
        }
        if retireConnection {
            // This stream no longer appears in the active Directory snapshot.
            // Its already-started handoff still belongs to shutdown's ledger.
            await registry.unregister(connectionID: connections[0])
        }
        let shutdownCompleted = RegistryHeartbeatDrainResult()
        let shutdown = Task {
            await registry.shutdownRealtimeRecovery()
            shutdownCompleted.mark()
        }
        let closeDeadline = ContinuousClock.now + .seconds(2)
        while !(await registry.realtimeRecoverySnapshot().closed), ContinuousClock.now < closeDeadline { await Task.yield() }
        #expect(await registry.realtimeRecoverySnapshot().closed)
        // Socket ownership has moved out of shared query slots, but shutdown
        // must still join the original bounded connection handoff.
        #expect(await registry.realtimeRecoverySnapshot().actual == 0)
        #expect(await registry.registryRecoveryMetricsSnapshot().stages[.presence]?[.outboundRetention]?.count == 1)
        #expect(await slow.roomReadyCount == 0)
        #expect(!shutdownCompleted.completed)
        await slow.releaseReady()
        await shutdown.value; await registry.shutdownRealtimeRecovery()
        #expect(shutdownCompleted.completed)
        #expect(await registry.realtimeRecoverySnapshot().actual == 0)
        #expect(await slow.roomReadyCount == 0)
        for connection in connections { await registry.unregister(connectionID: connection) }
    }

    @Test("five suspended connection writers cannot consume the four presence query slots")
    func recoveryAuthorizationDoesNotWaitForSocket() async throws {
        let registry = V2DeviceConnectionRegistry()
        let user = try identityFixture().userID
        let rooms = (0..<6).map { _ in RoomID(uuid: UUID()) }
        let owner = try V2RoomDataOwner(shardID: "rooms", epoch: 1)
        let targets = rooms.map { _ in UserID(uuid: UUID()) }
        let topics = targets.map { V2RealtimeTopic(kind: .userPresence, id: $0.rawValue, owner: owner) }
        let confirmations = Dictionary(uniqueKeysWithValues: topics.map { topic in
            (topic.id, V2RealtimeCoverageConfirmation(token: .init(partitionID: V2RealtimeTopicKey(topic).partitionID(),
                host: .init(nodeID: "host", serviceID: "host", incarnationID: UUID()), epoch: 1, leaseToken: UUID()),
                sessionID: UUID(), interestGeneration: 1, highWatermark: 0, deadline: .now + .seconds(30)))
        })
        let reader = GatedRegistryPresenceReader(deniedViewer: UserID(uuid: UUID()))
        let broker = GatedRegistryRecoveryPresenceInterests()
        await reader.release(); await broker.release()
        await registry.configurePresenceReader(reader)
        await registry.configureLiveActivityBroker(broker)
        await registry.configureRealtimeCoverageValidation(current: { _, id in confirmations[id] },
            confirms: { _, id, value in
                guard let expected = confirmations[id] else { return false }
                return expected.token == value.token && expected.sessionID == value.sessionID
                    && expected.interestGeneration == value.interestGeneration
            })
        var recorders: [ScopedRecoveryRecorder] = [], connections: [UUID] = []
        func cleanup() async {
            for recorder in recorders { await recorder.releaseReady(); await recorder.releaseHint() }
            await registry.shutdownRealtimeRecovery()
            for connection in connections { await registry.unregister(connectionID: connection) }
        }
        do {
            for (index, room) in rooms.enumerated() {
                let recorder = ScopedRecoveryRecorder(blockHint: false, scope: .presence, blockReady: index < 5)
                recorders.append(recorder)
                let (connection, stream) = try await makeScopedRegistryTestStream(registry: registry,
                    recorder: recorder, user: user, room: room)
                await registry.subscribePresence(stream, connectionID: connection, roomID: room, targetUserID: targets[index])
                connections.append(connection)
                let until = ContinuousClock.now + .seconds(3)
                while index < 5 ? !(await recorder.readyHeld) : !(await recorder.hasRoomReady) {
                    guard ContinuousClock.now < until else { throw RegistryRecoveryTestFailure.timeout }
                    await Task.yield()
                }
            }
            #expect(await reader.batchCalls >= 6)
            #expect(await reader.scalarCalls == 0)
            #expect(await registry.realtimeRecoverySnapshot().queryRoots == 0)
            for recorder in recorders.prefix(5) { #expect(await recorder.roomReadyCount == 0) }
            #expect(await recorders[5].roomReadyCount == 1)
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    @Test("a refused presence Ready reuses its still-valid observation proof")
    func refusedReadyReusesOriginalProof() async throws {
        let registry = V2DeviceConnectionRegistry()
        let user = try identityFixture().userID, room = RoomID(uuid: UUID())
        let owner = try V2RoomDataOwner(shardID: "rooms", epoch: 1)
        let target = UserID(uuid: UUID())
        let topic = V2RealtimeTopic(kind: .userPresence, id: target.rawValue, owner: owner)
        let confirmation = V2RealtimeCoverageConfirmation(
            token: .init(partitionID: V2RealtimeTopicKey(topic).partitionID(),
                host: .init(nodeID: "host", serviceID: "host", incarnationID: UUID()), epoch: 1, leaseToken: UUID()),
            sessionID: UUID(), interestGeneration: 1, highWatermark: 0, deadline: .now + .seconds(30))
        let reader = GatedRegistryPresenceReader(deniedViewer: UserID(uuid: UUID()))
        let broker = GatedRegistryRecoveryPresenceInterests()
        await reader.release(); await broker.release()
        await registry.configurePresenceReader(reader)
        await registry.configureLiveActivityBroker(broker)
        await registry.configureRealtimeCoverageValidation(current: { kind, id in
            kind == topic.kind && id == topic.id ? confirmation : nil
        }, confirms: { _, _, value in
            value.token == confirmation.token && value.sessionID == confirmation.sessionID
                && value.interestGeneration == confirmation.interestGeneration
                && value.highWatermark == confirmation.highWatermark && value.deadline == confirmation.deadline
        })
        let recorder = ScopedRecoveryRecorder(blockHint: false, scope: .presence)
        await recorder.rejectNextReady()
        let (connection, stream) = try await makeScopedRegistryTestStream(registry: registry,
            recorder: recorder, user: user, room: room)
        await registry.subscribePresence(stream, connectionID: connection, roomID: room, targetUserID: target)
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await recorder.hasRoomReady), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await recorder.roomReadyCount == 1)
        #expect(await recorder.readyRejections == 1)
        let refusedMetrics = await registry.registryRecoveryMetricsSnapshot()
        #expect((refusedMetrics.schedulingTelemetry.readyRejections[.enqueueRefused] ?? 0) >= 1)
        #expect(await reader.batchCalls == 1)
        #expect(await reader.scalarCalls == 0)
        await registry.shutdownRealtimeRecovery()
        await registry.unregister(connectionID: connection)
    }

    @Test("one blocked recovery writer cannot block another connection Ready or revive an ended scope")
    func recoveryRetentionIsPerConnection() async throws {
        let registry = V2DeviceConnectionRegistry(connectionAdmissionPolicy: .init(
            maximumConnectionsPerDevice: 8, maximumConnectionsPerUser: 8))
        let user = try identityFixture().userID, room = RoomID(uuid: UUID())
        let owner = try V2RoomDataOwner(shardID: "rooms", epoch: 1), target = UserID(uuid: UUID())
        let topic = V2RealtimeTopic(kind: .userPresence,
            id: target.rawValue, owner: owner)
        let head: UInt64 = 0
        let wireScope: IMV2RealtimeCoverage.Scope = .presence
        let reader = GatedRegistryPresenceReader(deniedViewer: UserID(uuid: UUID()))
        let broker = GatedRegistryRecoveryPresenceInterests()

        await registry.configurePresenceReader(reader)
        await registry.configureLiveActivityBroker(broker)

        let confirmation = V2RealtimeCoverageConfirmation(token: .init(partitionID: V2RealtimeTopicKey(topic).partitionID(),
            host: .init(nodeID: "host", serviceID: "host", incarnationID: UUID()), epoch: 1, leaseToken: UUID()),
            sessionID: UUID(), interestGeneration: 1, highWatermark: head, deadline: .now + .seconds(30))
        await registry.configureRealtimeCoverageValidation(current: { kind, id in
            guard kind == topic.kind && id == topic.id else { return nil }
            return .init(token: confirmation.token, sessionID: confirmation.sessionID,
                interestGeneration: confirmation.interestGeneration,
                highWatermark: confirmation.highWatermark, deadline: confirmation.deadline)
        }, confirms: { kind, id, value in kind == topic.kind && id == topic.id && value.token == confirmation.token && value.sessionID == confirmation.sessionID
                && value.interestGeneration == confirmation.interestGeneration && value.highWatermark == confirmation.highWatermark })
        let slow = ScopedRecoveryRecorder(blockHint: true, scope: wireScope)
        let healthy = ScopedRecoveryRecorder(blockHint: false, scope: wireScope)
        var streams: [V2GatewayByteStream] = [], connections: [UUID] = []
        let version = UInt8(IMV2ProtocolVersion.current)
        for recorder in [slow, healthy] {
            let connection = UUID(), device = DeviceID(uuid: UUID())
            let session = V2GatewaySession(limits: try .init(maximumInFlightRequests: 1),
                authenticator: RegistryPresenceAuthenticator(user: user), capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission())
            let stream = V2GatewayByteStream(frameLimits: try .init(maximumPayloadBytes: 4096, acceptedVersions: [0, version]),
                session: session, handler: RegistryReentrancyCommandHandler(), connectionID: connection, registry: registry)
           #expect(await stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
                scopedNotificationWriter: { await recorder.record($0) }))
            var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello.deviceID = device.rawValue
            hello.clientHello.supportedProtocolVersions = [UInt32(version)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
            _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0),
                limits: .init(maximumPayloadBytes: 4096, acceptedVersions: [0, version])))
            var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
            auth.authenticate.accessToken = "fixture"; auth.authenticate.deviceID = device.rawValue
            _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(auth, frameVersion: version),
                limits: .init(maximumPayloadBytes: 4096, acceptedVersions: [0, version])))
            await registry.subscribePresence(stream, connectionID: connection, roomID: room, targetUserID: target)
            streams.append(stream); connections.append(connection)
        }
        let refresh: Task<Void, Never>?

        refresh = Task { await registry.refreshAllObservedPresence() }
        let submitted = ContinuousClock.now + .seconds(2)
        while await reader.batchCalls == 0 {
            guard ContinuousClock.now < submitted else {
                await reader.release(); await broker.release(); await slow.releaseHint()
                await registry.shutdownRealtimeRecovery()
                for connection in connections { await registry.unregister(connectionID: connection) }
                throw RegistryRecoveryTestFailure.timeout
            }
            await Task.yield()
        }
        #expect(await reader.lastKeys.count == 1)
        await reader.release()
        let delivered = ContinuousClock.now + .seconds(2)
        while true {
            let held = await slow.hintHeld, seen = await healthy.presenceFrames
            if held && seen == 1 { break }
            guard ContinuousClock.now < delivered else {
                await broker.release(); await slow.releaseHint(); await refresh?.value
                    await registry.shutdownRealtimeRecovery()
                    for connection in connections { await registry.unregister(connectionID: connection) }
                    throw RegistryRecoveryTestFailure.timeout
                }
                await Task.yield()
            }
            await broker.release()

        #expect(try await registry.arrangeRealtimeRecoveryHeads([topic: head]) == [topic])
        await registry.realtimeCoverageReady(confirmations: [topic: confirmation], confirms: { _, _ in true })
        let until = ContinuousClock.now + .seconds(2)
        while true {
            let held = await slow.hintHeld, ready = await healthy.hasRoomReady
            if held && ready { break }
            guard ContinuousClock.now < until else {
                await slow.releaseHint(); await registry.shutdownRealtimeRecovery()
                for connection in connections { await registry.unregister(connectionID: connection) }
                throw RegistryRecoveryTestFailure.timeout
            }
            await Task.yield()
        }
        #expect(!(await slow.hasRoomReady))
        #expect(await reader.batchCalls == 1); #expect(await healthy.presenceFrames == 1)

        let lossReturned = RegistryPresenceFrameCounter()
        let loss = Task {
            await registry.invalidateRealtimeCoverage(topics: [topic], registeredThrough: .now)
            lossReturned.value.withLock { $0 += 1 }
        }
        let lossDeadline = ContinuousClock.now + .seconds(2)
        while lossReturned.value.withLock({ $0 }) == 0 {
            guard ContinuousClock.now < lossDeadline else {
                await slow.releaseHint(); await loss.value; await refresh?.value
                await registry.shutdownRealtimeRecovery()
                for connection in connections { await registry.unregister(connectionID: connection) }
                throw RegistryRecoveryTestFailure.timeout
            }
            await Task.yield()
        }
        await loss.value

        // The old actual write completes only after its scope ended. Its permit
        // must reject and it must not manufacture a receipt for the successor.
        let revokedScopeGeneration = await slow.lastRecoveringGeneration
        #expect(revokedScopeGeneration > 0)

        await registry.unsubscribePresence(connectionID: connections[0], roomID: room)
        await registry.subscribePresence(streams[0], connectionID: connections[0], roomID: room, targetUserID: target)

        await slow.releaseHint()
        let resumed = ContinuousClock.now + .seconds(2)
        while !(await slow.hasRoomReady) {
            guard ContinuousClock.now < resumed else {
                await refresh?.value; await registry.shutdownRealtimeRecovery()
                for connection in connections { await registry.unregister(connectionID: connection) }
                throw RegistryRecoveryTestFailure.timeout
            }
            await Task.yield()
        }
        #expect(await slow.presenceFrames == 1)
        await refresh?.value
        let endedGeneration = await slow.lastEndedGeneration
        // Bounded control retention may coalesce Ended into a successor's
        // Recovering. The actual old permit must still lose to that successor.
        #expect(await slow.roomReadyGenerations.allSatisfy { $0 > max(endedGeneration, revokedScopeGeneration) })
        await registry.shutdownRealtimeRecovery()
        for connection in connections { await registry.unregister(connectionID: connection) }
    }

    private func identityFixture() throws -> V2AuthenticatedConnection {
        .init(
            userID: try .init("00000000-0000-0000-0000-000000000d01"),
            deviceID: try .init("00000000-0000-0000-0000-000000000d02"),
            capabilityProfile: "base"
        )
    }

    private func streamFixture() throws -> V2GatewayByteStream {
        V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, 1]),
            session: .init(
                limits: try .init(maximumInFlightRequests: 1),
                authenticator: RegistryReentrancyAuthenticator(),
                capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()
            ),
            handler: RegistryReentrancyCommandHandler(),
            registry: V2DeviceConnectionRegistry()
        )
    }
}

private actor SuspendedPresenceLeases: V2LivePresenceLeaseManaging {
    private var active: Set<UUID> = []
    private var identities: [UUID: V2AuthenticatedConnection] = [:]
    private var suppressed: [UUID: Bool] = [:]
    private var refreshStarted: CheckedContinuation<Void, Never>?
    private var refreshResume: CheckedContinuation<Void, Never>?
    private var didStartRefresh = false

    func admitConnection(
        identity: V2AuthenticatedConnection,
        connectionID: UUID,
        publicationSuppressed: Bool,
        policy _: V2AuthenticatedConnectionAdmissionPolicy,
        now: Date
    ) async throws -> V2AuthenticatedConnectionLeaseOutcome {
        active.insert(connectionID)
        identities[connectionID] = identity
        suppressed[connectionID] = publicationSuppressed
        didStartRefresh = true
        refreshStarted?.resume()
        refreshStarted = nil
        await withCheckedContinuation { refreshResume = $0 }
        return .accepted(expiresAt: now.addingTimeInterval(30))
    }

    func renewConnection(
        identity: V2AuthenticatedConnection,
        connectionID: UUID,
        now: Date
    ) -> V2AuthenticatedConnectionLeaseOutcome {
        guard active.contains(connectionID), identities[connectionID] == identity else { return .rejected }
        return .accepted(expiresAt: now.addingTimeInterval(30))
    }

    func removePresence(
        identity: V2AuthenticatedConnection,
        connectionID: UUID,
        now _: Date
    ) -> Bool {
        guard identities[connectionID] == identity else { return !active.isEmpty }
        active.remove(connectionID)
        identities.removeValue(forKey: connectionID)
        suppressed.removeValue(forKey: connectionID)
        return !active.isEmpty
    }

    func setPresencePublication(identity: V2AuthenticatedConnection, connectionID: UUID,
        suppressed value: Bool, now: Date) throws -> V2PresencePublicationLeaseObservation {
        guard active.contains(connectionID), identities[connectionID] == identity else {
            throw V2GatewaySessionError.unsupportedCommand
        }
        suppressed[connectionID] = value
        let online = identities.contains { id, stored in stored.userID == identity.userID && suppressed[id] == false }
        return .init(isOnline: online, expiresAt: now.addingTimeInterval(30))
    }

    func allowsOnlinePresence(userID _: UserID) -> Bool { true }

    func waitUntilRefreshStarts() async {
        if didStartRefresh { return }
        await withCheckedContinuation { refreshStarted = $0 }
    }
    func resumeRefresh() { refreshResume?.resume(); refreshResume = nil }
    func activeConnectionIDs() -> Set<UUID> { active }
}

private actor SuspendedPreferencePresenceLeases: V2LivePresenceLeaseManaging {
    private var active: Set<UUID> = []
    private var identities: [UUID: V2AuthenticatedConnection] = [:]
    private var suppressed: [UUID: Bool] = [:]
    private var lookupStarted: CheckedContinuation<Void, Never>?
    private var lookupResume: CheckedContinuation<Void, Never>?
    private var didStartLookup = false

    func admitConnection(
        identity: V2AuthenticatedConnection,
        connectionID: UUID,
        publicationSuppressed: Bool,
        policy _: V2AuthenticatedConnectionAdmissionPolicy,
        now: Date
    ) -> V2AuthenticatedConnectionLeaseOutcome {
        active.insert(connectionID)
        identities[connectionID] = identity
        suppressed[connectionID] = publicationSuppressed
        return .accepted(expiresAt: now.addingTimeInterval(30))
    }

    // Match the production combined admission result. The separately gated
    // preference lookup belongs to the background publication worker.
    func admitConnectionRefresh(identity: V2AuthenticatedConnection, connectionID: UUID,
        publicationSuppressed: Bool, policy: V2AuthenticatedConnectionAdmissionPolicy, now: Date) -> V2LivePresenceLeaseRefresh {
        .init(outcome: admitConnection(identity: identity, connectionID: connectionID,
            publicationSuppressed: publicationSuppressed, policy: policy, now: now), allowsOnlinePresence: false)
    }

    func renewConnection(
        identity: V2AuthenticatedConnection,
        connectionID: UUID,
        now: Date
    ) -> V2AuthenticatedConnectionLeaseOutcome {
        guard active.contains(connectionID), identities[connectionID] == identity else { return .rejected }
        return .accepted(expiresAt: now.addingTimeInterval(30))
    }

    func removePresence(
        identity: V2AuthenticatedConnection,
        connectionID: UUID,
        now _: Date
    ) -> Bool {
        guard identities[connectionID] == identity else { return !active.isEmpty }
        active.remove(connectionID)
        identities.removeValue(forKey: connectionID)
        suppressed.removeValue(forKey: connectionID)
        return !active.isEmpty
    }

    func setPresencePublication(identity: V2AuthenticatedConnection, connectionID: UUID,
        suppressed value: Bool, now: Date) throws -> V2PresencePublicationLeaseObservation {
        guard active.contains(connectionID), identities[connectionID] == identity else {
            throw V2GatewaySessionError.unsupportedCommand
        }
        suppressed[connectionID] = value
        let online = identities.contains { id, stored in stored.userID == identity.userID && suppressed[id] == false }
        return .init(isOnline: online, expiresAt: now.addingTimeInterval(30))
    }

    func allowsOnlinePresence(userID _: UserID) async -> Bool {
        didStartLookup = true
        lookupStarted?.resume()
        lookupStarted = nil
        await withCheckedContinuation { lookupResume = $0 }
        return false
    }

    func waitUntilPreferenceLookupStarts() async {
        if didStartLookup { return }
        await withCheckedContinuation { lookupStarted = $0 }
    }

    func resumePreferenceLookup() {
        lookupResume?.resume()
        lookupResume = nil
    }

    func activeConnectionIDs() -> Set<UUID> { active }
}

private actor SuspendedLiveActivityBroker: V2LiveActivityInterestManaging, V2LiveActivityPublishing {
    private(set) var publications = 0
    private var presenceTargets: Set<UserID> = []
    private var activationStarted: CheckedContinuation<Void, Never>?
    private var activationResume: CheckedContinuation<Void, Never>?
    private var didStartActivation = false

    func activatePresence(targetUserID: UserID) async throws {
        didStartActivation = true
        activationStarted?.resume()
        activationStarted = nil
        await withCheckedContinuation { activationResume = $0 }
        presenceTargets.insert(targetUserID)
    }
    func deactivatePresence(targetUserID: UserID) { presenceTargets.remove(targetUserID) }
    func activateTyping(roomID _: RoomID) async throws {}
    func deactivateTyping(roomID _: RoomID) {}
    func publishPresence(targetUserID _: UserID, isOnline _: Bool, expiresAt _: Date) { publications += 1 }
    func publishTyping(_ state: V2TypingState) {}

    func waitUntilPresenceActivationStarts() async {
        if didStartActivation { return }
        await withCheckedContinuation { activationStarted = $0 }
    }
    func resumePresenceActivation() { activationResume?.resume(); activationResume = nil }
    func activePresenceTargets() -> Set<UserID> { presenceTargets }
}

private struct RegistryReentrancyAuthenticator: V2GatewayAuthenticator {
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) async throws -> V2GatewayAuthentication {
        try .init(userID: .init("00000000-0000-0000-0000-000000000d01"), expiresAt: nil)
    }
}

private struct RegistryReentrancyCommandHandler: V2GatewayCommandHandler {
    func handle(envelope _: IMV2Envelope, identity _: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        .init()
    }
}

private enum RegistryRecoveryTestFailure: Error { case timeout }

private actor GatedAccountSyncInterests: V2GroupEventWakeInterestManaging {
    private(set) var activations = 0
    private var started: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    func activate(roomID _: RoomID) async throws {
        activations += 1; started?.resume(); started = nil
        if !released { await withCheckedContinuation { gate = $0 } }
    }
    func deactivate(roomID _: RoomID) async {}
    func waitUntilStarted() async {
        if activations > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { released = true; gate?.resume(); gate = nil }
}

private final class RegistryPresenceFrameCounter: Sendable {
    let value = Mutex(0)
}
private actor RegistryPresenceRecorder {
    private let counter = RegistryPresenceFrameCounter()
    private let pauseWrites: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var writeHeld = false
    init(pauseWrites: Bool) { self.pauseWrites = pauseWrites }
    var presenceFrames: Int { counter.value.withLock { $0 } }
    func releaseWrite() { gate?.resume(); gate = nil }
    func recordScoped(_ write: V2GatewayScopedNotificationWrite) async -> Bool {
        let limits = try? V2FrameLimits(maximumPayloadBytes: 4096, acceptedVersions: [UInt8(IMV2ProtocolVersion.current)])
        let envelope = limits.flatMap { try? V2FrameCodec.decodeExactlyOne(write.bytes, limits: $0) }
            .flatMap { try? V2ServerProtobufFrameCodec.decode($0) }
        let isPresence: Bool
        if case .presenceChanged? = envelope?.body { isPresence = true } else { isPresence = false }
        if pauseWrites && isPresence { writeHeld = true; await withCheckedContinuation { gate = $0 } }
        let counter = counter
        return write.enqueueIfCurrent { if isPresence { counter.value.withLock { $0 += 1 } } }
    }
    func record(_ bytes: Data) {
        guard let limits = try? V2FrameLimits(maximumPayloadBytes: 4096, acceptedVersions: [UInt8(IMV2ProtocolVersion.current)]) else { return }
        var decoder = V2FrameDecoder(limits: limits)
        guard let frame = try? decoder.append(bytes).first,
              let envelope = try? V2ServerProtobufFrameCodec.decode(frame) else { return }
        if case .presenceChanged? = envelope.body { counter.value.withLock { $0 += 1 } }
    }
}
private struct RegistryPresenceAuthenticator: V2GatewayAuthenticator {
    let user: UserID
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) async throws -> V2GatewayAuthentication {
        try .init(userID: user, expiresAt: nil)
    }
}
private actor GatedRegistryPresenceReader: V2LiveActivityStore {
    let deniedViewer: UserID
    private(set) var batchCalls = 0
    private(set) var scalarCalls = 0
    private(set) var lastKeys: [V2PresenceObservationRequest] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    init(deniedViewer: UserID) { self.deniedViewer = deniedViewer }
    func presenceBatch(_ requests: [V2PresenceObservationRequest], now: Date) async throws
        -> [V2PresenceObservationRequest: V2PresenceObservationOutcome] {
        batchCalls += 1; lastKeys = requests
        if !released { await withCheckedContinuation { gate = $0 } }
        return Dictionary(uniqueKeysWithValues: requests.map { request in
            (request, request.viewerUserID == deniedViewer ? .denied(.interactionBlocked) : .observed(
                .init(roomID: request.roomID, targetUserID: request.targetUserID, isOnline: true, expiresAt: now.addingTimeInterval(30))))
        })
    }
    func release() { released = true; gate?.resume(); gate = nil }
    func presence(roomID _: RoomID, viewerUserID _: UserID, now _: Date) throws -> V2PresenceState {
        scalarCalls += 1; throw RegistryRecoveryTestFailure.timeout
    }
    func preferences(userID _: UserID, now _: Date) throws -> V2LiveActivityPreferences { throw RegistryRecoveryTestFailure.timeout }
    func authorizeTyping(roomID _: RoomID, actorUserID _: UserID, now _: Date) throws { throw RegistryRecoveryTestFailure.timeout }
    func authorizeObservation(roomID _: RoomID, viewerUserID _: UserID, subjectUserID _: UserID, now _: Date) throws { throw RegistryRecoveryTestFailure.timeout }
    func allowsOnlinePresence(userID _: UserID) -> Bool { true }
}

private actor GatedHeartbeatLeases: V2LivePresenceLeaseManaging {
    let leaseSeconds: Double
    let unknown: Bool
    private(set) var actualCalls = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(leaseSeconds: Double, unknown: Bool = false) { self.leaseSeconds = leaseSeconds; self.unknown = unknown }
    func admitConnection(identity: V2AuthenticatedConnection, connectionID: UUID, publicationSuppressed: Bool,
        policy: V2AuthenticatedConnectionAdmissionPolicy, now: Date) -> V2AuthenticatedConnectionLeaseOutcome {
        .accepted(expiresAt: now.addingTimeInterval(leaseSeconds))
    }
    func admitConnectionRefresh(identity: V2AuthenticatedConnection, connectionID: UUID, publicationSuppressed: Bool,
        policy: V2AuthenticatedConnectionAdmissionPolicy, now: Date) -> V2LivePresenceLeaseRefresh {
        .init(outcome: .accepted(expiresAt: now.addingTimeInterval(leaseSeconds)), allowsOnlinePresence: false,
            remainingLeaseSeconds: leaseSeconds)
    }
    func renewConnections(_ requests: [V2LivePresenceLeaseRenewalRequest]) async throws -> [UUID: V2LivePresenceLeaseRefresh] {
        actualCalls += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
        if unknown { throw RegistryRecoveryTestFailure.timeout }
        return Dictionary(uniqueKeysWithValues: requests.map {
            ($0.connectionID, .init(outcome: .accepted(expiresAt: Date().addingTimeInterval(30)),
                allowsOnlinePresence: false, remainingLeaseSeconds: 30))
        })
    }
    func renewConnection(identity: V2AuthenticatedConnection, connectionID: UUID, now: Date) throws -> V2AuthenticatedConnectionLeaseOutcome {
        Issue.record("heartbeat must use actual batch renewal"); throw RegistryRecoveryTestFailure.timeout
    }
    func removePresence(identity: V2AuthenticatedConnection, connectionID: UUID, now: Date) -> Bool { false }
    func allowsOnlinePresence(userID: UserID) -> Bool { false }
    func setPresencePublication(identity: V2AuthenticatedConnection, connectionID: UUID, suppressed: Bool,
        now: Date) -> V2PresencePublicationLeaseObservation { .init(isOnline: false, expiresAt: now) }
    func release() { released = true; let current = waiters; waiters.removeAll(); for waiter in current { waiter.resume() } }
    func waitForStart() async throws {
        let bound = ContinuousClock.now + .seconds(2)
        while actualCalls == 0 {
            guard ContinuousClock.now < bound else { throw RegistryRecoveryTestFailure.timeout }
            await Task.yield()
        }
    }
}

private final class RegistryHeartbeatDrainResult: Sendable {
    private let state = Mutex(false)
    func mark() { state.withLock { $0 = true } }
    var completed: Bool { state.withLock { $0 } }
}


private final class ScopedRecoveryFrames: Sendable { let frames = Mutex<[Data]>([]) }
private actor ScopedRecoveryRecorder {
    private let holder = ScopedRecoveryFrames()
    private let scope: IMV2RealtimeCoverage.Scope
    private var blockHint: Bool
    private var blockReady: Bool
    private var rejectReady: Bool
    private var rejectOneReady = false
    private(set) var readyRejections = 0
    private(set) var readyPermitRejections = 0
    private var readyGate: CheckedContinuation<Void, Never>?
    private(set) var readyHeld = false
    private var gate: CheckedContinuation<Void, Never>?
    private var lossGate: CheckedContinuation<Void, Never>?
    private(set) var lossHeld = false
    private(set) var hintHeld = false
    init(blockHint: Bool, scope: IMV2RealtimeCoverage.Scope, blockReady: Bool = false, rejectReady: Bool = false) {
        self.blockHint = blockHint; self.scope = scope; self.blockReady = blockReady; self.rejectReady = rejectReady
    }
    func blockNextReady() { blockReady = true; readyHeld = false }
    func rejectNextReady() { rejectOneReady = true }
    func blockNextHint() { blockHint = true; hintHeld = false }
    func releaseReady() { blockReady = false; readyGate?.resume(); readyGate = nil }
    func releaseHint() {
        blockHint = false; gate?.resume(); gate = nil; lossGate?.resume(); lossGate = nil
    }
    func record(_ write: V2GatewayScopedNotificationWrite) async -> Bool {
        let envelope = try? Self.decode(write.bytes)
        if case .realtimeCoverage(let coverage)? = envelope?.body,
           coverage.scope == scope, coverage.state == .ready, (rejectReady || rejectOneReady) {
            rejectOneReady = false
            readyRejections += 1; return false
        }
        if case .realtimeCoverage(let coverage)? = envelope?.body, coverage.scope == scope,
           coverage.state == .ready, blockReady {
            readyHeld = true; await withCheckedContinuation { readyGate = $0 }
        }
        if case .realtimeCoverage(let coverage)? = envelope?.body, coverage.reason == .coverageLost, blockHint {
            lossHeld = true
            await withCheckedContinuation { lossGate = $0 }
        }
        let hint: Bool
        switch envelope?.body { case .groupEventAvailable?, .presenceChanged?: hint = true; default: hint = false }
        if hint && blockHint { hintHeld = true; await withCheckedContinuation { gate = $0 } }
        let holder = holder
        let accepted = write.enqueueIfCurrent { holder.frames.withLock { $0.append(write.bytes) } }
        if !accepted, case .realtimeCoverage(let coverage)? = envelope?.body,
           coverage.state == .ready { readyPermitRejections += 1 }
        return accepted
    }
    private static func decode(_ bytes: Data) throws -> IMV2Envelope {
        var decoder = V2FrameDecoder(limits: try .init(maximumPayloadBytes: 4096, acceptedVersions: [UInt8(IMV2ProtocolVersion.current)]))
        let frame = try #require(decoder.append(bytes).first)
        return try V2ServerProtobufFrameCodec.decode(frame)
    }
    var roomReadyCount: Int {
        holder.frames.withLock { bytes in bytes.compactMap { try? Self.decode($0) }.filter {
            if case .realtimeCoverage(let value)? = $0.body { return value.scope == scope && value.state == .ready }
            return false
        }.count }
    }
    var roomReadyGenerations: [UInt64] {
        holder.frames.withLock { $0.compactMap { try? Self.decode($0) }.compactMap {
            if case .realtimeCoverage(let value)? = $0.body, value.scope == scope, value.state == .ready { return value.scopeGeneration }
            return nil
        } }
    }
    var lastEndedGeneration: UInt64 {
        holder.frames.withLock { $0.compactMap { try? Self.decode($0) }.compactMap {
            if case .realtimeCoverage(let value)? = $0.body, value.scope == scope, value.state == .ended { return value.scopeGeneration }
            return nil
        }.max() ?? 0 }
    }
    var lastRecoveringGeneration: UInt64 {
        holder.frames.withLock { $0.compactMap { try? Self.decode($0) }.compactMap {
            if case .realtimeCoverage(let value)? = $0.body, value.scope == scope, value.state == .recovering { return value.scopeGeneration }
            return nil
        }.max() ?? 0 }
    }
    var hasRoomReady: Bool { roomReadyCount > 0 }
    var presenceFrames: Int {
        holder.frames.withLock { $0.compactMap { try? Self.decode($0) }.filter {
            if case .presenceChanged? = $0.body { return true }; return false
        }.count }
    }
    var hintWatermarks: [UInt64] {
        holder.frames.withLock { $0.compactMap { try? Self.decode($0) }.compactMap {
            if case .groupEventAvailable(let value)? = $0.body { return value.highWatermark }; return nil
        } }
    }
}

private actor GatedRegistryRecoveryPresenceInterests: V2LiveActivityInterestManaging, V2LiveActivityPublishing {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func activatePresence(targetUserID: UserID) async throws {
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { released = true; let old = waiters; waiters.removeAll(); for waiter in old { waiter.resume() } }
    func deactivatePresence(targetUserID: UserID) async {}
    func activateTyping(roomID: RoomID) async throws {}
    func deactivateTyping(roomID: RoomID) async {}
    func publishPresence(targetUserID: UserID, isOnline: Bool, expiresAt: Date) async {}
    func publishTyping(_ state: V2TypingState) async {}
}







private func makeScopedRegistryTestStream(registry: V2DeviceConnectionRegistry,
    recorder: ScopedRecoveryRecorder, user: UserID, room: RoomID) async throws -> (UUID, V2GatewayByteStream) {
    let connection = UUID(), device = DeviceID(uuid: UUID()), version = UInt8(IMV2ProtocolVersion.current)
    let session = V2GatewaySession(limits: try .init(maximumInFlightRequests: 1),
        authenticator: RegistryPresenceAuthenticator(user: user), capabilityProfile: "base",
        commandAdmission: V2AllowingGatewayCommandAdmission())
    let stream = V2GatewayByteStream(frameLimits: try .init(maximumPayloadBytes: 4096, acceptedVersions: [0, version]),
        session: session, handler: RegistryReentrancyCommandHandler(), connectionID: connection, registry: registry)
    #expect(await stream.attachTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
        scopedNotificationWriter: { await recorder.record($0) }))
    var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello.deviceID = device.rawValue
    hello.clientHello.supportedProtocolVersions = [UInt32(version)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
    _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0),
        limits: .init(maximumPayloadBytes: 4096, acceptedVersions: [0, version])))
    var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
    auth.authenticate.accessToken = "fixture"; auth.authenticate.deviceID = device.rawValue
    _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(auth, frameVersion: version),
        limits: .init(maximumPayloadBytes: 4096, acceptedVersions: [0, version])))
    return (connection, stream)
}
