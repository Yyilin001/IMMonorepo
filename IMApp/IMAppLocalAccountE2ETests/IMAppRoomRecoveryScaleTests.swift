import Foundation
import IMV2ClientKit
import IMV2Core
import XCTest

/// The disposable harness seeds committed nonempty rooms before registration
/// returns. Every recovery request uses the production TLS connection.
final class IMAppRoomRecoveryScaleTests: XCTestCase {
    func testNonemptyRoomsRecoverAcrossReconnect() async throws {
        guard let count = ProcessInfo.processInfo.environment["IMV2_ROOM_RECOVERY_SCALE"].flatMap(Int.init) else {
            throw XCTSkip("Requires the disposable room recovery scale harness")
        }
        XCTAssertTrue([0, 50, 129, 1000, 10000].contains(count))
        let account = try await registerLocalAccount(displayName: "Room recovery scale")
        let connection = V2TLSFrameConnection(endpoint: try .init(host: "localhost", port: 7443),
            frameLimits: try .init(maximumPayloadBytes: 65536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]))
        let directory = FileManager.default.temporaryDirectory.appending(path: "tls-room-scale-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await V2LocalStoreBootstrapper(bindingStore: LocalE2EInstallationBindingStore())
            .open(databaseURL: directory.appending(path: "client.sqlite"), userID: account.userID)
        let credentialStore = RecoveryScaleCredentialStore()
        let authMeter = RecoveryScaleAuthMeter(transport: try V2HTTPDeviceCredentialAuthTransport(
            refreshEndpoint: XCTUnwrap(URL(string: "https://localhost:8443/v2/device-credentials/refresh"))))
        let auth = V2AuthSession(credentialStore: credentialStore,
            transport: authMeter,
            revocationScheduler: V2DeviceRevocationStore(service: "tls-room-scale-revocations-\(UUID())"))
        let coordinator = V2RealtimeSessionCoordinator(authSession: auth, connection: connection,
            supportedCapabilityProfiles: ["base"])
        var onlineRoom: RoomID?
        var stage = "authentication"
        do {
            try await auth.establish(account.credentials)
            for cycle in 0..<2 {
                if count == 50 && cycle == 1 {
                    // Exercise a real rotation cheaply before the large-account
                    // run reaches natural expiry. This is not an expiry simulation.
                    _ = try await auth.refresh()
                    print("IMV2_TLS_ROOM_FORCED_REFRESH_PASSED rooms=50")
                }
                stage = "authentication"
                let start = ContinuousClock.now
                let recoveryDeadline = start.advanced(by: .seconds(max(600, count / 5)))
                var reconnections = 0
                // Keep one meter across connection replacements in this cycle.
                // Otherwise a successful retry hides the traffic before expiry.
                let measured = RecoveryScaleFrameMeter(wire: connection)
                while true {
                    do {
                        let session = try await coordinator.connect()
                        let transport = V2ProtobufSyncTransport(wire: measured, protocolVersion: session.protocolVersion)
                        let personal = V2SyncEngine(transport: transport, store: store, capabilityProfile: session.capabilityProfile)
                        stage = "personal-sync"
                        try await synchronizeInitialState(personal)
                        stage = "room-recovery"
                        let engine = V2RoomRecoveryEngine(transport: transport, latestVisible: transport, store: store,
                            groupEvents: V2GroupEventSyncEngine(transport: transport, store: store))
                        let runner = V2RoomRecoveryRunner(engine: engine, source: connection, personalSync: personal)
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask { try await runner.run(userID: account.userID) }
                            group.addTask {
                                let deadline = recoveryDeadline
                                var reportedList = false
                                while await engine.phase != .live {
                                    if !reportedList {
                                        let page = try await store.conversationListPage(isArchived: false, limit: 20)
                                        if page.entries.count == min(20, count) {
                                            print("IMV2_TLS_ROOM_LIST_READY rooms=\(count) cycle=\(cycle) elapsed=\(start.duration(to: .now))")
                                            reportedList = true
                                        }
                                    }
                                    guard ContinuousClock.now < deadline else { throw V2RealtimeTransportError.unexpectedResponse }
                                    try await Task.sleep(for: .milliseconds(20))
                                }
                                let progress = try await engine.progress()
                                guard progress.directoryComplete, progress.pendingRoomCount == 0 else {
                                    throw V2RealtimeTransportError.unexpectedResponse
                                }
                            }
                            defer { group.cancelAll() }
                            _ = try await group.next()
                        }
                        let elapsed = start.duration(to: .now)
                        print("IMV2_TLS_ROOM_RECOVERY_REQUESTS rooms=\(count) cycle=\(cycle) \(await measured.report())")
                        stage = "verification"
                        var cursor: String?, rooms: Set<RoomID> = []
                        repeat {
                            let page = try await transport.userRoomDirectory(cursor: cursor, pageSize: 100)
                            for entry in page.rooms {
                                XCTAssertTrue(rooms.insert(entry.roomID).inserted)
                                let messages = try await store.messages(in: entry.roomID)
                                XCTAssertEqual(messages.count, 1)
                                XCTAssertEqual(messages.first?.text, "tls-scale-message")
                                let applied = try await store.groupEventCursor(roomID: entry.roomID)
                                XCTAssertEqual(applied, 1)
                            }
                            cursor = page.nextCursor
                        } while cursor != nil
                        XCTAssertEqual(rooms.count, count)
                        let ordered = rooms.sorted { $0.rawValue < $1.rawValue }
                        if !ordered.isEmpty { onlineRoom = ordered[min(128, ordered.count - 1)] }
                        await connection.disconnect()
                        print("IMV2_TLS_ROOM_RECOVERY_SCALE rooms=\(count) cycle=\(cycle) catchup=\(elapsed)")
                        break
                    } catch V2TLSFrameConnectionError.connectionClosed {
                        // Preserve the SQLite checkpoint and use the production
                        // credential owner to refresh an expired token on reconnect.
                        await coordinator.disconnect()
                        guard ContinuousClock.now < recoveryDeadline, reconnections < 4 else {
                            throw V2TLSFrameConnectionError.connectionClosed
                        }
                        reconnections += 1
                        print("IMV2_TLS_ROOM_RECOVERY_RECONNECT rooms=\(count) cycle=\(cycle) attempt=\(reconnections)")
                    }
                }
            }
            if let onlineRoom {
                stage = "online-change"
                try await verifyOnlineChange(connection: connection, coordinator: coordinator, auth: auth, account: account, store: store,
                    roomID: onlineRoom, count: count)
                await connection.disconnect()
                if ProcessInfo.processInfo.environment["IMV2_ROOM_RECOVERY_MEMBERSHIP_RACE"] == "1" {
                    stage = "membership-race"
                    try await verifyMembershipRace(connection: connection, coordinator: coordinator,
                        account: account, store: store)
                    await coordinator.disconnect()
                }
                if ProcessInfo.processInfo.environment["IMV2_ROOM_RECOVERY_APP_RECONNECT"] == "1" {
                    stage = "app-automatic-reconnect"
                    try await Self.verifyAppAutomaticReconnect(auth: auth, account: account, roomID: onlineRoom)
                }
                if ProcessInfo.processInfo.environment["IMV2_ROOM_RECOVERY_SLOW_TLS"] == "1" {
                    stage = "slow-tls"
                    try await verifySlowTLS(connection: connection, coordinator: coordinator, auth: auth,
                        account: account, store: store, roomID: onlineRoom)
                    await coordinator.disconnect()
                }
                if let boundary = ProcessInfo.processInfo.environment["IMV2_ROOM_RECOVERY_SCAN_RACE"] {
                    stage = "scan-race-\(boundary)"
                    try await verifyScanRace(connection: connection, coordinator: coordinator, auth: auth,
                        account: account, store: store, roomID: onlineRoom, boundary: boundary)
                    await coordinator.disconnect()
                }
                if ProcessInfo.processInfo.environment["IMV2_ROOM_RECOVERY_DROP_TAIL"] == "1" {
                    stage = "silent-tail"
                    try await verifyOnlineChange(connection: connection, coordinator: coordinator, auth: auth,
                        account: account, store: store, roomID: onlineRoom, count: count,
                        expectedMessageCount: 3, dropTail: true)
                    await coordinator.disconnect()
                    print("IMV2_TLS_ROOM_SILENT_TAIL_RECOVERY_PASSED")
                }
                if ProcessInfo.processInfo.environment["IMV2_ROOM_RECOVERY_BROKER_OUTAGE"] == "1" {
                    stage = "broker-outage"
                    try await verifyBrokerOutage(connection: connection, coordinator: coordinator,
                        account: account, store: store)
                    try await verifyOnlineChange(connection: connection, coordinator: coordinator, auth: auth,
                        account: account, store: store, roomID: onlineRoom, count: count, expectedMessageCount: 3)
                    await coordinator.disconnect()
                    print("IMV2_TLS_ROOM_BROKER_RECOVERY_PASSED")
                }
            }
            print("IMV2_TLS_ROOM_RECOVERY_SCALE_PASSED rooms=\(count)")
            print("IMV2_TLS_ROOM_AUTH_REFRESHES count=\(await authMeter.successfulRefreshes)")
            try await credentialStore.delete()
        } catch {
            print("IMV2_TLS_ROOM_RECOVERY_SCALE_FAILED stage=\(stage)")
            await connection.disconnect()
            try await credentialStore.delete()
            throw error
        }
    }

    private func verifyOnlineChange(connection: V2TLSFrameConnection, coordinator: V2RealtimeSessionCoordinator, auth: V2AuthSession, account: LocalE2EAccountCredentials,
                                    store: GRDBV2LocalSyncStore, roomID: RoomID, count: Int, expectedMessageCount: Int = 2, dropTail: Bool = false) async throws {
        let session = try await coordinator.connect()
        let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: session.protocolVersion)
        let personal = V2SyncEngine(transport: transport, store: store, capabilityProfile: session.capabilityProfile)
        try await synchronizeInitialState(personal)
        let engine = V2RoomRecoveryEngine(transport: transport, latestVisible: transport, store: store,
            groupEvents: V2GroupEventSyncEngine(transport: transport, store: store))
        let loss = RecoveryTailLossSource(connection: connection, roomID: roomID,
            targetHead: UInt64(expectedMessageCount))
        let source: any V2AccountRoomChangeSource = dropTail ? loss : connection
        let runner = V2RoomRecoveryRunner(engine: engine, source: source, personalSync: personal,
            integrityInterval: { dropTail ? 5 : 3600 })
        _ = try await transport.subscribeToGroupEvents(roomID: roomID,
            afterRoomSequence: try await store.groupEventCursor(roomID: roomID))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await runner.run(userID: account.userID) }
            group.addTask {
                while true {
                    let hint = try await loss.nextGroupEventAvailabilityHint()
                    if hint.roomID == roomID { await runner.requestCatchUp() }
                }
            }
            group.addTask {
                let readyDeadline = ContinuousClock.now.advanced(by: .seconds(max(600, count / 5)))
                while await engine.phase != .live {
                    guard ContinuousClock.now < readyDeadline else { throw V2RealtimeTransportError.unexpectedResponse }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                if dropTail { await loss.arm() }
                try await sendRecoveryOnlineMessage(transport: transport, connection: connection, auth: auth, account: account, roomID: roomID, deadline: deadline)
                // The current Owner room hint wakes recovery. Dropped hints
                // never reach requestCatchUp; only the runner's integrity scan
                // can repair the intentionally missing tail.
                while true {
                    let messages = try await store.messages(in: roomID)
                    if messages.count == expectedMessageCount, messages.contains(where: { $0.text == "tls-scale-online" }),
                       try await store.groupEventCursor(roomID: roomID) == UInt64(expectedMessageCount) { break }
                    guard ContinuousClock.now < deadline else { throw V2RealtimeTransportError.unexpectedResponse }
                    try await Task.sleep(for: .milliseconds(20))
                }
                if dropTail {
                    let dropped = await loss.droppedCount
                    let forwarded = await loss.forwardedCount
                    XCTAssertGreaterThan(dropped, 0, "The intended real TLS notification was not dropped")
                    XCTAssertEqual(forwarded, 0, "Another notification could have triggered recovery")
                    print("IMV2_TLS_ROOM_TAIL_DROPPED count=\(dropped)")
                }
                print("IMV2_TLS_ROOM_ONLINE_PASSED rooms=\(count) directoryPosition=\(min(129, count))")
                if ProcessInfo.processInfo.environment["IMV2_ROOM_RECOVERY_SECONDARY_PORT"] != nil {
                    print("IMV2_TLS_ROOM_CROSS_GATEWAY_PASSED rooms=\(count)")
                }
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func verifyBrokerOutage(connection: V2TLSFrameConnection, coordinator: V2RealtimeSessionCoordinator,
                                    account: LocalE2EAccountCredentials, store: GRDBV2LocalSyncStore) async throws {
        let session = try await coordinator.connect()
        let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: session.protocolVersion)
        let personal = V2SyncEngine(transport: transport, store: store, capabilityProfile: session.capabilityProfile)
        try await synchronizeInitialState(personal)
        let engine = V2RoomRecoveryEngine(transport: transport, latestVisible: transport, store: store,
            groupEvents: V2GroupEventSyncEngine(transport: transport, store: store))
        let runner = V2RoomRecoveryRunner(engine: engine, source: connection, personalSync: personal,
            integrityInterval: { 3600 })
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await runner.run(userID: account.userID) }
                group.addTask {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                    while await engine.phase != .live {
                        guard ContinuousClock.now < deadline else { throw V2RealtimeTransportError.unexpectedResponse }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    try await controlRecoveryBroker(action: "stop")
                    // An actual coverageLost error must beat this timeout.
                    try await Task.sleep(for: .seconds(30))
                    throw V2RealtimeTransportError.unexpectedResponse
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
            throw V2RealtimeTransportError.unexpectedResponse
        } catch V2RoomRecoveryEngineError.coverageLost {
            print("IMV2_TLS_ROOM_BROKER_COVERAGE_LOST")
            try await controlRecoveryBroker(action: "start")
            await coordinator.disconnect()
        } catch {
            await coordinator.disconnect()
            throw error
        }
    }
}

/// Fault injection only after the real TLS inbox has decoded/validated a frame.
/// Drops all copies of one target wake; never changes a pull response or requests
/// catch-up. This tests periodic source reconciliation, not transport gap detection.
private actor RecoveryTailLossSource: V2AccountRoomChangeSource, V2GroupEventAvailabilityHintSource {
    let connection: V2TLSFrameConnection
    let roomID: RoomID
    let targetHead: UInt64
    private(set) var droppedCount = 0
    private(set) var forwardedCount = 0
    private var armed = false
    init(connection: V2TLSFrameConnection, roomID: RoomID, targetHead: UInt64) {
        self.connection = connection; self.roomID = roomID; self.targetHead = targetHead
    }
    func arm() { armed = true; droppedCount = 0; forwardedCount = 0 }
    func nextAccountRoomChange() async throws -> V2AccountRoomChange {
        try await connection.nextAccountRoomChange()
    }
    func nextGroupEventAvailabilityHint() async throws -> V2GroupEventAvailabilityHint {
        while true {
            try Task.checkCancellation()
            let change = try await connection.nextGroupEventAvailabilityHint()
            if armed, change.roomID == roomID, change.highWatermark == targetHead {
                droppedCount += 1
                continue
            }
            if armed { forwardedCount += 1 }
            return change
        }
    }
}

private func controlRecoveryBroker(action: String) async throws {
    guard ["stop", "start"].contains(action),
          let url = URL(string: "https://localhost:8443/__fixture__/broker-\(action)") else {
        throw V2RealtimeTransportError.unexpectedResponse
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    let (_, response) = try await V2URLSessionAuthHTTPTransport().data(for: request)
    guard response.statusCode == 204 else { throw V2RealtimeTransportError.unexpectedResponse }
}

func sendRecoveryOnlineMessage(transport: V2ProtobufSyncTransport, connection: V2TLSFrameConnection, auth: V2AuthSession,
                               account: LocalE2EAccountCredentials,
                               roomID: RoomID, deadline: ContinuousClock.Instant) async throws {
    // Send and recovery share the authenticated TCP connection and persisted operation identity.
    let clientID = try ClientMessageID(UUID().uuidString.lowercased())
    guard ContinuousClock.now < deadline else { throw V2RealtimeTransportError.unexpectedResponse }
    _ = try await V2HTTPRequestDeadline.run(until: deadline, service: "accountAPI") {
        try await account.sendMessage(roomID: roomID, clientMessageID: clientID, text: "tls-scale-online", auth: auth, connection: connection, transport: transport)
    }
}

/// Counts successful real refresh responses without retaining or logging credentials.
private actor RecoveryScaleAuthMeter: V2AuthTransport {
    let transport: V2HTTPDeviceCredentialAuthTransport
    private(set) var successfulRefreshes = 0
    init(transport: V2HTTPDeviceCredentialAuthTransport) { self.transport = transport }
    func refresh(_ request: V2RefreshRequest) async throws -> V2AuthCredentials {
        let credentials = try await transport.refresh(request)
        successfulRefreshes += 1
        return credentials
    }
}

/// The XCTest runner has no application Keychain access group. This same-process
/// fixture supplies the atomic credential boundary; App Keychain persistence is
/// exercised by the separate application lifecycle acceptance tests.
private actor RecoveryScaleCredentialStore: V2CredentialStore {
    private var record: V2AuthCredentialRecord?
    func load() -> V2AuthCredentialRecord? { record }
    func save(_ record: V2AuthCredentialRecord) { self.record = record }
    func delete() { record = nil }
}

/// Counts logical request/response frames at the protobuf boundary. These byte
/// totals exclude handshake, unsolicited notifications, compression and TLS overhead.
private actor RecoveryScaleFrameMeter: V2AuthenticatedFrameTransport {
    let wire: any V2AuthenticatedFrameTransport
    private var requests: [UInt16: Int] = [:]
    private var sentBytes = 0
    private var receivedBytes = 0
    init(wire: any V2AuthenticatedFrameTransport) { self.wire = wire }
    func request(_ frame: V2Frame) async throws -> V2Frame {
        requests[frame.command.rawValue, default: 0] += 1
        sentBytes += V2Frame.headerLength + frame.payload.count
        let response = try await wire.request(frame)
        receivedBytes += V2Frame.headerLength + response.payload.count
        return response
    }
    func report() -> String {
        let counts = requests.keys.sorted().map { "\($0):\(requests[$0]!)" }.joined(separator: ",")
        return "commands=[\(counts)] logicalSentBytes=\(sentBytes) logicalReceivedBytes=\(receivedBytes)"
    }
}
