@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Crypto
import FluentKit
import FluentPostgresDriver
import Foundation
import HTTPTypes
import IMV2Core
import IMV2ServerHTTP
import PostgresNIO
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Synchronization
import Testing
import Vapor
import VaporTesting

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("Account disable validates required revision changes without suppressing inactive-profile results",
          arguments: ["policy", "profile", "visibility", "suspended", "deleted", "absent"])
    func accountDisableRevisionBoundary(path: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let user = path == "absent" ? UUID() : senderUUID
            let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: database),
                dispatcher: .init(database: database, projectionDelivery: SuccessfulProjectionDelivery()))
            let service = try V2PostgresAccountDisableService(operatorPrincipal: "revision-maintenance", policyOwners: owners)
            let command = try V2AccountDisableCommand(userID: .init(uuid: user), operationID: UUID(), reason: .userRequested)
            if path == "suspended" || path == "deleted" {
                try await sql.raw("UPDATE im_v2.public_user_profiles SET state = \(bind: path), revision = \(bind: Int64.max), visibility_revision = \(bind: Int64.max) WHERE user_id = \(bind: user)").run()
            }
            let needsChange = ["policy", "profile", "visibility"].contains(path)
            let table = path == "policy" ? "user_direct_send_policy_versions" : "public_user_profiles"
            let column = path == "visibility" ? "visibility_revision" : "revision"
            if path == "policy" {
                try await sql.raw("INSERT INTO im_v2.user_direct_send_policy_versions (user_id, revision, updated_at) VALUES (\(bind: user), \(bind: Int64.max), \(bind: now)) ON CONFLICT (user_id) DO UPDATE SET revision = EXCLUDED.revision").run()
            } else if needsChange {
                try await sql.raw("UPDATE im_v2.public_user_profiles SET \(unsafeRaw: column) = \(bind: Int64.max) WHERE user_id = \(bind: user)").run()
            }
            func snapshot() async throws -> [String] {
                var rows: [String] = []
                for name in ["account_disables", "user_direct_send_policy_versions", "public_user_profiles", "public_profile_update_outbox",
                    "auth_devices", "device_refresh_sessions", "device_access_tokens", "device_revocation_events"] {
                    guard let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: name) r").first(decoding: StringValueRow.self) else { throw CancellationError() }
                    rows.append(row.value)
                }
                return rows
            }
            let before = try await snapshot()
            if needsChange {
                for _ in 0..<2 {
                    await #expect(throws: V2AccountDisableError.unavailable) { try await service.disable(command) }
                    #expect(try await snapshot() == before)
                }
                try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET \(unsafeRaw: column) = \(bind: Int64.max - 1) WHERE user_id = \(bind: user)").run()
            }
            guard case .disabled(let committedAt) = try await service.disable(command) else {
                Issue.record("Expected current policy owner to disable account")
                await owners.shutdown()
                return
            }
            #expect(try await count("im_v2.account_disables", on: sql) == 1)
            #expect(try await count("im_v2.public_profile_update_outbox", on: sql) == (needsChange ? 1 : 0))
            if needsChange {
                #expect(try await sql.raw("SELECT \(unsafeRaw: column) AS value FROM im_v2.\(unsafeRaw: table) WHERE user_id = \(bind: user)").first(decoding: CountRow.self)?.value == Int64.max)
                #expect(try await sql.raw("SELECT state AS value FROM im_v2.public_user_profiles WHERE user_id = \(bind: user)").first(decoding: StringValueRow.self)?.value == "suspended")
            } else if path != "absent" {
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.public_user_profiles WHERE user_id = \(bind: user) AND state = \(bind: path) AND revision = \(bind: Int64.max) AND visibility_revision = \(bind: Int64.max)").first(decoding: CountRow.self)?.value == 1)
            }
            let committed = try await snapshot()
            let other = try V2AccountDisableCommand(userID: command.userID, operationID: UUID(), reason: .userRequested)
            for _ in 0..<2 {
                #expect(try await service.disable(command) == .idempotent(disabledAt: committedAt))
                #expect(try await service.disable(other) == .alreadyDisabled(disabledAt: committedAt))
                #expect(try await snapshot() == committed)
            }
            await owners.shutdown()
        }
    }

    @Test("Account disable returns its database commit timestamp consistently on first response and replay")
    func accountDisableResponseTimestampPrecision() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: database),
                dispatcher: .init(database: database, projectionDelivery: SuccessfulProjectionDelivery()))
            let service = try V2PostgresAccountDisableService(operatorPrincipal: "timestamp-maintenance", policyOwners: owners)
            let command = try V2AccountDisableCommand(userID: senderID, operationID: UUID(), reason: .userRequested)
            let before = Date()
            let outcome = try await service.disable(command)
            let persisted = try #require(try await sql.raw("SELECT disabled_at AS value FROM im_v2.account_disables WHERE operation_id = \(bind: command.operationID)").first(decoding: RevocationClockDateRow.self)).value
            #expect(outcome == .disabled(disabledAt: persisted))
            #expect(persisted >= before && persisted <= Date())
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.account_disables d JOIN im_v2.public_profile_update_outbox o ON o.source_event_id=d.operation_id JOIN im_v2.public_user_profiles p ON p.user_id=d.user_id JOIN im_v2.user_direct_send_policy_versions v ON v.user_id=d.user_id WHERE d.operation_id=\(bind: command.operationID) AND o.profile_updated_at=d.disabled_at AND o.created_at=d.disabled_at AND p.updated_at=d.disabled_at AND v.updated_at=d.disabled_at").first(decoding: CountRow.self)?.value == 1)
            let other = try V2AccountDisableCommand(userID: senderID, operationID: UUID(), reason: .userRequested)
            for _ in 0..<3 {
                let retry = try V2PostgresAccountDisableService(operatorPrincipal: "timestamp-maintenance", policyOwners: owners)
                #expect(try await retry.disable(command) == .idempotent(disabledAt: persisted))
                #expect(try await retry.disable(other) == .alreadyDisabled(disabledAt: persisted))
            }
            #expect(try await count("im_v2.account_disables", on: sql) == 1)
            #expect(try await count("im_v2.public_profile_update_outbox", on: sql) == 1)
            await owners.shutdown()
        }
    }

    @Test("Policy owner account disable rolls back partial writes and commits concurrent retries once")
    func accountDisableClockBounds() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: database),
                dispatcher: .init(database: database, projectionDelivery: SuccessfulProjectionDelivery()))
            let service = try V2PostgresAccountDisableService(operatorPrincipal: "clock-maintenance", policyOwners: owners)
            let command = try V2AccountDisableCommand(userID: senderID, operationID: UUID(), reason: .userRequested)
            let otherOperation = try V2AccountDisableCommand(userID: senderID, operationID: UUID(), reason: .userRequested)
            let conflicting = try V2AccountDisableCommand(userID: .init(uuid: memberTwoUUID), operationID: command.operationID, reason: .userRequested)
            func snapshot() async throws -> String {
                try #require(try await sql.raw("""
                    SELECT jsonb_build_object(
                        'disables', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id) FROM im_v2.account_disables r),
                        'profiles', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id) FROM im_v2.public_user_profiles r),
                        'policy', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id) FROM im_v2.user_direct_send_policy_versions r),
                        'updates', (SELECT jsonb_agg(to_jsonb(r) ORDER BY source_event_id) FROM im_v2.public_profile_update_outbox r),
                        'devices', (SELECT count(*) FROM im_v2.auth_devices),
                        'refresh', (SELECT count(*) FROM im_v2.device_refresh_sessions),
                        'access', (SELECT count(*) FROM im_v2.device_access_tokens),
                        'revocations', (SELECT count(*) FROM im_v2.device_revocation_events)
                    )::text AS value
                    """).first(decoding: StringValueRow.self)).value
            }
            let initial = try await snapshot()
            // A downstream persistence failure also rolls back the disable
            // record and policy update before a retry commits exactly once.
            try await sql.raw("CREATE FUNCTION im_v2.fail_disable_profile_update() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test profile update failure'; END $$").run()
            try await sql.raw("CREATE TRIGGER fail_disable_profile_update BEFORE INSERT ON im_v2.public_profile_update_outbox FOR EACH ROW EXECUTE FUNCTION im_v2.fail_disable_profile_update()").run()
            await #expect(throws: (any Error).self) { _ = try await service.disable(command) }
            #expect(try await snapshot() == initial)
            try await sql.raw("DROP TRIGGER fail_disable_profile_update ON im_v2.public_profile_update_outbox").run()
            try await sql.raw("DROP FUNCTION im_v2.fail_disable_profile_update()").run()
            let results = try await withThrowingTaskGroup(of: V2AccountDisableOutcome.self) { group in
                for _ in 0..<8 { group.addTask { try await service.disable(command) } }
                var results: [V2AccountDisableOutcome] = []
                for try await result in group { results.append(result) }
                return results
            }
            let committedAt = try #require(results.compactMap { result -> Date? in
                if case .disabled(let date) = result { return date }
                return nil
            }.first)
            #expect(results.count == 8)
            #expect(results.filter { $0 == .disabled(disabledAt: committedAt) }.count == 1)
            #expect(results.filter { $0 == .idempotent(disabledAt: committedAt) }.count == 7)
            #expect(try await count("im_v2.account_disables", on: sql) == 1)
            #expect(try await count("im_v2.public_user_profiles WHERE state = 'suspended'", on: sql) == 1)
            #expect(try await count("im_v2.public_profile_update_outbox", on: sql) == 1)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.account_disables WHERE user_id = \(bind: senderUUID) AND disabled_at = \(bind: committedAt)").first(decoding: CountRow.self)?.value == 1)
            let committed = try await snapshot()
            for _ in 0..<3 {
                #expect(try await service.disable(command) == .idempotent(disabledAt: committedAt))
                #expect(try await service.disable(otherOperation) == .alreadyDisabled(disabledAt: committedAt))
                await #expect(throws: V2AccountDisableError.operationConflict) { _ = try await service.disable(conflicting) }
                #expect(try await snapshot() == committed)
            }
            for user in [memberTwoUUID, memberThreeUUID] {
                let next = try V2AccountDisableCommand(userID: .init(uuid: user), operationID: UUID(), reason: .userRequested)
                guard case .disabled(let date) = try await service.disable(next) else {
                    Issue.record("Each account must be disabled independently")
                    await owners.shutdown()
                    return
                }
                #expect(try await service.disable(next) == .idempotent(disabledAt: date))
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.account_disables WHERE user_id=\(bind: user) AND disabled_at=\(bind: date)").first(decoding: CountRow.self)?.value == 1)
            }
            #expect(try await count("im_v2.account_disables", on: sql) == 3)
            #expect(try await count("im_v2.public_profile_update_outbox", on: sql) == 3)
            #expect(try await count("im_v2.auth_devices", on: sql) == 0)
            #expect(try await count("im_v2.device_refresh_sessions", on: sql) == 0)
            #expect(try await count("im_v2.device_access_tokens", on: sql) == 0)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 0)
            await owners.shutdown()
        }
    }

    @Test("owner writes complete with separate one-connection control and owner pools",
          .timeLimit(.minutes(1)), arguments: [false, true])
    func routedDirectControlPools(colocated: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { _, _, _, _, groupRoom in
            let primary = try #require(Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"))
            let secondary = try #require(Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"))
            let resources = makeV2DatabaseTestResources()
            do {
                let controlID = DatabaseID(string: "send-authority")
                resources.databases.use(try .postgres(url: secondary, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
                resources.databases.use(try .postgres(url: colocated ? secondary : primary, maxConnectionsPerEventLoop: 1), as: controlID)
                let owner = resources.database(.psql), control = resources.database(controlID)
                let sql = try #require(control as? any SQLDatabase)
                let now = Date(), profile = try forwardImportTestProfile()
                let ownerSQL = try #require(owner as? any SQLDatabase)
                try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until = \(bind: now.addingTimeInterval(600))").run()
                try await ownerSQL.raw("UPDATE im_v2.shard_admission_pools SET valid_until = \(bind: now.addingTimeInterval(600))").run()
                let recipient = UserID(uuid: memberTwoUUID)
                let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner, identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()),
                    capacityProfile: profile, roomShardID: "room-b", now: { now })
                let room = try await direct.openedIdentity(actorUserID: senderID,
                    operationID: .init(uuid: UUID()), targetUserID: recipient, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                for id in [room.roomID, groupRoom] {
                    try await sql.raw("""
                        INSERT INTO im_v2.room_owner_routes(room_id, room_shard_id, route_epoch, created_at, updated_at)
                        VALUES (\(bind: id.uuidValue!), 'room-b', 0, \(bind: now), \(bind: now)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id = EXCLUDED.room_shard_id, route_epoch = EXCLUDED.route_epoch, updated_at = EXCLUDED.updated_at
                """).run()
                }
                try await withFixturePolicyOwners(database: control, projectionDelivery: SuccessfulProjectionDelivery()) { owners in
                try await withRoomActivation(database: owner, roomID: groupRoom, shardID: "room-b", epoch: 0) { groupToken in
                try await withRoomActivation(database: owner, roomID: room.roomID, shardID: "room-b", epoch: 0) { directToken in
                let scope = try V2RoomActivationWriteScope(tokens: [groupToken, directToken])
                let write = V2PolicyAuthorizedTestWriteStore(database: owner, controlDatabase: control,
                    store: PostgresV2RoomWriteStore(database: owner).usingControlDatabase(control),
                    shardID: "room-b", epoch: 0, activationScope: scope, policyOwners: owners)
                // The concurrent calls share the granted activation; the fixture never
                // creates competing actors or keeps a SQL connection while loading policy.
                let service = V2SendMessageService(store: write, capacityProfile: profile,
                    limits: try .init(maxUTF8Bytes: 64), now: { now })
                guard case .accepted = try await service.send(.init(roomID: groupRoom, actorUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "group stays on owner")) else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                async let first = service.send(.init(roomID: room.roomID, actorUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "first"))
                async let second = service.send(.init(roomID: room.roomID, actorUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "second"))
                let results = try await [first, second]
                #expect(results.allSatisfy { if case .accepted = $0 { true } else { false } })
                _ = try await PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(), policyOwners: owners)
                    .executeSocialFixture(actorUserID: recipient, targetUserID: senderID, operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now:  now)
                await #expect(throws: V2SendOperationResponseError.directPolicyDenied) {
                    _ = try await service.send(.init(roomID: room.roomID, actorUserID: senderID,
                        clientMessageID: .init(uuid: UUID()), text: "blocked"))
                }
                }
                }
                }
                try await resources.shutdown()
            } catch {
                try? await resources.shutdown()
                throw error
            }
        }
    }

    @Test("direct forward imports enforce control blocks and preserve terminal replay")
    func directForwardControlAuthority() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, controlSQL, ownerSQL, _ in
            try await withFixturePolicyOwners(database: control, projectionDelivery: SuccessfulProjectionDelivery()) { owners in
            let now = Date(), profile = try forwardImportTestProfile()
            for sql in [controlSQL, ownerSQL] {
                try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=\(bind: now.addingTimeInterval(600))").run()
            }
            let limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let actor = UserID(uuid: memberTwoUUID), recipient = UserID(uuid: memberThreeUUID)
            let sourceSend = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: control, controlDatabase: control,
                store: PostgresV2RoomWriteStore(database: control).usingControlDatabase(control), shardID: "room-a", epoch: 0),
                capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let message) = try await sourceSend.send(.init(roomID: roomID, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "forward control")) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner, identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: profile, roomShardID: "room-b", now: { now })
            let room = try await direct.openedIdentity(actorUserID: actor,
                operationID: .init(uuid: UUID()), targetUserID: recipient, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let exports = PostgresV2ForwardExportStore(database: control)
            @Sendable func prepare() async throws -> V2ForwardExport {
                try await exports.prepare(actorUserID: actor, operationID: .init(uuid: UUID()),
                    source: .init(roomID: roomID, messageID: message.messageID, revision: .init(1)),
                    sourceRoute: .init(shardID: "room-a", epoch: 0), targetRoomID: room.roomID,
                    targetRoute: .init(shardID: "room-b", epoch: 0), now: now)
            }
            let write = V2PolicyAuthorizedTestWriteStore(database: owner, controlDatabase: control,
                store: PostgresV2RoomWriteStore(database: owner).usingControlDatabase(control).usingWorkloadDatabase(owner), shardID: "room-b", epoch: 0, policyOwners: owners)
            @Sendable func receive(_ value: V2ForwardExport) async throws -> V2ForwardImportOutcome {
                try await write.importForwardExport(value, capacityProfile: profile, limits: limits,
                    identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
            }
            let original = try await prepare(), accepted = try await receive(original)
            guard case .accepted = accepted else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let social = PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(), policyOwners: owners)
            _ = try await social.executeSocialFixture(actorUserID: recipient, targetUserID: actor, operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now:  now)
            #expect(try await receive(original) == accepted)
            let blocked = try await prepare(), denied = try await receive(blocked)
            guard case .rejected = denied else { throw V2RoomWriteStoreError.corruptPersistenceState }
            #expect(try await count("im_v2.messages", on: ownerSQL) == 1)
            #expect(try await count("im_v2.user_blocks", on: ownerSQL) == 0)
            _ = try await social.executeSocialFixture(actorUserID: recipient, targetUserID: actor, operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.unblock), now:  now)
            #expect(try await receive(blocked) == denied)
            guard case .accepted = try await receive(prepare()) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            #expect(try await count("im_v2.messages", on: ownerSQL) == 2)
            }
        }
    }

    @Test("Independent direct room turns apply control authority without rolling back another room",
          arguments: [false, true])
    func directBatchControlAuthority(blockedFirst: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, _, ownerSQL, _ in
            let now = Date(), profile = try forwardImportTestProfile()
            try await ownerSQL.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes'").run()
            let recipients = [UserID(uuid: memberTwoUUID), UserID(uuid: memberThreeUUID)]
            let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner,
                identityReader: PostgresV2DirectRoomIdentityReader(database: control),
                projectionDelivery: SuccessfulProjectionDelivery()), capacityProfile: profile,
                roomShardID: "room-b", now: { now })
            var opened: [RoomID] = []
            for recipient in recipients {
                let room = try await direct.openedIdentity(actorUserID: senderID,
                    operationID: .init(uuid: UUID()), targetUserID: recipient,
                    firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                opened.append(room.roomID)
            }
            let rooms = opened
            try await withRoomActivation(database: owner, roomID: rooms[0], shardID: "room-b") { firstToken in
                try await withRoomActivation(database: owner, roomID: rooms[1], shardID: "room-b") { secondToken in
                    let tokens = [firstToken, secondToken]
                    try await withFixturePolicyOwners(database: control,
                        projectionDelivery: SuccessfulProjectionDelivery()) { owners in
                        let policies = V2RoomPolicyAuthorizationService(roomDatabase: owner,
                            policyOwners: owners, endpoint: "independent-control-test", maximumRooms: 2)
                        do {
                            let writes = PostgresV2RoomWriteStore(database: owner,
                                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 20, window: 86_400),
                                contentReviewMode: .disabled).usingControlDatabase(control).usingPolicyAuthorizations(policies)
                            let store = PostgresV2MessageSendOperationStore(database: owner, writes: writes)
                            @Sendable func requests(reversed: Bool = false) throws -> [V2MessageSendOperationCommand] {
                                try (reversed ? Array(rooms.reversed()) : rooms).map { room in
                                    try .init(command: .init(roomID: room, senderUserID: senderID,
                                        clientMessageID: .init(uuid: UUID()), text: "control authority",
                                        limits: .init(maxUTF8Bytes: 64)),
                                        firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                                }
                            }
                            @Sendable func send(_ command: V2MessageSendOperationCommand) async throws -> V2MessageSendOperationRecoveryResult {
                                let index = try #require(rooms.firstIndex(of: command.command.roomID))
                                return try await store.send(command, token: tokens[index], capacityProfile: profile,
                                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())))
                            }
                            @Sendable func sendAll(_ commands: [V2MessageSendOperationCommand]) async throws -> [V2MessageSendOperationRecoveryResult] {
                                var results: [V2MessageSendOperationRecoveryResult] = []
                                for command in commands { results.append(try await send(command)) }
                                return results
                            }
                            for _ in 0..<2 {
                                for result in try await sendAll(requests()) {
                                    guard case .receipt(let receipt) = result, case .accepted = receipt.outcome else {
                                        Issue.record("warm-up failed"); throw CancellationError()
                                    }
                                }
                            }
                            let forwardInputs = try requests(), reverseInputs = try requests(reversed: true)
                            async let forward = sendAll(forwardInputs)
                            async let reverse = sendAll(reverseInputs)
                            let concurrent = try await forward + reverse
                            #expect(concurrent.count == 4)
                            for result in concurrent {
                                guard case .receipt(let receipt) = result, case .accepted = receipt.outcome else {
                                    Issue.record("concurrent room turn rejected"); throw CancellationError()
                                }
                            }
                            let before = try await count("im_v2.messages", on: ownerSQL)
                            let blockedIndex = blockedFirst ? 0 : 1
                            let social = PostgresV2SocialRelationshipStore(database: control,
                                projectionDelivery: SuccessfulProjectionDelivery(), policyOwners: owners)
                            _ = try await social.executeSocialFixture(actorUserID: recipients[blockedIndex], targetUserID: senderID,
                                operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now: Date())
                            #expect(try await count("im_v2.user_blocks", on: ownerSQL) == 0)
                            let inputs = try requests()
                            let results = try await sendAll(inputs)
                            guard case .receipt(let rejection) = results[blockedIndex],
                                  case .receipt(let success) = results[1 - blockedIndex], case .accepted = success.outcome else {
                                Issue.record("room outcomes were not independent"); throw CancellationError()
                            }
                            #expect(rejection.outcome == .rejected(.directPolicyDenied))
                            #expect(try await count("im_v2.messages", on: ownerSQL) == before + 1)
                            #expect(try await retiredDirectDenialTableIsAbsent(on: ownerSQL))
                            let input = inputs[blockedIndex]
                            let recovery = try await store.recover(.init(identity: input.identity, fingerprint: input.fingerprint,
                                domainFingerprint: input.command.fingerprint), token: tokens[blockedIndex])
                            #expect(recovery == .unresolved)
                            _ = try await social.executeSocialFixture(actorUserID: recipients[blockedIndex], targetUserID: senderID,
                                operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.unblock), now: Date())
                            let restored = try await sendAll(inputs)
                            guard case .receipt(let retry) = restored[blockedIndex], case .accepted = retry.outcome else {
                                Issue.record("same identity retry failed"); throw CancellationError()
                            }
                            #expect(restored[1 - blockedIndex] == results[1 - blockedIndex])
                            #expect(try await count("im_v2.messages", on: ownerSQL) == before + 2)
                            #expect(try await count("im_v2.message_send_completions", on: ownerSQL) == before + 2)
                            #expect(try await retiredDirectDenialTableIsAbsent(on: ownerSQL))
                            await policies.shutdown()
                        } catch {
                            await policies.shutdown()
                            throw error
                        }
                    }
                }
            }
        }
    }

    @Test("actual direct sends refresh control authority despite stale owner policies", arguments:
        ["block", "concurrent-block", "relationship", "preference", "disable-sender", "disable-recipient"], [false, true])
    func directSendControlAuthority(kind: String, warm: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, _, ownerSQL, _ in
            let now = Date()
            let recipient = UserID(uuid: memberTwoUUID), profile = try forwardImportTestProfile()
            try await ownerSQL.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes'").run()
            try await withFixturePolicyOwners(database: control,
                projectionDelivery: SuccessfulProjectionDelivery()) { owners in
            if kind == "relationship" {
                @Sendable func seedFriendship(_ database: any Database, _ policyOwners: PostgresV2PolicyOwnerDirectory) async throws {
                    let store = PostgresV2SocialRelationshipStore(database: database,
                        projectionDelivery: SuccessfulProjectionDelivery(), policyOwners: policyOwners)
                    _ = try await store.executeSocialFixture(actorUserID: senderID, targetUserID: recipient,
                        operation: .relationship(.init(uuid: UUID())), action: .relationship(.request), now: now)
                    _ = try await store.executeSocialFixture(actorUserID: recipient, targetUserID: senderID,
                        operation: .relationship(.init(uuid: UUID())), action: .relationship(.accept), now: now)
                }
                try await seedFriendship(control, owners)
                try await withFixturePolicyOwners(database: owner,
                    projectionDelivery: SuccessfulProjectionDelivery()) { ownerPolicies in
                    try await seedFriendship(owner, ownerPolicies)
                }
                _ = try await PostgresV2AccountPreferenceOperationStore(database: control,
                    projectionDelivery: SuccessfulProjectionDelivery(), policyOwners: owners)
                    .executePreferenceFixture(owner: recipient,
                        operation: .strangerMessagePreference(.init(uuid: UUID())),
                        value: .strangerMessage(.deny), now: now)
            }
            let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner, identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: profile, roomShardID: "room-b", now: { now })
            let room = try await direct.openedIdentity(actorUserID: senderID,
                operationID: .init(uuid: UUID()), targetUserID: recipient, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            try await withRoomActivation(database: owner, roomID: room.roomID, shardID: "room-b") { token in
                    let social = PostgresV2SocialRelationshipStore(database: control,
                        projectionDelivery: SuccessfulProjectionDelivery(), policyOwners: owners)
                    let preferences = PostgresV2AccountPreferenceOperationStore(database: control,
                        projectionDelivery: SuccessfulProjectionDelivery(), policyOwners: owners)
                    let policies = V2RoomPolicyAuthorizationService(roomDatabase: owner, policyOwners: owners,
                        endpoint: "control-authority-test", maximumRooms: 1)
                    do {
                        let writes = PostgresV2RoomWriteStore(database: owner,
                            strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
                            contentReviewMode: .disabled).usingControlDatabase(control).usingPolicyAuthorizations(policies)
                        let writer = PostgresV2MessageSendOperationStore(database: owner, writes: writes)
                        @Sendable func request() throws -> V2MessageSendOperationCommand {
                            try .init(command: .init(roomID: room.roomID, senderUserID: senderID,
                                clientMessageID: .init(uuid: UUID()), text: "control authority",
                                limits: .init(maxUTF8Bytes: 64)),
                                firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                        }
                        @Sendable func send(_ input: V2MessageSendOperationCommand) async throws -> V2MessageSendOperationRecoveryResult {
                            try await writer.send(input, token: token, capacityProfile: profile,
                                identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())))
                        }
                        let original = try request()
                        let accepted = try await send(original)
                        guard case .receipt(let acceptedReceipt) = accepted, case .accepted = acceptedReceipt.outcome else {
                            Issue.record("expected initial acceptance"); throw CancellationError()
                        }
                        if warm {
                            for _ in 0..<2 {
                                guard case .receipt(let receipt) = try await send(request()), case .accepted = receipt.outcome else {
                                    Issue.record("warm send rejected"); throw CancellationError()
                                }
                            }
                        }
                        if kind == "concurrent-block" {
                            let gate = PostgreSQLTransactionGate()
                            let holder = Task {
                                try await owner.transaction { transaction in
                                    let heldSQL = try #require(transaction as? any SQLDatabase)
                                    try await heldSQL.raw("SELECT room_id FROM im_v2.rooms WHERE room_id = \(bind: room.roomID.uuidValue!) FOR UPDATE").run()
                                    await gate.holdTransaction()
                                }
                            }
                            await gate.waitUntilHeld()
                            let input = try request()
                            let pending = Task { try await send(input) }
                            @Sendable func waitForLock(_ database: any SQLDatabase, query: String) async throws -> Bool {
                                for _ in 0..<500 {
                                    let waiting = try await database.raw("""
                                        SELECT count(*) AS value FROM pg_stat_activity WHERE datname = current_database()
                                        AND wait_event_type = 'Lock' AND query LIKE \(bind: query)
                                        """).first(decoding: CountRow.self)?.value ?? 0
                                    if waiting > 0 { return true }
                                    try await Task.sleep(for: .milliseconds(10))
                                }
                                return false
                            }
                            do {
                                #expect(try await waitForLock(ownerSQL, query: "%im_v2.rooms%"))
                                let revocation = Task {
                                    try await social.executeSocialFixture(actorUserID: recipient, targetUserID: senderID, operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now:  now)
                                }
                                do {
                                    await gate.releaseTransaction()
                                    try await holder.value
                                    let outcome = try await pending.value
                                    guard case .receipt(let receipt) = outcome else {
                                        Issue.record("concurrent send did not resolve"); throw CancellationError()
                                    }
                                    guard case .accepted = receipt.outcome else {
                                        Issue.record("already admitted send did not commit"); throw CancellationError()
                                    }
                                    _ = try await revocation.value
                                } catch {
                                    revocation.cancel()
                                    await gate.releaseTransaction()
                                    _ = await revocation.result
                                    throw error
                                }
                            } catch {
                                pending.cancel()
                                await gate.releaseTransaction()
                                _ = await holder.result
                                _ = await pending.result
                                throw error
                            }
                        }
                        let before = try await count("im_v2.messages", on: ownerSQL)
                        switch kind {
                        case "concurrent-block": break
                        case "block":
                            _ = try await social.executeSocialFixture(actorUserID: recipient, targetUserID: senderID, operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now:  now)
                        case "relationship":
                            _ = try await social.executeSocialFixture(actorUserID: recipient, targetUserID: senderID, operation: .relationship(.init(uuid: UUID())), action: .relationship(.remove), now:  now)
                        case "preference":
                            _ = try await preferences.executePreferenceFixture(owner: recipient, operation: .strangerMessagePreference(.init(uuid: UUID())), value: .strangerMessage(.deny), now: now)
                        default:
                            _ = try await V2PostgresAccountDisableService(operatorPrincipal: "send-policy-test", policyOwners: owners)
                                .disable(.init(userID: kind == "disable-sender" ? senderID : recipient,
                                    operationID: UUID(), reason: .userRequested))
                        }
                        // Durable owner copies deliberately remain permissive, including warm-cache revisions.
                        #expect(try await count("im_v2.user_blocks", on: ownerSQL) == 0)
                        #expect(try await count("im_v2.account_disables", on: ownerSQL) == 0)
                        if kind == "relationship" {
                            #expect(try await ownerSQL.raw("SELECT count(*) AS value FROM im_v2.user_relationships WHERE state = 'accepted'")
                                .first(decoding: CountRow.self)?.value == 1)
                        }
                        let replay = try await send(original)
                        #expect(replay == accepted)
                        let deniedRequest = try request()
                        guard case .receipt(let rejection) = try await send(deniedRequest) else {
                            Issue.record("control revocation ignored"); throw CancellationError()
                        }
                        #expect(rejection.outcome == .rejected(kind == "disable-sender" ? .permissionDenied : .directPolicyDenied))
                        let recovery = try await writer.recover(.init(identity: deniedRequest.identity,
                            fingerprint: deniedRequest.fingerprint, domainFingerprint: deniedRequest.command.fingerprint), token: token)
                        #expect(recovery == .unresolved)
                        #expect(try await count("im_v2.messages", on: ownerSQL) == before)
                        #expect(try await count("im_v2.message_send_completions", on: ownerSQL) == before)
                        #expect(try await retiredDirectDenialTableIsAbsent(on: ownerSQL))
                        if kind == "block" || kind == "concurrent-block" {
                            _ = try await social.executeSocialFixture(actorUserID: recipient, targetUserID: senderID,
                                operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.unblock), now: Date())
                        } else if kind == "relationship" || kind == "preference" {
                            _ = try await preferences.executePreferenceFixture(owner: recipient,
                                operation: .strangerMessagePreference(.init(uuid: UUID())), value: .strangerMessage(.allow), now: Date())
                        }
                        if kind != "disable-sender" && kind != "disable-recipient" {
                            let retried = try await send(deniedRequest)
                            guard case .receipt(let receipt) = retried, case .accepted = receipt.outcome else {
                                Issue.record("same identity permission retry failed"); throw CancellationError()
                            }
                            #expect(try await send(deniedRequest) == retried)
                            #expect(try await count("im_v2.messages", on: ownerSQL) == before + 1)
                            #expect(try await count("im_v2.message_send_completions", on: ownerSQL) == before + 1)
                            #expect(try await retiredDirectDenialTableIsAbsent(on: ownerSQL))
                        }
                        await policies.shutdown()
                    } catch {
                        await policies.shutdown()
                        throw error
                    }
                }
            }
        }
    }

    @Test("Special-account audit clocks preserve message retries and concurrent recording", arguments: [V2AccountKind.system, .customerSupport])
    func specialAccountMessageClockBounds(kind: V2AccountKind) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let controlResources = makeV2DatabaseTestResources()
            let identityPoolID = DatabaseID(string: "special-audit-identity")
            let routePoolID = DatabaseID(string: "special-audit-route")
            let primary = try #require(Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"))
            controlResources.databases.use(try .postgres(url: primary, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            controlResources.databases.use(try .postgres(url: primary, maxConnectionsPerEventLoop: 4), as: identityPoolID)
            // The pair-route fence holds a transaction across the handoff call.
            // Waiting route transactions must not occupy the handoff's pool.
            controlResources.databases.use(try .postgres(url: primary, maxConnectionsPerEventLoop: 4), as: routePoolID)
            let control = controlResources.database(.psql)
            let identityDatabase = controlResources.database(identityPoolID)
            do {
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let customer = UserID(uuid: memberTwoUUID)
            let profile = try forwardImportTestProfile()
            try await sql.raw("UPDATE im_v2.public_user_profiles SET account_kind = \(bind: kind.rawValue) WHERE user_id = \(bind: senderUUID)").run()
            try await sql.raw("INSERT INTO im_v2.special_accounts (account_user_id, stable_key, account_kind, allows_customer_messages, allows_service_messages, created_at, updated_at) VALUES (\(bind: senderUUID), 'clock_special_account', \(bind: kind.rawValue), \(bind: kind == .customerSupport), true, \(bind: base), \(bind: base))").run()
            let store = PostgresV2SpecialAccountMessagingStore(database: database)
            let account = try #require(try await store.resolveActiveAccount(stableKey: "clock_special_account"))
            let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: identityDatabase), projectionDelivery: SuccessfulProjectionDelivery()), capacityProfile: profile, roomShardID: "room-a", now: { base })
            let opened = try await direct.openedIdentity(actorUserID: customer, operationID: .init(uuid: UUID()), targetUserID: senderID, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(base))
            let messages = try V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0), capacityProfile: profile, limits: .init(maxUTF8Bytes: 64), now: { base.addingTimeInterval(1) })
            if kind == .customerSupport {
                guard case .accepted = try await messages.send(.init(roomID: opened.roomID, actorUserID: customer, clientMessageID: .init(uuid: UUID()), text: "support request")) else { throw V2SpecialAccountMessagingError.corruptPersistenceState }
                #expect(try await count("im_v2.support_conversation_sessions WHERE state = 'open'", on: sql) == 1)
            }
            let clock = TestSequenceClock([base])
            let bootstrap = try V2RoomBootstrapDomainExecutor(shardID: "room-a", direct: direct.store,
                group: PostgresV2GroupMessagingStore(database: database), capacityProfile: profile, now: { base })
            let bootstrapPort = V2ActorCreationBootstrapPort(execute: { command, _ in try await bootstrap.execute(command) },
                stage: { intent, page, _ in try await bootstrap.stage(intent: intent, page: page) })
            let directOperations = PostgresV2DirectRoomOperationStore(database: control,
                routes: V2PostgresRoomShardRouter(database: controlResources.database(routePoolID)), selector: try .init(shardIDs: ["room-a"]), bootstrap: bootstrapPort)
            let service = V2TrustedSpecialAccountMessagingService(store: store, directMessaging: directOperations, messages: messages, now: { clock.now() })
            func request(operation: ClientMessageID = .init(uuid: UUID()), fingerprint: String = "1234567890abcdef") throws -> V2TrustedSpecialAccountMessage {
                try .init(stableAccountKey: "clock_special_account", servicePrincipal: "clock-service", operatorID: kind == .customerSupport ? "clock-operator" : nil, operationID: operation, requestFingerprint: fingerprint, firstSubmissionDeadlineMilliseconds: UInt64(base.timeIntervalSince1970 * 1000) + 600_000, customerUserID: customer, text: "service message")
            }
            let original = try request()
            func snapshot() async throws -> String {
                try #require(try await sql.raw("""
                    SELECT jsonb_build_object(
                        'operations', (SELECT jsonb_agg(to_jsonb(r) ORDER BY operation_id) FROM im_v2.special_account_message_operations r),
                        'audit', (SELECT jsonb_agg(to_jsonb(r) ORDER BY message_id) FROM im_v2.special_account_message_audit r),
                        'messages', (SELECT jsonb_agg(to_jsonb(r) ORDER BY message_id) FROM im_v2.messages r),
                        'events', (SELECT jsonb_agg(to_jsonb(r) ORDER BY event_id) FROM im_v2.room_events r),
                        'direct_operations', (SELECT jsonb_agg(to_jsonb(r) ORDER BY actor_user_id, operation_id) FROM im_v2.direct_room_operation_handoffs r),
                        'sessions', (SELECT jsonb_agg(to_jsonb(r) ORDER BY room_id) FROM im_v2.support_conversation_sessions r),
                        'admission', (SELECT jsonb_agg(to_jsonb(r) ORDER BY room_id) FROM im_v2.room_admission r),
                        'shard', (SELECT to_jsonb(r) FROM im_v2.shard_admission_pools r WHERE room_shard_id = 'room-a')
                    )::text AS value
                    """).first(decoding: StringValueRow.self)).value
            }
            let badClocks = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            var awaitingAudit: String?
            for bad in badClocks {
                // Keep admission time valid; this loop injects the audit clock failure.
                clock.set([base, bad])
                await #expect(throws: V2SpecialAccountMessagingError.corruptPersistenceState) { _ = try await service.send(original) }
                #expect(try await count("im_v2.messages", on: sql) == (kind == .customerSupport ? 2 : 1))
                #expect(try await count("im_v2.special_account_message_operations", on: sql) == 0)
                #expect(try await count("im_v2.special_account_message_audit", on: sql) == 0)
                let state = try await snapshot()
                if let awaitingAudit { #expect(state == awaitingAudit) }
                else { awaitingAudit = state }
            }
            // A failure of the second insert must roll back the operation row,
            // while the independently accepted customer-visible message remains.
            clock.set([base.addingTimeInterval(2)])
            try await sql.raw("CREATE FUNCTION im_v2.fail_special_message_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test audit failure'; END $$").run()
            try await sql.raw("CREATE TRIGGER fail_special_message_audit BEFORE INSERT ON im_v2.special_account_message_audit FOR EACH ROW EXECUTE FUNCTION im_v2.fail_special_message_audit()").run()
            await #expect(throws: (any Error).self) { _ = try await service.send(original) }
            #expect(try await snapshot() == awaitingAudit)
            try await sql.raw("DROP TRIGGER fail_special_message_audit ON im_v2.special_account_message_audit").run()
            try await sql.raw("DROP FUNCTION im_v2.fail_special_message_audit()").run()
            let results = try await withThrowingTaskGroup(of: V2SendMessageOutcome.self) { group in
                for _ in 0..<8 { group.addTask { try await service.send(original) } }
                var results: [V2SendMessageOutcome] = []
                for try await result in group { results.append(result) }
                return results
            }
            #expect(results.count == 8)
            let first = try #require(results.first)
            let receipt = try #require(first.acceptanceReceipt)
            for result in results { #expect(result == .idempotent(receipt)) }
            #expect(try await count("im_v2.special_account_message_operations", on: sql) == 1)
            #expect(try await count("im_v2.special_account_message_audit", on: sql) == 1)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.special_account_message_audit WHERE message_id = \(bind: receipt.messageID.uuidValue!) AND created_at = \(bind: base.addingTimeInterval(2)) AND (support_session_room_id IS NOT NULL) = \(bind: kind == .customerSupport)").first(decoding: CountRow.self)?.value == 1)
            let committed = try await snapshot()
            for bad in badClocks {
                clock.set([bad])
                #expect(try await service.send(original) == .idempotent(receipt))
                await #expect(throws: V2SpecialAccountMessagingError.idempotencyConflict) {
                    try await store.record(request: request(operation: original.operationID, fingerprint: "fedcba0987654321"), account: account, roomID: opened.roomID, outcome: first, now: bad)
                }
                #expect(try await snapshot() == committed)
            }
            for valid in [Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000), Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)] {
                clock.set([base, valid])
                let next = try request()
                guard case .accepted(let accepted) = try await service.send(next) else { throw V2SpecialAccountMessagingError.corruptPersistenceState }
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.special_account_message_audit WHERE message_id = \(bind: accepted.messageID.uuidValue!) AND created_at = \(bind: valid)").first(decoding: CountRow.self)?.value == 1)
            }
            #expect(try await count("im_v2.messages", on: sql) == (kind == .customerSupport ? 4 : 3))
            #expect(try await count("im_v2.special_account_message_operations", on: sql) == 3)
            #expect(try await count("im_v2.special_account_message_audit", on: sql) == 3)
            try await controlResources.shutdown()
            } catch {
                try? await controlResources.shutdown()
                throw error
            }
        }
    }

    @Test("Moderation audit retention rejects invalid clocks and preserves authoritative operations")
    func moderationRetentionClockBounds() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            var operations: [(V2MessageModerationCommand, V2MessageModerationReceipt)] = []
            for index in 0..<4 {
                let time = base.addingTimeInterval(Double(index) * 10)
                let sender = try V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0), capacityProfile: profile, limits: .init(maxUTF8Bytes: 64), now: { time })
                guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "audit retention \(index)")) else { throw V2ModerationStoreError.corruptPersistenceState }
                let command = try await freezeMessageModerationFixture(database: database, roomID: roomID,
                    actorUserID: senderID, operationID: .init(uuid: UUID()), messageID: message.messageID,
                    reasonCode: .init("abuse_spam"), now: time)
                guard case .receipt(let result) = try await submitMessageModerationFixture(database: database,
                    command: command, profile: profile, eventID: .init(uuid: UUID()), now: time.addingTimeInterval(1)),
                    case .redacted = result.outcome else { throw V2ModerationStoreError.corruptPersistenceState }
                #expect(result.validates(intent: command.intent))
                operations.append((command, result))
            }
            func snapshot(includeAudit: Bool) async throws -> String {
                try #require(try await sql.raw("""
                    SELECT jsonb_build_object(
                        'audit', CASE WHEN \(bind: includeAudit) THEN (SELECT jsonb_agg(to_jsonb(r) ORDER BY operation_id) FROM im_v2.moderation_audit_entries r) ELSE NULL END,
                        'operations', (SELECT jsonb_agg(to_jsonb(r) ORDER BY operation_id) FROM im_v2.moderation_operations r),
                        'proofs', (SELECT jsonb_agg(to_jsonb(r) ORDER BY actor_user_id, operation_id) FROM im_v2.message_moderation_receipts r),
                        'messages', (SELECT jsonb_agg(to_jsonb(r) ORDER BY message_id) FROM im_v2.messages r),
                        'events', (SELECT jsonb_agg(to_jsonb(r) ORDER BY event_id) FROM im_v2.room_events r),
                        'room', (SELECT to_jsonb(r) FROM im_v2.rooms r WHERE room_id = \(bind: roomUUID)),
                        'admission', (SELECT to_jsonb(r) FROM im_v2.room_admission r WHERE room_id = \(bind: roomUUID)),
                        'shard', (SELECT to_jsonb(r) FROM im_v2.shard_admission_pools r WHERE room_shard_id = 'room-a')
                    )::text AS value
                    """).first(decoding: StringValueRow.self)).value
            }
            let retention = PostgresV2ModerationAuditRetentionStore(database: database)
            let clock = TestSequenceClock([base])
            let worker = V2ModerationAuditRetentionWorker(store: retention, now: { clock.now() })
            let initial = try await snapshot(includeAudit: true)
            let business = try await snapshot(includeAudit: false)
            let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            for bad in badDates {
                clock.set([bad])
                await #expect(throws: V2ModerationStoreError.corruptPersistenceState) { _ = try await worker.runOnce(limit: 1) }
                await #expect(throws: V2ModerationStoreError.corruptPersistenceState) { _ = try await retention.deleteExpiredAuditEntries(now: bad, limit: Int.max) }
                #expect(try await snapshot(includeAudit: true) == initial)
            }
            clock.set([base])
            for limit in [Int.min, -1, 0] {
                await #expect(throws: V2ModerationStoreError.corruptPersistenceState) { _ = try await worker.runOnce(limit: limit) }
                await #expect(throws: V2ModerationStoreError.corruptPersistenceState) { _ = try await retention.deleteExpiredAuditEntries(now: base, limit: limit) }
            }
            #expect(try await snapshot(includeAudit: true) == initial)
            let firstExpiry = base.addingTimeInterval(180 * 86_400 + 1)
            clock.set([firstExpiry.addingTimeInterval(-0.5)])
            #expect(try await worker.runOnce(limit: Int.max) == 0)
            #expect(try await snapshot(includeAudit: true) == initial)
            clock.set([firstExpiry])
            #expect(try await worker.runOnce(limit: 1) == 1)
            #expect(try await count("im_v2.moderation_audit_entries", on: sql) == 3)
            #expect(try await snapshot(includeAudit: false) == business)
            let afterFirst = try await snapshot(includeAudit: true)
            clock.set([base])
            #expect(try await worker.runOnce(limit: 1) == 0)
            #expect(try await snapshot(includeAudit: true) == afterFirst)
            for bad in badDates {
                clock.set([bad])
                await #expect(throws: V2ModerationStoreError.corruptPersistenceState) { _ = try await worker.runOnce(limit: 1) }
                #expect(try await snapshot(includeAudit: true) == afterFirst)
            }
            clock.set([firstExpiry.addingTimeInterval(20)])
            let removed = try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<4 { group.addTask { try await worker.runOnce(limit: 1) } }
                var total = 0
                for try await value in group { #expect((0...1).contains(value)); total += value }
                return total
            }
            #expect(removed == 2)
            #expect(try await count("im_v2.moderation_audit_entries", on: sql) == 1)
            #expect(try await snapshot(includeAudit: false) == business)
            clock.set([firstExpiry.addingTimeInterval(30)])
            #expect(try await worker.runOnce(limit: Int.max) == 1)
            #expect(try await worker.runOnce(limit: 1) == 0)
            #expect(try await count("im_v2.moderation_audit_entries", on: sql) == 0)
            // Expiring an audit copy does not undo redaction or discard the
            // operation result. A normal retry must not recreate the audit.
            for (command, result) in operations {
                #expect(try await submitMessageModerationFixture(database: database, command: command,
                    profile: profile, eventID: .init(uuid: UUID()), now: base.addingTimeInterval(40)) == .receipt(result))
            }
            #expect(try await count("im_v2.moderation_audit_entries", on: sql) == 0)
            #expect(try await snapshot(includeAudit: false) == business)
            #expect(try await count("im_v2.messages WHERE withdrawn_at IS NOT NULL", on: sql) == 4)
            #expect(try await count("im_v2.moderation_operations", on: sql) == 0)
            #expect(try await count("im_v2.message_moderation_receipts", on: sql) == 4)
        }
    }

    @Test("privacy closure waits for the first target receipt commit", arguments: [false, true])
    func directReceiptPreferenceCommitFence(closeViewer: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, target, controlSQL, targetSQL, _ in
            struct Fence: V2UserShardRouteFencing {
                let database: any Database
                func withCurrentRoute<Result: Sendable>(for userID: UserID,
                    _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result) async throws -> Result {
                    try await database.transaction { transaction in
                        try await operation(.init(bucket: "user", observedRouterEpoch: 1), transaction)
                    }
                }
            }
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let source = EventID(uuid: UUID()), room = UUID()
            func candidate(_ source: EventID) throws -> V2UserStateEvent {
                try .init(sourceEventID: source, userID: .init(uuid: memberTwoUUID), kind: .directReadReceipt,
                    payload: JSONSerialization.data(withJSONObject: ["room_id": room.uuidString,
                        "reader_user_id": senderUUID.uuidString, "read_through_room_sequence": 7,
                        "recorded_at_ms": 1750000000000]), createdAt: now)
            }
            let event = try candidate(source)
            let projector = try V2RoutedUserStateEventProjector(routeFence: Fence(database: control),
                registry: V2StaticUserShardStorageRegistry(locations: [.init(bucket: "user", database: target, schema: "im_v2")]))
            try await targetSQL.raw("""
                CREATE FUNCTION im_v2.test_hold_first_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    PERFORM pg_advisory_xact_lock(8153782331::bigint);
                    RETURN NEW;
                END $$
                """).run()
            try await targetSQL.raw("CREATE TRIGGER test_hold_first_receipt BEFORE INSERT ON im_v2.user_state_event_receipts FOR EACH ROW EXECUTE FUNCTION im_v2.test_hold_first_receipt()").run()
            let gate = PostgreSQLTransactionGate()
            let blocker = Task {
                try await target.transaction { transaction in
                    let sql = try #require(transaction as? any SQLDatabase)
                    try await sql.raw("SELECT pg_advisory_xact_lock(8153782331::bigint)").run()
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()
            let delivery = Task { try await projector.project(event) }
            do {
                // The target INSERT waits on the target server; its control
                // transaction has already acquired both shared locks.
                try await waitForAdvisoryWaiters(1, on: targetSQL)
            } catch {
                delivery.cancel()
                await gate.releaseTransaction()
                _ = try? await blocker.value
                _ = try? await delivery.value
                throw error
            }
            let preferences = V2PostgresAccountPreferencePersistence(database: control, projectionDelivery: SuccessfulProjectionDelivery())
            let writer = Task {
                try await preferences.executePreferenceFixture(owner: .init(uuid: closeViewer ? memberTwoUUID : senderUUID), operation: .readReceiptPreference(.init(uuid: UUID())), value: .readReceipt(allowsDirectReadReceipts: false, allowsGroupReadReceipts: true), now: now)
            }
            do {
                // The preference writer waits on the control server, which
                // cannot observe the target server's advisory lock waiter.
                try await waitForAdvisoryWaiters(1, on: controlSQL)
                #expect(try await count("im_v2.user_read_receipt_preferences", on: controlSQL) == 0)
                #expect(try await count("im_v2.user_state_event_receipts", on: targetSQL) == 0)
                #expect(try await count("im_v2.user_sync_log", on: targetSQL) == 0)
            } catch {
                delivery.cancel(); writer.cancel()
                await gate.releaseTransaction()
                _ = try? await blocker.value
                _ = try? await delivery.value
                _ = try? await writer.value
                throw error
            }
            await gate.releaseTransaction()
            try await blocker.value
            #expect(try await delivery.value == 1)
            guard case .receipt(let proof) = try await writer.value, case .applied = proof.outcome else { throw CancellationError() }
            #expect(try await targetSQL.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE source_event_id = \(bind: source.uuidValue!) AND (payload->>'is_visible')::boolean AND (payload->>'read_through_room_sequence')::bigint = 7").first(decoding: CountRow.self)?.value == 1)
            #expect(try await projector.project(event) == 1)
            let later = try candidate(.init(uuid: UUID()))
            #expect(try await projector.project(later) == 2)
            #expect(try await targetSQL.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE source_event_id = \(bind: later.sourceEventID.uuidValue!) AND NOT (payload->>'is_visible')::boolean AND (payload->>'read_through_room_sequence')::bigint = 0").first(decoding: CountRow.self)?.value == 1)
            #expect(try await count("im_v2.user_sync_log", on: targetSQL) == 2)
        }
    }

}
