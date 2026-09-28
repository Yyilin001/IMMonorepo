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
            let senderBinding = LocalE2EInstallationBindingStore()
            let senderStore = try await V2LocalStoreBootstrapper(
                bindingStore: senderBinding
            ).open(databaseURL: senderDatabaseURL, userID: sender.userID)
            let receiverStore = try await V2LocalStoreBootstrapper(
                bindingStore: LocalE2EInstallationBindingStore()
            ).open(databaseURL: databaseURL, userID: receiver.userID)
            let receiverSync = V2SyncEngine(
                transport: receiverTransport,
                store: receiverStore,
                capabilityProfile: receiverSession.capabilityProfile
            )
            try await synchronizeInitialState(receiverSync)
            await receiverConnection.disconnect()

            let directRoom = try await localOpenDirectRoom(account:sender,target:receiver.userID)
            let expectedText = "dual-client-local-\(UUID().uuidString.lowercased())"
            await senderConnection.disconnect()
            let client = LocalE2EMessageClient(account: sender, online: false)
            let service = V2MessageSendOperationService(accountID: sender.userID, store: senderStore, client: client)
            _ = try await service.enqueueMessage(roomID: directRoom.roomID, text: expectedText)
            let work = try #require(try await senderStore.dueOperationWork(now: Date(), kinds: [.sendMessage]).first)
            guard case .sendMessage(let clientMessageID) = work.identity.operation,
                  case .claimed(let claim) = try await senderStore.claimOperationWork(id: work.id, ownerID: UUID(), action: .submit, now: Date()) else {
                throw LocalE2EContractError.missingValue
            }
            try await service.execute(claim)
            let scheduled = try #require(try await senderStore.operationWork(id: work.id))
            #expect(scheduled.execution == .awaitingConfirmation)
            #expect(scheduled.attemptCount == 1)
            try await senderStore.close()
            let restoredSenderStore = try await V2LocalStoreBootstrapper(
                bindingStore: senderBinding
            ).open(databaseURL: senderDatabaseURL, userID: sender.userID)
            await client.setOnline()
            let receipt = try await awaitSenderReplay(store: restoredSenderStore, account: sender, client: client, workID: work.id)
            #expect(receipt.identity.operation == .sendMessage(clientMessageID))
            guard case .accepted(let acceptance) = receipt.outcome else { throw LocalE2EContractError.missingValue }
            let acceptedMessageID = acceptance.messageID
            #expect(acceptance.roomSequence > 0)
            #expect(try await restoredSenderStore.operationWork(id: work.id)?.execution == .committed)
            try await restoredSenderStore.close()

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
            try await localSetAccountPreference(account:receiver,value:.strangerMessage(.deny))
            let directRoom = try await localOpenDirectRoom(account:sender,target:receiver.userID)
            await expectStrangerMessageIsForbidden(
                senderAccount: sender,
                roomID: directRoom.roomID
            )

            try await localSetAccountPreference(account:receiver,value:.strangerMessage(.allow))
            let accepted = try await localAcceptedMessage(account: sender,
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
            let requested = try await localChangeRelationship(account:requester,target:recipient.userID,action:.request)
            #expect((requested) == (.pending))
            let accepted = try await localChangeRelationship(account:recipient,target:requester.userID,action:.accept)
            #expect((accepted) == (.accepted))
            let directRoom = try await localOpenDirectRoom(account:requester,target:recipient.userID)
            let message = try await localAcceptedMessage(account: requester,
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
            let directRoom = try await localOpenDirectRoom(account:sender,target:receiver.userID)
            for messageIndex in 1 ... 3 {
                let accepted = try await localAcceptedMessage(account: sender,
                    roomID: directRoom.roomID,
                    clientMessageID: try ClientMessageID(UUID().uuidString.lowercased()),
                    text: "stranger-window-message-\(messageIndex)",
                    media: [],
                    mentions: []
                )
                #expect((accepted.roomID) == (directRoom.roomID))
            }
            await expectStrangerMessageIsRateLimited(
                senderAccount: sender,
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
            let groupOperationID = GroupRoomOperationID(uuid: UUID())
            let creation = try V2HTTPGroupCreationOperationClient(baseURL: #require(URL(string: "https://localhost:8443")),
                credentials: LocalE2EMessageCredentials(account: owner), transport: LocalE2EMessageHTTP())
            let members = try V2GroupCreationAudience.canonical([initialMember.userID], actorUserID: owner.userID)
            let creationIntent = try V2GroupCreationIntent(identity: .init(accountID: owner.userID, scope: .account(owner.userID), operation: .groupRoom(groupOperationID)),
                title: "  Local gateway group  ", capacityClass: .standard, initialMemberCount: members.count,
                audienceDigest: V2GroupCreationAudience.digest(members), firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000) + 600_000)
            _ = try await creation.begin(creationIntent)
            _ = try await creation.append(.init(intent: creationIntent, offset: 0, memberUserIDs: members))
            var creationResult = try await creation.finalize(creationIntent)
            for _ in 0..<100 {
                if case .receipt = creationResult { break }
                try await Task.sleep(for: .milliseconds(100))
                creationResult = try await creation.recover(creationIntent, action: .query)
            }
            guard case .receipt(let creationProof) = creationResult,
                  creationProof.validates(intent: creationIntent), case .created(let roomID, let title, _, let count) = creationProof.outcome else { Issue.record("Expected original creation proof"); return }
            let group = (roomID: roomID, title: title, memberCount: count)
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

            let membershipClient=try V2HTTPMembershipOperationClient(baseURL:#require(URL(string:"https://localhost:8443")),credentials:LocalE2EMessageCredentials(account:owner),transport:LocalE2EMessageHTTP())
            let intent=try V2MembershipIntent(roomID:group.roomID,actorUserID:owner.userID,operationID:.init(uuid:UUID()),targetUserID:addedMember.userID,action:.add,expectedMembershipRevision:ownerPage.membershipRevision,confirmedUntilMilliseconds:UInt64(Date().timeIntervalSince1970*1000)+120_000)
            guard case .admitted(let admission)=try await membershipClient.admit(intent) else { throw LocalE2EMembershipFailure.noAdmission }
            let frozen=try V2MembershipOperationCommand(intent:intent,admission:admission)
            guard case .receipt(let proof)=try await membershipClient.submit(frozen),proof.validates(command:frozen),case .changed(let added)=proof.outcome else { throw LocalE2EMembershipFailure.noReceipt }
            #expect(added.membershipRevision > ownerPage.membershipRevision)

            let addedMemberPage = try await addedMemberTransport.listRoomMembers(
                roomID: group.roomID,
                cursor: nil,
                pageSize: 10
            )
            #expect((addedMemberPage.actorRole) == (.member))
            #expect((addedMemberPage.membershipRevision) == (added.membershipRevision))
            #expect((Set(addedMemberPage.members.map(\.userID))) == (Set([owner.userID, initialMember.userID, addedMember.userID])))
            let acceptance = try await localAcceptedMessage(account: addedMember,
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

private struct LocalE2EMessageCredentials: V2ClientMediaEdgeCredentialProvider {
    let account: LocalE2EAccountCredentials
    func mediaEdgeCredentials() async throws -> V2ClientMediaEdgeCredentials {
        .init(accessToken: account.accessToken, deviceID: account.deviceID)
    }
}
private struct LocalE2EMessageHTTP: V2ClientMediaEdgeHTTPTransport {
    let executor = V2HTTPExecutor()
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await executor.execute(request)
    }
}
private actor LocalE2EMessageClient: V2MessageSendOperationClient {
    let account: LocalE2EAccountCredentials
    var online: Bool
    private(set) var receipt: V2MessageSendOperationReceipt?
    init(account: LocalE2EAccountCredentials, online: Bool = true) { self.account = account; self.online = online }
    func setOnline() { online = true }
    private func remote() throws -> V2HTTPMessageSendOperationClient {
        guard online else { throw URLError(.notConnectedToInternet) }
        return try .init(baseURL: #require(URL(string: "https://localhost:8443")),
            credentials: LocalE2EMessageCredentials(account: account), transport: LocalE2EMessageHTTP())
    }
    func submit(_ command: V2MessageSendOperationCommand) async throws -> V2MessageSendOperationRecoveryResult {
        let result = try await remote().submit(command)
        if case .receipt(let value) = result { receipt = value }
        return result
    }
    func recover(_ request: V2MessageSendOperationRecoveryRequest) async throws -> V2MessageSendOperationRecoveryResult {
        let result = try await remote().recover(request)
        if case .receipt(let value) = result { receipt = value }
        return result
    }
}

private func awaitSenderReplay(store: GRDBV2LocalSyncStore, account: LocalE2EAccountCredentials,
    client: LocalE2EMessageClient, workID: UUID) async throws -> V2MessageSendOperationReceipt {
    let service = V2MessageSendOperationService(accountID: account.userID, store: store, client: client)
    let dispatcher = V2OperationWorkDispatcher(store: store, handlers: [.init(kind: .sendMessage) { try await service.execute($0) }])
    let worker = Task { try await dispatcher.run() }
    do {
        for _ in 0..<300 {
            if try await store.operationWork(id: workID)?.execution == .committed,
               let receipt = await client.receipt {
                await dispatcher.stopAndDrain(); worker.cancel(); _ = await worker.result
                return receipt
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LocalE2EDeliveryError.senderOutboxReplayTimedOut
    } catch {
        await dispatcher.stopAndDrain(); worker.cancel(); _ = await worker.result
        throw error
    }
}

private func localMessageResult(account: LocalE2EAccountCredentials, roomID: RoomID,
    clientMessageID: ClientMessageID, text: String, media: [V2MediaReference] = [], mentions: [V2MentionTarget] = []) async throws -> V2MessageSendOperationRecoveryResult {
    let command = try V2MessageSendOperationCommand(command: .init(roomID: roomID, senderUserID: account.userID,
        clientMessageID: clientMessageID, text: text, media: media, mentions: mentions, limits: .init(maxUTF8Bytes: 65_536)),
        firstSubmissionDeadlineMilliseconds: UInt64(Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1_000))
    return try await LocalE2EMessageClient(account: account).submit(command)
}
private struct LocalE2EAcceptedMessage {
    let roomID: RoomID
    let messageID: MessageID
}
private func localAcceptedMessage(account: LocalE2EAccountCredentials, roomID: RoomID,
    clientMessageID: ClientMessageID, text: String, media: [V2MediaReference], mentions: [V2MentionTarget]) async throws -> LocalE2EAcceptedMessage {
    guard case .receipt(let receipt) = try await localMessageResult(account: account, roomID: roomID,
        clientMessageID: clientMessageID, text: text, media: media, mentions: mentions),
        case .accepted(let acceptance) = receipt.outcome else { throw LocalE2EContractError.missingValue }
    return .init(roomID: roomID, messageID: acceptance.messageID)
}
private func expectStrangerMessageIsForbidden(senderAccount: LocalE2EAccountCredentials, roomID: RoomID) async {
    do {
        let result = try await localMessageResult(account: senderAccount, roomID: roomID,
            clientMessageID: .init(uuid: UUID()), text: "must-not-deliver")
        guard case .receipt(let receipt) = result else { Issue.record("Expected authoritative policy rejection"); return }
        #expect(receipt.outcome == .rejected(.directPolicyDenied))
    } catch { Issue.record("Expected policy receipt, received error: \(error)") }
}
private func expectStrangerMessageIsRateLimited(senderAccount: LocalE2EAccountCredentials, roomID: RoomID) async {
    do {
        let result = try await localMessageResult(account: senderAccount, roomID: roomID,
            clientMessageID: .init(uuid: UUID()), text: "must-hit-stranger-window-limit")
        guard case .deferred(let hint) = result else { Issue.record("Expected authoritative rate limit hint"); return }
        #expect(hint.reason == .rateLimited)
        #expect(try #require(hint.retryAfterMilliseconds) > 0)
    } catch { Issue.record("Expected unresolved retryable operation, received error: \(error)") }
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

private enum LocalE2EMembershipFailure:Error { case noAdmission,noReceipt }

private func localSetAccountPreference(account:LocalE2EAccountCredentials,value:V2AccountPreferenceValue) async throws {
    let client=try V2HTTPAccountPreferenceOperationClient(baseURL:#require(URL(string:"https://localhost:8443")),credentials:LocalE2EMessageCredentials(account:account),transport:LocalE2EMessageHTTP())
    let snapshot=try await client.baseline(kind:value.kind)
    let reference:V2OperationReference
    switch value { case .strangerMessage:reference = .strangerMessagePreference(.init(uuid:UUID()));case .userAdd:reference = .userAddPreference(.init(uuid:UUID()));case .readReceipt:reference = .readReceiptPreference(.init(uuid:UUID()));case .liveActivity:reference = .liveActivityPreference(.init(uuid:UUID())) }
    let command=try V2AccountPreferenceCommand(identity:.init(accountID:account.userID,scope:.account(account.userID),operation:reference),value:value,expectedRevision:snapshot.revision,firstSubmissionDeadlineMilliseconds:UInt64(Date().timeIntervalSince1970*1000)+120000)
    guard case .receipt(let proof)=try await client.submit(command),proof.validates(command:command),case .applied=proof.outcome else { throw LocalE2EMembershipFailure.noReceipt }
}
private func localChangeRelationship(account:LocalE2EAccountCredentials,target:UserID,action:V2RelationshipAction) async throws -> V2RelationshipState {
    let client=try V2HTTPSocialOperationClient(baseURL:#require(URL(string:"https://localhost:8443")),credentials:LocalE2EMessageCredentials(account:account),transport:LocalE2EMessageHTTP())
    let snapshot=try await client.baseline(targetUserID:target)
    let command=try V2SocialOperationCommand(identity:.init(accountID:account.userID,scope:.userPair(account.userID,target),operation:.relationship(.init(uuid:UUID()))),action:.relationship(action),expectedRevision:snapshot.relationshipRevision,firstSubmissionDeadlineMilliseconds:UInt64(Date().timeIntervalSince1970*1000)+600000)
    guard case .receipt(let proof)=try await client.submit(command),proof.validates(command:command),case .applied(.relationship(let state,_))=proof.outcome else { throw LocalE2EMembershipFailure.noReceipt };return state
}

private struct LocalE2EOpenedRoom {let roomID:RoomID}
private func localOpenDirectRoom(account:LocalE2EAccountCredentials,target:UserID) async throws -> LocalE2EOpenedRoom {
    let client=try V2HTTPDirectRoomOperationClient(baseURL:#require(URL(string:"https://localhost:8443")),credentials:LocalE2EMessageCredentials(account:account),transport:LocalE2EMessageHTTP())
    let command=try V2DirectRoomOperationCommand(actorUserID:account.userID,operationID:.init(uuid:UUID()),targetUserID:target,firstSubmissionDeadlineMilliseconds:UInt64(Date().timeIntervalSince1970*1000)+600000)
    guard case .receipt(let receipt)=try await client.submit(command),receipt.validates(command:command),case .opened(let room,_)=receipt.outcome else {throw LocalE2EMembershipFailure.noReceipt}
    return .init(roomID:room)
}
