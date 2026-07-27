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

    /// Isolates simulator-to-host TLS reachability before the registration UI
    /// test. The deliberately malformed body must reach the real local edge
    /// and receive its public 400 contract; no account or credential is made.
    func testSimulatorCanReachLocalAccountEdge() async throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://localhost:8443/v2/account-auth/password/assertion")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 400, "本机账户边缘必须可被所选模拟器经 HTTPS 访问。")
    }

    /// Checks the two HTTPS contracts consumed by ClientKit without importing
    /// the App's transitive GRDB module graph into this UI-test target.
    func testSimulatorCanRegisterAndIssueLocalDeviceCredentials() async throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let deviceID = UUID().uuidString.lowercased()
        let accountHandle = "kit_\(suffix.prefix(20))"
        let publicHandle = "kit\(suffix.prefix(20))"
        let registration = try await localJSONRequest(
            endpoint: try XCTUnwrap(URL(string: "https://localhost:8443/v2/account-auth/password/register")),
            body: [
                "accountHandle": accountHandle,
                "password": "local-clientkit-password",
                "deviceID": deviceID,
                "publicHandle": publicHandle,
                "displayName": "Local HTTPS E2E",
            ]
        )
        let assertion = try XCTUnwrap(registration["accountAssertion"] as? String)
        XCTAssertFalse(assertion.isEmpty)
        let issued = try await localJSONRequest(
            endpoint: try XCTUnwrap(URL(string: "https://localhost:8443/v2/device-credentials")),
            body: [
                "accountAssertion": assertion,
                "deviceID": deviceID,
                "operationID": UUID().uuidString.lowercased(),
            ]
        )
        let issuedUserID = try XCTUnwrap(issued["userID"] as? String)
        let issuedExpiry = try XCTUnwrap(issued["accessTokenExpiresAtMilliseconds"] as? NSNumber)
        XCTAssertEqual(issued["deviceID"] as? String, deviceID)
        XCTAssertNotNil(UUID(uuidString: issuedUserID))
        XCTAssertFalse((issued["accessToken"] as? String ?? "").isEmpty)
        XCTAssertFalse((issued["refreshCredential"] as? String ?? "").isEmpty)
        XCTAssertGreaterThan(
            issuedExpiry.int64Value,
            Int64(Date().timeIntervalSince1970 * 1_000),
            "账户边缘返回的访问凭据必须尚未过期。"
        )
    }

    /// Uses two independently registered local accounts, two authenticated
    /// TLS connections and the receiver's own SQLite projection. The receiver
    /// disconnects after its initial sync and reconnects before projecting the
    /// accepted message, proving local offline catch-up without claiming APNs
    /// wake-up or a deployed environment's delivery behavior.
    func testTwoLocalClientsDeliverDirectMessageIntoReceiverProjection() async throws {
        let sender = try await registerLocalAccount(displayName: "Local sender")
        let receiver = try await registerLocalAccount(displayName: "Local receiver")
        let frameLimits = try V2FrameLimits(
            maximumPayloadBytes: 65_536,
            acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]
        )
        let endpoint = try V2RealtimeEndpoint(host: "localhost", port: 7_443)
        let senderConnection = V2TLSFrameConnection(endpoint: endpoint, frameLimits: frameLimits)
        let receiverConnection = V2TLSFrameConnection(endpoint: endpoint, frameLimits: frameLimits)
        let reconnectingReceiverConnection = V2TLSFrameConnection(endpoint: endpoint, frameLimits: frameLimits)

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
            let databaseDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("im-v2-dual-client-e2e-\(UUID().uuidString)", isDirectory: true)
            let databaseURL = databaseDirectory.appendingPathComponent("receiver.sqlite")
            defer { try? FileManager.default.removeItem(at: databaseDirectory) }
            let receiverStore = try await V2LocalStoreBootstrapper(
                bindingStore: LocalE2EInstallationBindingStore()
            ).open(databaseURL: databaseURL)
            let receiverSync = V2SyncEngine(
                transport: receiverTransport,
                store: receiverStore,
                capabilityProfile: receiverSession.capabilityProfile
            )
            try await synchronizeInitialState(receiverSync)
            await receiverConnection.disconnect()

            let directRoom = try await senderTransport.openDirectRoom(
                operationID: try DirectRoomOperationID(UUID().uuidString.lowercased()),
                targetUserID: receiver.userID
            )
            let expectedText = "dual-client-local-\(UUID().uuidString.lowercased())"
            let accepted = try await senderTransport.sendMessage(
                roomID: directRoom.roomID,
                clientMessageID: try ClientMessageID(UUID().uuidString.lowercased()),
                text: expectedText,
                media: [],
                mentions: []
            )
            XCTAssertEqual(accepted.roomID, directRoom.roomID)

            let reconnectedReceiverSession = try await reconnectingReceiverConnection.connectAndAuthenticate(
                accessToken: receiver.accessToken,
                deviceID: receiver.deviceID,
                supportedCapabilityProfiles: ["base"]
            )
            XCTAssertEqual(reconnectedReceiverSession.userID, receiver.userID)
            let reconnectedReceiverSync = V2SyncEngine(
                transport: V2ProtobufSyncTransport(
                    wire: reconnectingReceiverConnection,
                    protocolVersion: reconnectedReceiverSession.protocolVersion
                ),
                store: receiverStore,
                capabilityProfile: reconnectedReceiverSession.capabilityProfile
            )
            let delivered = try await awaitReceiverProjection(
                in: receiverStore,
                roomID: directRoom.roomID,
                messageID: accepted.messageID,
                syncEngine: reconnectedReceiverSync
            )
            XCTAssertEqual(delivered.messageID, accepted.messageID)
            XCTAssertEqual(delivered.senderUserID, sender.userID)
            XCTAssertEqual(delivered.text, expectedText)
        } catch {
            await senderConnection.disconnect()
            await receiverConnection.disconnect()
            await reconnectingReceiverConnection.disconnect()
            throw error
        }

        await senderConnection.disconnect()
        await receiverConnection.disconnect()
        await reconnectingReceiverConnection.disconnect()
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

private struct LocalE2EAccountCredentials: Sendable {
    let accessToken: String
    let deviceID: DeviceID
    let userID: UserID
}

private actor LocalE2EInstallationBindingStore: V2InstallationBindingStore {
    private var binding: V2LocalInstallationBinding?

    func load() -> V2LocalInstallationBinding? { binding }

    func save(_ binding: V2LocalInstallationBinding) {
        self.binding = binding
    }

    func delete() {
        binding = nil
    }
}

private func registerLocalAccount(displayName: String) async throws -> LocalE2EAccountCredentials {
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let deviceID = try DeviceID(UUID().uuidString.lowercased())
    let registration = try await localJSONRequest(
        endpoint: try XCTUnwrap(URL(string: "https://localhost:8443/v2/account-auth/password/register")),
        body: [
            "accountHandle": "dual_\(suffix.prefix(20))",
            "password": "local-clientkit-password",
            "deviceID": deviceID.rawValue,
            "publicHandle": "dual\(suffix.prefix(20))",
            "displayName": displayName,
        ]
    )
    let assertion = try XCTUnwrap(registration["accountAssertion"] as? String)
    let issued = try await localJSONRequest(
        endpoint: try XCTUnwrap(URL(string: "https://localhost:8443/v2/device-credentials")),
        body: [
            "accountAssertion": assertion,
            "deviceID": deviceID.rawValue,
            "operationID": UUID().uuidString.lowercased(),
        ]
    )
    return try .init(
        accessToken: XCTUnwrap(issued["accessToken"] as? String),
        deviceID: deviceID,
        userID: .init(XCTUnwrap(issued["userID"] as? String))
    )
}

private func synchronizeInitialState(_ syncEngine: V2SyncEngine) async throws {
    if case .resetPending = try await syncEngine.synchronizeUntilCaughtUp() {
        try await syncEngine.completePendingReset()
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

private enum LocalE2EDeliveryError: Error, LocalizedError {
    case receiverProjectionTimedOut(visibleMessageCount: Int)

    var errorDescription: String? {
        switch self {
        case .receiverProjectionTimedOut(let visibleMessageCount):
            "等待接收端 SQLite 投影超时；当前房间可见消息数：\(visibleMessageCount)。"
        }
    }
}

private func localJSONRequest(endpoint: URL, body: [String: String]) async throws -> [String: Any] {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    request.httpBody = try JSONEncoder().encode(body)
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    XCTAssertEqual(http.statusCode, 200, "本机账户 HTTPS 合约应接受测试中的有效请求。")
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}
