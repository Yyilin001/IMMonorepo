import Foundation
import IMV2ClientKit
import IMV2Core
import XCTest

extension IMAppRoomRecoveryScaleTests {
    func verifySlowTLS(connection: V2TLSFrameConnection, coordinator: V2RealtimeSessionCoordinator,
                       auth: V2AuthSession, account: LocalE2EAccountCredentials,
                       store: GRDBV2LocalSyncStore, roomID: RoomID) async throws {
        guard let port = ProcessInfo.processInfo.environment["IMV2_ROOM_RECOVERY_SECONDARY_PORT"].flatMap(UInt16.init) else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        let secondary = V2TLSFrameConnection(endpoint: try .init(host: "localhost", port: port),
            frameLimits: try .init(maximumPayloadBytes: 65536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]))
        let senderCoordinator = V2RealtimeSessionCoordinator(authSession: auth, connection: secondary,
            supportedCapabilityProfiles: ["base"])
        var paused = false
        do {
            let session = try await coordinator.connect()
            let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: session.protocolVersion)
            _ = try await transport.startAccountRoomChanges()
            // Coverage is installed by authorized directory reads, not by Ready.
            var cursor: String?
            var covered = false
            var coveredRooms: [RoomID] = []
            repeat {
                let page = try await transport.userRoomDirectory(cursor: cursor, pageSize: 100)
                covered = covered || page.rooms.contains { $0.roomID == roomID }
                coveredRooms.append(contentsOf: page.rooms.map(\.roomID))
                cursor = page.nextCursor
            } while cursor != nil && !covered
            guard covered else { throw V2RealtimeTransportError.unexpectedResponse }
            let pressureRooms = Array(coveredRooms.prefix(129))
            guard !pressureRooms.isEmpty, Set(pressureRooms).count == pressureRooms.count else {
                throw V2RealtimeTransportError.unexpectedResponse
            }
            try await sendRecoveryOnlineMessage(transport: transport, connection: connection, auth: auth, account: account, roomID: roomID,
                deadline: ContinuousClock.now.advanced(by: .seconds(30)))
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while true {
                        let notification = try await connection.nextAccountRoomChange()
                        if case .changed(_, let room, let head) = notification, room == roomID, head == 3 { return }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw V2RealtimeTransportError.unexpectedResponse
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
            print("IMV2_TLS_ROOM_SLOW_TLS_COVERAGE_PROVEN")
            _ = try await transport.subscribeToGroupEvents(roomID: roomID, afterRoomSequence: 3)
            let senderSession = try await senderCoordinator.connect()
            let senderTransport = V2ProtobufSyncTransport(wire: secondary, protocolVersion: senderSession.protocolVersion)
            let baseline = try await controlSlowTLS(.pause)
            paused = true
            guard baseline.paused else { throw V2RealtimeTransportError.unexpectedResponse }
            let deadline = ContinuousClock.now.advanced(by: .seconds(600))
            var textsByRoom: [RoomID: Set<String>] = [:]
            var committed = 0
            var observed = baseline
            // Group delivery can carry only a small head notification, regardless
            // of body size. Bound command count separately from stored payload.
            // Rotate covered rooms so one hot room's coalesced head does not
            // stand in for the account's aggregate notification pressure.
            // Stable IDs are retained across server-requested retries.
            while observed.closures == baseline.closures {
                guard committed < 8192, ContinuousClock.now < deadline else {
                    print("IMV2_TLS_ROOM_SLOW_TLS_PRESSURE_EXHAUSTED committed=\(committed)")
                    throw V2RealtimeTransportError.unexpectedResponse
                }
                let text = (0..<4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined()
                let id = try ClientMessageID(UUID().uuidString.lowercased())
                let targetRoom = pressureRooms[committed % pressureRooms.count]
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw V2RealtimeTransportError.unexpectedResponse }
                _ = try await V2HTTPRequestDeadline.run(until: deadline, service: "accountAPI") {
                    try await account.sendMessage(roomID: targetRoom, clientMessageID: id, text: text,
                        auth: auth, connection: secondary, transport: senderTransport)
                }
                textsByRoom[targetRoom, default: []].insert(text)
                committed += 1
                if committed.isMultiple(of: 8) { observed = try await controlSlowTLS(.status) }
                guard observed.idle_timeout == baseline.idle_timeout else {
                    print("IMV2_TLS_ROOM_SLOW_TLS_IDLE_CLOSED committed=\(committed)")
                    throw V2RealtimeTransportError.unexpectedResponse
                }
            }
            guard observed.closures == baseline.closures + 1 else {
                throw V2RealtimeTransportError.unexpectedResponse
            }
            print("IMV2_TLS_ROOM_SLOW_TLS_CLOSED committed=\(committed)")
            let resumed = try await controlSlowTLS(.resume)
            paused = false
            guard !resumed.paused else { throw V2RealtimeTransportError.unexpectedResponse }
            await senderCoordinator.disconnect()
            await coordinator.disconnect()

            let recoveredSession = try await coordinator.connect()
            let recoveredTransport = V2ProtobufSyncTransport(wire: connection, protocolVersion: recoveredSession.protocolVersion)
            let personal = V2SyncEngine(transport: recoveredTransport, store: store, capabilityProfile: recoveredSession.capabilityProfile)
            try await synchronizeInitialState(personal)
            let engine = V2RoomRecoveryEngine(transport: recoveredTransport, latestVisible: recoveredTransport,
                store: store, groupEvents: V2GroupEventSyncEngine(transport: recoveredTransport, store: store))
            let runner = V2RoomRecoveryRunner(engine: engine, source: connection, personalSync: personal,
                integrityInterval: { 3600 })
            let expectedTexts = textsByRoom
            let expectedTotal = committed
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await runner.run(userID: account.userID) }
                group.addTask {
                    let recoveryDeadline = ContinuousClock.now.advanced(by: .seconds(120))
                    while true {
                        if await engine.phase == .live {
                            var complete = true
                            for (targetRoom, texts) in expectedTexts {
                                let messages = try await store.messages(in: targetRoom)
                                let expectedCount = texts.count + (targetRoom == roomID ? 3 : 1)
                                if messages.count != expectedCount || !texts.isSubset(of: Set(messages.map(\.text))) {
                                    complete = false; break
                                }
                                if try await store.groupEventCursor(roomID: targetRoom) != UInt64(expectedCount) {
                                    complete = false; break
                                }
                            }
                            if complete { break }
                        }
                        guard ContinuousClock.now < recoveryDeadline else { throw V2RealtimeTransportError.unexpectedResponse }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    print("IMV2_TLS_ROOM_SLOW_TLS_RECOVERY_PASSED committed=\(expectedTotal) rooms=\(expectedTexts.count)")
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch {
            // Resume before closing so cleanup cannot strand the primary reader.
            if paused { _ = try? await controlSlowTLS(.resume) }
            await senderCoordinator.disconnect()
            await coordinator.disconnect()
            throw error
        }
    }
}

private enum SlowTLSAction: String { case pause, resume, status, disconnect }
private struct SlowTLSState: Decodable {
    let paused: Bool
    let required_notification_backpressure: Int
    let required_notification_write_timeout: Int
    let idle_timeout: Int
    var closures: Int { required_notification_backpressure + required_notification_write_timeout }
}

private func controlSlowTLS(_ action: SlowTLSAction) async throws -> SlowTLSState {
    let url = URL(string: "https://localhost:8443/__fixture__/tls-\(action.rawValue)")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    let (data, response) = try await V2URLSessionAuthHTTPTransport().data(for: request)
    guard response.statusCode == 200 else { throw V2RealtimeTransportError.unexpectedResponse }
    return try JSONDecoder().decode(SlowTLSState.self, from: data)
}


extension IMAppRoomRecoveryScaleTests {
    /// Exercises the App-owned foreground loop, with no test-owned receiver runtime.
    @MainActor
    static func verifyAppAutomaticReconnect(auth: V2AuthSession, account: LocalE2EAccountCredentials,
                                     roomID: RoomID) async throws {
        let port = try XCTUnwrap(ProcessInfo.processInfo.environment["IMV2_ROOM_RECOVERY_SECONDARY_PORT"].flatMap(UInt16.init))
        let connection = V2TLSFrameConnection(endpoint: try .init(host: "localhost", port: port),
            frameLimits: try .init(maximumPayloadBytes: 65536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]))
        let coordinator = V2RealtimeSessionCoordinator(authSession: auth, connection: connection,
            supportedCapabilityProfiles: ["base"])
        let app = XCUIApplication()
        let scope = ["-v2-ui-testing-live-local-account", "-v2-ui-testing-e2e-scope", UUID().uuidString.lowercased()]
        defer {
            app.terminate()
            app.launchArguments = scope + ["-v2-ui-testing-cleanup-local-account"]
            app.launch()
            XCTAssertTrue(app.staticTexts["v2.local-e2e.cleanup.completed"].waitForExistence(timeout: 15))
            app.terminate()
        }
        do {
            _ = try await coordinator.connect()
            let initialText = "app-reconnect-initial-" + UUID().uuidString.lowercased()
            _ = try await account.sendMessage(roomID: roomID, clientMessageID: ClientMessageID(UUID().uuidString.lowercased()),
                text: initialText, media: [], mentions: [], auth: auth)
            app.launchArguments = scope + ["-v2-ui-testing-account-handle", account.accountHandle,
                "-v2-ui-testing-local-password", "local-clientkit-password"]
            app.launch()
            let login = app.buttons["v2.password.submit"]
            guard login.waitForExistence(timeout: 15) else { throw V2RealtimeTransportError.unexpectedResponse }
            login.tap()
            let room = app.descendants(matching: .any).matching(identifier: "v2.conversation.group.\(roomID.rawValue)").firstMatch
            let openingDeadline = ContinuousClock.now.advanced(by: .seconds(60))
            while !room.exists || !room.isHittable {
                guard ContinuousClock.now < openingDeadline else { throw V2RealtimeTransportError.unexpectedResponse }
                // Initial recovery preserves the visible list anchor as newer
                // rows arrive. Navigate to its newest window before injecting
                // any fault; the reconnect phase below performs no UI recovery.
                let latest = app.buttons["v2.conversation.return-to-latest"]
                if latest.exists {
                    if !latest.isHittable { app.collectionViews["v2.conversation.list"].swipeDown() }
                    if latest.isHittable { latest.tap() }
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            room.tap()
            guard app.staticTexts[initialText].waitForExistence(timeout: 30) else {
                throw V2RealtimeTransportError.unexpectedResponse
            }
            for cycle in 1...3 {
                XCTAssertEqual(app.state, .runningForeground)
                _ = try await controlSlowTLS(.disconnect)
                let text = "app-reconnect-\(cycle)-" + UUID().uuidString.lowercased()
                _ = try await account.sendMessage(roomID: roomID, clientMessageID: ClientMessageID(UUID().uuidString.lowercased()),
                    text: text, media: [], mentions: [], auth: auth)
                let recoveredBody = app.staticTexts[text]
                let bodyDeadline = ContinuousClock.now.advanced(by: .seconds(90))
                while !recoveredBody.exists {
                    guard ContinuousClock.now < bodyDeadline else {
                        XCTFail("App foreground loop did not recover message after disconnect \(cycle)")
                        throw V2RealtimeTransportError.unexpectedResponse
                    }
                    // ScrollView/LazyVStack materializes only nearby rows. A
                    // plain gesture here has no load, refresh or network hook;
                    // never tap the separate return-latest/load-older actions.
                    app.scrollViews["v2.message.list"].swipeUp()
                    _ = recoveredBody.waitForExistence(timeout: 2)
                }
                XCTAssertEqual(app.state, .runningForeground)
            }
            await coordinator.disconnect()
            print("IMV2_APP_AUTOMATIC_RECONNECT_PASSED cycles=3")
        } catch {
            XCTContext.runActivity(named: "Automatic reconnect App failure state") { activity in
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.lifetime = .keepAlways
                activity.add(screenshot)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.lifetime = .keepAlways
                activity.add(hierarchy)
            }
            await coordinator.disconnect()
            throw error
        }
    }
}
