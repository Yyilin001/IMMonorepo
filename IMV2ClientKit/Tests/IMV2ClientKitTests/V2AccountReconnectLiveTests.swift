import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

/// Opt-in test against an explicitly supplied deployment and temporary device.
/// The private fixture stays outside the repo; no tokens or message text are logged.
@Suite("Deployed account reconnect", .timeLimit(.minutes(30)))
struct V2AccountReconnectLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_ACCOUNT_RECONNECT_FIXTURE"] != nil))
    func deployedReconnect() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["IMV2_ACCOUNT_RECONNECT_FIXTURE"])
        let fixture = try JSONDecoder().decode(ReconnectDeploymentFixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let output = URL(fileURLWithPath: fixture.outputDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let user = try UserID(fixture.userID), device = try DeviceID(fixture.deviceID)
        let databaseURL = output.appending(path: "client.sqlite")
        let existingStore = FileManager.default.fileExists(atPath: databaseURL.path)
        let store = try GRDBV2LocalSyncStore(databaseURL: databaseURL,
            installationBinding: .init(value: fixture.installationBinding ?? UUID()), userID: user)
        // A new local installation cannot reuse this device's acknowledged
        // server cursor from a previous test run. Rebuild through the public
        // snapshot protocol before incremental recovery. A resumed test fixture
        // instead supplies its original binding and retains its durable cursor.
        if !existingStore { try await store.requestSnapshotRebuild() }
        let deliveryTimings = LiveDeliveryTimings()
        let measurements = LiveRecoveryMeasurements()
        var samples: [LiveReconnectSample] = []
        for round in 0..<3 {
            let connection = V2TLSFrameConnection(endpoint: try .init(host: fixture.host, port: fixture.port),
                frameLimits: try .init(maximumPayloadBytes: 8 * 1024 * 1024, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]))
            let start = ContinuousClock.now
            let session = try await connection.connectAndAuthenticate(accessToken: fixture.accessToken,
                deviceID: device, supportedCapabilityProfiles: ["base"])
            #expect(session.userID == user)
            let authSeconds = seconds(start.duration(to: .now))
            let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: session.protocolVersion)
            let wire = LiveRecoveryWire(transport: transport)
            let personal = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base", maxRecords: 100)
            let recovery = V2RoomRecoveryEngine(transport: wire, latestVisible: wire, store: store,
                groupEvents: V2GroupEventSyncEngine(transport: wire, store: store),
                didPersistProgress: { room, cursor in
                    let started = ContinuousClock.now
                    defer { measurements.record("delivery_observer", since: started) }
                    try await deliveryTimings.record(room: room, cursor: cursor, store: store)
                    try await transport.enqueueDeviceRoomProgress(roomID: room, appliedThrough: cursor)
                }, observeStage: { stage, ms in
                    measurements.record(stage.rawValue, milliseconds: ms)
                })
            do {
                try await recovery.prepare(userID: user)
                let readySeconds = seconds(start.duration(to: .now))
                let deadline = ContinuousClock.now + .seconds(1200)
                while true {
                    try #require(ContinuousClock.now < deadline, "Recovery did not drain before the deadline")
                    if try await recoveryPass(user: user, personal: personal, recovery: recovery,
                        transport: transport, directoryPages: 1, checkComplete: true, measurements: measurements, deliveryTimings: deliveryTimings, store: store) { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let counts = await wire.counts
                if round > 0 { #expect(counts.directoryPages == 0 && counts.stateRooms == 0 && counts.contentPulls == 0) }
                let rooms = try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM v2_room_sync_states") ?? 0 }
                #expect(rooms >= fixture.minimumRooms)
                samples.append(.init(round: round, authSeconds: authSeconds, accountReadySeconds: readySeconds,
                    recoverySeconds: seconds(start.duration(to: .now)), rooms: rooms,
                    directoryPages: counts.directoryPages, stateRooms: counts.stateRooms, contentPulls: counts.contentPulls))
                try JSONEncoder().encode(samples).write(to: output.appending(path: "reconnect.json"), options: .atomic)
                print("IMV2_DEPLOYED_RECONNECT round=\(round) auth=\(authSeconds) ready=\(readySeconds) directory_pages=\(counts.directoryPages) state_rooms=\(counts.stateRooms) content_pulls=\(counts.contentPulls)")
                if round == 2 && fixture.waitForLoad {
                    measurements.reset()
                    try await deliveryTimings.begin(store: store)
                    try Data("ready".utf8).write(to: output.appending(path: "receiver-ready"), options: .atomic)
                    let loadDeadline = ContinuousClock.now + .seconds(600)
                    while !FileManager.default.fileExists(atPath: output.appending(path: "senders-finished").path) {
                        try #require(ContinuousClock.now < loadDeadline, "Sender completion marker did not arrive")
                        _ = try await recoveryPass(user: user, personal: personal, recovery: recovery,
                            transport: transport, directoryPages: 0, checkComplete: false, measurements: measurements, deliveryTimings: deliveryTimings, store: store)
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    // The sender completion marker means source ACKs, not async account delivery.
                    // A separate source-drained marker proves all account facts have committed.
                    let drainDeadline = ContinuousClock.now + .seconds(120)
                    while true {
                        try #require(ContinuousClock.now < drainDeadline, "Account recovery did not drain")
                        _ = try await recoveryPass(user: user, personal: personal, recovery: recovery,
                            transport: transport, directoryPages: 0, checkComplete: false, measurements: measurements, deliveryTimings: deliveryTimings, store: store)
                        if FileManager.default.fileExists(atPath: output.appending(path: "source-drained").path),
                           try await recoveryPass(user: user, personal: personal, recovery: recovery,
                            transport: transport, directoryPages: 0, checkComplete: true, measurements: measurements, deliveryTimings: deliveryTimings, store: store) { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                if round == 2 && fixture.waitForLoad {
                    try await deliveryTimings.write(to: output.appending(path: "delivery-timings.json"))
                    try measurements.write(to: output.appending(path: "recovery-stages.json"))
                    let finalCounts = await wire.counts
                    let result: [String: Double] = ["completedAt": Date().timeIntervalSince1970,
                        "directoryPages": Double(finalCounts.directoryPages),
                        "stateRooms": Double(finalCounts.stateRooms), "contentPulls": Double(finalCounts.contentPulls)]
                    try JSONEncoder().encode(result).write(to: output.appending(path: "load-result.json"), options: .atomic)
                }
                await recovery.stop(); await connection.disconnect()
            } catch {
                await recovery.stop(); await connection.disconnect(); try? await store.close(); throw error
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        let cursors = try await store.databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT room_id, applied_room_sequence FROM v2_group_event_cursors").map {
                LiveRoomCursor(roomID: $0["room_id"], sequence: $0["applied_room_sequence"])
            }
        }
        try JSONEncoder().encode(cursors).write(to: output.appending(path: "room-cursors.json"), options: .atomic)
        try await store.close()
    }
    // Read/recovery operations resume from committed cursors. Honor the server's
    // explicit rate limit without reconnecting or treating other failures as success.
    private func recoveryPass(user: UserID, personal: V2SyncEngine,
        recovery: V2RoomRecoveryEngine, transport: V2ProtobufSyncTransport,
        directoryPages: Int, checkComplete: Bool, measurements: LiveRecoveryMeasurements, deliveryTimings: LiveDeliveryTimings, store: GRDBV2LocalSyncStore) async throws -> Bool {
        do {
            let passStart = ContinuousClock.now
            defer { measurements.record("pass", since: passStart) }
            var stageStart = ContinuousClock.now
            _ = try await personal.synchronizeIncludingResets()
            measurements.record("personal_sync", since: stageStart)
            try await deliveryTimings.observeHeads(store: store)
            stageStart = .now
            _ = try await recovery.runBudget(userID: user, maximumDirectoryPages: directoryPages, maximumRooms: 100)
            measurements.record("recovery_budget", since: stageStart)
            stageStart = .now
            try await transport.flushDeviceRoomProgressReports()
            measurements.record("progress_flush", since: stageStart)
            return checkComplete ? try await recovery.completeIfCaughtUp(using: personal) : false
        } catch let error as V2RealtimeTransportError {
            // Match the foreground recovery runner: every explicit retryable
            // server response retains durable work and honors its cooldown.
            guard case .server(let code, true, let seconds, _) = error else { throw error }
            print("IMV2_DEPLOYED_RETRY code=\(code) retry_seconds=\(seconds)")
            try await Task.sleep(for: .seconds(max(1, seconds)))
            return false
        }
    }
    private func seconds(_ value: Duration) -> Double {
        Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
    }
}
private struct ReconnectDeploymentFixture: Decodable {
    let host: String, userID: String, deviceID: String, accessToken: String, outputDirectory: String
    let port: UInt16, minimumRooms: Int
    let waitForLoad: Bool
    let installationBinding: UUID?
}
private struct LiveReconnectSample: Codable {
    let round: Int
    let authSeconds: Double, accountReadySeconds: Double, recoverySeconds: Double
    let rooms: Int, directoryPages: Int, stateRooms: Int, contentPulls: Int
}
private struct LiveRoomCursor: Codable { let roomID: String; let sequence: Int64 }
private actor LiveRecoveryWire: V2ClientRoomRecoveryTransport, V2ClientRoomLatestVisibleTransport, V2ClientGroupEventTransport {
    struct Counts: Sendable { var directoryPages = 0; var stateRooms = 0; var contentPulls = 0 }
    private(set) var counts = Counts()
    let transport: V2ProtobufSyncTransport
    init(transport: V2ProtobufSyncTransport) { self.transport = transport }
    func startAccountRoomChanges() async throws -> UUID { try await transport.startAccountRoomChanges() }
    func userRoomDirectory(cursor: String?, pageSize: Int) async throws -> V2ClientUserRoomPage {
        counts.directoryPages += 1
        return try await transport.userRoomDirectory(cursor: cursor, pageSize: pageSize)
    }
    func roomSyncStates(roomIDs: [RoomID]) async throws -> [RoomID: V2ClientRoomStateResult] {
        counts.stateRooms += roomIDs.count
        return try await transport.roomSyncStates(roomIDs: roomIDs)
    }
    func latestVisible(roomIDs: [RoomID]) async throws -> [RoomID: V2ClientRoomLatestVisibleResult] {
        try await transport.latestVisible(roomIDs: roomIDs)
    }
    func pullGroupEventPages(_ requests: [V2ClientGroupEventPull]) async throws -> [RoomID: V2ClientGroupEventPageResult] {
        counts.contentPulls += 1
        return try await transport.pullGroupEventPages(requests)
    }
    func pullGroupEvents(roomID: RoomID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2ClientGroupEventPage {
        counts.contentPulls += 1
        return try await transport.pullGroupEvents(roomID: roomID, afterRoomSequence: afterRoomSequence, pageSize: pageSize)
    }
}

/// Test-only observation after SQLite commits. No message content or identifiers
/// are exported. Server clock offset is checked separately by the run script.
private actor LiveDeliveryTimings {
    private var cursors: [RoomID: Int64] = [:]
    private var startedAt: Double?
    private var delays: [Double] = []
    private var lastDeliveryAt: Double = 0
    private var observedThrough: [RoomID: Int64] = [:]
    private var observations: [RoomID: [(Int64, Double)]] = [:]
    private var accountDelays: [Double] = [], recoveryDelays: [Double] = []
    private var windows: [Int: [Double]] = [:]
    func observeHeads(store: GRDBV2LocalSyncStore) async throws {
        guard startedAt != nil else { return }
        let at = Date().timeIntervalSince1970
        let heads = try await store.databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT room_id, room_sequence FROM v2_account_room_heads").map {
                (try RoomID($0["room_id"] as String), $0["room_sequence"] as Int64)
            }
        }
        for (room, head) in heads where head > observedThrough[room, default: 0] {
            observations[room, default: []].append((head, at)); observedThrough[room] = head
        }
    }
    func begin(store: GRDBV2LocalSyncStore) async throws {
        cursors = try await store.databasePool.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT room_id, applied_room_sequence FROM v2_group_event_cursors").map {
                (try RoomID($0["room_id"] as String), $0["applied_room_sequence"] as Int64)
            })
        }
        observedThrough = cursors
        startedAt = Date().timeIntervalSince1970; delays = []
    }
    func record(room: RoomID, cursor: UInt64, store: GRDBV2LocalSyncStore) async throws {
        guard let startedAt else { return }
        let after = cursors[room, default: 0], through = Int64(cursor)
        guard through > after else { return }
        let committedAt = Date().timeIntervalSince1970
        let timestamps = try await store.databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT room_sequence, server_created_at FROM v2_message_projections WHERE room_id = ? AND room_sequence > ? AND room_sequence <= ? AND server_created_at >= ?",
                arguments: [room.rawValue, after, through, startedAt]).map { ($0["room_sequence"] as Int64, $0["server_created_at"] as Double) }
        }
        for (sequence, created) in timestamps {
            let delay = (committedAt - created) * 1000
            delays.append(delay); windows[Int((created-startedAt)/30), default: []].append(delay)
            if let seen = observations[room]?.first(where: { $0.0 >= sequence })?.1 {
                accountDelays.append((seen-created)*1000); recoveryDelays.append((committedAt-seen)*1000)
            }
        }
        cursors[room] = through
        if !timestamps.isEmpty { lastDeliveryAt = committedAt }
    }
    func write(to url: URL) throws {
        let sorted = delays.sorted()
        func percentile(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        let result: [String: Double] = ["messages": Double(delays.count), "p50_ms": percentile(0.5),
            "p95_ms": percentile(0.95), "p99_ms": percentile(0.99), "maximum_ms": sorted.last ?? 0,
            "minimum_ms": sorted.first ?? 0, "lastDeliveryAt": lastDeliveryAt]
        try JSONEncoder().encode(result).write(to: url, options: .atomic)
        let stages = ["account_observed": LiveRecoveryMeasurements.summary(accountDelays),
                      "observed_to_commit": LiveRecoveryMeasurements.summary(recoveryDelays)]
        try JSONEncoder().encode(stages).write(to: url.deletingLastPathComponent().appending(path: "delivery-stage-delays.json"), options: .atomic)
        try JSONEncoder().encode(windows.mapValues { LiveRecoveryMeasurements.summary($0) }).write(to: url.deletingLastPathComponent().appending(path: "delivery-windows.json"), options: .atomic)
    }
}
