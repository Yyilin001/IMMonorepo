import Foundation
import Synchronization
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerApplication
import Testing
@testable import IMV2ServerGateway

@Suite("Gateway authoritative user controls")
struct V2GatewayJournalUserControlTests {
    @Test("replayed membership control cuts do not rescan the account directory")
    func membershipCutReplayDoesNotRescan() async throws {
        let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), connection = UUID()
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits)
        let socket = try stream(registry: registry, connection: connection)
        try #require(await registry.register(socket, connectionID: connection,
            identity: .init(userID: user, deviceID: device, capabilityProfile: "base"), publicationSuppressed: true))
        let scans = Mutex(0)
        let targeted = Mutex<[RoomID]>([])
        let service = try V2AccountRoomChangeService(states: EmptyMembershipStates(requested: { rooms in targeted.withLock { $0.append(contentsOf: rooms) } }),
            directoryPage: { _, _ in
                scans.withLock { $0 += 1 }
                return .init(rooms: [], nextCursor: nil, topologyGeneration: "stable")
            }, onlineDelivery: .init(activate: { _, _, _ in }, deactivate: { _ in }))
        await registry.configureAccountRoomChanges(service)
        let ticket = try await service.begin(userID: user, connectionID: connection, send: { _ in true }, close: {})
        try await service.bootstrap(ticket)
        let identity = V2RealtimeJournalSourceIdentity(sourceID: UUID(), databaseIncarnation: UUID())
        let source = V2RealtimeJournalSource(sourceID: "membership", incarnationID: identity.databaseIncarnation, partitionID: 1)
        let captured = await registry.journalUserControlInterests()
        let snapshot = V2RealtimeJournalUserSnapshot(identity: identity, observedAt: Date(),
            cuts: [.init(partitionID: 1, publishedThrough: 1, trimmedThrough: 0)], requestedUserIDs: [user.uuidValue!],
            requestedDeviceKeys: [.init(userID: user.uuidValue!, deviceID: device.uuidValue!)],
            users: [.init(userID: user.uuidValue!, controlVersion: 1,
                membershipDiscoveryVersion: 1, sessionControlVersion: 0)],
            devices: [.init(userID: user.uuidValue!, deviceID: device.uuidValue!, latestChangeVersion: 0)])
        let initial = await registry.applyAuthoritativeUserControl(snapshot, source: source, expectedIdentity: identity,
            isAuthenticationSource: false, minimumControlVersions: [user: 1], credentialChangedDeviceKeys: [],
            requested: captured, requestedAt: .now, deadline: .now + .seconds(30), isCurrent: { true })
        try #require(initial?.versions[user] == 1)
        try await waitUntil { scans.withLock { $0 } >= 2 }
        for _ in 0..<100 {
            let receipt = await registry.applyAuthoritativeUserControl(snapshot, source: source, expectedIdentity: identity,
                isAuthenticationSource: false, minimumControlVersions: [user: 1], credentialChangedDeviceKeys: [],
                requested: captured, requestedAt: .now, deadline: .now + .seconds(30), isCurrent: { true })
            #expect(receipt?.versions[user] == 1)
        }
        #expect(scans.withLock { $0 } == 2)
        let advanced = V2RealtimeJournalUserSnapshot(identity: identity, observedAt: Date(), cuts: snapshot.cuts,
            requestedUserIDs: snapshot.requestedUserIDs, requestedDeviceKeys: snapshot.requestedDeviceKeys,
            users: [.init(userID: user.uuidValue!, controlVersion: 2, membershipDiscoveryVersion: 2, sessionControlVersion: 0)],
            devices: snapshot.devices)
        let changed = await registry.applyAuthoritativeUserControl(advanced, source: source, expectedIdentity: identity,
            isAuthenticationSource: false, minimumControlVersions: [user: 2], credentialChangedDeviceKeys: [],
            requested: captured, requestedAt: .now, deadline: .now + .seconds(30), isCurrent: { true })
        try #require(changed?.versions[user] == 2)
        try await waitUntil { scans.withLock { $0 } == 3 }
        let room = RoomID(uuid: UUID())
        let mixed = V2RealtimeJournalUserSnapshot(identity: identity, observedAt: Date(), cuts: snapshot.cuts,
            requestedUserIDs: snapshot.requestedUserIDs, requestedDeviceKeys: snapshot.requestedDeviceKeys,
            users: [.init(userID: user.uuidValue!, controlVersion: 4, membershipDiscoveryVersion: 3, sessionControlVersion: 4)],
            devices: snapshot.devices)
        let mixedApplied = await registry.applyAuthoritativeUserControl(mixed, source: source, expectedIdentity: identity,
            isAuthenticationSource: false, minimumControlVersions: [user: 4], credentialChangedDeviceKeys: [],
            membershipChangedRooms: [user: [room]], membershipChangeVersions: [user: 3],
            requested: captured, requestedAt: .now, deadline: .now + .seconds(30), isCurrent: { true })
        try #require(mixedApplied?.versions[user] == 4)
        try await waitUntil { targeted.withLock { $0 } == [room] }
        #expect(scans.withLock { $0 } == 3)
        let ahead = V2RealtimeJournalUserSnapshot(identity: identity, observedAt: Date(), cuts: snapshot.cuts,
            requestedUserIDs: snapshot.requestedUserIDs, requestedDeviceKeys: snapshot.requestedDeviceKeys,
            users: [.init(userID: user.uuidValue!, controlVersion: 5, membershipDiscoveryVersion: 5, sessionControlVersion: 4)],
            devices: snapshot.devices)
        let aheadApplied = await registry.applyAuthoritativeUserControl(ahead, source: source, expectedIdentity: identity,
            isAuthenticationSource: false, minimumControlVersions: [user: 4], credentialChangedDeviceKeys: [],
            membershipChangedRooms: [user: [room]], membershipChangeVersions: [user: 3],
            requested: captured, requestedAt: .now, deadline: .now + .seconds(30), isCurrent: { true })
        try #require(aheadApplied?.versions[user] == 5)
        try await waitUntil { scans.withLock { $0 } == 4 }
        await service.shutdown()
        #expect(scans.withLock { $0 } == 4)
        await registry.unregister(connectionID: connection)
        await socket.closeForAccountRecovery()
        await registry.shutdownRealtimeRecovery()
    }
    @Test("authentication cuts fence baseline races and preserve reauthenticated successors", arguments: [false, true])
    func authoritativeDeviceControls(changedBeforeBaseline: Bool) async throws {
        let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), otherDevice = DeviceID(uuid: UUID())
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits)
        let identity = V2RealtimeJournalSourceIdentity(sourceID: UUID(), databaseIncarnation: UUID())
        let source = V2RealtimeJournalSource(sourceID: "users", incarnationID: identity.databaseIncarnation, partitionID: 1)
        let first = UUID(), second = UUID()
        let firstStream = try stream(registry: registry, connection: first)
        let admitted = try await registry.register(firstStream, connectionID: first,
            identity: .init(userID: user, deviceID: device, capabilityProfile: "base", credentialControlVersion: 6), publicationSuppressed: true)
        #expect(admitted)
        let otherConnection = UUID()
        let otherStream = try stream(registry: registry, connection: otherConnection)
        let otherAdmitted = try await registry.register(otherStream, connectionID: otherConnection,
            identity: .init(userID: user, deviceID: otherDevice, capabilityProfile: "base", credentialControlVersion: 6), publicationSuppressed: true)
        #expect(otherAdmitted)
        let captured = await registry.journalUserControlInterests()
        let initial = snapshot(identity: identity, user: user, device: device, unchangedDevice: otherDevice, version: 6)
        let roomSource = V2RealtimeJournalSource(sourceID: "rooms", incarnationID: identity.databaseIncarnation, partitionID: 1)
        let roomSnapshot = V2RealtimeJournalUserSnapshot(identity: identity, observedAt: Date(), cuts: initial.cuts,
            requestedUserIDs: initial.requestedUserIDs, requestedDeviceKeys: initial.requestedDeviceKeys, users: initial.users,
            devices: initial.devices)
        let roomApplied = await registry.applyAuthoritativeUserControl(roomSnapshot, source: roomSource, expectedIdentity: identity,
            isAuthenticationSource: false, minimumControlVersions: [:], credentialChangedDeviceKeys: [],
            requested: captured, requestedAt: .now, deadline: .now + .seconds(30), isCurrent: { true })
        #expect(roomApplied != nil)
        #expect(await registry.connectionCount(for: device) == 1)
        #expect(await registry.connectionCount(for: otherDevice) == 1)
        if !changedBeforeBaseline {
            let seed = await registry.applyAuthoritativeUserControl(initial, source: source, expectedIdentity: identity,
                isAuthenticationSource: true, minimumControlVersions: [:], credentialChangedDeviceKeys: [], requested: captured,
                requestedAt: .now, deadline: .now + .seconds(30), isCurrent: { true })
            #expect(seed?.versions[user] == 6)
            #expect(await registry.connectionCount(for: device) == 1)
        }
        let secondStream = try stream(registry: registry, connection: second)
        let secondAdmitted = try await registry.register(secondStream, connectionID: second,
            identity: .init(userID: user, deviceID: device, capabilityProfile: "base", credentialControlVersion: 7), publicationSuppressed: true)
        #expect(secondAdmitted)
        let newer = snapshot(identity: identity, user: user, device: device, unchangedDevice: otherDevice, version: 7)
        let applied = await registry.applyAuthoritativeUserControl(newer, source: source, expectedIdentity: identity,
            isAuthenticationSource: true, minimumControlVersions: [user: 7],
            credentialChangedDeviceKeys: changedBeforeBaseline ? [] : [.init(userID: user.uuidValue!, deviceID: device.uuidValue!)], requested: captured, requestedAt: .now, deadline: .now + .seconds(30), isCurrent: { true })
        #expect(applied?.versions[user] == 7)
        #expect(await registry.connectionCount(for: device) == 1)
        #expect(await registry.connectionCount(for: otherDevice) == 1)
        let remainingConnections = Set(await registry.journalUserControlInterests().map(\.connectionID))
        #expect(remainingConnections == [second, otherConnection])
        let current = await registry.journalUserControlInterests()
        let stale = await registry.applyAuthoritativeUserControl(initial, source: source, expectedIdentity: identity,
            isAuthenticationSource: true, minimumControlVersions: [:], credentialChangedDeviceKeys: [], requested: current, requestedAt: .now, deadline: .now + .seconds(30), isCurrent: { true })
        #expect(stale == nil)
        let incomplete = V2RealtimeJournalUserSnapshot(identity: identity, observedAt: Date(), cuts: newer.cuts,
            requestedUserIDs: newer.requestedUserIDs, requestedDeviceKeys: newer.requestedDeviceKeys,
            users: newer.users, devices: [])
        let rejected = await registry.applyAuthoritativeUserControl(incomplete, source: source, expectedIdentity: identity,
            isAuthenticationSource: true, minimumControlVersions: [:], credentialChangedDeviceKeys: [], requested: current, requestedAt: .now, deadline: .now + .seconds(30), isCurrent: { true })
        #expect(rejected == nil)
        #expect(await registry.connectionCount(for: device) == 1)
        await registry.unregister(connectionID: otherConnection)
        await otherStream.closeForAccountRecovery()
        await registry.unregister(connectionID: second)
        await firstStream.closeForAccountRecovery(); await secondStream.closeForAccountRecovery()
        await registry.shutdownRealtimeRecovery()
    }

    private func snapshot(identity: V2RealtimeJournalSourceIdentity, user: UserID, device: DeviceID, unchangedDevice: DeviceID,
                          version: Int64) -> V2RealtimeJournalUserSnapshot {
        let now = Date()
        let unchanged = V2RealtimeJournalDeviceControl(userID: user.uuidValue!, deviceID: unchangedDevice.uuidValue!, latestChangeVersion: 6)
        return .init(identity: identity, observedAt: now,
            cuts: [.init(partitionID: 1, publishedThrough: 1, trimmedThrough: 0)],
            requestedUserIDs: [user.uuidValue!], requestedDeviceKeys: [.init(userID: user.uuidValue!, deviceID: device.uuidValue!),
                .init(userID: user.uuidValue!, deviceID: unchangedDevice.uuidValue!)],
            users: [.init(userID: user.uuidValue!, controlVersion: version, membershipDiscoveryVersion: 0, sessionControlVersion: version)],
            devices: [unchanged, .init(userID: user.uuidValue!, deviceID: device.uuidValue!, latestChangeVersion: version)])
    }
    func stream(registry: V2DeviceConnectionRegistry, connection: UUID) throws -> V2GatewayByteStream {
        let limits = try V2FrameLimits(maximumPayloadBytes: 4096, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
        return V2GatewayByteStream(frameLimits: limits,
            session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: UserControlAuthenticator(),
                capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: UserControlHandler(), connectionID: connection, registry: registry)
    }
    private func waitUntil(_ predicate: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw UserControlFailure.timeout }
            await Task.yield()
        }
    }
}
private struct EmptyMembershipStates: V2RoomStateReading {
    var requested: (@Sendable ([RoomID]) -> Void)? = nil
    func states(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomStateReadResult] {
        if let requested {
            requested(roomIDs)
            return Dictionary(uniqueKeysWithValues: roomIDs.map { ($0, .unavailable) })
        }
        #expect(roomIDs.isEmpty)
        return [:]
    }
}
private enum UserControlFailure: Error { case timeout }
private struct UserControlAuthenticator: V2GatewayAuthenticator {
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication { throw UserControlFailure.timeout }
}
private struct UserControlHandler: V2GatewayCommandHandler {
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope { envelope }
}
