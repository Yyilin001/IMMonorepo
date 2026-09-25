import Foundation
import IMV2ClientKit
import IMV2Core
import Testing

@Suite("Local account transport and persistence", .enabled(if: ProcessInfo.processInfo.environment["IMV2_LOCAL_ACCOUNT_E2E"] == "1"))
struct IMAppLocalAccountIntegrationTests {
    @Test
    func testSimulatorCanReachLocalAccountEdge() async throws {
        var request = URLRequest(url: try #require(URL(string: "https://localhost:8443/v2/account-auth/password/assertion")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect((http.statusCode) == (400), "本机账户边缘必须可被所选模拟器经 HTTPS 访问。")
    }

    @Test
    func testSimulatorCanRegisterAndIssueLocalDeviceCredentials() async throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let deviceID = UUID().uuidString.lowercased()
        let accountHandle = "kit_\(suffix.prefix(20))"
        let publicHandle = "kit\(suffix.prefix(20))"
        let registration = try await localJSONRequest(
            endpoint: try #require(URL(string: "https://localhost:8443/v2/account-auth/password/register")),
            body: [
                "accountHandle": accountHandle,
                "password": "local-clientkit-password",
                "deviceID": deviceID,
                "publicHandle": publicHandle,
                "displayName": "Local HTTPS E2E",
            ]
        )
        let assertion = try #require(registration["accountAssertion"] as? String)
        #expect(!(assertion.isEmpty))
        let pending = try V2PendingDeviceCredentialRegistration.prepare(deviceID: DeviceID(deviceID), operationID: UUID())
        let issued = try await localJSONRequest(
            endpoint: try #require(URL(string: "https://localhost:8443/v2/device-credentials")),
            body: [
                "accountAssertion": assertion,
                "deviceID": deviceID,
                "operationID": pending.operationID.uuidString,
            ], cancellation: pending.cancellation
        )
        let issuedUserID = try #require(issued["userID"] as? String)
        let issuedExpiry = try #require(issued["accessTokenExpiresAtMilliseconds"] as? NSNumber)
        #expect(((issued["deviceID"] as? String).flatMap(UUID.init(uuidString:))) == (UUID(uuidString: deviceID)))
        #expect(UUID(uuidString: issuedUserID) != nil)
        #expect(!((issued["accessToken"] as? String ?? "").isEmpty))
        #expect(!((issued["refreshCredential"] as? String ?? "").isEmpty))
        #expect((issuedExpiry.int64Value) > (Int64(Date().timeIntervalSince1970 * 1_000)), "账户边缘返回的访问凭据必须尚未过期。")
    }

    @Test
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
        let reconnectingSenderConnection = V2TLSFrameConnection(endpoint: endpoint, frameLimits: frameLimits)
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
            #expect((senderSession.userID) == (sender.userID))
            #expect((receiverSession.userID) == (receiver.userID))

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
            let senderDatabaseURL = databaseDirectory.appendingPathComponent("sender.sqlite")
            let databaseURL = databaseDirectory.appendingPathComponent("receiver.sqlite")
            defer { try? FileManager.default.removeItem(at: databaseDirectory) }
            let senderStore = try await V2LocalStoreBootstrapper(
                bindingStore: LocalE2EInstallationBindingStore()
            ).open(databaseURL: senderDatabaseURL)
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
            await senderConnection.disconnect()
            let offlineSenderOutbox = V2CommandOutboxEngine(store: senderStore, transport: senderTransport)
            let command = try await offlineSenderOutbox.enqueueMessage(
                roomID: directRoom.roomID,
                text: expectedText,
                media: [],
                mentions: []
            )
            let firstFlush = try await offlineSenderOutbox.flushOnce()
            #expect((firstFlush) == (.retryScheduled(command.clientMessageID)), "断线时消息必须保存在 sender SQLite outbox 中，而不能丢弃。")
            let scheduledCommands = try await senderStore.pendingMessageCommands()
            let scheduledCommand = try #require(scheduledCommands.first(where: { $0.clientMessageID == command.clientMessageID }))
            #expect((scheduledCommand.state) == (.pending))
            #expect((scheduledCommand.attemptCount) == (1))

            let reconnectedSenderSession = try await reconnectingSenderConnection.connectAndAuthenticate(
                accessToken: sender.accessToken,
                deviceID: sender.deviceID,
                supportedCapabilityProfiles: ["base"]
            )
            #expect((reconnectedSenderSession.userID) == (sender.userID))
            let reconnectedSenderOutbox = V2CommandOutboxEngine(
                store: senderStore,
                transport: V2ProtobufSyncTransport(
                    wire: reconnectingSenderConnection,
                    protocolVersion: reconnectedSenderSession.protocolVersion
                )
            )
            let acceptedClientMessageID = try await awaitSenderOutboxReplay(
                reconnectedSenderOutbox,
                expectedClientMessageID: command.clientMessageID
            )
            #expect((acceptedClientMessageID) == (command.clientMessageID))
            let acceptedCommands = try await senderStore.pendingMessageCommands()
            let acceptedCommand = try #require(acceptedCommands.first(where: { $0.clientMessageID == command.clientMessageID }))
            let acceptedMessageID = try #require(acceptedCommand.acceptedMessageID)
            #expect((acceptedCommand.state) == (.accepted))
            #expect(acceptedCommand.acceptedRoomSequence != nil)

            let reconnectedReceiverSession = try await reconnectingReceiverConnection.connectAndAuthenticate(
                accessToken: receiver.accessToken,
                deviceID: receiver.deviceID,
                supportedCapabilityProfiles: ["base"]
            )
            #expect((reconnectedReceiverSession.userID) == (receiver.userID))
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
                messageID: acceptedMessageID,
                syncEngine: reconnectedReceiverSync
            )
            #expect((delivered.messageID) == (acceptedMessageID))
            #expect((delivered.senderUserID) == (sender.userID))
            #expect((delivered.text) == (expectedText))
        } catch {
            await senderConnection.disconnect()
            await receiverConnection.disconnect()
            await reconnectingSenderConnection.disconnect()
            await reconnectingReceiverConnection.disconnect()
            throw error
        }

        await senderConnection.disconnect()
        await receiverConnection.disconnect()
        await reconnectingSenderConnection.disconnect()
        await reconnectingReceiverConnection.disconnect()
    }

    @Test
    func testReceiverCanDenyAndRestoreStrangerMessageDelivery() async throws {
        let sender = try await registerLocalAccount(displayName: "Stranger sender")
        let receiver = try await registerLocalAccount(displayName: "Stranger receiver")
        let frameLimits = try V2FrameLimits(
            maximumPayloadBytes: 65_536,
            acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]
        )
        let endpoint = try V2RealtimeEndpoint(host: "localhost", port: 7_443)
        let senderConnection = V2TLSFrameConnection(endpoint: endpoint, frameLimits: frameLimits)
        let receiverConnection = V2TLSFrameConnection(endpoint: endpoint, frameLimits: frameLimits)

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
            #expect((senderSession.userID) == (sender.userID))
            #expect((receiverSession.userID) == (receiver.userID))

            let senderTransport = V2ProtobufSyncTransport(
                wire: senderConnection,
                protocolVersion: senderSession.protocolVersion
            )
            let receiverTransport = V2ProtobufSyncTransport(
                wire: receiverConnection,
                protocolVersion: receiverSession.protocolVersion
            )
            _ = try await receiverTransport.setStrangerMessagePermission(
                operationID: try StrangerMessagePreferenceOperationID(UUID().uuidString.lowercased()),
                permission: .deny
            )
            let directRoom = try await senderTransport.openDirectRoom(
                operationID: try DirectRoomOperationID(UUID().uuidString.lowercased()),
                targetUserID: receiver.userID
            )
            await expectStrangerMessageIsForbidden(
                senderTransport: senderTransport,
                roomID: directRoom.roomID
            )

            _ = try await receiverTransport.setStrangerMessagePermission(
                operationID: try StrangerMessagePreferenceOperationID(UUID().uuidString.lowercased()),
                permission: .allow
            )
            let accepted = try await senderTransport.sendMessage(
                roomID: directRoom.roomID,
                clientMessageID: try ClientMessageID(UUID().uuidString.lowercased()),
                text: "allowed-after-explicit-restore",
                media: [],
                mentions: []
            )
            #expect((accepted.roomID) == (directRoom.roomID))
        } catch {
            await senderConnection.disconnect()
            await receiverConnection.disconnect()
            throw error
        }

        await senderConnection.disconnect()
        await receiverConnection.disconnect()
    }

    @Test
    func testTwoLocalClientsCanRequestAndAcceptRelationshipBeforeMessaging() async throws {
        let requester = try await registerLocalAccount(displayName: "Relationship requester")
        let recipient = try await registerLocalAccount(displayName: "Relationship recipient")
        let frameLimits = try V2FrameLimits(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
        let endpoint = try V2RealtimeEndpoint(host: "localhost", port: 7_443)
        let requesterConnection = V2TLSFrameConnection(endpoint: endpoint, frameLimits: frameLimits)
        let recipientConnection = V2TLSFrameConnection(endpoint: endpoint, frameLimits: frameLimits)

        do {
            let requesterSession = try await requesterConnection.connectAndAuthenticate(accessToken: requester.accessToken, deviceID: requester.deviceID, supportedCapabilityProfiles: ["base"])
            let recipientSession = try await recipientConnection.connectAndAuthenticate(accessToken: recipient.accessToken, deviceID: recipient.deviceID, supportedCapabilityProfiles: ["base"])
            #expect((requesterSession.userID) == (requester.userID))
            #expect((recipientSession.userID) == (recipient.userID))

            let requesterTransport = V2ProtobufSyncTransport(wire: requesterConnection, protocolVersion: requesterSession.protocolVersion)
            let recipientTransport = V2ProtobufSyncTransport(wire: recipientConnection, protocolVersion: recipientSession.protocolVersion)
            let requested = try await requesterTransport.changeRelationship(
                operationID: try RelationshipOperationID(UUID().uuidString.lowercased()),
                targetUserID: recipient.userID,
                action: .request
            )
            #expect((requested.resultingState) == (.pending))
            let accepted = try await recipientTransport.changeRelationship(
                operationID: try RelationshipOperationID(UUID().uuidString.lowercased()),
                targetUserID: requester.userID,
                action: .accept
            )
            #expect((accepted.resultingState) == (.accepted))
            let directRoom = try await requesterTransport.openDirectRoom(
                operationID: try DirectRoomOperationID(UUID().uuidString.lowercased()),
                targetUserID: recipient.userID
            )
            let message = try await requesterTransport.sendMessage(
                roomID: directRoom.roomID,
                clientMessageID: try ClientMessageID(UUID().uuidString.lowercased()),
                text: "accepted-relationship-message",
                media: [],
                mentions: []
            )
            #expect((message.roomID) == (directRoom.roomID))
        } catch {
            await requesterConnection.disconnect()
            await recipientConnection.disconnect()
            throw error
        }

        await requesterConnection.disconnect()
        await recipientConnection.disconnect()
    }

    @Test
    func testStrangerMessageRateLimitIsEnforcedByGateway() async throws {
        let sender = try await registerLocalAccount(displayName: "Rate-limit sender")
        let receiver = try await registerLocalAccount(displayName: "Rate-limit receiver")
        let frameLimits = try V2FrameLimits(
            maximumPayloadBytes: 65_536,
            acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]
        )
        let endpoint = try V2RealtimeEndpoint(host: "localhost", port: 7_443)
        let senderConnection = V2TLSFrameConnection(endpoint: endpoint, frameLimits: frameLimits)
        let receiverConnection = V2TLSFrameConnection(endpoint: endpoint, frameLimits: frameLimits)

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
            #expect((senderSession.userID) == (sender.userID))
            #expect((receiverSession.userID) == (receiver.userID))

            let senderTransport = V2ProtobufSyncTransport(
                wire: senderConnection,
                protocolVersion: senderSession.protocolVersion
            )
            let directRoom = try await senderTransport.openDirectRoom(
                operationID: try DirectRoomOperationID(UUID().uuidString.lowercased()),
                targetUserID: receiver.userID
            )
            for messageIndex in 1 ... 3 {
                let accepted = try await senderTransport.sendMessage(
                    roomID: directRoom.roomID,
                    clientMessageID: try ClientMessageID(UUID().uuidString.lowercased()),
                    text: "stranger-window-message-\(messageIndex)",
                    media: [],
                    mentions: []
                )
                #expect((accepted.roomID) == (directRoom.roomID))
            }
            await expectStrangerMessageIsRateLimited(
                senderTransport: senderTransport,
                roomID: directRoom.roomID
            )
        } catch {
            await senderConnection.disconnect()
            await receiverConnection.disconnect()
            throw error
        }

        await senderConnection.disconnect()
        await receiverConnection.disconnect()
    }

    @Test
    func testGroupCreationMembershipChangeAndRosterReadThroughGateway() async throws {
        let owner = try await registerLocalAccount(displayName: "Group owner")
        let initialMember = try await registerLocalAccount(displayName: "Initial group member")
        let addedMember = try await registerLocalAccount(displayName: "Added group member")
        let frameLimits = try V2FrameLimits(
            maximumPayloadBytes: 65_536,
            acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]
        )
        let endpoint = try V2RealtimeEndpoint(host: "localhost", port: 7_443)
        let ownerConnection = V2TLSFrameConnection(endpoint: endpoint, frameLimits: frameLimits)
        let initialMemberConnection = V2TLSFrameConnection(endpoint: endpoint, frameLimits: frameLimits)
        let addedMemberConnection = V2TLSFrameConnection(endpoint: endpoint, frameLimits: frameLimits)

        do {
            let ownerSession = try await ownerConnection.connectAndAuthenticate(
                accessToken: owner.accessToken,
                deviceID: owner.deviceID,
                supportedCapabilityProfiles: ["base"]
            )
            let initialMemberSession = try await initialMemberConnection.connectAndAuthenticate(
                accessToken: initialMember.accessToken,
                deviceID: initialMember.deviceID,
                supportedCapabilityProfiles: ["base"]
            )
            let addedMemberSession = try await addedMemberConnection.connectAndAuthenticate(
                accessToken: addedMember.accessToken,
                deviceID: addedMember.deviceID,
                supportedCapabilityProfiles: ["base"]
            )
            #expect((ownerSession.userID) == (owner.userID))
            #expect((initialMemberSession.userID) == (initialMember.userID))
            #expect((addedMemberSession.userID) == (addedMember.userID))

            let ownerTransport = V2ProtobufSyncTransport(
                wire: ownerConnection,
                protocolVersion: ownerSession.protocolVersion
            )
            let initialMemberTransport = V2ProtobufSyncTransport(
                wire: initialMemberConnection,
                protocolVersion: initialMemberSession.protocolVersion
            )
            let addedMemberTransport = V2ProtobufSyncTransport(
                wire: addedMemberConnection,
                protocolVersion: addedMemberSession.protocolVersion
            )
            let groupOperationID = try GroupRoomOperationID(UUID().uuidString.lowercased())
            _ = try await ownerTransport.beginGroupRoomCreation(
                operationID: groupOperationID,
                title: "  Local gateway group  "
            )
            _ = try await ownerTransport.appendGroupRoomCreationMembers(
                operationID: groupOperationID,
                memberUserIDs: [initialMember.userID]
            )
            let group = try await ownerTransport.finalizeGroupRoomCreation(operationID: groupOperationID)
            #expect((group.title) == ("Local gateway group"))
            #expect((group.memberCount) == (2))

            let ownerPage = try await ownerTransport.listRoomMembers(
                roomID: group.roomID,
                cursor: nil,
                pageSize: 10
            )
            #expect((ownerPage.actorRole) == (.owner))
            #expect((Set(ownerPage.members.map(\.userID))) == (Set([owner.userID, initialMember.userID])))
            #expect(ownerPage.nextCursor == nil)

            let initialMemberPage = try await initialMemberTransport.listRoomMembers(
                roomID: group.roomID,
                cursor: nil,
                pageSize: 10
            )
            #expect((initialMemberPage.actorRole) == (.member))
            #expect((initialMemberPage.membershipRevision) == (ownerPage.membershipRevision))
            #expect((Set(initialMemberPage.members.map(\.userID))) == (Set([owner.userID, initialMember.userID])))

            let added = try await ownerTransport.changeMembership(
                roomID: group.roomID,
                operationID: try MembershipOperationID(UUID().uuidString.lowercased()),
                targetUserID: addedMember.userID,
                action: .add,
                expectedMembershipRevision: ownerPage.membershipRevision
            )
            #expect((added.action) == (.add))
            #expect((added.targetUserID) == (addedMember.userID))
            #expect((added.membershipRevision) > (ownerPage.membershipRevision))

            let addedMemberPage = try await addedMemberTransport.listRoomMembers(
                roomID: group.roomID,
                cursor: nil,
                pageSize: 10
            )
            #expect((addedMemberPage.actorRole) == (.member))
            #expect((addedMemberPage.membershipRevision) == (added.membershipRevision))
            #expect((Set(addedMemberPage.members.map(\.userID))) == (Set([owner.userID, initialMember.userID, addedMember.userID])))
            let acceptance = try await addedMemberTransport.sendMessage(
                roomID: group.roomID,
                clientMessageID: try ClientMessageID(UUID().uuidString.lowercased()),
                text: "accepted-after-membership-change",
                media: [],
                mentions: []
            )
            #expect((acceptance.roomID) == (group.roomID))
        } catch {
            await ownerConnection.disconnect()
            await initialMemberConnection.disconnect()
            await addedMemberConnection.disconnect()
            throw error
        }

        await ownerConnection.disconnect()
        await initialMemberConnection.disconnect()
        await addedMemberConnection.disconnect()
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

private func awaitSenderOutboxReplay(
    _ outbox: V2CommandOutboxEngine,
    expectedClientMessageID: ClientMessageID
) async throws -> ClientMessageID {
    for _ in 0 ..< 50 {
        switch try await outbox.flushOnce() {
        case .accepted(let clientMessageID):
            guard clientMessageID == expectedClientMessageID else {
                throw LocalE2EDeliveryError.unexpectedOutboxCommand(clientMessageID)
            }
            return clientMessageID
        case .idle, .retryScheduled:
            try await Task.sleep(for: .milliseconds(100))
        case .rejected(_, let code):
            throw LocalE2EDeliveryError.senderOutboxRejected(code)
        }
    }
    throw LocalE2EDeliveryError.senderOutboxReplayTimedOut
}

private func expectStrangerMessageIsForbidden(
    senderTransport: V2ProtobufSyncTransport,
    roomID: RoomID
) async {
    await expectDirectMessageIsRestricted(senderTransport: senderTransport, roomID: roomID, text: "must-not-deliver")
}

private func expectDirectMessageIsRestricted(
    senderTransport: V2ProtobufSyncTransport,
    roomID: RoomID,
    text: String
) async {
    do {
        _ = try await senderTransport.sendMessage(
            roomID: roomID,
            clientMessageID: try ClientMessageID(UUID().uuidString.lowercased()),
            text: text,
            media: [],
            mentions: []
        )
        Issue.record("接收方拒绝 direct 消息后，发送端不应获得消息接受结果。")
    } catch let error as V2RealtimeTransportError {
        guard case .server(let code, let retryable, _, _) = error else {
            Issue.record("direct 消息拒收必须返回服务端授权结果，实际错误：\(error)。")
            return
        }
        #expect(code == "DIRECT_MESSAGE_RESTRICTED")
        #expect(!retryable)
    } catch {
        Issue.record("direct 消息拒收应映射为不透明授权错误，实际错误：\(error)。")
    }
}

private func expectStrangerMessageIsRateLimited(
    senderTransport: V2ProtobufSyncTransport,
    roomID: RoomID
) async {
    do {
        _ = try await senderTransport.sendMessage(
            roomID: roomID,
            clientMessageID: try ClientMessageID(UUID().uuidString.lowercased()),
            text: "must-hit-stranger-window-limit",
            media: [],
            mentions: []
        )
        Issue.record("本机陌生人消息窗口的第 4 条消息不应被接受。")
    } catch let error as V2RealtimeTransportError {
        guard case .server(let code, let retryable, _, _) = error else {
            Issue.record("陌生人限额必须返回服务端限流结果，实际错误：\(error)。")
            return
        }
        #expect(code == "RATE_LIMITED")
        #expect(retryable)
    } catch {
        Issue.record("陌生人限额应映射为服务端限流错误，实际错误：\(error)。")
    }
}

private enum LocalE2EDeliveryError: Error, LocalizedError {
    case receiverProjectionTimedOut(visibleMessageCount: Int)
    case senderOutboxReplayTimedOut
    case senderOutboxRejected(String)
    case unexpectedOutboxCommand(ClientMessageID)

    var errorDescription: String? {
        switch self {
        case .receiverProjectionTimedOut(let visibleMessageCount):
            "等待接收端 SQLite 投影超时；当前房间可见消息数：\(visibleMessageCount)。"
        case .senderOutboxReplayTimedOut:
            "等待发送端 SQLite outbox 重放超时。"
        case .senderOutboxRejected(let code):
            "发送端 SQLite outbox 被服务端终态拒绝：\(code)。"
        case .unexpectedOutboxCommand(let clientMessageID):
            "发送端 SQLite outbox 重放了非预期消息：\(clientMessageID.rawValue)。"
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
