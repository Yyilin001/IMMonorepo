import Foundation
import IMV2ClientKit
import IMV2Core
import XCTest

/// A real local-stack integration test. It has its own target and scheme so
/// the ordinary UI suite remains fully offline and deterministic.
final class IMAppLocalAccountUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Covers the App relaunch and UI-visible private hint as well as the live gateway contract.
    func testReceiverCanBlockAndRestoreExistingDirectMessageDelivery() async throws {
        let sender = try await registerLocalAccount(displayName: "Blocked sender")
        let receiver = try await registerLocalAccount(displayName: "Blocking receiver")
        let frameLimits = try V2FrameLimits(
            maximumPayloadBytes: 65_536,
            acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]
        )
        let endpoint = try V2RealtimeEndpoint(host: "localhost", port: 7_443)
        let senderConnection = V2TLSFrameConnection(endpoint: endpoint, frameLimits: frameLimits)
        let secondaryPort = ProcessInfo.processInfo.environment["IMV2_ROOM_RECOVERY_SECONDARY_PORT"].flatMap(UInt16.init)
        let receiverEndpoint = try V2RealtimeEndpoint(host: "localhost", port: secondaryPort ?? 7_443)
        let receiverConnection = V2TLSFrameConnection(endpoint: receiverEndpoint, frameLimits: frameLimits)

        let restoredSenderConnection = V2TLSFrameConnection(endpoint: endpoint, frameLimits: frameLimits)
        let restoredReceiverConnection = V2TLSFrameConnection(endpoint: endpoint, frameLimits: frameLimits)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("im-v2-private-hint-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let senderSession = try await senderConnection.connectAndAuthenticate(
                accessToken: sender.accessToken,
                deviceID: sender.deviceID,
                supportedCapabilityProfiles: ["base"]
            )
            let receiverSession = try await receiverConnection.connectAndAuthenticate(
                accessToken: receiver.accessToken,
                deviceID: receiver.deviceID,
                supportedCapabilityProfiles: ["base"]
            )
            XCTAssertEqual(senderSession.userID, sender.userID)
            XCTAssertEqual(receiverSession.userID, receiver.userID)

            let senderTransport = V2ProtobufSyncTransport(
                wire: senderConnection,
                protocolVersion: senderSession.protocolVersion
            )
            let receiverTransport = V2ProtobufSyncTransport(
                wire: receiverConnection,
                protocolVersion: receiverSession.protocolVersion
            )
            let directRoom = try await sender.openDirectRoom(target: receiver.userID)
            try await receiver.setBlock(target: sender.userID, blocked: true)
            await assertDirectMessageIsRestricted(
                sender: sender,
                roomID: directRoom.roomID,
                text: "must-not-deliver-while-blocked", connection: senderConnection, transport: senderTransport
            )

            let senderBinding = LocalE2EInstallationBindingStore()
            let senderURL = directory.appendingPathComponent("sender.sqlite")
            let senderStore = try await V2LocalStoreBootstrapper(bindingStore: senderBinding).open(databaseURL: senderURL, userID: sender.userID)
            let receiverStore = try await V2LocalStoreBootstrapper(bindingStore: LocalE2EInstallationBindingStore())
                .open(databaseURL: directory.appendingPathComponent("receiver.sqlite"), userID: receiver.userID)
            let senderSync = V2SyncEngine(transport: senderTransport, store: senderStore,
                capabilityProfile: senderSession.capabilityProfile)
            let receiverSync = V2SyncEngine(transport: receiverTransport, store: receiverStore,
                capabilityProfile: receiverSession.capabilityProfile)
            var hints: [V2ClientTimelineActivityProjection] = []
            for _ in 0..<100 {
                try await synchronizeInitialState(senderSync)
                hints = try await senderStore.timelineActivities(in: directRoom.roomID)
                if !hints.isEmpty { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(hints.count, 1, "受限发送必须产生一条可持久恢复的单侧提示。")
            let hint = try XCTUnwrap(hints.first)
            XCTAssertEqual(hint.kind, .directMessageRestricted)
            try await synchronizeInitialState(receiverSync)
            let receiverHints = try await receiverStore.timelineActivities(in: directRoom.roomID)
            XCTAssertTrue(receiverHints.isEmpty, "对方不能收到发送者的单侧提示。")

            await senderConnection.disconnect()
            let restoredSession = try await restoredSenderConnection.connectAndAuthenticate(
                accessToken: sender.accessToken, deviceID: sender.deviceID, supportedCapabilityProfiles: ["base"])
            let restoredStore = try await V2LocalStoreBootstrapper(bindingStore: senderBinding).open(databaseURL: senderURL, userID: sender.userID)
            let persistedHints = try await restoredStore.timelineActivities(in: directRoom.roomID)
            XCTAssertEqual(persistedHints, hints, "重新打开 SQLite 后必须保留原提示身份和顺序。")
            let restoredTransport = V2ProtobufSyncTransport(wire: restoredSenderConnection,
                protocolVersion: restoredSession.protocolVersion)
            let restoredSync = V2SyncEngine(transport: restoredTransport, store: restoredStore,
                capabilityProfile: restoredSession.capabilityProfile)
            try await synchronizeInitialState(restoredSync)
            let replayedHints = try await restoredStore.timelineActivities(in: directRoom.roomID)
            XCTAssertEqual(replayedHints, hints, "重连补拉不得重复插入提示。")
            try await assertPrivateHintSurvivesAppRelaunch(sender: sender, roomID: directRoom.roomID.rawValue, hintID: hint.id) {
                let before = Set(try await restoredStore.timelineActivities(in: directRoom.roomID).map(\.id))
                await assertDirectMessageIsRestricted(sender: sender, roomID: directRoom.roomID,
                    text: "background-recovery-\(UUID())", connection: restoredSenderConnection, transport: restoredTransport)
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while ContinuousClock.now < deadline {
                    try await synchronizeInitialState(restoredSync)
                    if let new = try await restoredStore.timelineActivities(in: directRoom.roomID).first(where: { !before.contains($0.id) }) {
                        return new.id
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw V2RealtimeTransportError.unexpectedResponse
            }


            try await receiver.setBlock(target: sender.userID, blocked: false)
            // Keep the authenticated old connection and its directory interests
            // alive while the same device restores on the other Gateway.
            _ = try await receiverTransport.startAccountRoomChanges()
            _ = try await receiverTransport.userRoomDirectory(cursor: nil, pageSize: 100)
            let reconnected = try await restoredReceiverConnection.connectAndAuthenticate(
                accessToken: receiver.accessToken, deviceID: receiver.deviceID, supportedCapabilityProfiles: ["base"])
            XCTAssertEqual(reconnected.userID, receiverSession.userID)
            let accepted = try await sender.sendMessage(
                roomID: directRoom.roomID,
                clientMessageID: try ClientMessageID(UUID().uuidString.lowercased()),
                text: "allowed-after-explicit-unblock",
                media: [],
                mentions: [], connection: restoredSenderConnection, transport: restoredTransport
            )
            try await waitForRoomChange(receiverConnection, roomID: directRoom.roomID,
                sequence: accepted.roomSequence)
            let recoveryTransport = V2ProtobufSyncTransport(wire: restoredReceiverConnection,
                protocolVersion: reconnected.protocolVersion)
            let recoveryPersonal = V2SyncEngine(transport: recoveryTransport, store: receiverStore,
                capabilityProfile: reconnected.capabilityProfile)
            try await synchronizeInitialState(recoveryPersonal)
            let recoveryGroupEvents = V2GroupEventSyncEngine(transport: recoveryTransport, store: receiverStore)
            let recoveryEngine = V2RoomRecoveryEngine(transport: recoveryTransport, latestVisible: recoveryTransport,
                store: receiverStore, groupEvents: recoveryGroupEvents)
            let recoveryRunner = V2RoomRecoveryRunner(engine: recoveryEngine, source: restoredReceiverConnection,
                personalSync: recoveryPersonal)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await recoveryRunner.run(userID: receiver.userID) }
                group.addTask {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
                    while await recoveryEngine.phase != .live {
                        try Task.checkCancellation()
                        guard ContinuousClock.now < deadline else {
                            throw V2RealtimeTransportError.unexpectedResponse
                        }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let progress = try await recoveryEngine.progress()
                    guard progress.directoryComplete, progress.pendingRoomCount == 0 else {
                        throw V2RealtimeTransportError.unexpectedResponse
                    }
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
            // The runner owns cancellation and drains its consumer before returning.
            let stoppedPhase = await recoveryEngine.phase
            XCTAssertEqual(stoppedPhase, .idle)
            print("IMV2_FOREGROUND_RECOVERY_COMPLETION_PASSED")
            let recovered = try await receiverStore.messages(in: directRoom.roomID)
            XCTAssertEqual(recovered.map(\.messageID), [accepted.messageID])
            XCTAssertEqual(recovered.first?.text, "allowed-after-explicit-unblock")
            let cursor = try await receiverStore.groupEventCursor(roomID: directRoom.roomID)
            XCTAssertGreaterThanOrEqual(cursor, accepted.roomSequence)
            // The new connection has persisted recovery before the old one is
            // retired; its cleanup must leave the new connection's scopes intact.
            await receiverConnection.disconnect()
            let list = try await receiverStore.conversationListPage(isArchived: false, before: nil, limit: 20)
            let entry = try XCTUnwrap(list.entries.first { $0.roomID == directRoom.roomID })
            XCTAssertEqual(entry.lastMessage?.messageID, accepted.messageID)
            let summaries = try await recoveryTransport.latestVisible(roomIDs: [directRoom.roomID])
            guard case .snapshot(let summary)? = summaries[directRoom.roomID] else {
                XCTFail("Authorized recovery must return a latest-visible snapshot")
                throw V2RealtimeTransportError.unexpectedResponse
            }
            XCTAssertEqual(summary.latest?.id, accepted.messageID)
            let privateActivities = try await receiverStore.timelineActivities(in: directRoom.roomID)
            XCTAssertTrue(privateActivities.isEmpty)
            if secondaryPort != nil {
                let online = try await sender.sendMessage(roomID: directRoom.roomID,
                    clientMessageID: .init(UUID().uuidString.lowercased()), text: "cross-gateway-online",
                    media: [], mentions: [], connection: restoredSenderConnection, transport: restoredTransport)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        while true {
                            let change = try await restoredReceiverConnection.nextAccountRoomChange()
                            if case .changed(_, let room, let head) = change,
                               room == directRoom.roomID, head >= online.roomSequence { return }
                            if case .resyncRequired = change { throw V2RealtimeTransportError.unexpectedResponse }
                        }
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(10))
                        throw V2RealtimeTransportError.unexpectedResponse
                    }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
                try await recoveryGroupEvents.synchronizeUntilCaughtUp(roomID: directRoom.roomID)
                let restoredMessages = try await receiverStore.messages(in: directRoom.roomID)
                XCTAssertTrue(restoredMessages.contains { $0.messageID == online.messageID })
                let restoredCursor = try await receiverStore.groupEventCursor(roomID: directRoom.roomID)
                XCTAssertGreaterThanOrEqual(restoredCursor, online.roomSequence)
                print("IMV2_CROSS_GATEWAY_SAME_DEVICE_OVERLAP_AND_OLD_EXIT_PASSED")
                print("IMV2_CROSS_GATEWAY_RECOVERY_AND_ONLINE_WAKE_PASSED")
                try await verifyCrossGatewaySiblingDevice(account: receiver, sender: sender,
                    senderConnection: restoredSenderConnection, senderTransport: restoredTransport, existing: restoredReceiverConnection, existingTransport: recoveryTransport, endpoint: receiverEndpoint, frameLimits: frameLimits,
                    roomID: directRoom.roomID)
            }
        } catch {
            await senderConnection.disconnect()
            await receiverConnection.disconnect()
            await restoredSenderConnection.disconnect()
            await restoredReceiverConnection.disconnect()
            throw error
        }

        await senderConnection.disconnect()
        await receiverConnection.disconnect()
        await restoredSenderConnection.disconnect()
        await restoredReceiverConnection.disconnect()
    }

    @MainActor
    func testPasswordRegistrationEstablishesLocalSession() throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let accountHandle = "ios_\(suffix.prefix(20))"
        let publicHandle = "ios\(suffix.prefix(20))"
        let password = "localpassword"
        let e2eScope = UUID().uuidString.lowercased()

        let app = XCUIApplication()
        defer {
            // This only terminates the app-under-test so the next DEBUG-only
            // launch can release its scoped SQLite handle. It never changes
            // the simulator lifecycle or its ordinary account data.
            app.terminate()
            app.launchArguments = [
                "-v2-ui-testing-live-local-account",
                "-v2-ui-testing-cleanup-local-account",
                "-v2-ui-testing-e2e-scope",
                e2eScope,
            ]
            app.launch()
            XCTAssertTrue(
                app.staticTexts["v2.local-e2e.cleanup.completed"].waitForExistence(timeout: 10),
                "本地 E2E 回归结束后必须删除其随机 scope 的 Keychain 和 SQLite 测试工件。"
            )
        }
        app.launchArguments = [
            "-v2-ui-testing-live-local-account",
            "-v2-ui-testing-e2e-scope",
            e2eScope,
            "-v2-ui-testing-password-register",
            "-v2-ui-testing-local-password",
            password,
            "-v2-ui-testing-account-handle",
            accountHandle,
            "-v2-ui-testing-public-handle",
            publicHandle,
            "-v2-ui-testing-display-name",
            "Local iOS E2E",
        ]
        app.launch()

        let accountField = app.textFields["v2.password.account-handle"]
        let passwordField = app.secureTextFields["v2.password.value"]
        let publicHandleField = app.textFields["v2.identity.public-handle"]
        let displayNameField = app.textFields["v2.identity.display-name"]
        let submit = app.buttons["v2.password.submit"]

        XCTAssertTrue(accountField.waitForExistence(timeout: 10))
        XCTAssertTrue(passwordField.exists)
        XCTAssertTrue(publicHandleField.exists)
        XCTAssertTrue(displayNameField.exists)

        // The iOS 26.2 Simulator/XCTest runtime injects only one character per
        // field in this SwiftUI form. The DEBUG-only live-local mode preloads
        // these disposable values instead; this E2E still exercises the real
        // submit action, account HTTPS, device credentials and local session.
        XCTAssertTrue(submit.isEnabled)

        submit.tap()

        let directConversationButton = app.buttons["v2.conversation.new-direct"]
        let reachedAuthenticatedSession = directConversationButton.waitForExistence(timeout: 30)
        let authenticationMessage = app.staticTexts["v2.authentication.message"]
        let safeFailureMessage = authenticationMessage.exists
            ? authenticationMessage.label
            : "未显示认证错误文案"
        XCTAssertTrue(
            reachedAuthenticatedSession,
            "本地注册、设备凭证签发和 V2 本地会话打开后应显示已登录会话列表；当前安全错误：\(safeFailureMessage)"
        )
        XCTAssertFalse(authenticationMessage.exists)
    }
}


struct LocalE2EAccountCredentials: Sendable {
    let accountHandle: String
    let credentials: V2AuthCredentials
    var accessToken: String { credentials.accessToken }
    var deviceID: DeviceID { credentials.deviceID }
    var userID: UserID { credentials.userID }
}

actor LocalE2EInstallationBindingStore: V2InstallationBindingStore {
    private var binding: V2LocalInstallationBinding?

    func load() -> V2LocalInstallationBinding? { binding }

    func save(_ binding: V2LocalInstallationBinding) {
        self.binding = binding
    }

    func delete() {
        binding = nil
    }
}

private enum LocalE2EContractError: Error {
    case missingValue
    case unexpectedHTTPStatus(Int)
    case mismatchedCancellation
}

private func requireLocalE2E<T>(_ value: T?) throws -> T {
    guard let value else { throw LocalE2EContractError.missingValue }
    return value
}

func registerLocalAccount(displayName: String) async throws -> LocalE2EAccountCredentials {
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let deviceID = try DeviceID(UUID().uuidString.lowercased())
    let registration = try await localJSONRequest(
        endpoint: try requireLocalE2E(URL(string: "https://localhost:8443/v2/account-auth/password/register")),
        body: [
            "accountHandle": "dual_\(suffix.prefix(20))",
            "password": "local-clientkit-password",
            "deviceID": deviceID.rawValue,
            "publicHandle": "dual\(suffix.prefix(20))",
            "displayName": displayName,
        ]
    )
    let assertion = try requireLocalE2E(registration["accountAssertion"] as? String)
    let pending = try V2PendingDeviceCredentialRegistration.prepare(deviceID: deviceID, operationID: UUID())
    let issued = try await localJSONRequest(
        endpoint: try requireLocalE2E(URL(string: "https://localhost:8443/v2/device-credentials")),
        body: [
            "accountAssertion": assertion,
            "deviceID": deviceID.rawValue,
            "operationID": pending.operationID.uuidString,
        ], cancellation: pending.cancellation
    )
    return try .init(
        accountHandle: "dual_\(suffix.prefix(20))",
        credentials: .init(
            userID: .init(requireLocalE2E(issued["userID"] as? String)), deviceID: deviceID,
            accessToken: requireLocalE2E(issued["accessToken"] as? String),
            accessTokenExpiresAt: Date(timeIntervalSince1970: requireLocalE2E(issued["accessTokenExpiresAtMilliseconds"] as? Double) / 1000),
            refreshCredential: requireLocalE2E(issued["refreshCredential"] as? String),
            revocationCredential: .init(rawValue: requireLocalE2E(issued["revocationCredential"] as? String)),
            revocationCredentialExpiresAt: Date(timeIntervalSince1970: requireLocalE2E(issued["revocationCredentialExpiresAtMilliseconds"] as? Double) / 1000)
        )
    )
}

func synchronizeInitialState(_ syncEngine: V2SyncEngine) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while true {
        do {
            if case .resetPending = try await syncEngine.synchronizeUntilCaughtUp() {
                try await syncEngine.completePendingReset()
            }
            return
        } catch V2RealtimeTransportError.server(code: _, retryable: true, retryAfterSeconds: let seconds, currentRevision: _) {
            guard ContinuousClock.now < deadline else { throw V2RealtimeTransportError.unexpectedResponse }
            try await Task.sleep(for: .seconds(max(1, seconds)))
        }
    }
}

/// A second real device of the same account subscribes on the other Gateway.
/// Closing that device must preserve the existing device's delivery coverage.
private func verifyCrossGatewaySiblingDevice(account: LocalE2EAccountCredentials,
    sender: LocalE2EAccountCredentials, senderConnection: V2TLSFrameConnection, senderTransport: V2ProtobufSyncTransport,
    existing: V2TLSFrameConnection, existingTransport: V2ProtobufSyncTransport,
    endpoint: V2RealtimeEndpoint, frameLimits: V2FrameLimits, roomID: RoomID) async throws {
    let deviceID = try DeviceID(UUID().uuidString.lowercased())
    let assertion = try await localJSONRequest(
        endpoint: try requireLocalE2E(URL(string: "https://localhost:8443/v2/account-auth/password/assertion")),
        body: ["accountHandle": account.accountHandle, "password": "local-clientkit-password",
            "deviceID": deviceID.rawValue])
    let pending = try V2PendingDeviceCredentialRegistration.prepare(deviceID: deviceID, operationID: UUID())
    let issued = try await localJSONRequest(
        endpoint: try requireLocalE2E(URL(string: "https://localhost:8443/v2/device-credentials")),
        body: ["accountAssertion": requireLocalE2E(assertion["accountAssertion"] as? String),
            "deviceID": deviceID.rawValue, "operationID": pending.operationID.uuidString],
        cancellation: pending.cancellation)
    let sibling = V2TLSFrameConnection(endpoint: endpoint, frameLimits: frameLimits)
    do {
        let session = try await sibling.connectAndAuthenticate(
            accessToken: requireLocalE2E(issued["accessToken"] as? String), deviceID: deviceID,
            supportedCapabilityProfiles: ["base"])
        XCTAssertEqual(session.userID, account.userID)
        XCTAssertNotEqual(deviceID, account.deviceID)
        let transport = V2ProtobufSyncTransport(wire: sibling, protocolVersion: session.protocolVersion)
        _ = try await transport.startAccountRoomChanges()
        _ = try await transport.userRoomDirectory(cursor: nil, pageSize: 100)
        // A real reply establishes mutual messaging before this delivery test;
        // the stranger-message allowance is a separate authorization boundary.
        _ = try await account.sendMessage(roomID: roomID,
            clientMessageID: .init(UUID().uuidString.lowercased()), text: "multi-device-peer-reply",
            media: [], mentions: [], connection: existing, transport: existingTransport)
        let first = try await sender.sendMessage(roomID: roomID,
            clientMessageID: .init(UUID().uuidString.lowercased()), text: "two-devices-two-gateways",
            media: [], mentions: [], connection: senderConnection, transport: senderTransport)
        async let originalReceived: Void = waitForRoomChange(existing, roomID: roomID, sequence: first.roomSequence)
        async let siblingReceived: Void = waitForRoomChange(sibling, roomID: roomID, sequence: first.roomSequence)
        _ = try await (originalReceived, siblingReceived)
        await sibling.disconnect()
        let second = try await sender.sendMessage(roomID: roomID,
            clientMessageID: .init(UUID().uuidString.lowercased()), text: "delivery-after-sibling-exit",
            media: [], mentions: [], connection: senderConnection, transport: senderTransport)
        try await waitForRoomChange(existing, roomID: roomID, sequence: second.roomSequence)
        print("IMV2_CROSS_GATEWAY_TWO_DEVICES_AND_SINGLE_EXIT_PASSED")
    } catch {
        await sibling.disconnect()
        throw error
    }
}

private func waitForRoomChange(_ connection: V2TLSFrameConnection, roomID: RoomID,
    sequence: UInt64) async throws {
    try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask {
            while true {
                let change = try await connection.nextAccountRoomChange()
                if case .changed(_, let room, let head) = change, room == roomID, head >= sequence { return }
                if case .resyncRequired = change { throw V2RealtimeTransportError.unexpectedResponse }
            }
        }
        tasks.addTask {
            try await Task.sleep(for: .seconds(10))
            throw V2RealtimeTransportError.unexpectedResponse
        }
        defer { tasks.cancelAll() }
        _ = try await tasks.next()
    }
}

private func awaitReceiverProjection(
    in store: GRDBV2LocalSyncStore,
    roomID: RoomID,
    messageID: MessageID,
    syncEngine: V2SyncEngine
) async throws -> V2ClientMessageProjection {
    for _ in 0 ..< 50 {
        try await synchronizeInitialState(syncEngine)
        if let message = try await store.messages(in: roomID).first(where: { $0.messageID == messageID }) {
            return message
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    let visibleMessages = try await store.messages(in: roomID)
    throw LocalE2EDeliveryError.receiverProjectionTimedOut(visibleMessageCount: visibleMessages.count)
}

private func assertDirectMessageIsRestricted(sender: LocalE2EAccountCredentials, roomID: RoomID, text: String, connection: V2TLSFrameConnection? = nil, transport: V2ProtobufSyncTransport? = nil) async {
    do {
        try await sender.withMessageSendClient(connection: connection, transport: transport) { client in
        let command = try V2MessageSendOperationCommand(command: .init(roomID: roomID,
            senderUserID: sender.userID, clientMessageID: .init(uuid: UUID()), text: text,
            media: [], mentions: [], limits: .init(maxUTF8Bytes: 4096)),
            firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 86_400_000)
        guard case .receipt(let proof) = try await client.submit(command) else {
            XCTFail("Restricted message must return original terminal proof"); return
        }
        XCTAssertTrue(try proof.validates(identity: command.identity, fingerprint: command.fingerprint))
        XCTAssertEqual(proof.outcome, .rejected(.directPolicyDenied))
        guard case .receipt(let replay) = try await client.recover(.init(identity: command.identity, fingerprint: command.fingerprint, domainFingerprint: command.command.fingerprint, action: .query)) else {
            XCTFail("Restricted message must recover its original proof"); return
        }
        XCTAssertEqual(replay, proof)
        }
    } catch { XCTFail("Restricted message must return a bound authorization proof: \(error)") }
}

private enum LocalE2EDeliveryError: Error, LocalizedError {
    case receiverProjectionTimedOut(visibleMessageCount: Int)
    var errorDescription: String? {
        switch self {
        case .receiverProjectionTimedOut(let count): "等待接收端 SQLite 投影超时；当前房间可见消息数：\(count)。"
        }
    }
}

private func localJSONRequest(endpoint: URL, body: [String: String], cancellation: V2DeviceRegistrationCancellation? = nil) async throws -> [String: Any] {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    var payload: [String: Any] = body
    if let cancellation { payload["cancellation"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cancellation)) }
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try requireLocalE2E(response as? HTTPURLResponse)
    guard http.statusCode == 200 else { throw LocalE2EContractError.unexpectedHTTPStatus(http.statusCode) }
    let result = try requireLocalE2E(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    if let cancellation {
        let confirmation = try requireLocalE2E(result["registrationCancellation"])
        let decoded = try JSONDecoder().decode(V2DeviceRegistrationCancellation.self,
            from: JSONSerialization.data(withJSONObject: confirmation))
        guard decoded == cancellation else { throw LocalE2EContractError.mismatchedCancellation }
    }
    return result
}

/// Uses the same real source event as the two-client sync assertion, with a
/// separate scoped App installation and its real Keychain/SQLite restoration.
@MainActor
private func assertPrivateHintSurvivesAppRelaunch(
    sender: LocalE2EAccountCredentials, roomID: String, hintID: String,
    produceWhileBackgrounded: () async throws -> String
) async throws {
    let app = XCUIApplication()
    let scoped = ["-v2-ui-testing-live-local-account", "-v2-ui-testing-e2e-scope", UUID().uuidString.lowercased()]
    defer {
        app.terminate()
        app.launchArguments = scoped + ["-v2-ui-testing-cleanup-local-account"]
        app.launch()
        XCTAssertTrue(app.staticTexts["v2.local-e2e.cleanup.completed"].waitForExistence(timeout: 15))
        app.terminate()
    }
    app.launchArguments = scoped + ["-v2-ui-testing-account-handle", sender.accountHandle,
        "-v2-ui-testing-local-password", "local-clientkit-password"]
    app.launch()
    let login = app.buttons["v2.password.submit"]
    guard login.waitForExistence(timeout: 15) else { XCTFail("真实账号登录入口未出现"); return }
    login.tap()
    for restored in [false, true] {
        if restored {
            app.terminate()
            app.launchArguments = scoped + ["-v2-ui-testing-restore-local-account"]
            app.launch()
        }
        let room = app.descendants(matching: .any).matching(identifier: "v2.conversation.direct.\(roomID)").firstMatch
        guard room.waitForExistence(timeout: 30) else { XCTFail("登录或冷启动恢复后未同步到原私聊"); return }
        room.tap()
        let identifier = "v2.timeline.activity.\(hintID)"
        let hint = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        guard hint.waitForExistence(timeout: 30) else { XCTFail("聊天页缺少持久单侧提示，恢复状态：\(restored)"); return }
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: identifier).count, 1,
            "同一源事件在聊天页只能显示一次")
        XCTAssertEqual(hint.label, "系统提示")
        if restored {
            for cycle in 1...3 {
                XCUIDevice.shared.press(.home)
                XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
                let newID = try await produceWhileBackgrounded()
                app.activate()
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
                let newIdentifier = "v2.timeline.activity.\(newID)"
                let newHint = app.descendants(matching: .any).matching(identifier: newIdentifier)
                XCTAssertTrue(newHint.firstMatch.waitForExistence(timeout: 30),
                    "Foreground cycle \(cycle) must recover the event produced in background")
                XCTAssertEqual(newHint.count, 1)
                XCTAssertEqual(app.descendants(matching: .any).matching(identifier: identifier).count, 1)
            }
            print("IMV2_THREE_FOREGROUND_RECOVERY_CYCLES_PASSED")
        }
    }
}

private struct PrivateHintCredentials: V2ClientMediaEdgeCredentialProvider {
    let account: LocalE2EAccountCredentials
    func mediaEdgeCredentials() async throws -> V2ClientMediaEdgeCredentials {
        .init(accessToken: account.accessToken, deviceID: account.deviceID)
    }
}
private extension LocalE2EAccountCredentials {
    func openDirectRoom(target: UserID) async throws -> (roomID: RoomID, proof: V2DirectRoomOperationReceipt) {
        let client = try V2HTTPDirectRoomOperationClient(baseURL: URL(string: "https://localhost:8443")!,
            credentials: PrivateHintCredentials(account: self), transport: V2URLSessionMediaEdgeHTTPTransport())
        let command = try V2DirectRoomOperationCommand(actorUserID: userID, operationID: .init(uuid: UUID()),
            targetUserID: target, firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 600_000)
        guard case .receipt(let proof) = try await client.submit(command), proof.validates(command: command),
              case .opened(let room, _) = proof.outcome,
              case .receipt(let replay) = try await client.recover(command, action: .query), replay == proof else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        return (room, proof)
    }
    func setBlock(target: UserID, blocked: Bool) async throws {
        let client = try V2HTTPSocialOperationClient(baseURL: URL(string: "https://localhost:8443")!,
            credentials: PrivateHintCredentials(account: self), transport: V2URLSessionMediaEdgeHTTPTransport())
        let baseline = try await client.baseline(targetUserID: target)
        let command = try V2SocialOperationCommand(identity: .init(accountID: userID,
            scope: .userPair(userID, target), operation: .userBlock(.init(uuid: UUID()))),
            action: .userBlock(blocked ? .block : .unblock), expectedRevision: baseline.blockRevision,
            firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 120_000)
        guard case .receipt(let proof) = try await client.submit(command), proof.validates(command: command),
              case .applied(.userBlock(let value, _)) = proof.outcome, value == blocked,
              case .receipt(let replay) = try await client.recover(command, action: .query), replay == proof else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
    }
}
