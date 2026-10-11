@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit
import Testing
import Synchronization
import FluentKit

private struct TCPUnusedConversationCapabilities: V2GatewayConversationCapabilitiesHandling {
    func setConversationState(actorUserID: UserID, command: V2ConversationStateCommand) async throws -> V2PersonalPreferenceReceipt {
        throw V2RoomRecoveryReadError.invalidRequest
    }
    func setMessageFavorite(actorUserID: UserID, command: V2MessageFavoriteCommand) async throws -> V2PersonalPreferenceReceipt {
        throw V2RoomRecoveryReadError.invalidRequest
    }
}
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
@testable import IMV2ServerGateway

private struct ObservedAccountMembershipStates: V2RoomStateReading {
    let read: @Sendable ([RoomID], UserID) async throws -> [RoomID: V2RoomStateReadResult]
    func states(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomStateReadResult] {
        try await read(roomIDs, actorUserID)
    }
}

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("committed membership joins and exits update account routes without another directory scan",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"), arguments: [false, true])
    func postgresTargetedAccountMembership(trimControls: Bool) async throws {
        _ = try #require(ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"])
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let user = UserID(uuid: memberTwoUUID)
            try await sql.raw("DELETE FROM im_v2.room_memberships WHERE room_id=\(bind: roomID.uuidValue!) AND user_id=\(bind: memberTwoUUID)").run()
            try await sql.raw("CREATE TABLE IF NOT EXISTS im_v2.realtime_control_versions(topic_kind text NOT NULL,topic_id text NOT NULL,version bigint NOT NULL,membership_discovery_version bigint NOT NULL DEFAULT 0,session_control_version bigint NOT NULL DEFAULT 0,PRIMARY KEY(topic_kind,topic_id))").run()
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let journalSQL = try String(contentsOf: root.appending(path: "IMV2/sql/realtime-change-journal.sql"), encoding: .utf8)
            for statement in postgresStatements(in: journalSQL) {
                guard !statement.isEmpty, statement != "BEGIN", statement != "COMMIT" else { continue }
                try await sql.raw("\(unsafeRaw: statement)").run()
            }
            let journal = try PostgresV2RealtimeChangeJournalStore(database: database)
            let recovery = try PostgresV2RoomRecoveryStore(database: database)
            let topology = try PostgresV2RoomRecoveryTopology(database: database,
                stores: [recovery], orderedStoreIdentities: ["room-a"])
            let directory = V2UserRoomDirectoryService(topologySource: topology,
                cursorCodec: try .init(key: Data(repeating: 7, count: 32)))
            let scans = Mutex(0), references = Mutex<Set<UUID>>([])
            let reads = Mutex<[[RoomID: V2RoomStateReadResult]]>([])
            let service = try V2AccountRoomChangeService(states: ObservedAccountMembershipStates(read: { rooms, user in
                let result = try await recovery.states(roomIDs: rooms, actorUserID: user)
                reads.withLock { $0.append(result) }
                return result
            }),
                directoryPage: { user, cursor in
                    scans.withLock { $0 += 1 }
                    return try await directory.list(actorUserID: user, cursor: cursor, pageSize: 100)
                }, onlineDelivery: .init(activate: { _, _, reference in
                    references.withLock { $0.insert(reference) }
                }, deactivate: { reference in references.withLock { $0.remove(reference) } }))
            let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: try .init(maximumPayloadBytes: 4096,
                acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])), connection = UUID(), device = DeviceID(uuid: UUID())
            try await registry.installDeviceRoomProgressStore(PostgresV2DeviceRoomProgressStore(database: database))
            let ingress = try await registry.configureRoomSubscriptionIngress(authority: V2GatewayRoomSubscriptionAuthority())
            let socket = try V2GatewayJournalUserControlTests().stream(registry: registry, connection: connection)
            try #require(await registry.register(socket, connectionID: connection,
                identity: .init(userID: user, deviceID: device, capabilityProfile: "base"), publicationSuppressed: true))
            await registry.configureAccountRoomChanges(service)
            let deviceKeys = [V2RealtimeJournalDeviceKey(userID: memberTwoUUID, deviceID: device.uuidValue!)]
            let partition = V2RealtimeTopicKey(kind: .userSync, id: memberTwoUUID.uuidString.lowercased()).partitionID()
            let initialSnapshot = try await journal.userSnapshot(userIDs: [memberTwoUUID], deviceIDs: deviceKeys, partitionIDs: [partition])
            let identity = initialSnapshot.identity
            let source = V2RealtimeJournalSource(sourceID: "tcp-rooms", incarnationID: identity.databaseIncarnation, partitionID: partition)
            let captured = await registry.journalUserControlInterests()
            let recoverControl: V2GatewayJournalAuthorityIngress.RecoverControls = { batch, authenticatedService, _, controls in
                    try #require(authenticatedService == "owner" && batch.source == source)
                    let lease = try #require(try await journal.currentPublisherLease(partitionID: partition))
                    try #require(lease.token == batch.fence.sourceLeaseToken && lease.epoch == batch.fence.sourceLeaseEpoch)
                    try #require(lease.identity.incarnationID == batch.fence.publisherIncarnationID)
                    let snapshot = try await journal.userSnapshot(userIDs: [memberTwoUUID], deviceIDs: deviceKeys, partitionIDs: [partition])
                    let receipt = await registry.applyAuthoritativeUserControl(snapshot, source: source, expectedIdentity: identity,
                        isAuthenticationSource: false, minimumControlVersions: controls.versions, credentialChangedDeviceKeys: controls.devices,
                        membershipChangedRooms: controls.membershipRooms, membershipChangeVersions: controls.membershipVersions,
                        requested: captured, requestedAt: .now, deadline: .now + .seconds(5), isCurrent: { true })
                    try #require(receipt != nil)
                    if !controls.versions.isEmpty { try #require(receipt?.versions[user] == controls.versions[user]) }
            }
            let recoveryIngress = V2GatewayJournalAuthorityIngress(receiver: .init(projection: .init()),
                recoverControls: recoverControl, recover: { batch, service, minimum in
                    try await recoverControl(batch, service, minimum, .init())
                }, notify: { _ in })
            recoveryIngress.start()
            let router = try await TCPAccountClusterRouter.start(ingresses: [ingress], journalHandlers: [recoveryIngress])
            let claimed = try await journal.claim(partitionIDs: [partition],
                identity: await router.publisherIdentity(), token: UUID(), leaseDuration: 30)
            let lease = try #require(claimed.first)
            func applyMembershipControl(_ version: Int64) async throws {
                let published = try await journal.publishPending(lease: lease, limit: 128)
                let event = try #require(published.entries.first { $0.topicKind == "userSync"
                    && $0.topicID == memberTwoUUID.uuidString.lowercased() && $0.userControlVersion == version })
                let changedRoom = RoomID(uuid: try #require(event.membershipRoomID))
                try #require(changedRoom == roomID)
                try #require(event.changeKind == "membership.changed")
                if trimControls {
                    try await journal.trim(lease: lease, through: published.publishedThrough)
                    let replay = try await journal.replay(partitionID: partition, after: event.sequence - 1, limit: 128)
                    try #require(replay.requiresSnapshot && replay.entries.isEmpty)
                }
                try #require(try await router.sendMembership(user: user, room: changedRoom, gateway: 0,
                    version: UInt64(version), source: source, sequence: event.sequence, sourceLease: lease, coldBaseline: trimControls) == .snapshotRequired)
            }
            do {
                let ticket = try await service.begin(userID: user, connectionID: connection, send: { _ in true }, close: {})
                try await service.bootstrap(ticket)
                #expect(references.withLock { $0.isEmpty })
                try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision) VALUES(\(bind: roomID.uuidValue!),\(bind: memberTwoUUID),0)").run()
                try await applyMembershipControl(1)
                let joinDeadline = ContinuousClock.now + .seconds(2)
                while references.withLock({ $0.isEmpty }), .now < joinDeadline { try await Task.sleep(for: .milliseconds(1)) }
                try #require(references.withLock { $0.count } == 1)
                try await sql.raw("DELETE FROM im_v2.room_memberships WHERE room_id=\(bind: roomID.uuidValue!) AND user_id=\(bind: memberTwoUUID)").run()
                try await applyMembershipControl(2)
                let exitDeadline = ContinuousClock.now + .seconds(2)
                while (references.withLock({ !$0.isEmpty }) || (!trimControls && reads.withLock({ $0.count < 2 }))), .now < exitDeadline {
                    try await Task.sleep(for: .milliseconds(1))
                }
                if trimControls {
                    #expect(reads.withLock { $0.isEmpty })
                    #expect(scans.withLock { $0 } == 3)
                } else {
                    #expect(reads.withLock { $0.count } == 2)
                    #expect(reads.withLock { $0.last?[roomID] } == .unavailable)
                    #expect(scans.withLock { $0 } == 1)
                }
                #expect(references.withLock { $0.isEmpty })
                await service.shutdown()
                await router.stop()
                await recoveryIngress.shutdown()
                await registry.unregister(connectionID: connection)
                await socket.closeForAccountRecovery()
                await registry.shutdownRealtimeRecovery()
            } catch {
                await service.shutdown()
                await router.stop()
                await recoveryIngress.shutdown()
                await registry.unregister(connectionID: connection)
                await socket.closeForAccountRecovery()
                await registry.shutdownRealtimeRecovery()
                throw error
            }
        }
    }

    @Test("a durable send automatically reaches both recipient devices through the Owner and remote Gateway",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"),
          arguments: [false, true])
    func durableSendAutomaticRecipientCoverage(loseCommitNotification: Bool) async throws {
        _ = try #require(ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"])
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            try await sql.raw("CREATE TABLE IF NOT EXISTS im_v2.realtime_control_versions(topic_kind text NOT NULL,topic_id text NOT NULL,version bigint NOT NULL,membership_discovery_version bigint NOT NULL DEFAULT 0,session_control_version bigint NOT NULL DEFAULT 0,PRIMARY KEY(topic_kind,topic_id))").run()
            if loseCommitNotification {
                let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
                let source = try String(contentsOf: root.appending(path: "IMV2/sql/realtime-change-journal.sql"), encoding: .utf8)
                for statement in postgresStatements(in: source) {
                    guard !statement.isEmpty, statement != "BEGIN", statement != "COMMIT" else { continue }
                    try await sql.raw("\(unsafeRaw: statement)").run()
                }
            }
            let recipient = UserID(uuid: memberTwoUUID)
            let dirtyHeads = try PostgresV2RoomSubscriptionDirtyHeadStore(database: database)
            let host = V2RoomSubscriptionHost(checkInterval: loseCommitNotification ? .milliseconds(50) : .seconds(3_600),
                dirtyChanges: { host, cursor, limit, deadline in
                    if loseCommitNotification { return try await dirtyHeads.pending(host: host, after: cursor, limit: limit, deadline: deadline) }
                    return .init(changes: [], nextCursor: nil)
                }, dirtyAcknowledge: { heads, deadline in
                    if loseCommitNotification { try await dirtyHeads.acknowledge(heads, deadline: deadline) }
                })
            let facts = V2RoomCommittedFactsFeed(notify: { host.signal(room: $0) })
            host.install(feed: facts)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let store = v2FixtureMessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                    contentReviewMode: .disabled).usingControlDatabase(database), clock: { now },
                committedMessageObserver: loseCommitNotification ? nil : facts)
            let recovery = try PostgresV2RoomRecoveryStore(database: database)
            let topology = try PostgresV2RoomRecoveryTopology(database: database,
                stores: [recovery], orderedStoreIdentities: ["room-a"])
            let directory = V2UserRoomDirectoryService(topologySource: topology,
                cursorCodec: try .init(key: Data(repeating: 7, count: 32)))
            let key = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 71, count: 32))
            try await withRoomActivation(database: database, roomID: roomID) { token in
                let source = try PostgresV2RoomSubscriptionSource(database: database, activation: token)
                let owner = try await V2RoomSubscriptionOwner.restore(source: source, roomID: roomID,
                    owner: token.owner, activation: token, deadline: .now + .seconds(5), trackedUserIDs: [recipient],
                    notifyChanged: { host.signal(gateway: .init(roomID: roomID, gateway: $0)) })
                let authentications = Mutex(0)
                do {
                    try await V2AccountDeliveryTCPTests().exercise(
                        store: PostgresV2DeviceRoomProgressStore(database: database), user: recipient, rooms: [roomID],
                        actorRouting: true, automaticAccountCoverage: true, automaticOwner: (owner, token),
                        automaticHost: host,
                        directoryPage: { user, cursor in
                            try await directory.list(actorUserID: user, cursor: cursor, pageSize: 100)
                        },
                        messageCommands: .init(messageSendOperations: V2RoomRefMessagingClient(callTimeout: try .init(5_000)) { request, principal, deadline in
                            guard case .messaging(.sendOperation(let command)) = request,
                                  principal == (try command.identity.accountID), deadline > .now else {
                                throw V2RoomCallFailure.outcomeUnknown
                            }
                            let result = try await store.send(command, token: token, capacityProfile: profile,
                                identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())))
                            return .messaging(.sendOperation(result))
                        }, messageLimits: try .init(maxUTF8Bytes: 64), conversationCapabilities: TCPUnusedConversationCapabilities()),
                        commitOnline: { port in
                            let command = try V2MessageSendOperationCommand(command: .init(roomID: roomID,
                                senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "automatic recipient delivery",
                                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
                            let device = DeviceID(uuid: UUID()), accessToken = UUID().uuidString
                            let issued = Date(), expires = issued.addingTimeInterval(3_600)
                            try await sql.raw("INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at,session_expires_at) VALUES(\(bind: senderID.uuidValue!),\(bind: device.uuidValue!),\(bind: issued),\(bind: issued),\(bind: expires))").run()
                            try await sql.raw("INSERT INTO im_v2.device_access_tokens(token_hmac,user_id,device_id,issued_at,expires_at) VALUES(\(bind: key.digest(accessToken)),\(bind: senderID.uuidValue!),\(bind: device.uuidValue!),\(bind: issued),\(bind: expires))").run()
                            let result = try await V2AccountDeliveryTCPTests().sendOperationOverTCP(port: port,
                                token: accessToken, device: device, command: command)
                            guard case .receipt(let receipt) = result, case .accepted(let accepted) = receipt.outcome else {
                                throw V2RoomWriteStoreError.corruptPersistenceState
                            }
                            let page = try await source.read(roomID: roomID, owner: token.owner,
                                afterRoomSequence: 0, trackedUserIDs: [recipient], limit: 64)
                            let record = try #require(page.records.first)
                            try #require(record.hasOnlineBody)
                            try #require(record.event.roomSequence == accepted.roomSequence)
                            return record.event
                        }, authenticator: ObservedPostgresGatewayAuthenticator(underlying: V2PostgresGatewayAuthenticator(database: database, tokenKey: key),
                            observed: { authentications.withLock { $0 += 1 } }),
                        credentials: { device in
                            let token = UUID().uuidString, issued = Date(), expires = issued.addingTimeInterval(3_600)
                            try await sql.raw("INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at,session_expires_at) VALUES(\(bind: recipient.uuidValue!),\(bind: device.uuidValue!),\(bind: issued),\(bind: issued),\(bind: expires))").run()
                            try await sql.raw("INSERT INTO im_v2.device_access_tokens(token_hmac,user_id,device_id,issued_at,expires_at) VALUES(\(bind: key.digest(token)),\(bind: recipient.uuidValue!),\(bind: device.uuidValue!),\(bind: issued),\(bind: expires))").run()
                            return token
                        })
                    #expect(authentications.withLock { $0 } == 3)
                    await host.close()
                    try await owner.close()
                } catch { await host.close(); try? await owner.close(); throw error }
            }
        }
    }

    @Test("committed send remains readable by a replacement subscription source without online publication",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"), arguments: [false, true])
    func committedSendSurvivesMissingOnlinePublication(actualCrash: Bool) async throws {
        _ = try #require(ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"])
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            // The room-write fixture installs the core schema without this journal extension.
            try await sql.raw("CREATE TABLE IF NOT EXISTS im_v2.realtime_control_versions(topic_kind text NOT NULL,topic_id text NOT NULL,version bigint NOT NULL,membership_discovery_version bigint NOT NULL DEFAULT 0,session_control_version bigint NOT NULL DEFAULT 0,PRIMARY KEY(topic_kind,topic_id))").run()
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let store = v2FixtureMessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                    contentReviewMode: .disabled).usingControlDatabase(database), clock: { now })
            let command = try V2MessageSendOperationCommand(command: .init(roomID: roomID,
                senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "committed without push",
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            let before = try await withRoomActivation(database: database, roomID: roomID) { token in
                let source = try PostgresV2RoomSubscriptionSource(database: database, activation: token)
                let baseline = try await source.snapshot(roomID: roomID, owner: token.owner, trackedUserIDs: [senderID])
                if actualCrash {
                    try await crashCommittedSend(token: token)
                    return (baseline.highWatermark, token)
                }
                let result = try await store.send(command, token: token, capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())))
                guard case .receipt(let receipt) = result, case .accepted = receipt.outcome else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                // Deliberately omit every in-memory commit notification.
                return (baseline.highWatermark, token)
            }
            try await withRoomActivation(database: database, roomID: roomID) { token in
                let replacement = try PostgresV2RoomSubscriptionSource(database: database, activation: token)
                let snapshot = try await replacement.snapshot(roomID: roomID, owner: token.owner, trackedUserIDs: [senderID])
                let page = try await replacement.read(roomID: roomID, owner: token.owner,
                    afterRoomSequence: before.0, trackedUserIDs: [senderID], limit: 64)
                #expect(snapshot.highWatermark == before.0 + 1)
                #expect(page.highWatermark == snapshot.highWatermark)
                #expect(page.records.count == 1)
                #expect(page.records.first?.hasOnlineBody == true)
                #expect(page.records.first?.event.highWatermark == snapshot.highWatermark)
                let record = try #require(page.records.first)
                let member = try #require(snapshot.members.first { $0.userID == senderID && $0.authorized })
                let key = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 71, count: 32))
                let authenticatedUser = senderID
                try await V2AccountDeliveryTCPTests().exercise(
                    store: PostgresV2DeviceRoomProgressStore(database: database), user: senderID, rooms: [roomID],
                    committed: (token, record.event, .init(userID: member.userID, memberRevision: member.memberRevision)),
                    separateGateways: true, actorRouting: true, retiredActivation: actualCrash ? before.1 : nil,
                    authenticator: V2PostgresGatewayAuthenticator(database: database, tokenKey: key),
                    credentials: { device in
                        let token = UUID().uuidString, issued = Date(), expires = issued.addingTimeInterval(3_600)
                        try await sql.raw("INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at,session_expires_at) VALUES(\(bind: authenticatedUser.uuidValue!),\(bind: device.uuidValue!),\(bind: issued),\(bind: issued),\(bind: expires))").run()
                        try await sql.raw("INSERT INTO im_v2.device_access_tokens(token_hmac,user_id,device_id,issued_at,expires_at) VALUES(\(bind: key.digest(token)),\(bind: authenticatedUser.uuidValue!),\(bind: device.uuidValue!),\(bind: issued),\(bind: expires))").run()
                        return token
                    })
            }
        }
    }

    private func crashCommittedSend(token: V2RoomActivationToken) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "imv2-commit-crash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appending(path: "activation.json")
        try JSONEncoder().encode(token).write(to: input)
        let process = Process(), host = URL(fileURLWithPath: CommandLine.arguments[0])
        let binary = try #require(Bundle(for: CommitCrashBundleMarker.self).executableURL)
        try #require(host.lastPathComponent == "swiftpm-testing-helper")
        process.executableURL = host
        process.arguments = ["--test-bundle-path", binary.path, binary.path,
            "--testing-library", "swift-testing", "--filter", "committedSendCrashChild"]
        var environment = ProcessInfo.processInfo.environment
        environment["IMV2_COMMITTED_SEND_CRASH_SPEC"] = input.path
        process.environment = environment
        let log = root.appending(path: "child.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardOutput = output; process.standardError = output
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled && process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        try #require(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL)
        try #require(String(contentsOf: input.appendingPathExtension("checkpoint"), encoding: .utf8) == "committed-before-notification")
        print("Committed send SIGKILL evidence: " + root.path)
    }

    @Test("isolated process dies at committed send observer before publication",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_COMMITTED_SEND_CRASH_SPEC"] != nil))
    func committedSendCrashChild() async throws {
        let input = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["IMV2_COMMITTED_SEND_CRASH_SPEC"]))
        let token = try JSONDecoder().decode(V2RoomActivationToken.self, from: Data(contentsOf: input))
        try #require(ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1")
        let url = try #require(ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"])
        let resources = makeV2DatabaseTestResources()
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
        let database = resources.database(.psql), now = Date(timeIntervalSince1970: 1_750_000_000)
        let observer = CommitCrashObserver(checkpoint: input.appendingPathExtension("checkpoint"))
        let store = v2FixtureMessageSendOperationStore(database: database,
            writes: PostgresV2RoomWriteStore(database: database,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                contentReviewMode: .disabled).usingControlDatabase(database), clock: { now },
            committedMessageObserver: observer)
        let command = try V2MessageSendOperationCommand(command: .init(roomID: token.roomID,
            senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "committed without push",
            limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
        _ = try await store.send(command, token: token, capacityProfile: forwardImportTestProfile(),
            identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())))
        Issue.record("The committed observer must terminate this process")
        try await resources.shutdown()
    }
    @Test("durable sendOperation batch ignores retired shard command credits")
    func durableSendBatchRespectsCumulativeShardCapacity() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools
                SET command_window_limit = 1, command_window_used = 0,
                    valid_until = \(bind: now.addingTimeInterval(600))
                WHERE room_shard_id = 'room-a'
                  AND capacity_profile_id = (SELECT capacity_profile_id FROM im_v2.rooms WHERE room_id = \(bind: roomID.uuidValue!))
                """).run()
            let store = v2FixtureMessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                    contentReviewMode: .disabled).usingControlDatabase(database), clock: { now })
            let deadline = UInt64(now.timeIntervalSince1970 * 1000) + 60_000
            func command(_ text: String) throws -> V2MessageSendOperationCommand {
                try .init(command: .init(roomID: roomID, senderUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: text,
                    limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: deadline)
            }
            let batch = try [command("capacity one"), command("capacity two")]
            let results = try await withRoomActivation(database: database, roomID: roomID) { token in
                try await store.sendBatch(batch, token: token, capacityProfile: profile,
                    identifiers: .init(), now: { now })
            }
            #expect(results.count == 2)
            for result in results {
                guard case .sendOperation(.receipt(let accepted)) = result,
                      case .accepted = accepted.outcome else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
            }
            let pool = try await sql.raw("""
                SELECT command_window_used AS count FROM im_v2.shard_admission_pools
                WHERE room_shard_id = 'room-a'
                  AND capacity_profile_id = (SELECT capacity_profile_id FROM im_v2.rooms WHERE room_id = \(bind: roomID.uuidValue!))
                """).first(decoding: SendRollbackCount.self)
            #expect(pool?.count == 0)
            for item in batch {
                let completions = try await sql.raw("""
                    SELECT count(*) AS count FROM im_v2.message_send_completions
                    WHERE room_id = \(bind: roomID.uuidValue!) AND sender_user_id = \(bind: senderUUID)
                      AND client_message_id = \(bind: item.command.clientMessageID.uuidValue!)
                    """).first(decoding: SendRollbackCount.self)
                #expect(completions?.count == 1)
            }
        }
    }

    @Test("durable sendOperation batch tail failure rolls back provisional acceptance")
    func durableSendBatchTailFailureRollsBackAcceptedWrites() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools
                SET command_window_limit = 10, command_window_used = 0,
                    valid_until = \(bind: now.addingTimeInterval(600))
                WHERE room_shard_id = 'room-a'
                  AND capacity_profile_id = (SELECT capacity_profile_id FROM im_v2.rooms WHERE room_id = \(bind: roomID.uuidValue!))
                """).run()
            try await sql.raw("""
                CREATE FUNCTION im_v2.fixture_reject_shard_admission_tail() RETURNS trigger
                LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected message persistence lock failure' USING ERRCODE='55P03'; END $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER fixture_reject_shard_admission_tail
                BEFORE INSERT ON im_v2.messages
                FOR EACH ROW EXECUTE FUNCTION im_v2.fixture_reject_shard_admission_tail()
                """).run()
            let store = v2FixtureMessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                    contentReviewMode: .disabled).usingControlDatabase(database), clock: { now })
            let deadline = UInt64(now.timeIntervalSince1970 * 1000) + 60_000
            let acceptedCandidate = try V2MessageSendOperationCommand(command: .init(roomID: roomID,
                senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "tail rollback",
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: deadline)
            let expired = try V2MessageSendOperationCommand(command: .init(roomID: roomID,
                senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "expired before body",
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1)
            try await withRoomActivation(database: database, roomID: roomID) { token in
                await #expect(throws: V2RoomCallFailure.rolledBack(.unavailable)) {
                    try await store.sendBatch([acceptedCandidate, acceptedCandidate, expired], token: token,
                        capacityProfile: profile, identifiers: .init(), now: { now })
                }
            }
            let messageCount = try await sql.raw("""
                SELECT count(*) AS count FROM im_v2.message_send_completions
                WHERE room_id = \(bind: roomID.uuidValue!) AND sender_user_id = \(bind: senderUUID)
                  AND client_message_id = \(bind: acceptedCandidate.command.clientMessageID.uuidValue!)
                """).first(decoding: SendRollbackCount.self)
            #expect(messageCount?.count == 0)
            let acceptedReceiptCount = try await sql.raw("""
                SELECT count(*) AS count FROM im_v2.message_send_completions
                WHERE room_id = \(bind: roomID.uuidValue!) AND sender_user_id = \(bind: senderUUID)
                  AND client_message_id = \(bind: acceptedCandidate.command.clientMessageID.uuidValue!)
                """).first(decoding: SendRollbackCount.self)
            #expect(acceptedReceiptCount?.count == 0)
            let expiredReceiptCount = try await sql.raw("""
                SELECT count(*) AS count FROM im_v2.message_send_completions
                WHERE room_id = \(bind: roomID.uuidValue!) AND sender_user_id = \(bind: senderUUID)
                  AND client_message_id = \(bind: expired.command.clientMessageID.uuidValue!)
                """).first(decoding: SendRollbackCount.self)
            #expect(expiredReceiptCount?.count == 0)
            try await sql.raw("DROP TRIGGER fixture_reject_shard_admission_tail ON im_v2.messages").run()
            try await sql.raw("DROP FUNCTION im_v2.fixture_reject_shard_admission_tail()").run()
        }
    }

    @Test("send execution v1 recovers committed results and leaves absent identities retryable",arguments:[false,true])
    func permanentMessageSendReceipts(direct:Bool) async throws {
        try await withForwardOwnerDatabases(mode:.standard) { database,_,sql,_,_ in
            let now=Date(timeIntervalSince1970:1_750_000_000),profile=try forwardImportTestProfile()
            let operationRoom=direct ? RoomID(uuid:UUID()) : roomID
            if direct {
                _ = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                    roomShardID: "room-a", roomID: operationRoom, now: { now }).openedReceipt(
                        actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                        firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
            }
            let leases=PostgresV2RoomActivationStore(database:database)
            let owner=try V2RoomDataOwner(shardID:"room-a",epoch:0)
            guard case .acquired(let lease)=try await leases.acquire(roomID:operationRoom,owner:owner,host:.init(hostID:.init("send-receipts"),incarnationID:UUID()),duration:.init(30_000)) else { throw CancellationError() }
            let store=v2FixtureMessageSendOperationStore(database:database,writes:PostgresV2RoomWriteStore(database:database,strangerMessagePolicy:try .init(maximumMessagesPerWindow:100,window:86_400),contentReviewMode:.disabled).usingControlDatabase(database),clock:{now})
            let deadline=UInt64(now.timeIntervalSince1970*1000)+60_000
            func command(_ text:String,operation:ClientMessageID = .init(uuid:UUID()),deadlineMS:UInt64? = nil) throws -> V2MessageSendOperationCommand {
                try .init(command:.init(roomID:operationRoom,senderUserID:senderID,clientMessageID:operation,text:text,limits:.init(maxUTF8Bytes:64)),firstSubmissionDeadlineMilliseconds:deadlineMS ?? deadline)
            }
            func recovery(_ command:V2MessageSendOperationCommand) throws -> V2MessageSendOperationRecoveryRequest {
                try .init(identity:command.identity,fingerprint:command.fingerprint,domainFingerprint:command.command.fingerprint)
            }
            let first=try command("Accepted")
            #expect(try first.fingerprint.version==1 && first.command.fingerprint.version==3)
            guard case .receipt(let original)=try await store.send(first,token:lease.token,capacityProfile:profile,identifiers:.init(messageID:.init(uuid:UUID()),eventID:.init(uuid:UUID()))) else { throw CancellationError() }
            guard case .accepted(let accepted)=original.outcome else { throw CancellationError() }
            let batch = try [command("Batch one"), command("Batch two")]
            let batchResults = try await store.sendBatch(batch, token: lease.token, capacityProfile: profile,
                identifiers: .init(), now: { now })
            #expect(batchResults.count == 2)
            for (command, result) in zip(batch, batchResults) {
                guard case .sendOperation(.receipt(let receipt)) = result else { throw CancellationError() }
                #expect(receipt.identity == (try command.identity))
                guard case .accepted = receipt.outcome else { throw CancellationError() }
            }
            #expect(try await store.sendBatch(batch, token: lease.token, capacityProfile: profile,
                identifiers: .init(), now: { now }) == batchResults)
            // The protobuf Gateway command and JSON HTTP command must reach the
            // same durable operation key and return the original receipt.
            let gatewayCommand = try V2MessageSendOperationWireCodec.decode(
                command: V2MessageSendOperationWireCodec.encode(command: first))
            let httpCommand = try JSONDecoder().decode(V2MessageSendOperationCommand.self,
                from: JSONEncoder().encode(first))
            #expect(gatewayCommand == httpCommand)
            #expect(try await store.send(gatewayCommand,token:lease.token,capacityProfile:profile,
                identifiers:.init(messageID:.init(uuid:UUID()),eventID:.init(uuid:UUID()))) == .receipt(original))
            let gatewayRecovery = try V2MessageSendOperationWireCodec.decode(recovery:
                V2MessageSendOperationWireCodec.encode(recovery: recovery(first)))
            #expect(try await store.recover(gatewayRecovery,token:lease.token) == .receipt(original))
            #expect(try await store.send(first,token:lease.token,capacityProfile:profile,identifiers:.init(messageID:.init(uuid:UUID()),eventID:.init(uuid:UUID()))) == .receipt(original))
            #expect(try await store.recover(recovery(first),token:lease.token) == .receipt(original))
            let deadlineChanged = try command("Accepted", operation: first.command.clientMessageID, deadlineMS: deadline + 1)
            #expect(try await store.recover(recovery(deadlineChanged),token:lease.token) == .fingerprintConflict)
            let changed=try command("Changed",operation:first.command.clientMessageID)
            #expect(try await store.send(changed,token:lease.token,capacityProfile:profile,identifiers:.init(messageID:.init(uuid:UUID()),eventID:.init(uuid:UUID()))) == .fingerprintConflict)
            let expired=try command("Expired",deadlineMS:deadline-120_000)
            guard case .receipt(let expiredReceipt)=try await store.send(expired,token:lease.token,capacityProfile:profile,identifiers:.init(messageID:.init(uuid:UUID()),eventID:.init(uuid:UUID()))) else { throw CancellationError() }
            #expect(expiredReceipt.outcome == .rejected(.expiredUnsubmitted))
            #expect(try await store.recover(recovery(expired),token:lease.token) == .unresolved)
            let pending=try command("Unsubmitted")
            #expect(try await store.recover(recovery(pending),token:lease.token) == .unresolved)
            guard case .receipt(let laterReceipt) = try await store.send(pending,token:lease.token,capacityProfile:profile,
                identifiers:.init(messageID:.init(uuid:UUID()),eventID:.init(uuid:UUID()))),
                  case .accepted = laterReceipt.outcome else { throw CancellationError() }
            #expect(try await store.recover(recovery(pending),token:lease.token) == .receipt(laterReceipt))
            for _ in 0..<4 {
                let racing=try command("Race")
                async let send=store.send(racing,token:lease.token,capacityProfile:profile,identifiers:.init(messageID:.init(uuid:UUID()),eventID:.init(uuid:UUID())))
                async let query=store.recover(recovery(racing),token:lease.token)
                let (submitted,observed)=try await(send,query)
                #expect(observed == .unresolved || submitted == observed)
                #expect(try await store.recover(recovery(racing),token:lease.token) == submitted)
            }
            if direct {
                let limited=v2FixtureMessageSendOperationStore(database:database,writes:PostgresV2RoomWriteStore(database:database,strangerMessagePolicy:try .init(maximumMessagesPerWindow:1,window:86_400),contentReviewMode:.disabled).usingControlDatabase(database),clock:{now})
                let quota=try command("Quota")
                guard case .deferred(let quotaHint)=try await limited.send(quota,token:lease.token,capacityProfile:profile,identifiers:.init(messageID:.init(uuid:UUID()),eventID:.init(uuid:UUID()))) else { throw CancellationError() }
                #expect(quotaHint.reason == .rateLimited)
                // Admission can defer before the stranger window is consulted.
                let retryAfter = try #require(quotaHint.retryAfterMilliseconds)
                #expect(retryAfter > 0 && retryAfter <= 86_400_000)
                #expect(try quotaHint.validates(identity:quota.identity,fingerprint:quota.fingerprint))
                #expect(try await limited.recover(recovery(quota),token:lease.token) == .unresolved)
                #expect(try await limited.recover(recovery(quota),token:lease.token) == .unresolved)
                #expect(try await count("pg_catalog.pg_class WHERE oid=to_regclass('im_v2.direct_authorization_intents')", on: sql) == 0)
                #expect(try await count("pg_catalog.pg_class WHERE oid=to_regclass('im_v2.direct_authorization_receipts')", on: sql) == 0)
            }
            // Body retention cannot erase the minimal original acceptance identity.
            try await sql.raw("UPDATE im_v2.messages SET text_body='Retained replacement',content_revision=content_revision+1 WHERE message_id=\(bind:accepted.messageID.uuidValue!)").run()
            #expect(try await store.recover(recovery(first),token:lease.token) == .receipt(original))
            try await sql.raw("CREATE FUNCTION im_v2.fixture_receipt_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture failure' USING ERRCODE='23514'; END $$").run()
            try await sql.raw("CREATE TRIGGER fixture_receipt_failure BEFORE INSERT ON im_v2.message_send_completions FOR EACH ROW EXECUTE FUNCTION im_v2.fixture_receipt_failure()").run()
            let rolledBack=try command("Rollback")
            await #expect(throws:(any Error).self) { _ = try await store.send(rolledBack,token:lease.token,capacityProfile:profile,identifiers:.init(messageID:.init(uuid:UUID()),eventID:.init(uuid:UUID()))) }
            let countRow=try await sql.raw("SELECT count(*) AS count FROM im_v2.message_send_completions WHERE client_message_id=\(bind:rolledBack.command.clientMessageID.uuidValue!)").first(decoding:SendRollbackCount.self)
            #expect(countRow?.count==0)
            let batchRollback = try [command("Batch rollback one"), command("Batch rollback two")]
            await #expect(throws: (any Error).self) {
                _ = try await store.sendBatch(batchRollback, token: lease.token, capacityProfile: profile,
                    identifiers: .init(), now: { now })
            }
            for item in batchRollback {
                let batchCount = try await sql.raw("SELECT count(*) AS count FROM im_v2.message_send_completions WHERE client_message_id=\(bind:item.command.clientMessageID.uuidValue!)").first(decoding: SendRollbackCount.self)
                #expect(batchCount?.count == 0)
                let completionCount = try await sql.raw("SELECT count(*) AS count FROM im_v2.message_send_completions WHERE client_message_id=\(bind:item.command.clientMessageID.uuidValue!)").first(decoding: SendRollbackCount.self)
                #expect(completionCount?.count == 0)
            }
            try await sql.raw("DROP TRIGGER fixture_receipt_failure ON im_v2.message_send_completions").run()
            try await sql.raw("DROP FUNCTION im_v2.fixture_receipt_failure()").run()
            await #expect(throws:(any Error).self) { try await sql.raw("DELETE FROM im_v2.message_send_completions WHERE sender_user_id=\(bind:senderUUID)").run() }
        }
    }
}

private struct SendRollbackCount:Decodable { let count:Int64 }

private struct ObservedPostgresGatewayAuthenticator: V2GatewayAuthenticator {
    let underlying: V2PostgresGatewayAuthenticator
    let observed: @Sendable () -> Void
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        observed()
        return try await underlying.authenticateSession(accessToken: accessToken, deviceID: deviceID)
    }
}

private final class CommitCrashBundleMarker: NSObject {}
private struct CommitCrashObserver: V2CommittedMessageBatchObserving {
    let checkpoint: URL
    func observeCommittedMessages(_ outcomes: [V2SendMessageOutcome], activation: V2RoomActivationToken) {
        guard !outcomes.isEmpty else { return }
        do {
            try Data("committed-before-notification".utf8).write(to: checkpoint)
        } catch { fatalError("Cannot record committed crash checkpoint") }
        kill(getpid(), SIGKILL)
        fatalError("SIGKILL must terminate the child")
    }
}
