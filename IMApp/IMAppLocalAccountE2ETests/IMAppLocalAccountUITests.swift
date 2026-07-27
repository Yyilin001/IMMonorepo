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
    /// TLS connections and two independent SQLite stores. Both parties
    /// disconnect after the direct room is established: the sender persists
    /// its message in the outbox, reconnects and replays that immutable ID;
    /// the receiver then reconnects and projects the accepted message.
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
            XCTAssertEqual(
                firstFlush,
                .retryScheduled(command.clientMessageID),
                "断线时消息必须保存在 sender SQLite outbox 中，而不能丢弃。"
            )
            let scheduledCommands = try await senderStore.pendingMessageCommands()
            let scheduledCommand = try XCTUnwrap(
                scheduledCommands.first(where: { $0.clientMessageID == command.clientMessageID })
            )
            XCTAssertEqual(scheduledCommand.state, .pending)
            XCTAssertEqual(scheduledCommand.attemptCount, 1)

            let reconnectedSenderSession = try await reconnectingSenderConnection.connectAndAuthenticate(
                accessToken: sender.accessToken,
                deviceID: sender.deviceID,
                supportedCapabilityProfiles: ["base"]
            )
            XCTAssertEqual(reconnectedSenderSession.userID, sender.userID)
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
            XCTAssertEqual(acceptedClientMessageID, command.clientMessageID)
            let acceptedCommands = try await senderStore.pendingMessageCommands()
            let acceptedCommand = try XCTUnwrap(
                acceptedCommands.first(where: { $0.clientMessageID == command.clientMessageID })
            )
            let acceptedMessageID = try XCTUnwrap(acceptedCommand.acceptedMessageID)
            XCTAssertEqual(acceptedCommand.state, .accepted)
            XCTAssertNotNil(acceptedCommand.acceptedRoomSequence)

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
                messageID: acceptedMessageID,
                syncEngine: reconnectedReceiverSync
            )
            XCTAssertEqual(delivered.messageID, acceptedMessageID)
            XCTAssertEqual(delivered.senderUserID, sender.userID)
            XCTAssertEqual(delivered.text, expectedText)
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

    /// The stranger-message preference is recipient-owned. A sender can open
    /// the deterministic direct room, but a denied recipient must receive no
    /// message until the recipient explicitly restores the permission.
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
            _ = try await receiverTransport.setStrangerMessagePermission(
                operationID: try StrangerMessagePreferenceOperationID(UUID().uuidString.lowercased()),
                permission: .deny
            )
            let directRoom = try await senderTransport.openDirectRoom(
                operationID: try DirectRoomOperationID(UUID().uuidString.lowercased()),
                targetUserID: receiver.userID
            )
            await assertStrangerMessageIsForbidden(
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
            XCTAssertEqual(accepted.roomID, directRoom.roomID)
        } catch {
            await senderConnection.disconnect()
            await receiverConnection.disconnect()
            throw error
        }

        await senderConnection.disconnect()
        await receiverConnection.disconnect()
    }

    /// A private block applies even to an already-open direct room. The
    /// sender receives only the generic authorization result and may resume
    /// once the recipient explicitly removes that block.
    func testReceiverCanBlockAndRestoreExistingDirectMessageDelivery() async throws {
        let sender = try await registerLocalAccount(displayName: "Blocked sender")
        let receiver = try await registerLocalAccount(displayName: "Blocking receiver")
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
            let directRoom = try await senderTransport.openDirectRoom(
                operationID: try DirectRoomOperationID(UUID().uuidString.lowercased()),
                targetUserID: receiver.userID
            )
            let blocked = try await receiverTransport.changeUserBlock(
                operationID: try UserBlockOperationID(UUID().uuidString.lowercased()),
                targetUserID: sender.userID,
                action: .block
            )
            XCTAssertTrue(blocked.isBlocked)
            await assertDirectMessageIsForbidden(
                senderTransport: senderTransport,
                roomID: directRoom.roomID,
                text: "must-not-deliver-while-blocked"
            )

            let unblocked = try await receiverTransport.changeUserBlock(
                operationID: try UserBlockOperationID(UUID().uuidString.lowercased()),
                targetUserID: sender.userID,
                action: .unblock
            )
            XCTAssertFalse(unblocked.isBlocked)
            let accepted = try await senderTransport.sendMessage(
                roomID: directRoom.roomID,
                clientMessageID: try ClientMessageID(UUID().uuidString.lowercased()),
                text: "allowed-after-explicit-unblock",
                media: [],
                mentions: []
            )
            XCTAssertEqual(accepted.roomID, directRoom.roomID)
        } catch {
            await senderConnection.disconnect()
            await receiverConnection.disconnect()
            throw error
        }

        await senderConnection.disconnect()
        await receiverConnection.disconnect()
    }

    /// A friendship is server-authoritative: both sides complete the private
    /// request/accept exchange before the resulting direct room is used.
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
            XCTAssertEqual(requesterSession.userID, requester.userID)
            XCTAssertEqual(recipientSession.userID, recipient.userID)

            let requesterTransport = V2ProtobufSyncTransport(wire: requesterConnection, protocolVersion: requesterSession.protocolVersion)
            let recipientTransport = V2ProtobufSyncTransport(wire: recipientConnection, protocolVersion: recipientSession.protocolVersion)
            let requested = try await requesterTransport.changeRelationship(
                operationID: try RelationshipOperationID(UUID().uuidString.lowercased()),
                targetUserID: recipient.userID,
                action: .request
            )
            XCTAssertEqual(requested.resultingState, .pending)
            let accepted = try await recipientTransport.changeRelationship(
                operationID: try RelationshipOperationID(UUID().uuidString.lowercased()),
                targetUserID: requester.userID,
                action: .accept
            )
            XCTAssertEqual(accepted.resultingState, .accepted)
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
            XCTAssertEqual(message.roomID, directRoom.roomID)
        } catch {
            await requesterConnection.disconnect()
            await recipientConnection.disconnect()
            throw error
        }

        await requesterConnection.disconnect()
        await recipientConnection.disconnect()
    }

    /// The local stack's stranger policy permits three initial messages in a
    /// 24-hour window. The limit is enforced at the authenticated gateway,
    /// rather than being a sender-side UI convention, and the fourth request
    /// remains retryable so a durable outbox can apply its own backoff before
    /// attempting the server window again.
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
            XCTAssertEqual(senderSession.userID, sender.userID)
            XCTAssertEqual(receiverSession.userID, receiver.userID)

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
                XCTAssertEqual(accepted.roomID, directRoom.roomID)
            }
            await assertStrangerMessageIsRateLimited(
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

    /// Exercises the ordinary group command surface against the real local
    /// gateway. Group roster facts stay on the explicit directory read: they
    /// are never inferred from a direct-message projection or from a client
    /// cache.
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
            XCTAssertEqual(ownerSession.userID, owner.userID)
            XCTAssertEqual(initialMemberSession.userID, initialMember.userID)
            XCTAssertEqual(addedMemberSession.userID, addedMember.userID)

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
            let group = try await ownerTransport.createGroupRoom(
                operationID: try GroupRoomOperationID(UUID().uuidString.lowercased()),
                title: "  Local gateway group  ",
                initialMemberUserIDs: [initialMember.userID]
            )
            XCTAssertEqual(group.title, "Local gateway group")
            XCTAssertEqual(Set(group.memberUserIDs), Set([owner.userID, initialMember.userID]))

            let ownerPage = try await ownerTransport.listRoomMembers(
                roomID: group.roomID,
                cursor: nil,
                pageSize: 10
            )
            XCTAssertEqual(ownerPage.actorRole, .owner)
            XCTAssertEqual(Set(ownerPage.members.map(\.userID)), Set([owner.userID, initialMember.userID]))
            XCTAssertNil(ownerPage.nextCursor)

            let initialMemberPage = try await initialMemberTransport.listRoomMembers(
                roomID: group.roomID,
                cursor: nil,
                pageSize: 10
            )
            XCTAssertEqual(initialMemberPage.actorRole, .member)
            XCTAssertEqual(initialMemberPage.membershipRevision, ownerPage.membershipRevision)
            XCTAssertEqual(Set(initialMemberPage.members.map(\.userID)), Set([owner.userID, initialMember.userID]))

            let added = try await ownerTransport.changeMembership(
                roomID: group.roomID,
                operationID: try MembershipOperationID(UUID().uuidString.lowercased()),
                targetUserID: addedMember.userID,
                action: .add,
                expectedMembershipRevision: ownerPage.membershipRevision
            )
            XCTAssertEqual(added.action, .add)
            XCTAssertEqual(added.targetUserID, addedMember.userID)
            XCTAssertGreaterThan(added.membershipRevision, ownerPage.membershipRevision)

            let addedMemberPage = try await addedMemberTransport.listRoomMembers(
                roomID: group.roomID,
                cursor: nil,
                pageSize: 10
            )
            XCTAssertEqual(addedMemberPage.actorRole, .member)
            XCTAssertEqual(addedMemberPage.membershipRevision, added.membershipRevision)
            XCTAssertEqual(
                Set(addedMemberPage.members.map(\.userID)),
                Set([owner.userID, initialMember.userID, addedMember.userID])
            )
            let acceptance = try await addedMemberTransport.sendMessage(
                roomID: group.roomID,
                clientMessageID: try ClientMessageID(UUID().uuidString.lowercased()),
                text: "accepted-after-membership-change",
                media: [],
                mentions: []
            )
            XCTAssertEqual(acceptance.roomID, group.roomID)
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

private func assertStrangerMessageIsForbidden(
    senderTransport: V2ProtobufSyncTransport,
    roomID: RoomID
) async {
    await assertDirectMessageIsForbidden(
        senderTransport: senderTransport,
        roomID: roomID,
        text: "must-not-deliver"
    )
}

private func assertDirectMessageIsForbidden(
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
        XCTFail("接收方拒绝 direct 消息后，发送端不应获得消息接受结果。")
    } catch let error as V2RealtimeTransportError {
        guard case .server(let code, let retryable, _, _) = error else {
            XCTFail("direct 消息拒收必须返回服务端授权结果，实际错误：\(error)。")
            return
        }
        XCTAssertEqual(code, "FORBIDDEN")
        XCTAssertFalse(retryable)
    } catch {
        XCTFail("direct 消息拒收应映射为不透明授权错误，实际错误：\(error)。")
    }
}

private func assertStrangerMessageIsRateLimited(
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
        XCTFail("本机陌生人消息窗口的第 4 条消息不应被接受。")
    } catch let error as V2RealtimeTransportError {
        guard case .server(let code, let retryable, _, _) = error else {
            XCTFail("陌生人限额必须返回服务端限流结果，实际错误：\(error)。")
            return
        }
        XCTAssertEqual(code, "RATE_LIMITED")
        XCTAssertTrue(retryable)
        // `retry_after_seconds` is optional in the current protobuf contract;
        // a zero value means the client falls back to its bounded local
        // backoff. The stable gateway guarantee here is the retryable code.
    } catch {
        XCTFail("陌生人限额应映射为服务端限流错误，实际错误：\(error)。")
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
