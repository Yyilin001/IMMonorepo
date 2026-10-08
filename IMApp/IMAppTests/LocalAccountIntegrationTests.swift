import Foundation
@testable import IMV2ClientKit
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

    /// Requires an explicitly owned ACK-cut proxy and an external PostgreSQL
    /// COMMIT gate. The default local suite never arms a transport fault.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_APP_ACK_CUT_E2E"] == "1"))
    func unexpectedTCPDisconnectReplaysDurableWorkAcrossGateway() async throws {
        let environment = ProcessInfo.processInfo.environment
        let proxyPort = try #require(environment["IMV2_APP_ACK_CUT_PORT"].flatMap(UInt16.init))
        let controlPort = try #require(environment["IMV2_APP_ACK_CUT_CONTROL_PORT"].flatMap(UInt16.init))
        let receiverPort = try #require(environment["IMV2_APP_ACK_CUT_RECEIVER_PORT"].flatMap(UInt16.init))
        #expect(Set([proxyPort, controlPort, receiverPort]).count == 3)
        let sender = try await registerLocalAccount(displayName: "ACK-cut sender")
        let receiver = try await registerLocalAccount(displayName: "ACK-cut receiver")
        let room = try await localOpenDirectRoom(account: sender, target: receiver.userID)
        let limits = try V2FrameLimits(maximumPayloadBytes: 65_536,
            acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
        let connection = V2TLSFrameConnection(endpoint: try .init(host: "localhost", port: proxyPort), frameLimits: limits)
        let receiverConnection = V2TLSFrameConnection(endpoint: try .init(host: "localhost", port: receiverPort), frameLimits: limits)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imv2-app-ack-cut-\(UUID())", isDirectory: true)
        let binding = LocalE2EInstallationBindingStore()
        let senderDatabaseURL = directory.appendingPathComponent("sender.sqlite")
        let store = try await V2LocalStoreBootstrapper(bindingStore: binding)
            .open(databaseURL: senderDatabaseURL, userID: sender.userID)
        let receiverStore = try await V2LocalStoreBootstrapper(bindingStore: LocalE2EInstallationBindingStore())
            .open(databaseURL: directory.appendingPathComponent("receiver.sqlite"), userID: receiver.userID)
        let account = V2AccountRuntime()
        let auth = V2AuthSession(credentialStore: ACKCutCredentials(sender.credentials),
            transport: ACKCutNoRefresh(), revocationScheduler: ACKCutNoRevocation())
        let session = V2RealtimeSessionCoordinator(authSession: auth, connection: connection, supportedCapabilityProfiles: ["base"])
        let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: UInt8(IMV2ProtocolVersion.current))
        let sync = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")
        let coverage = ACKCutCoverage()
        // Use the same subscription and durable room-recovery owners as the App.
        // A Ready frame is a server coverage witness; it never advances SQLite.
        let roomSubscriptions = V2RoomSubscriptionCoordinator(subscriptions: transport, activity: transport,
            groupEvents: connection, activityEvents: connection,
            isAuthorized: { try await store.groupEventAccess(roomID: $0)?.isAuthorized == true },
            roomCursor: { try await store.groupEventCursor(roomID: $0) })
        let roomLease = try await roomSubscriptions.acquire(roomID: room.roomID, channels: [.roomEvents])
        let roomRecovery = V2RoomRecoveryRunner(engine: V2RoomRecoveryEngine(transport: transport,
            latestVisible: transport, store: store,
            groupEvents: V2GroupEventSyncEngine(transport: transport, store: store)),
            source: connection, personalSync: sync)
        let activity = V2DefaultClientRuntimeActivity(syncEngine: sync, availabilitySource: connection,
            heartbeatSender: transport, heartbeatInterval: .seconds(30),
            afterDurableSynchronization: {
                await roomRecovery.requestCatchUp()
                await roomSubscriptions.authorityDidChange()
            }, roomSubscriptionLoop: { connectionID in
                guard let connectionID else { throw V2TLSFrameConnectionError.notConnected }
                try await roomSubscriptions.run(connectionID: connectionID)
            }, roomCatchUpLoop: {
                try await roomRecovery.run(userID: sender.userID)
            }, policyRecoveryLoop: {
                for await value in await connection.realtimeCoverageChanges() {
                    try Task.checkCancellation()
                    await coverage.receive(value)
                }
            })
        let runtime = V2ClientRuntime(connection: session, activity: activity)
        let realtimeTask = Task { try await account.runRealtime(runtime) }
        let client = ACKCutObservedClient(base: V2RoutedMessageSendOperationClient(accountID: sender.userID,
            realtime: V2ProtobufMessageSendOperationClient(transport: transport, connection: connection)))
        let service = V2MessageSendOperationService(accountID: sender.userID, store: store, client: client)
        let dispatcher = V2OperationWorkDispatcher(store: store,
            handlers: [.init(kind: .sendMessage) { try await service.execute($0) }])
        do {
            let receiverSession = try await receiverConnection.connectAndAuthenticate(accessToken: receiver.accessToken,
                deviceID: receiver.deviceID, supportedCapabilityProfiles: ["base"])
            let receiverTransport = V2ProtobufSyncTransport(wire: receiverConnection, protocolVersion: receiverSession.protocolVersion)
            let receiverSync = V2SyncEngine(transport: receiverTransport, store: receiverStore,
                capabilityProfile: receiverSession.capabilityProfile)
            // A fresh direct room is not bilateral message visibility. Establish
            // the actual receiver reply fact before arming the lost-ACK fault;
            // acceptance of the main operation must not bypass stranger policy.
            let baseline = try V2MessageSendOperationCommand(command: .init(roomID: room.roomID,
                senderUserID: receiver.userID, clientMessageID: .init(UUID().uuidString),
                text: "ACK-cut receiver baseline reply", limits: .init(maxUTF8Bytes: 65_536)),
                firstSubmissionDeadlineMilliseconds: UInt64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1_000))
            let baselineResult = try await V2ProtobufMessageSendOperationClient(transport: receiverTransport,
                connection: receiverConnection).submit(baseline)
            guard case .receipt(let baselineReceipt) = baselineResult,
                  case .accepted = baselineReceipt.outcome,
                  baselineReceipt.validates(identity: try baseline.identity, fingerprint: try baseline.fingerprint)
            else { throw LocalE2EContractError.missingValue }
            try await synchronizeInitialState(receiverSync)
            try await ackCutAwait { await coverage.ready(room: room.roomID, excluding: nil, atLeast: 0) != nil }
            let initial = try #require(await connection.messageSendSession())
            let text = "app-ack-cut-\(UUID())"
            // Ready covers server acceleration, not intent preparation. The App
            // has an independent account-owned resource-preparation schedule.
            try #require(try await store.groupEventAccess(roomID: room.roomID)?.isAuthorized == true)
            let intentID = try await service.enqueueMessage(roomID: room.roomID, text: text)
            await account.startActivity(id: "resource-preparation") {
                try await runACKCutPlainSendPreparation(store: store)
            }
            try await ackCutAwait {
                try await store.dueOperationWork(now: Date(), kinds: [.sendMessage]).contains { $0.intentID == intentID }
            }
            let work = try #require(try await store.dueOperationWork(now: Date(), kinds: [.sendMessage]).first { $0.intentID == intentID })
            let command = try await store.messageSendCommand(workID: work.id)
            let fingerprint = try command.fingerprint
            let nonce = UUID().uuidString.lowercased()
            // No dispatcher exists yet: proxy arm completion precedes the first
            // submission. The runner reads this public identity, never tokens.
            _ = try await ackCutControl(port: controlPort, path: "/arm", body: [
                "nonce": nonce, "accountID": sender.userID.rawValue, "roomID": room.roomID.rawValue,
                "clientMessageID": command.command.clientMessageID.rawValue, "workID": work.id.uuidString,
                "fingerprintHex": fingerprint.digest.map { String(format: "%02x", $0) }.joined(),
                "fingerprintVersion": Int(fingerprint.version),
                "firstSubmissionDeadlineMilliseconds": command.firstSubmissionDeadlineMilliseconds,
                "connectionGeneration": initial.generation.uuidString])
            await account.startActivity(id: "durable-outbox") { try await dispatcher.run() }
            try await ackCutAwait { try await store.operationWork(id: work.id)?.execution == .committed }
            let receipt = try #require(await client.receipt)
            #expect(receipt.validates(identity: try command.identity, fingerprint: fingerprint))
            guard case .accepted(let acceptance) = receipt.outcome else { throw LocalE2EContractError.missingValue }
            try await ackCutAwait {
                await coverage.ready(room: room.roomID, excluding: initial.generation, atLeast: acceptance.roomSequence) != nil
            }
            let restoredCoverage = try #require(await coverage.ready(room: room.roomID,
                excluding: initial.generation, atLeast: acceptance.roomSequence))
            try await ackCutAwait {
                try await store.groupEventCursor(roomID: room.roomID) >= restoredCoverage.highWatermark
            }
            let senderApplied = try await store.groupEventCursor(roomID: room.roomID)
            let replacement = try #require(await connection.messageSendSession())
            #expect(replacement.generation == restoredCoverage.connectionGeneration)
            #expect(replacement.generation != initial.generation)
            #expect(await client.sawUnknown)
            #expect(await client.recoveryCount > 0)
            #expect(await client.identitiesAreUnchanged)
            let unchanged = try await store.messageSendCommand(workID: work.id)
            #expect(unchanged == command)
            let restoredWork = try #require(try await store.operationWork(id: work.id))
            #expect(restoredWork.identity == work.identity && restoredWork.fingerprint == work.fingerprint)
            // User sync carries authority/profile changes; ordinary direct body
            // lives in the room log. Pull/apply that log BEFORE inspecting the
            // message projection, rather than waiting for user sync to invent it.
            try await synchronizeInitialState(receiverSync)
            let groupSync = V2GroupEventSyncEngine(transport: receiverTransport, store: receiverStore)
            try await groupSync.synchronizeUntilCaughtUp(roomID: room.roomID)
            let projection = try #require(try await receiverStore.messages(in: room.roomID)
                .first { $0.messageID == acceptance.messageID })
            #expect(projection.text == text)
            #expect(try await receiverStore.groupEventCursor(roomID: room.roomID) >= acceptance.roomSequence)
            #expect(try await receiverStore.messages(in: room.roomID).filter { $0.messageID == acceptance.messageID }.count == 1)
            let status = try await ackCutControl(port: controlPort, path: "/status", body: nil)
            #expect(status["switched"] as? Bool == true)
            #expect((status["drained"] as? Int ?? 0) >= 1)
            #expect(status["closeFailures"] as? Int == 0)
            await dispatcher.stopAndDrain(); await account.close()
            realtimeTask.cancel(); _ = await realtimeTask.result
            try await store.close()
            let reopened = try await V2LocalStoreBootstrapper(bindingStore: binding)
                .open(databaseURL: senderDatabaseURL, userID: sender.userID)
            do {
                #expect(try await reopened.operationWork(id: work.id)?.execution == .committed)
                #expect(try await reopened.messageSendCommand(workID: work.id) == command)
                try await reopened.close()
            } catch { try? await reopened.close(); throw error }
            print("IMV2_APP_ACK_CUT_PROOF " + String(data: try JSONSerialization.data(withJSONObject: [
                "nonce": nonce, "workID": work.id.uuidString, "messageID": acceptance.messageID.rawValue,
                "roomID": room.roomID.rawValue, "roomSequence": acceptance.roomSequence,
                "oldConnectionGeneration": initial.generation.uuidString,
                "newConnectionGeneration": replacement.generation.uuidString,
                "receiverCursor": try await receiverStore.groupEventCursor(roomID: room.roomID),
                "senderReadyHighWatermark": restoredCoverage.highWatermark, "senderAppliedCursor": senderApplied,
                "sameIdentity": await client.identitiesAreUnchanged,
                "unknownObserved": await client.sawUnknown,
                "automaticReconnect": replacement.generation != initial.generation
            ], options: [.sortedKeys]), encoding: .utf8)!)
        } catch {
            await dispatcher.stopAndDrain(); await account.close()
            realtimeTask.cancel(); _ = await realtimeTask.result
            await roomSubscriptions.release(roomID: room.roomID, consumerID: roomLease.id)
            await receiverConnection.disconnect()
            try? await store.close(); try? await receiverStore.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        await dispatcher.stopAndDrain(); await account.close()
        realtimeTask.cancel(); _ = await realtimeTask.result
        await roomSubscriptions.release(roomID: room.roomID, consumerID: roomLease.id)
        await receiverConnection.disconnect()
        try await store.close(); try await receiverStore.close()
        try? FileManager.default.removeItem(at: directory)
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
            let group = try await localCreateGroup(account: owner, title: "  Local gateway group  ",
                members: [initialMember.userID])
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

            let added = try await localChangeMembership(account: owner, roomID: group.roomID,
                target: addedMember.userID, action: .add, revision: ownerPage.membershipRevision)
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
    return try .init(accountHandle: "dual_\(suffix.prefix(20))",
        credentials: localIssuedCredentials(issued, deviceID: deviceID))
}

func registerSiblingLocalDevice(_ account: LocalE2EAccountCredentials) async throws -> LocalE2EAccountCredentials {
    let deviceID = DeviceID(uuid: UUID())
    let assertion = try await localJSONRequest(
        endpoint: requireLocalE2E(URL(string: "https://localhost:8443/v2/account-auth/password/assertion")),
        body: ["accountHandle": account.accountHandle, "password": "local-clientkit-password", "deviceID": deviceID.rawValue])
    let pending = try V2PendingDeviceCredentialRegistration.prepare(deviceID: deviceID, operationID: UUID())
    let issued = try await localJSONRequest(
        endpoint: requireLocalE2E(URL(string: "https://localhost:8443/v2/device-credentials")),
        body: ["accountAssertion": requireLocalE2E(assertion["accountAssertion"] as? String),
            "deviceID": deviceID.rawValue, "operationID": pending.operationID.uuidString], cancellation: pending.cancellation)
    let credentials = try localIssuedCredentials(issued, deviceID: deviceID)
    guard credentials.userID == account.userID else { throw LocalE2EContractError.missingValue }
    return .init(accountHandle: account.accountHandle, credentials: credentials)
}

private func localIssuedCredentials(_ issued: [String: Any], deviceID: DeviceID) throws -> V2AuthCredentials {
    guard try DeviceID(requireLocalE2E(issued["deviceID"] as? String)) == deviceID else { throw LocalE2EContractError.missingValue }
    return try .init(
            userID: .init(requireLocalE2E(issued["userID"] as? String)), deviceID: deviceID,
            accessToken: requireLocalE2E(issued["accessToken"] as? String),
            accessTokenExpiresAt: Date(timeIntervalSince1970: requireLocalE2E(issued["accessTokenExpiresAtMilliseconds"] as? Double) / 1000),
            refreshCredential: requireLocalE2E(issued["refreshCredential"] as? String),
            revocationCredential: .init(rawValue: requireLocalE2E(issued["revocationCredential"] as? String)),
            revocationCredentialExpiresAt: Date(timeIntervalSince1970: requireLocalE2E(issued["revocationCredentialExpiresAtMilliseconds"] as? Double) / 1000)
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

func localCreateGroup(account: LocalE2EAccountCredentials, title: String, members: [UserID]) async throws
    -> (roomID: RoomID, title: String, memberCount: Int) {
    let client = try V2HTTPGroupCreationOperationClient(baseURL: #require(URL(string: "https://localhost:8443")),
        credentials: LocalE2EMessageCredentials(account: account), transport: LocalE2EMessageHTTP())
    let audience = try V2GroupCreationAudience.canonical(members, actorUserID: account.userID)
    let intent = try V2GroupCreationIntent(identity: .init(accountID: account.userID, scope: .account(account.userID),
        operation: .groupRoom(.init(uuid: UUID()))), title: title, capacityClass: .standard,
        initialMemberCount: audience.count, audienceDigest: V2GroupCreationAudience.digest(audience),
        firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000) + 600_000)
    _ = try await client.begin(intent)
    if !audience.isEmpty { _ = try await client.append(.init(intent: intent, offset: 0, memberUserIDs: audience)) }
    var result = try await client.finalize(intent)
    for _ in 0..<100 {
        if case .receipt = result { break }
        try await Task.sleep(for: .milliseconds(100))
        result = try await client.recover(intent, action: .query)
    }
    guard case .receipt(let proof) = result, proof.validates(intent: intent),
          case .created(let room, let createdTitle, _, let count) = proof.outcome else {
        throw LocalE2EMembershipFailure.noReceipt
    }
    return (room, createdTitle, count)
}

func localChangeMembership(account: LocalE2EAccountCredentials, roomID: RoomID, target: UserID,
    action: V2RoomMembershipAction, revision: UInt64) async throws -> V2MembershipApplied {
    let client = try V2HTTPMembershipOperationClient(baseURL: #require(URL(string: "https://localhost:8443")),
        credentials: LocalE2EMessageCredentials(account: account), transport: LocalE2EMessageHTTP())
    let intent = try V2MembershipIntent(roomID: roomID, actorUserID: account.userID, operationID: .init(uuid: UUID()),
        targetUserID: target, action: action, expectedMembershipRevision: revision,
        confirmedUntilMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000) + 120_000)
    guard case .admitted(let admission) = try await client.admit(intent) else { throw LocalE2EMembershipFailure.noAdmission }
    let command = try V2MembershipOperationCommand(intent: intent, admission: admission)
    guard case .receipt(let proof) = try await client.submit(command), proof.validates(command: command),
          case .changed(let applied) = proof.outcome else { throw LocalE2EMembershipFailure.noReceipt }
    return applied
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
    private func withRemote<Value: Sendable>(_ operation: (V2ProtobufMessageSendOperationClient) async throws -> Value) async throws -> Value {
        guard online else { throw V2MessageSendTransportError.unavailableBeforeSubmission }
        let connection = V2TLSFrameConnection(endpoint: try .init(host: "localhost", port: 7_443),
            frameLimits: try .init(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]))
        do {
            let session = try await connection.connectAndAuthenticate(accessToken: account.accessToken,
                deviceID: account.deviceID, supportedCapabilityProfiles: ["base"])
            guard session.userID == account.userID else { throw V2MessageSendTransportError.authenticationRequired }
            let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: session.protocolVersion)
            let value = try await operation(.init(transport: transport, connection: connection))
            await connection.disconnect(); return value
        } catch { await connection.disconnect(); throw error }
    }
    func submit(_ command: V2MessageSendOperationCommand) async throws -> V2MessageSendOperationRecoveryResult {
        let result = try await withRemote { try await $0.submit(command) }
        if case .receipt(let value) = result { receipt = value }
        return result
    }
    func recover(_ request: V2MessageSendOperationRecoveryRequest) async throws -> V2MessageSendOperationRecoveryResult {
        let result = try await withRemote { try await $0.recover(request) }
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

func localJSONRequest(endpoint: URL, body: [String: String], cancellation: V2DeviceRegistrationCancellation? = nil) async throws -> [String: Any] {
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

struct LocalE2EOpenedRoom {let roomID:RoomID}
func localOpenDirectRoom(account:LocalE2EAccountCredentials,target:UserID) async throws -> LocalE2EOpenedRoom {
    let client=try V2HTTPDirectRoomOperationClient(baseURL:#require(URL(string:"https://localhost:8443")),credentials:LocalE2EMessageCredentials(account:account),transport:LocalE2EMessageHTTP())
    let command=try V2DirectRoomOperationCommand(actorUserID:account.userID,operationID:.init(uuid:UUID()),targetUserID:target,firstSubmissionDeadlineMilliseconds:UInt64(Date().timeIntervalSince1970*1000)+600000)
    var result = try await client.submit(command)
    let deadline = ContinuousClock.now + .seconds(90)
    var reconciliationAttempt = 0
    while case .processing(let proof) = result {
        guard proof.validates(command: command), ContinuousClock.now < deadline else { throw LocalE2EMembershipFailure.noReceipt }
        let delay = V2NetworkWorkPolicy.acceptedResultPollDelay(attempt: reconciliationAttempt)
        try await Task.sleep(for: min(.seconds(delay), ContinuousClock.now.duration(to: deadline)))
        guard ContinuousClock.now < deadline else { throw LocalE2EMembershipFailure.noReceipt }
        reconciliationAttempt += 1
        result = try await client.recover(command, action: .query)
    }
    guard case .receipt(let receipt)=result,receipt.validates(command:command),case .opened(let room,_)=receipt.outcome else {throw LocalE2EMembershipFailure.noReceipt}
    return .init(roomID:room)
}

// Test-boundary credential storage; the issued credential remains authoritative.
private actor ACKCutCredentials: V2CredentialStore {
    var record: V2AuthCredentialRecord?
    init(_ value: V2AuthCredentials) { record = .init(credentials: value) }
    func load() -> V2AuthCredentialRecord? { record }
    func save(_ value: V2AuthCredentialRecord) { record = value }
    func delete() { record = nil }
}
private struct ACKCutNoRefresh: V2AuthTransport {
    func refresh(_ request: V2RefreshRequest) throws -> V2AuthCredentials { throw LocalE2EContractError.missingValue }
}
private struct ACKCutNoRevocation: V2DeviceRevocationScheduling {
    func enqueue(_ intent: V2DeviceRevocationIntent) throws { throw LocalE2EContractError.missingValue }
}
private actor ACKCutCoverage {
    private var states: [String: V2RealtimeCoverageState] = [:]
    func receive(_ value: V2RealtimeCoverageState) {
        let key = value.connectionGeneration.uuidString + ":" + String(value.scope.rawValue)
        states[key] = value
        if states.count > 16 { states = states.filter { $0.value.connectionGeneration == value.connectionGeneration } }
    }
    func ready(room: RoomID, excluding: UUID?, atLeast: UInt64) -> V2RealtimeCoverageState? {
        states.values.first { value in
            value.scope == .room && value.scopeID.lowercased() == room.rawValue.lowercased()
                && value.connectionGeneration != excluding && value.status == .ready && value.highWatermark >= atLeast
                && states.values.contains { $0.connectionGeneration == value.connectionGeneration && $0.scope == .account && $0.status == .ready }
        }
    }
}
private actor ACKCutObservedClient: V2MessageSendOperationClient {
    let base: V2RoutedMessageSendOperationClient
    var originalIdentity: V2OperationIdentity?
    var originalFingerprint: V2OperationFingerprint?
    private(set) var identitiesAreUnchanged = true
    private(set) var sawUnknown = false
    private(set) var recoveryCount = 0
    private(set) var receipt: V2MessageSendOperationReceipt?
    init(base: V2RoutedMessageSendOperationClient) { self.base = base }
    func submit(_ command: V2MessageSendOperationCommand) async throws -> V2MessageSendOperationRecoveryResult {
        let identity = try command.identity, fingerprint = try command.fingerprint
        if let originalIdentity { identitiesAreUnchanged = identitiesAreUnchanged && originalIdentity == identity && originalFingerprint == fingerprint }
        else { originalIdentity = identity; originalFingerprint = fingerprint }
        do { return record(try await base.submit(command)) }
        catch { if error as? V2MessageSendTransportError == .outcomeUnknown { sawUnknown = true }; throw error }
    }
    func recover(_ request: V2MessageSendOperationRecoveryRequest) async throws -> V2MessageSendOperationRecoveryResult {
        recoveryCount += 1
        identitiesAreUnchanged = identitiesAreUnchanged && originalIdentity == request.identity && originalFingerprint == request.fingerprint
        return record(try await base.recover(request))
    }
    private func record(_ result: V2MessageSendOperationRecoveryResult) -> V2MessageSendOperationRecoveryResult {
        if case .receipt(let value) = result { receipt = value }
        return result
    }
}
private func ackCutAwait(timeout: Duration = .seconds(90), _ condition: @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(try await condition()) {
        guard ContinuousClock.now < deadline else { throw LocalE2EContractError.missingValue }
        try await Task.sleep(for: .milliseconds(50))
    }
}
private func ackCutControl(port: UInt16, path: String, body: [String: Any]?) async throws -> [String: Any] {
    var request = URLRequest(url: try requireLocalE2E(URL(string: "http://localhost:\(port)\(path)")), timeoutInterval: 5)
    request.httpMethod = body == nil ? "GET" : "POST"
    if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
          let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LocalE2EContractError.missingValue }
    return value
}

/// Plain-text fixture uses the actual App preparation primitives. It creates no
/// operation records itself and never dispatches a request. Attachment/import
/// preparation remains outside this intentionally narrow fixture.
private func runACKCutPlainSendPreparation(store: GRDBV2LocalSyncStore) async throws {
    try await store.runResourcePreparation {
        for intent in try await store.duePreparedSendIntents() {
            try Task.checkCancellation()
            guard intent.attachmentJobIDs.isEmpty else { throw LocalE2EContractError.missingValue }
            do { _ = try await store.handOffSendIntent(intent.id) }
            catch is CancellationError { throw CancellationError() }
            catch { try await store.deferPreparedSendIntent(intent.id) }
        }
    }
}

@Suite("ACK-cut fixture durable preparation boundary")
struct ACKCutDurablePreparationBoundaryTests {
    @Test func createsExactWorkBeforeAnyNetworkSubmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ack-cut-preflight-\(UUID())", isDirectory: true)
        let accountID = try UserID(UUID().uuidString), room = try RoomID(UUID().uuidString)
        let store = try await V2LocalStoreBootstrapper(bindingStore: LocalE2EInstallationBindingStore())
            .open(databaseURL: directory.appendingPathComponent("local.sqlite"), userID: accountID)
        let client = ACKCutNeverSubmit()
        let service = V2MessageSendOperationService(accountID: accountID, store: store, client: client)
        let intentID = try await service.enqueueMessage(roomID: room, text: "real frozen preparation")
        let intent = try #require(try await store.preparingSendIntent(id: intentID))
        #expect(try await store.dueOperationWork(now: Date(), kinds: [.sendMessage]).isEmpty)
        let preparation = Task { try await runACKCutPlainSendPreparation(store: store) }
        do {
            try await ackCutAwait(timeout: .seconds(5)) {
                try await store.dueOperationWork(now: Date(), kinds: [.sendMessage]).contains { $0.intentID == intentID }
            }
            let work = try #require(try await store.dueOperationWork(now: Date(), kinds: [.sendMessage]).first { $0.intentID == intentID })
            let command = try await store.messageSendCommand(workID: work.id)
            #expect(command.command.clientMessageID == intent.clientMessageID)
            #expect(try command.identity == work.identity && command.fingerprint == work.fingerprint)
            #expect(try await store.preparingSendIntent(id: intentID) == nil)
            #expect(await client.calls == 0)
            preparation.cancel(); _ = await preparation.result
            try await store.close()
        } catch {
            preparation.cancel(); _ = await preparation.result
            try? await store.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        try? FileManager.default.removeItem(at: directory)
    }
}
private actor ACKCutNeverSubmit: V2MessageSendOperationClient {
    private(set) var calls = 0
    func submit(_ command: V2MessageSendOperationCommand) throws -> V2MessageSendOperationRecoveryResult {
        calls += 1; throw LocalE2EContractError.missingValue
    }
    func recover(_ request: V2MessageSendOperationRecoveryRequest) throws -> V2MessageSendOperationRecoveryResult {
        calls += 1; throw LocalE2EContractError.missingValue
    }
}
