@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Crypto
import FluentKit
import FluentPostgresDriver
import Foundation
import HTTPTypes
@testable import IMV2ServerGateway
#if os(macOS)
import Darwin
#endif
import IMV2Core
import IMV2ActorContracts
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
    @Test("Live preferences validate saved time and use the current clock only for new facts")
    func livePreferenceReplayTimestampBounds() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let live = try PostgresV2LiveActivityStore(database: database)
            let operations = V2PostgresAccountPreferencePersistence(database: database,
                projectionDelivery: SuccessfulProjectionDelivery())
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let minimum = Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000)
            let maximum = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)
            let invalidDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map(Date.init(timeIntervalSince1970:))
            let command = try await operations.freezePreferenceFixture(owner: senderID,
                operation: .liveActivityPreference(.init(uuid: UUID())), value: .liveActivity(allowsOnlinePresence: false, allowsTypingIndicators: false), now: base)
            func snapshot() async throws -> [String] {
                var result: [String] = []
                for table in ["user_live_activity_preferences", "account_preference_receipts", "account_preference_revisions", "user_live_presence_leases", "user_sync_sequences", "user_sync_log"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw:table) r").first(decoding: StringValueRow.self)
                    result.append(try #require(row).value)
                }
                return result
            }
            let empty = try await snapshot()
            for invalid in invalidDates {
                await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) { try await live.preferences(userID: senderID, now: invalid) }
                await #expect(throws: (any Error).self) { try await operations.submit(command, now: invalid) }
                #expect(try await snapshot() == empty)
            }
            for date in [minimum, maximum, base] {
                #expect(try await live.preferences(userID: senderID, now: date) == .init(allowsOnlinePresence: true, allowsTypingIndicators: true, updatedAt: date))
            }
            #expect(try await snapshot() == empty)
            guard case .receipt(let proof) = try await operations.submit(command, now: base), case .applied = proof.outcome else { throw CancellationError() }
            let saved = try await live.preferences(userID: senderID, now: base)
            #expect(!saved.allowsOnlinePresence && !saved.allowsTypingIndicators)
            #expect(try UInt64(v2GatewayMilliseconds(saved.updatedAt)) == proof.resolvedAtMilliseconds)
            let initial = try await snapshot()
            let conflict = try V2AccountPreferenceCommand(identity: command.identity,
                value: .liveActivity(allowsOnlinePresence: true, allowsTypingIndicators: false), expectedRevision: command.expectedRevision,
                firstSubmissionDeadlineMilliseconds: command.firstSubmissionDeadlineMilliseconds)
            let fresh = try await operations.freezePreferenceFixture(owner: senderID,
                operation: .liveActivityPreference(.init(uuid: UUID())), value: .liveActivity(allowsOnlinePresence: true, allowsTypingIndicators: true), now: base)
            for invalid in invalidDates {
                #expect(try await live.preferences(userID: senderID, now: invalid) == saved)
                #expect(try await operations.submit(command, now: invalid) == .receipt(proof))
                #expect(try await operations.submit(conflict, now: invalid) == .fingerprintConflict)
                await #expect(throws: (any Error).self) { try await operations.submit(fresh, now: invalid) }
                #expect(try await snapshot() == initial)
            }
            for literal in ["infinity", "-infinity", "294276-12-31 23:59:59.999999+00"] {
                try await sql.raw("UPDATE im_v2.user_live_activity_preferences SET updated_at=\(bind:literal)::timestamptz").run()
                let before = try await snapshot()
                await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) { try await live.preferences(userID: senderID, now: base) }
                #expect(try await operations.submit(command, now: base) == .receipt(proof))
                #expect(try await snapshot() == before)
            }
            try await sql.raw("UPDATE im_v2.user_live_activity_preferences SET updated_at=\(bind:saved.updatedAt)").run()
            await #expect(throws: (any Error).self) {
                try await sql.raw("UPDATE im_v2.account_preference_receipts SET receipt=jsonb_set(receipt,'{resolvedAtMilliseconds}','0') WHERE actor_user_id=\(bind:senderUUID) AND operation_id=\(bind:UUID(uuidString:command.identity.operation.rawOperationID)!)").run()
            }
            #expect(try await operations.submit(command, now: base) == .receipt(proof))
            #expect(try await snapshot() == initial)
        }
    }

    @Test("Presence responses validate the selected lease while preserving offline and hidden states")
    func livePresenceResponseTimestampBounds() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let live = try PostgresV2LiveActivityStore(database: database)
            let peer = UserID(uuid: memberTwoUUID)
            let room = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: forwardImportTestProfile(),
                roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { base }).openedIdentity(actorUserID: senderID,
                operationID: .init(uuid: UUID()), targetUserID: peer, firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
            let device = UUID(), primary = UUID(), secondary = UUID()
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: memberTwoUUID), \(bind: device), \(bind: base), \(bind: base))").run()
            for (connection, expiry) in [(primary, base.addingTimeInterval(30)), (secondary, base.addingTimeInterval(90))] {
                try await sql.raw("INSERT INTO im_v2.user_live_presence_leases (connection_id, publication_suppressed, user_id, device_id, expires_at, updated_at) VALUES (\(bind: connection), false, \(bind: memberTwoUUID), \(bind: device), \(bind: expiry), \(bind: base))").run()
            }
            let preferences = V2PostgresAccountPreferencePersistence(database: database,
                projectionDelivery: SuccessfulProjectionDelivery())
            guard case .receipt(let proof) = try await preferences.executePreferenceFixture(owner: peer,
                operation: .liveActivityPreference(.init(uuid: UUID())),
                value: .liveActivity(allowsOnlinePresence: true, allowsTypingIndicators: true), now: base),
                case .applied = proof.outcome else { throw CancellationError() }
            func snapshot() async throws -> [String] {
                var result: [String] = []
                for table in ["auth_devices", "user_live_presence_leases", "user_live_activity_preferences", "account_preference_receipts", "user_sync_log"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)
                    result.append(try #require(row).value)
                }
                return result
            }
            func presence() async throws -> V2PresenceState { try await live.presence(roomID: room.roomID, viewerUserID: senderID, now: base) }
            let original = try await snapshot()
            #expect(try await presence() == .init(roomID: room.roomID, targetUserID: peer, isOnline: true, expiresAt: base.addingTimeInterval(90)))
            #expect(try await snapshot() == original)
            for literal in ["infinity", "294276-12-31 23:59:59.999999+00"] {
                try await sql.raw("UPDATE im_v2.user_live_presence_leases SET expires_at = \(bind: literal)::timestamptz WHERE connection_id = \(bind: secondary)").run()
                let before = try await snapshot()
                await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) { try await presence() }
                #expect(try await snapshot() == before)
                try await sql.raw("UPDATE im_v2.user_live_activity_preferences SET allows_online_presence = false WHERE user_id = \(bind: memberTwoUUID)").run()
                let hidden = try await snapshot()
                #expect(try await presence() == .init(roomID: room.roomID, targetUserID: peer, isOnline: false, expiresAt: base))
                #expect(try await snapshot() == hidden)
                try await sql.raw("UPDATE im_v2.user_live_activity_preferences SET allows_online_presence = true WHERE user_id = \(bind: memberTwoUUID)").run()
            }
            // Expired rows do not participate in MAX(expires_at), including
            // PostgreSQL's negative infinity sentinel.
            try await sql.raw("UPDATE im_v2.user_live_presence_leases SET expires_at = '-infinity'::timestamptz WHERE connection_id = \(bind: secondary)").run()
            let expired = try await snapshot()
            #expect(try await presence() == .init(roomID: room.roomID, targetUserID: peer, isOnline: true, expiresAt: base.addingTimeInterval(30)))
            #expect(try await snapshot() == expired)
            try await sql.raw("DELETE FROM im_v2.user_live_presence_leases WHERE connection_id = \(bind: primary)").run()
            for date in [base.addingTimeInterval(-1), base, base.addingTimeInterval(1),
                         Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)] {
                try await sql.raw("UPDATE im_v2.user_live_presence_leases SET expires_at = \(bind: date) WHERE connection_id = \(bind: secondary)").run()
                let before = try await snapshot()
                #expect(try await presence() == .init(roomID: room.roomID, targetUserID: peer, isOnline: date > base, expiresAt: date > base ? date : base))
                #expect(try await snapshot() == before)
            }
        }
    }



    @Test("Preference replays use committed time and preserve projection forwarding",
          arguments: ["receipts"])
    func preferenceReplayTimestampBounds(kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000), operation = UUID()
            let shadow = PreferenceReplayClockDelivery()
            let store = V2PostgresAccountPreferencePersistence(database: database, projectionDelivery: shadow)
            let command = try await store.freezePreferenceFixture(owner: senderID, operation: .readReceiptPreference(.init(uuid: operation)),
                value: .readReceipt(allowsDirectReadReceipts: false, allowsGroupReadReceipts: true), now: base)
            let conflict = try V2AccountPreferenceCommand(identity: command.identity,
                value: .readReceipt(allowsDirectReadReceipts: true, allowsGroupReadReceipts: true), expectedRevision: command.expectedRevision,
                firstSubmissionDeadlineMilliseconds: command.firstSubmissionDeadlineMilliseconds)
            func snapshot() async throws -> [String] {
                var result: [String] = []
                for table in ["user_read_receipt_preferences", "account_preference_receipts", "account_preference_revisions",
                    "read_receipt_preference_propagation_outbox", "user_sync_sequences", "user_sync_log"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw:table) r").first(decoding: StringValueRow.self)
                    result.append(try #require(row).value)
                }
                return result
            }
            guard case .receipt(let proof) = try await store.submit(command, now: base), case .applied(let value, _) = proof.outcome else { throw CancellationError() }
            #expect(proof.validates(command: command) && value == command.value)
            let expectedDelivery = PreferenceReplayClockDelivery.Call(userID: senderID, sourceEventID: .init(uuid: operation), kinds: ["read_receipt_preferences"])
            #expect(shadow.calls == [expectedDelivery])
            let initial = try await snapshot()
            let fresh = try await store.freezePreferenceFixture(owner: senderID, operation: .readReceiptPreference(.init(uuid: UUID())),
                value: command.value, now: base)
            for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12] {
                let invalid = Date(timeIntervalSince1970: seconds), calls = shadow.calls
                #expect(try await store.submit(command, now: invalid) == .receipt(proof))
                #expect(shadow.calls == calls + [expectedDelivery])
                let afterReplay = shadow.calls
                #expect(try await store.submit(conflict, now: invalid) == .fingerprintConflict)
                await #expect(throws: (any Error).self) { try await store.submit(fresh, now: invalid) }
                #expect(shadow.calls == afterReplay)
                #expect(try await snapshot() == initial)
            }
            await #expect(throws: (any Error).self) {
                try await sql.raw("UPDATE im_v2.account_preference_receipts SET receipt=jsonb_set(receipt,'{resolvedAtMilliseconds}','0') WHERE actor_user_id=\(bind:senderUUID) AND operation_id=\(bind:operation)").run()
            }
            let calls = shadow.calls
            #expect(try await store.submit(command, now: base) == .receipt(proof))
            #expect(shadow.calls == calls + [expectedDelivery])
            #expect(try await snapshot() == initial)
        }
    }

    @Test("direct/preference clock checks and policy-owned social replays preserve immutable effects", arguments: ["direct", "userAdd", "relationship", "block"])
    func directSocialReplayTimestampBounds(kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date()
            let baseMilliseconds = UInt64(try v2GatewayMilliseconds(base))
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until = \(bind: base.addingTimeInterval(600))").run()
            try await withFixturePolicyOwners(database: database, projectionDelivery: SuccessfulProjectionDelivery()) { owners in
            let profile = try forwardImportTestProfile()
            let chosenRoom = RoomID(uuid: UUID()), operation = UUID()
            let social = PostgresV2SocialRelationshipStore(database: database, projectionDelivery: SuccessfulProjectionDelivery(), policyOwners: owners)
            let preferences = V2PostgresAccountPreferencePersistence(database: database,
                projectionDelivery: SuccessfulProjectionDelivery())
            enum Proof: Equatable { case direct(V2DirectRoomOperationReceipt), social(V2SocialOperationReceipt), preference(V2AccountPreferenceReceipt) }
            func invoke(_ id: UUID, at now: Date, conflict: Bool = false) async throws -> Proof? {
                let target = UserID(uuid: conflict ? memberThreeUUID : memberTwoUUID)
                switch kind {
                case "direct":
                    let command = try V2DirectRoomOperationCommand(actorUserID: senderID, operationID: .init(uuid: id), targetUserID: target,
                        firstSubmissionDeadlineMilliseconds: baseMilliseconds + 600_000)
                    let result = try await PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: SuccessfulProjectionDelivery()).submitDirectRoomOperation(command,
                        roomID: chosenRoom, roomShardID: "room-a", capacityProfile: profile, now: now)
                    if conflict { #expect(result == .fingerprintConflict); return nil }
                    guard case .receipt(let proof) = result, case .opened(let room, _) = proof.outcome else { throw CancellationError() }
                    #expect(room == chosenRoom && proof.validates(command: command))
                    return .direct(proof)
                case "userAdd":
                    let value: V2AccountPreferenceValue = .userAdd(conflict ? .allow : .deny)
                    let reference: V2OperationReference = .userAddPreference(.init(uuid: id))
                    let command = try V2AccountPreferenceCommand(identity: .init(accountID: senderID, scope: .account(senderID), operation: reference),
                        value: value, expectedRevision: 0, firstSubmissionDeadlineMilliseconds: baseMilliseconds + 120_000)
                    let result = try await preferences.submit(command, now: now)
                    if conflict { #expect(result == .fingerprintConflict); return nil }
                    guard case .receipt(let proof) = result, case .applied(let actual, let revision) = proof.outcome else { throw CancellationError() }
                    #expect(actual == value && revision == 1 && proof.validates(command: command))
                    return .preference(proof)
                default:
                    let action: V2SocialOperationAction = kind == "relationship" ? .relationship(.request) : .userBlock(.block)
                    let reference: V2OperationReference = kind == "relationship" ? .relationship(.init(uuid: id)) : .userBlock(.init(uuid: id))
                    let command = try V2SocialOperationCommand(identity: .init(accountID: senderID, scope: .userPair(senderID, target), operation: reference),
                        action: action, expectedRevision: 0, firstSubmissionDeadlineMilliseconds: kind == "relationship" ? baseMilliseconds + 600_000 : baseMilliseconds + 120_000)
                    let result = try await social.submitSocialOperation(command)
                    if conflict { #expect(result == .fingerprintConflict); return nil }
                    guard case .receipt(let proof) = result, case .applied = proof.outcome else { throw CancellationError() }
                    #expect(proof.validates(command: command))
                    return .social(proof)
                }
            }
            func snapshot() async throws -> [String] {
                var rows: [String] = []
                for table in ["rooms", "room_memberships", "room_admission", "direct_room_pairs", "direct_room_owner_receipts",
                    "user_stranger_message_preferences", "user_add_preferences", "account_preference_receipts", "account_preference_revisions",
                    "user_relationships", "user_blocks", "social_operation_receipts", "social_relationship_revisions", "social_block_revisions",
                    "user_state_event_outbox", "user_sync_sequences", "user_sync_log"] {
                    let values = try await sql.raw("SELECT to_jsonb(t)::text AS value FROM im_v2.\(unsafeRaw: table) t ORDER BY to_jsonb(t)::text").all(decoding: StringValueRow.self)
                    rows += values.map { table + ":" + $0.value }
                }
                return rows
            }
            let invalid = [Double.nan, .infinity, -.infinity, 1e14, -1e14].map { Date(timeIntervalSince1970: $0) }
            // Caller-clock validation only applies to APIs that still accept a clock.
            for date in (kind == "direct" || kind == "userAdd" ? invalid : []) {
                let before = try await snapshot()
                await #expect(throws: (any Error).self) { try await invoke(UUID(), at: date) }
                #expect(try await snapshot() == before)
            }
            let original = try #require(try await invoke(operation, at: base))
            let before = try await snapshot()
            let replayClocks = kind == "direct" || kind == "userAdd"
                ? invalid + [base.addingTimeInterval(700)] : [base]
            for date in replayClocks {
                #expect(try await invoke(operation, at: date) == original)
                #expect(try await snapshot() == before)
            }
            _ = try await invoke(operation, at: base, conflict: true)
            #expect(try await snapshot() == before)
            }
        }
    }

    @Test("Direct receipts commit owner outboxes and resolve control privacy across databases", arguments: [false, true])
    func directReceiptOwnerOutbox(batch: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { ownerDB, controlDB, ownerSQL, controlSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let room = RoomID(uuid: UUID())
            let profile = try forwardImportTestProfile()
            _ = try await V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: ownerDB, identityReader: PostgresV2DirectRoomIdentityReader(database: controlDB), projectionDelivery: SuccessfulProjectionDelivery()), capacityProfile: profile,
                roomShardID: "room-a", roomID: room, now: { now }).openedReceipt(actorUserID: senderID,
                    operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                    firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let sender = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: ownerDB, controlDatabase: controlDB,
                store: PostgresV2RoomWriteStore(database: ownerDB), shardID: "room-a", epoch: 0), capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted = try await sender.send(.init(roomID: room, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "read me")) else { throw CancellationError() }
            let store = PostgresV2ReadReceiptStore(database: ownerDB)
            let command = try V2RecordReadReceiptCommand(roomID: room, actorUserID: senderID,
                operationID: .init(uuid: UUID()), readThroughRoomSequence: 1)
            try await withRoomActivation(database: ownerDB, roomID: room) { token in
                let stale = V2RoomActivationToken(roomID: room, owner: try .init(shardID: "room-a", epoch: 99),
                    activationEpoch: token.activationEpoch, host: token.host)
                await #expect(throws: V2ReadReceiptStoreError.ownerChanged) {
                    _ = try await store.recordActivationValidated(command: command, token: stale, now: now)
                }
            }
            try await controlSQL.raw("""
                INSERT INTO im_v2.user_read_receipt_preferences(user_id, allows_direct_read_receipts, preference_revision, updated_at)
                VALUES (\(bind: memberTwoUUID), false, 1, \(bind: now))
                """).run()
            // Production records receipts through the room actor: one
            // activation turn, the owner store's activation-validated path.
            try await withRoomActivation(database: ownerDB, roomID: room, shardID: "room-a") { token in
                @Sendable func record(_ command: V2RecordReadReceiptCommand) async throws -> V2ReadReceiptOutcome {
                    try await store.recordActivationValidated(command: command, token: token, now: now)
                }
                let outcome: V2ReadReceiptOutcome
                if batch {
                    let results = try await store.recordBatchActivationValidated([.init(command: command, now: now)],
                        scope: try .init(tokens: [token]))
                    guard case .success(let result) = results.first else { throw CancellationError() }
                    outcome = result
                } else { outcome = try await record(command) }
                guard case .recorded(let saved) = outcome else { throw CancellationError() }
                #expect(try await record(command) == .idempotent(saved))
                let noChange = try V2RecordReadReceiptCommand(roomID: room, actorUserID: senderID,
                    operationID: .init(uuid: UUID()), readThroughRoomSequence: 1)
                _ = try await record(noChange)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<8 {
                        group.addTask {
                            let concurrent = try V2RecordReadReceiptCommand(roomID: room, actorUserID: senderID,
                                operationID: .init(uuid: UUID()), readThroughRoomSequence: 1)
                            _ = try await record(concurrent)
                        }
                    }
                    try await group.waitForAll()
                }
            }
            #expect(try await ownerSQL.raw("SELECT count(*) AS value FROM im_v2.user_state_event_outbox WHERE projection_kind IN ('own_read_watermark', 'direct_read_receipt')").first(decoding: CountRow.self)?.value == 2)
            #expect(try await ownerSQL.raw("SELECT count(*) AS value FROM im_v2.user_sync_log WHERE projection_kind IN ('own_read_watermark', 'direct_read_receipt')").first(decoding: CountRow.self)?.value == 0)
            #expect(try await controlSQL.raw("SELECT count(*) AS value FROM im_v2.rooms WHERE room_id = \(bind: room.uuidValue!)").first(decoding: CountRow.self)?.value == 0)
            let secondary = try #require(Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"))
            try await withUserEventDatabase(databaseURL: secondary) { targetDB, targetSQL, targetSchema in
                struct Fence: V2UserShardRouteFencing {
                    let database: any Database
                    func withCurrentRoute<Result: Sendable>(for userID: UserID,
                        _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result) async throws -> Result {
                        try await database.transaction { transaction in
                            try await operation(.init(bucket: "user", observedRouterEpoch: 1), transaction)
                        }
                    }
                }
                let projector = try V2RoutedUserStateEventProjector(routeFence: Fence(database: controlDB),
                    registry: V2StaticUserShardStorageRegistry(locations: [.init(bucket: "user", database: targetDB, schema: targetSchema)]))
                let outbox = try PostgresV2UserStateEventOutbox(database: ownerDB)
                let leases = try await deliverUserStateEvents(outbox, projector: projector, now: now.addingTimeInterval(1), leaseDuration: 30, limit: 100)
                    .filter { $0.event.kind == .ownReadWatermark || $0.event.kind == .directReadReceipt }
                #expect(leases.count == 2)
                #expect(try await targetSQL.raw("""
                    SELECT count(*) AS value FROM \(unsafeRaw: targetSchema).user_sync_log
                    WHERE projection_kind = 'direct_read_receipt' AND payload->>'is_visible' = 'false'
                      AND payload->>'viewer_preference_revision' = '1'
                    """).first(decoding: CountRow.self)?.value == 1)
                #expect(try await targetSQL.raw("SELECT count(*) AS value FROM \(unsafeRaw: targetSchema).user_sync_log WHERE projection_kind = 'own_read_watermark'").first(decoding: CountRow.self)?.value == 1)
            }
        }
    }

    @Test("Receipt policy propagation uses the control directory and survives reenable before delivery")
    func readReceiptPolicyDirectoryPropagation() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { controlDB, _, controlSQL, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let rooms = [UUID(), UUID()]
            for (room, peer) in zip(rooms, [memberTwoUUID, memberThreeUUID]) {
                try await controlSQL.raw("""
                    INSERT INTO im_v2.direct_room_owner_routes
                        (lower_user_id, higher_user_id, room_id, room_shard_id, created_at, updated_at)
                    VALUES (LEAST(\(bind: senderUUID)::text, \(bind: peer)::text)::uuid,
                            GREATEST(\(bind: senderUUID)::text, \(bind: peer)::text)::uuid,
                            \(bind: room), 'room-a', \(bind: now), \(bind: now))
                    """).run()
            }
            let preferences = V2PostgresAccountPreferencePersistence(database: controlDB, projectionDelivery: SuccessfulProjectionDelivery())
            _ = try await preferences.executePreferenceFixture(owner: senderID, operation: .readReceiptPreference(.init(uuid: UUID())), value: .readReceipt(allowsDirectReadReceipts: false, allowsGroupReadReceipts: true), now: now)
            let worker = V2ReadReceiptPreferencePropagationWorker(database: controlDB, now: { now })
            #expect(try await worker.runOnce(limit: 1) == .init(claimedOperationCount: 1, projectedRoomCount: 1, completedOperationCount: 0))
            #expect(try await worker.runOnce(limit: 1) == .init(claimedOperationCount: 1, projectedRoomCount: 1, completedOperationCount: 1))
            #expect(try await worker.runOnce(limit: 1).claimedOperationCount == 0)
            #expect(try await count("im_v2.direct_room_pairs", on: controlSQL) == 0)
            #expect(try await count("im_v2.user_state_event_outbox", on: controlSQL) == 4)
            #expect(try await controlSQL.raw("SELECT count(*) AS value FROM im_v2.user_sync_log WHERE projection_kind = 'direct_read_receipt'").first(decoding: CountRow.self)?.value == 0)
            _ = try await preferences.executePreferenceFixture(owner: senderID, operation: .readReceiptPreference(.init(uuid: UUID())), value: .readReceipt(allowsDirectReadReceipts: true, allowsGroupReadReceipts: true), now: now)
            let secondary = try #require(Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"))
            try await withUserEventDatabase(databaseURL: secondary) { targetDB, targetSQL, targetSchema in
                struct Fence: V2UserShardRouteFencing {
                    let database: any Database
                    func withCurrentRoute<Result: Sendable>(for userID: UserID,
                        _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result) async throws -> Result {
                        try await database.transaction { transaction in
                            try await operation(.init(bucket: "user", observedRouterEpoch: 1), transaction)
                        }
                    }
                }
                let projector = try V2RoutedUserStateEventProjector(routeFence: Fence(database: controlDB),
                    registry: V2StaticUserShardStorageRegistry(locations: [.init(bucket: "user", database: targetDB, schema: targetSchema)]))
                let outbox = try PostgresV2UserStateEventOutbox(database: controlDB)
                let readyAt = try #require(try await controlSQL.raw("SELECT max(next_attempt_at) AS value FROM im_v2.user_state_event_outbox").first(decoding: RevocationClockDateRow.self)).value.addingTimeInterval(1)
                let leases = try await deliverUserStateEvents(outbox, projector: projector, now: readyAt, leaseDuration: 30, limit: 10)
                #expect(leases.count == 4)
                for lease in leases {
                    let sequence = try await projector.project(lease.event)
                }
                #expect(try await targetSQL.raw("""
                    SELECT count(*) AS value FROM \(unsafeRaw: targetSchema).user_sync_log
                    WHERE projection_kind = 'direct_read_receipt' AND payload->>'is_visible' = 'true'
                      AND payload->>'read_through_room_sequence' = '0'
                    """).first(decoding: CountRow.self)?.value == 4)
                let positive = try V2UserStateEvent(sourceEventID: .init(uuid: UUID()), userID: .init(uuid: memberTwoUUID),
                    kind: .directReadReceipt, payload: JSONSerialization.data(withJSONObject: [
                        "room_id": rooms[0].uuidString, "reader_user_id": senderUUID.uuidString,
                        "read_through_room_sequence": 10, "recorded_at_ms": 1750000000000,
                    ]), createdAt: now)
                _ = try await projector.project(positive)
                for lease in leases { _ = try await projector.project(lease.event) }
                let snapshots = PostgresV2UserProjectionWorker(database: targetDB, schema: targetSchema)
                var applied = 0
                for _ in 0..<3 {
                    let result = try await snapshots.runOnce()
                    #expect(result.failedRecordCount == 0)
                    applied += result.appliedRecordCount
                }
                #expect(applied == 5)
                #expect(try await snapshots.runOnce().appliedRecordCount == 0)
                #expect(try await targetSQL.raw("""
                    SELECT count(*) AS value FROM \(unsafeRaw: targetSchema).user_projection_versions
                    WHERE user_id = \(bind: memberTwoUUID) AND valid_to_sequence IS NULL
                      AND payload->>'read_through_room_sequence' = '10'
                      AND payload->>'reader_preference_revision' = '2'
                    """).first(decoding: CountRow.self)?.value == 1)
            }
        }
    }

    @Test("Read receipt preference revisions advance independently of time and preserve replay at exhaustion")
    func readReceiptPreferenceRevisionOrdering() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let store = V2PostgresAccountPreferencePersistence(database: database, projectionDelivery: SuccessfulProjectionDelivery())
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let first = try await store.freezePreferenceFixture(owner: senderID, operation: .readReceiptPreference(.init(uuid: UUID())),
                value: .readReceipt(allowsDirectReadReceipts: false, allowsGroupReadReceipts: true), now: now)
            guard case .receipt(let saved) = try await store.submit(first, now: now), case .applied(_, let firstRevision) = saved.outcome else { throw CancellationError() }
            #expect(firstRevision == 1 && saved.validates(command: first))
            #expect(try await store.submit(first, now: now.addingTimeInterval(10)) == .receipt(saved))
            let earlier = now.addingTimeInterval(-10)
            let second = try await store.freezePreferenceFixture(owner: senderID, operation: .readReceiptPreference(.init(uuid: UUID())),
                value: .readReceipt(allowsDirectReadReceipts: true, allowsGroupReadReceipts: true), now: earlier)
            guard case .receipt(let laterProof) = try await store.submit(second, now: earlier), case .applied(_, let secondRevision) = laterProof.outcome else { throw CancellationError() }
            #expect(secondRevision == 2 && laterProof.validates(command: second))
            #expect(try await sql.raw("SELECT preference_revision AS value FROM im_v2.user_read_receipt_preferences WHERE user_id = \(bind: senderUUID)").first(decoding: CountRow.self)?.value == 2)
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.user_sync_log WHERE user_id = \(bind: senderUUID) AND projection_kind = 'read_receipt_preferences' AND source_event_id IN (\(bind: UUID(uuidString: first.identity.operation.rawOperationID)!), \(bind: UUID(uuidString: second.identity.operation.rawOperationID)!)) AND (payload->>'preference_revision')::bigint IN (1,2)").first(decoding: CountRow.self)?.value == 2)
            let conflicting = try V2AccountPreferenceCommand(identity: first.identity,
                value: .readReceipt(allowsDirectReadReceipts: true, allowsGroupReadReceipts: true), expectedRevision: first.expectedRevision,
                firstSubmissionDeadlineMilliseconds: first.firstSubmissionDeadlineMilliseconds)
            #expect(try await store.submit(conflicting, now: now) == .fingerprintConflict)
            try await sql.raw("UPDATE im_v2.user_read_receipt_preferences SET preference_revision = \(bind: Int64.max) WHERE user_id = \(bind: senderUUID)").run()
            #expect(throws: V2AccountPreferenceValidationError.invalidCommand) {
                try V2AccountPreferenceCommand(identity: second.identity,
                    value: .readReceipt(allowsDirectReadReceipts: false, allowsGroupReadReceipts: true), expectedRevision: UInt64(Int64.max),
                    firstSubmissionDeadlineMilliseconds: second.firstSubmissionDeadlineMilliseconds)
            }
            #expect(try await store.submit(first, now: now) == .receipt(saved))
            #expect(try await sql.raw("SELECT preference_revision AS value FROM im_v2.user_read_receipt_preferences WHERE user_id = \(bind: senderUUID) AND allows_direct_read_receipts = true").first(decoding: CountRow.self)?.value == Int64.max)
            #expect(try await count("im_v2.account_preference_receipts", on: sql) == 2)
            #expect(try await count("im_v2.read_receipt_preference_propagation_outbox", on: sql) == 1)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 2)
        }
    }

    @Test("Direct room creation validates persisted pair and profile timestamps", arguments: ["pair", "profile"])
    func directRoomSourceTimestampBounds(kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, target, sql, targetSQL, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let store = PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: SuccessfulProjectionDelivery())
            let profile = try forwardImportTestProfile()
            let createdRoom = RoomID(uuid: UUID()), operation = UUID()
            func open(_ operation: UUID) async throws -> V2DirectRoomOperationResult {
                let command = try V2DirectRoomOperationCommand(actorUserID: senderID, operationID: .init(uuid: operation),
                    targetUserID: .init(uuid: memberTwoUUID), firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(base))
                return try await store.submitDirectRoomOperation(command, roomID: createdRoom,
                    roomShardID: "room-a", capacityProfile: profile, now: base)
            }
            if kind == "pair" { guard case .receipt(let proof) = try await open(UUID()), case .opened = proof.outcome else { throw CancellationError() } }
            func snapshot() async throws -> [String] {
                var result: [String] = []
                for table in ["rooms", "room_memberships", "room_admission", "shard_admission_pools", "direct_room_pairs",
                    "direct_room_owner_receipts", "public_user_profiles", "user_direct_send_policy_versions", "user_sync_sequences", "user_sync_log", "user_state_event_outbox"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)
                    result.append(try #require(row).value)
                }
                return result
            }
            for literal in ["infinity", "-infinity", "294276-12-31 23:59:59.999999+00"] {
                if kind == "pair" {
                    try await sql.raw("UPDATE im_v2.direct_room_pairs SET created_at = \(bind: literal)::timestamptz").run()
                } else {
                    try await sql.raw("UPDATE im_v2.public_user_profiles SET updated_at = \(bind: literal)::timestamptz WHERE user_id = \(bind: memberTwoUUID)").run()
                }
                let before = try await snapshot()
                await #expect(throws: V2DirectMessagingStoreError.corruptPersistenceState) { try await open(operation) }
                #expect(try await snapshot() == before)
            }
            if kind == "pair" {
                try await sql.raw("UPDATE im_v2.direct_room_pairs SET created_at = \(bind: base)").run()
            } else {
                try await sql.raw("UPDATE im_v2.public_user_profiles SET updated_at = \(bind: base) WHERE user_id = \(bind: memberTwoUUID)").run()
            }
            guard case .receipt(let proof) = try await open(operation), case .opened(let room, let createdAt) = proof.outcome else { throw CancellationError() }
            // The proof derives milliseconds from the authoritative SQL timestamp,
            // whose floating-point Date representation can cross a millisecond edge.
            let storedRoom = try #require(try await sql.raw("SELECT floor(extract(epoch FROM created_at)*1000)::bigint AS value FROM im_v2.rooms WHERE room_id = \(bind: createdRoom.uuidValue!)").first(decoding: CountRow.self))
            let expectedCreatedAt = UInt64(storedRoom.value)
            #expect(room == createdRoom && createdAt == expectedCreatedAt)
            #expect(try await open(operation) == .receipt(proof))
            #expect(try await count("im_v2.direct_room_pairs", on: sql) == 1)
            #expect(try await count("im_v2.direct_room_owner_receipts", on: sql) == (kind == "pair" ? 2 : 1))
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
            #expect(try await count("im_v2.user_state_event_outbox", on: sql) == 1)
            let outbox = try PostgresV2UserStateEventOutbox(database: database)
            let projector = try PostgresV2UserStateEventProjector(database: target)
            let leases = try await outbox.claim(now: base.addingTimeInterval(1), leaseDuration: 1, limit: 10)
            #expect(leases.count == 1)
            for lease in leases {
                let sequence = try await projector.project(lease.event)
                #expect(try await projector.project(lease.event) == sequence)
                #expect(try await outbox.acknowledge(lease, sequence: sequence, now: base.addingTimeInterval(1)))
            }
            #expect(try await count("im_v2.user_sync_log", on: targetSQL) == 1)
        }
    }

    @Test("Mutation replay uses its committed timestamp while new work requires a valid clock",
          arguments: ["edit", "withdrawal", "membership", "reaction", "pin", "announcement", "permissions", "role"])
    func mutationReplayTimestampBounds(kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000), profile = try forwardImportTestProfile()
            try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE room_id=\(bind:roomUUID) AND user_id=\(bind:senderUUID)").run()
            if kind == "role" { try await sql.raw("UPDATE im_v2.rooms SET membership_revision=1 WHERE room_id=\(bind:roomUUID)").run() }
            let send = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0), capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64), now: { base })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "before")) else { throw CancellationError() }
            let operation = UUID(), target = UserID(uuid: memberTwoUUID)
            try await withRoomActivation(database: database, roomID: roomID) { token in
                let identity = try await V2PostgresMembershipIdentitySnapshotValidator(database: database).snapshot(actorUserID: senderID, targetUserID: target)
                func groupIntent(_ id: UUID) throws -> V2GroupCapabilityIntent {
                    let action: V2GroupCapabilityAction, reference: V2OperationReference, scope: V2OperationScope
                    switch kind {
                    case "pin": action = .pin(messageID: message.messageID, isPinned: true, expectedRoomSequence: 1); reference = .pinnedMessage(.init(uuid: id)); scope = .message(roomID, message.messageID)
                    case "announcement": action = .announcement(body: "Clock boundary", expectedRevision: 0); reference = .groupAnnouncement(.init(uuid: id)); scope = .room(roomID)
                    case "permissions": action = .rolePermissions(role: .member, permissions: [], expectedRevision: 1); reference = .groupPermission(.init(uuid: id)); scope = .room(roomID)
                    default: action = .memberRole(targetUserID: target, role: .admin, expectedMembershipRevision: 1); reference = .groupRole(.init(uuid: id)); scope = .room(roomID)
                    }
                    return try .init(identity: .init(accountID: senderID, scope: scope, operation: reference), action: action, confirmedUntilMilliseconds: 1_750_000_120_000)
                }
                func memberIntent(_ id: UUID) throws -> V2MembershipIntent {
                    try .init(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: id), targetUserID: target,
                        action: .remove, expectedMembershipRevision: 0, confirmedUntilMilliseconds: 1_750_000_120_000)
                }
                let groupCommand: V2GroupCapabilityCommand?
                if ["pin", "announcement", "permissions", "role"].contains(kind) {
                    let intent = try groupIntent(operation)
                    guard case .admitted(let gate) = try await PostgresV2GroupCapabilityOperationStore(database: database, clock: { base }).admit(intent, token: token) else { throw CancellationError() }
                    groupCommand = try .init(intent: intent, admission: gate)
                } else { groupCommand = nil }
                let memberCommand: V2MembershipOperationCommand?
                if kind == "membership" {
                    let intent = try memberIntent(operation)
                    guard case .admitted(let gate) = try await PostgresV2MembershipOperationStore(database: database, clock: { base }).admit(intent, identitySnapshot: identity, token: token) else { throw CancellationError() }
                    memberCommand = try .init(intent: intent, admission: gate)
                } else { memberCommand = nil }
                func invoke(_ id: UUID, at now: Date) async throws -> (date: Date?, event: EventID?, sequence: UInt64) {
                    let event = EventID(uuid: UUID()), deadline: UInt64 = 1_750_000_060_000
                    let sequence: UInt64, proofEvent: EventID?
                    switch kind {
                    case "edit", "withdrawal":
                        let store = PostgresV2MessageMutationOperationStore(database: database, contentReviewMode: .disabled, clock: { now })
                        let result: V2MessageMutationRecoveryResult
                        if kind == "edit" {
                            let command = try V2MessageEditOperationCommand(command: .init(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: id),
                                messageID: message.messageID, expectedMessageRevision: 1, text: "after", maximumUTF8Bytes: 64), firstSubmissionDeadlineMilliseconds: deadline)
                            result = try await store.edit(command, token: token, capacityProfile: profile, eventID: event, now: now, maximumUTF8Bytes: 64)
                        } else {
                            let command = try V2MessageWithdrawalOperationCommand(command: .init(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: id),
                                messageID: message.messageID, expectedMessageRevision: 1), firstSubmissionDeadlineMilliseconds: deadline)
                            result = try await store.withdraw(command, token: token, capacityProfile: profile, eventID: event, now: now)
                        }
                        guard case .receipt(let receipt) = result, case .committed(let value) = receipt.outcome else { throw CancellationError() }
                        sequence = value.roomSequence; proofEvent = value.eventID
                    case "reaction":
                        let command = try V2MessageReactionOperationCommand(command: .init(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: id),
                            messageID: message.messageID, reaction: "👍", action: .add), expectedReactionRevision: 0, firstSubmissionDeadlineMilliseconds: deadline)
                        guard case .receipt(let receipt) = try await PostgresV2MessageReactionOperationStore(database: database, clock: { now }).change(command,
                            token: token, capacityProfile: profile, eventID: event, now: now), case .committed(let value) = receipt.outcome, let savedEvent = value.event else { throw CancellationError() }
                        #expect(try receipt.validates(identity: command.identity, fingerprint: command.fingerprint))
                        sequence = savedEvent.roomSequence; proofEvent = savedEvent.eventID
                    case "membership":
                        let store = PostgresV2MembershipOperationStore(database: database, clock: { now })
                        let command: V2MembershipOperationCommand
                        if id == operation { command = try #require(memberCommand) }
                        else {
                            let intent = try memberIntent(id)
                            guard case .admitted(let gate) = try await store.admit(intent, identitySnapshot: identity, token: token) else { throw CancellationError() }
                            command = try .init(intent: intent, admission: gate)
                        }
                        guard case .receipt(let receipt) = try await store.submit(command, token: token, capacityProfile: profile, eventID: event, identitySnapshot: identity), case .changed(let value) = receipt.outcome else { throw CancellationError() }
                        #expect(receipt.validates(command: command))
                        sequence = value.roomSequence; proofEvent = value.eventID
                    default:
                        let store = PostgresV2GroupCapabilityOperationStore(database: database, clock: { now })
                        let command: V2GroupCapabilityCommand
                        if id == operation { command = try #require(groupCommand) }
                        else {
                            let intent = try groupIntent(id)
                            guard case .admitted(let gate) = try await store.admit(intent, token: token) else { throw CancellationError() }
                            command = try .init(intent: intent, admission: gate)
                        }
                        guard case .receipt(let receipt) = try await store.submit(command, token: token, capacityProfile: profile, eventID: event), case .applied(let value) = receipt.outcome else { throw CancellationError() }
                        #expect(receipt.validates(command: command))
                        switch value { case .pinned(_,_,let seq), .announcement(_,_,let seq), .rolePermissions(_,_,_,let seq), .memberRole(_,_,_,let seq): sequence = seq }
                        proofEvent = nil
                    }
                    let date: Date?
                    if ["permissions", "role"].contains(kind) { date = nil }
                    else if let proofEvent {
                        date = try #require(try await sql.raw("SELECT created_at AS value FROM im_v2.room_events WHERE event_id=\(bind:proofEvent.uuidValue!)").first(decoding: RevocationClockDateRow.self)).value
                    } else {
                        date = try #require(try await sql.raw("SELECT created_at AS value FROM im_v2.room_events WHERE room_id=\(bind:roomUUID) AND room_sequence=\(bind:Int64(sequence))").first(decoding: RevocationClockDateRow.self)).value
                    }
                    return (date, proofEvent, sequence)
                }
                let receiptTable: String = switch kind {
                case "edit", "withdrawal": "message_mutation_receipts"
                case "reaction": "message_reaction_receipts"
                case "membership": "membership_operation_receipts"
                default: "group_capability_receipts"
                }
                func snapshot() async throws -> [String] {
                    var values: [String] = []
                    for table in ["rooms", "room_memberships", "messages", "room_admission", "shard_admission_pools", "room_events", receiptTable,
                        "message_reactions", "room_pinned_messages", "group_announcements", "group_role_permissions", "group_role_policies",
                        "group_capability_admissions", "membership_operation_admissions"] {
                        let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw:table) r").first(decoding: StringValueRow.self)
                        values.append(try #require(row).value)
                    }
                    return values
                }
                let beforeFirstCommit = try await snapshot()
                // Exercise the bad clock while the observed domain baseline is
                // still current, so a later revision conflict cannot hide it.
                for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12] {
                    await #expect(throws: (any Error).self) { try await invoke(UUID(), at: Date(timeIntervalSince1970: seconds)) }
                    #expect(try await snapshot() == beforeFirstCommit)
                }
                let accepted = try await invoke(operation, at: base)
                #expect(accepted.sequence == 2 && accepted.date == (["permissions", "role"].contains(kind) ? nil : base))
                let initial = try await snapshot()
                for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12] {
                    let bad = Date(timeIntervalSince1970: seconds)
                    let replay = try await invoke(operation, at: bad)
                    #expect(replay.date == accepted.date && replay.event == accepted.event && replay.sequence == accepted.sequence)
                    #expect(try await snapshot() == initial)
                }
                await #expect(throws: (any Error).self) {
                    try await sql.raw("UPDATE im_v2.\(unsafeRaw:receiptTable) SET receipt=jsonb_set(receipt,'{resolvedAtMilliseconds}','0') WHERE actor_user_id=\(bind:senderUUID) AND operation_id=\(bind:operation)").run()
                }
                let replay = try await invoke(operation, at: base)
                #expect(replay.date == accepted.date && replay.event == accepted.event && replay.sequence == accepted.sequence)
                #expect(try await snapshot() == initial)
            }
        }
    }

    @Test("Gateway database clock failures preserve metadata and remain infrastructure errors")
    func gatewayDatabaseClockBounds() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let device = DeviceID(uuid: UUID())
            let key = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 7, count: 32))
            let localInput = "gateway-clock-local-fixture"
            let clock = TestSequenceClock([base])
            let gateway = V2PostgresGatewayAuthenticator(database: database, tokenKey: key, now: { clock.now() })
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: senderUUID), \(bind: device.uuidValue!), \(bind: base.addingTimeInterval(-120)), \(bind: base.addingTimeInterval(-120)), \(bind: base.addingTimeInterval(60)))").run()
            try await sql.raw("INSERT INTO im_v2.device_access_tokens (token_hmac, user_id, device_id, issued_at, expires_at) VALUES (\(bind: key.digest(localInput)), \(bind: senderUUID), \(bind: device.uuidValue!), \(bind: base.addingTimeInterval(-120)), \(bind: base.addingTimeInterval(60)))").run()
            try await sql.raw("INSERT INTO im_v2.realtime_device_control_versions (user_id, device_id, latest_change_version) VALUES (\(bind: senderUUID), \(bind: device.uuidValue!), 37)").run()
            func snapshot() async throws -> String {
                let row = try await sql.raw("SELECT jsonb_build_object('last_active_at', d.last_active_at, 'device_revoked_at', d.revoked_at, 'token_revoked_at', t.revoked_at)::text AS value FROM im_v2.auth_devices d JOIN im_v2.device_access_tokens t USING (user_id, device_id) WHERE d.device_id = \(bind: device.uuidValue!)").first(decoding: StringValueRow.self)
                guard let row else { throw V2GatewayAuthenticationError.corruptPersistenceState }
                return row.value
            }
            let initial = try await snapshot()
            for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12] {
                let bad = Date(timeIntervalSince1970: seconds)
                for sequence in [[bad], [base, bad]] {
                    clock.set(sequence)
                    await #expect(throws: V2GatewayAuthenticationError.corruptPersistenceState) {
                        try await gateway.authenticateSession(accessToken: localInput, deviceID: device)
                    }
                    #expect(try await snapshot() == initial)
                }
            }
            // A valid lookup that finishes at the exact expiry remains expired.
            clock.set([base, base.addingTimeInterval(60)])
            await #expect(throws: V2GatewayAuthenticationError.unauthenticated) {
                try await gateway.authenticateSession(accessToken: localInput, deviceID: device)
            }
            #expect(try await snapshot() == initial)
            // The finite SQL upper endpoint can round out of range as a Date.
            for table in ["auth_devices", "device_access_tokens"] {
                let column = table == "auth_devices" ? "session_expires_at" : "expires_at"
                try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET \(unsafeRaw: column) = '294276-12-31 23:59:59.999999+00'::timestamptz WHERE device_id = \(bind: device.uuidValue!)").run()
            }
            clock.set([base])
            await #expect(throws: V2GatewayAuthenticationError.corruptPersistenceState) {
                try await gateway.authenticateSession(accessToken: localInput, deviceID: device)
            }
            #expect(try await snapshot() == initial)
            for table in ["auth_devices", "device_access_tokens"] {
                let column = table == "auth_devices" ? "session_expires_at" : "expires_at"
                try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET \(unsafeRaw: column) = \(bind: base.addingTimeInterval(60)) WHERE device_id = \(bind: device.uuidValue!)").run()
            }
            clock.set([base, base.addingTimeInterval(-30)])
            let recovered = try await gateway.authenticateSession(accessToken: localInput, deviceID: device)
            #expect(recovered.userID == senderID)
            #expect(recovered.expiresAt == base.addingTimeInterval(60))
            let control = try #require(try await sql.raw("SELECT latest_change_version::text AS value FROM im_v2.realtime_device_control_versions WHERE user_id=\(bind: senderUUID) AND device_id=\(bind: device.uuidValue!)").first(decoding: StringValueRow.self))
            #expect(recovered.credentialControlVersion == Int64(control.value))
            let activity = try await sql.raw("SELECT last_active_at AS value FROM im_v2.auth_devices WHERE device_id = \(bind: device.uuidValue!)").first(decoding: RevocationClockDateRow.self)
            #expect(activity?.value == base)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 0)
        }
    }

    @Test("Gateway activity cutoff handles legal database clock endpoints")
    func gatewayActivityCutoffBounds() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let key = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 7, count: 32))
            for seconds: Double in [946_684_800 - 211_813_488_000, 946_684_800 + 9_223_371_331_200 - 1_000] {
                let start = Date(timeIntervalSince1970: seconds), device = DeviceID(uuid: UUID())
                let localInput = "gateway-cutoff-local-fixture-" + device.rawValue
                try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: senderUUID), \(bind: device.uuidValue!), \(bind: start), \(bind: start), \(bind: start.addingTimeInterval(120)))").run()
                try await sql.raw("INSERT INTO im_v2.device_access_tokens (token_hmac, user_id, device_id, issued_at, expires_at) VALUES (\(bind: key.digest(localInput)), \(bind: senderUUID), \(bind: device.uuidValue!), \(bind: start), \(bind: start.addingTimeInterval(120)))").run()
                let clock = TestSequenceClock([start])
                let gateway = V2PostgresGatewayAuthenticator(database: database, tokenKey: key, now: { clock.now() })
                #expect(try await gateway.authenticateSession(accessToken: localInput, deviceID: device).userID == senderID)
                clock.set([start.addingTimeInterval(61)])
                #expect(try await gateway.authenticateSession(accessToken: localInput, deviceID: device).userID == senderID)
                let activity = try await sql.raw("SELECT last_active_at AS value FROM im_v2.auth_devices WHERE device_id = \(bind: device.uuidValue!)").first(decoding: RevocationClockDateRow.self)
                #expect(activity?.value == start.addingTimeInterval(61))
            }
        }
    }


    @Test("Registration cancellation clock errors preserve pending and bound state", arguments: [false, true])
    func registrationCancellationClockBounds(bound: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let clock = TestSequenceClock([base])
            let device = DeviceID(uuid: UUID())
            let request = try V2DeviceRegistrationCancellation(deviceID: device, operationID: UUID(), proof: .generate(), issueBeforeMilliseconds: 1_750_000_600_000)
            let service = V2PostgresDeviceRegistrationCancellationService(database: database, now: { clock.now() })
            if bound {
                // Device metadata only; no credentials are issued for this fixture.
                try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: senderUUID), \(bind: device.uuidValue!), \(bind: base), \(bind: base), \(bind: base.addingTimeInterval(60)))").run()
                try await V2PostgresDeviceRegistrationCancellationService.bindIssuedSession(sql, request: request, userID: senderUUID, at: base)
            }
            func snapshot() async throws -> String {
                let row = try await sql.raw("""
                    SELECT jsonb_build_object(
                        'devices', (SELECT jsonb_agg(to_jsonb(r) ORDER BY device_id) FROM im_v2.auth_devices r),
                        'events', (SELECT jsonb_agg(to_jsonb(r) ORDER BY event_id) FROM im_v2.device_revocation_events r),
                        'cancellations', (SELECT jsonb_agg(to_jsonb(r) - 'request_digest' ORDER BY device_id, operation_id) FROM im_v2.device_registration_cancellations r)
                    )::text AS value
                    """).first(decoding: StringValueRow.self)
                guard let row else { throw V2DeviceSessionServiceError.malformedPersistence }
                return row.value
            }
            let initial = try await snapshot()
            let badSeconds: [Double] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12]
            for seconds in badSeconds {
                let bad = Date(timeIntervalSince1970: seconds)
                clock.set([bad])
                await #expect(throws: V2DeviceSessionServiceError.unavailable) { try await service.cancel(request) }
                await #expect(throws: V2DeviceSessionServiceError.unavailable) { try await V2PostgresDeviceRegistrationCancellationService.permitsIssuance(sql, request: request, at: bad) }
                await #expect(throws: V2DeviceSessionServiceError.unavailable) { try await V2PostgresDeviceRegistrationCancellationService.bindIssuedSession(sql, request: request, userID: senderUUID, at: bad) }
                #expect(try await snapshot() == initial)
            }
            clock.set([base.addingTimeInterval(bound ? 660 : 600)])
            #expect(try await service.cancel(request) == .expired)
            #expect(try await snapshot() == initial)
            if bound {
                clock.set([base])
                try await sql.raw("CREATE FUNCTION im_v2.test_cancel_clock_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'local cancellation rollback'; END $$").run()
                try await sql.raw("CREATE TRIGGER test_cancel_clock_failure BEFORE INSERT ON im_v2.device_revocation_events FOR EACH ROW EXECUTE FUNCTION im_v2.test_cancel_clock_failure()").run()
                await #expect(throws: (any Error).self) { try await service.cancel(request) }
                #expect(try await snapshot() == initial)
                try await sql.raw("DROP TRIGGER test_cancel_clock_failure ON im_v2.device_revocation_events").run()
            }
            clock.set([base.addingTimeInterval(1)])
            let outcomes = try await withThrowingTaskGroup(of: V2DeviceRegistrationCancellationOutcome.self) { group in
                for _ in 0..<8 { group.addTask { try await service.cancel(request) } }
                var results: [V2DeviceRegistrationCancellationOutcome] = []
                for try await result in group { results.append(result) }
                return results
            }
            #expect(outcomes.filter { $0 == .applied }.count == 1)
            #expect(outcomes.filter { $0 == .idempotent }.count == 7)
            #expect(try await count("im_v2.device_registration_cancellations WHERE cancelled_at IS NOT NULL", on: sql) == 1)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == (bound ? 1 : 0))
            let committed = try await snapshot()
            for seconds in badSeconds {
                clock.set([Date(timeIntervalSince1970: seconds)])
                #expect(try await service.cancel(request) == .idempotent)
                #expect(try await snapshot() == committed)
            }
        }
    }

    @Test("Cancellation deadlines use database microseconds for pending and bound requests")
    func registrationCancellationClockPrecision() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let epoch = Date(timeIntervalSince1970: 946_684_800)
            let clock = TestSequenceClock([epoch.addingTimeInterval(-0.00000025)])
            let service = V2PostgresDeviceRegistrationCancellationService(database: database, now: { clock.now() })
            let pending = try V2DeviceRegistrationCancellation(deviceID: .init(uuid: UUID()), operationID: UUID(), proof: .generate(), issueBeforeMilliseconds: 946_684_800_000)
            #expect(clock.now() < pending.issueBefore)
            #expect(try await service.cancel(pending) == .expired)
            #expect(try await count("im_v2.device_registration_cancellations", on: sql) == 0)
            clock.set([epoch.addingTimeInterval(-0.000002)])
            #expect(try await service.cancel(pending) == .applied)
            let device = DeviceID(uuid: UUID())
            let bound = try V2DeviceRegistrationCancellation(deviceID: device, operationID: UUID(), proof: .generate(), issueBeforeMilliseconds: 946_684_900_000)
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: senderUUID), \(bind: device.uuidValue!), '1999-12-31 23:59:59+00'::timestamptz, '1999-12-31 23:59:59+00'::timestamptz, '2000-01-01 00:00:00.000001+00'::timestamptz)").run()
            try await V2PostgresDeviceRegistrationCancellationService.bindIssuedSession(sql, request: bound, userID: senderUUID, at: epoch.addingTimeInterval(-1))
            let expiry = try await sql.raw("SELECT session_expires_at AS value FROM im_v2.auth_devices WHERE device_id=\(bind: device.uuidValue!)").first(decoding: RevocationClockDateRow.self)
            guard let expiry else { throw V2DeviceSessionServiceError.malformedPersistence }
            let roundedDeadline = expiry.value.addingTimeInterval(600)
            // The clock still encodes one microsecond before the SQL deadline,
            // even though the decoded Date plus 600 compares equal to it.
            let remaining = try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.auth_devices WHERE device_id=\(bind: device.uuidValue!) AND session_expires_at + interval '10 minutes' > \(bind: roundedDeadline)").first(decoding: CountRow.self)
            #expect(remaining?.value == 1)
            clock.set([roundedDeadline])
            #expect(try await service.cancel(bound) == .applied)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 1)
            for literal in ["294276-12-31 23:59:50+00", "294276-12-31 23:59:59.999999+00"] {
                let largeDevice = DeviceID(uuid: UUID())
                let large = try V2DeviceRegistrationCancellation(deviceID: largeDevice, operationID: UUID(), proof: .generate(), issueBeforeMilliseconds: 946_684_900_000)
                try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: senderUUID), \(bind: largeDevice.uuidValue!), '294276-12-31 22:00:00+00'::timestamptz, '294276-12-31 22:00:00+00'::timestamptz, \(bind: literal)::timestamptz)").run()
                try await V2PostgresDeviceRegistrationCancellationService.bindIssuedSession(sql, request: large, userID: senderUUID, at: epoch.addingTimeInterval(-1))
                // A stale binding one microsecond away must remain distinct,
                // even when the two SQL values decode to the same Date.
                try await sql.raw("UPDATE im_v2.auth_devices SET created_at=created_at + interval '1 microsecond' WHERE device_id=\(bind: largeDevice.uuidValue!)").run()
                await #expect(throws: V2DeviceSessionServiceError.malformedPersistence) { try await service.cancel(large) }
                let unchanged = try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.device_registration_cancellations WHERE device_id=\(bind: largeDevice.uuidValue!) AND cancelled_at IS NULL").first(decoding: CountRow.self)
                #expect(unchanged?.value == 1)
                try await sql.raw("UPDATE im_v2.auth_devices d SET created_at=c.session_created_at FROM im_v2.device_registration_cancellations c WHERE d.device_id=c.device_id AND d.device_id=\(bind: largeDevice.uuidValue!)").run()
                // The grace period need not fit timestamptz: it is compared,
                // not persisted, and this legal session must still be cancelled.
                #expect(try await service.cancel(large) == .applied)
            }
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 3)
        }
    }

    @Test("Revocation capability issuance validates clock, stored dates and grace-period overflow")
    func revocationCapabilityIssueClockBounds() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let device = DeviceID(uuid: UUID())
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: senderUUID), \(bind: device.uuidValue!), \(bind: base), \(bind: base), \(bind: base.addingTimeInterval(60)))").run()
            func issue(device: DeviceID, at: Date) async throws -> V2IssuedDeviceRevocationCapability {
                try await database.transaction { transaction in
                    guard let sql = transaction as? any SQLDatabase else { throw V2DeviceSessionServiceError.unavailable }
                    return try await V2PostgresDeviceSessionService.issueRevocationCapability(on: sql, userID: senderID, deviceID: device, at: at)
                }
            }
            let badSeconds: [Double] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12]
            for seconds in badSeconds {
                await #expect(throws: V2DeviceSessionServiceError.unavailable) { try await issue(device: device, at: Date(timeIntervalSince1970: seconds)) }
                #expect(try await count("im_v2.device_revocation_capabilities", on: sql) == 0)
            }
            for literal in ["infinity", "-infinity", "294276-12-31 23:59:59.999999+00"] {
                // Raw persisted extremes exercise Date decoding, without passing
                // unrepresentable Date values into the driver's encoder.
                try await sql.raw("UPDATE im_v2.auth_devices SET created_at=\(bind: literal)::timestamptz WHERE device_id=\(bind: device.uuidValue!)").run()
                await #expect(throws: V2DeviceSessionServiceError.malformedPersistence) { try await issue(device: device, at: base) }
                #expect(try await count("im_v2.device_revocation_capabilities", on: sql) == 0)
            }
            try await sql.raw("UPDATE im_v2.auth_devices SET created_at=\(bind: base), session_expires_at='294276-12-31 23:59:59.999999+00'::timestamptz WHERE device_id=\(bind: device.uuidValue!)").run()
            await #expect(throws: V2DeviceSessionServiceError.malformedPersistence) { try await issue(device: device, at: base) }
            let nearEnd = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)
            try await sql.raw("UPDATE im_v2.auth_devices SET session_expires_at=\(bind: nearEnd) WHERE device_id=\(bind: device.uuidValue!)").run()
            await #expect(throws: V2DeviceSessionServiceError.unavailable) { try await issue(device: device, at: base) }
            #expect(try await count("im_v2.device_revocation_capabilities", on: sql) == 0)
            for literal in ["2000-01-01 00:00:00.000001+00", "2025-06-15 12:00:00.123456+00"] {
                let preciseDevice = DeviceID(uuid: UUID())
                try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: senderUUID), \(bind: preciseDevice.uuidValue!), \(bind: literal)::timestamptz, \(bind: literal)::timestamptz, \(bind: literal)::timestamptz + interval '1 minute')").run()
                let created = try await sql.raw("SELECT created_at AS value FROM im_v2.auth_devices WHERE device_id=\(bind: preciseDevice.uuidValue!)").first(decoding: RevocationClockDateRow.self)
                guard let created else { throw V2DeviceSessionServiceError.malformedPersistence }
                let issued = try await issue(device: preciseDevice, at: created.value.addingTimeInterval(1))
                let matching = try await V2PostgresDeviceSessionService.matchingRevocationCapability(on: sql, userID: senderID, deviceID: preciseDevice, credential: issued.credential)
                #expect(matching?.expiresAt == issued.expiresAt)
                let exact = try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.device_revocation_capabilities c JOIN im_v2.auth_devices d USING (user_id, device_id) WHERE c.device_id=\(bind: preciseDevice.uuidValue!) AND c.session_created_at=d.created_at AND c.session_expires_at=d.session_expires_at AND c.expires_at=d.session_expires_at + interval '10 minutes'").first(decoding: CountRow.self)
                #expect(exact?.value == 1)
            }
            let validSeconds: [Double] = [946_684_800 - 211_813_488_000, 1_750_000_000, 946_684_800 + 9_223_371_331_200 - 1_000]
            for seconds in validSeconds {
                let date = Date(timeIntervalSince1970: seconds), localDevice = DeviceID(uuid: UUID())
                try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: senderUUID), \(bind: localDevice.uuidValue!), \(bind: date), \(bind: date), \(bind: date.addingTimeInterval(10)))").run()
                let issued = try await issue(device: localDevice, at: date)
                #expect(issued.expiresAt == date.addingTimeInterval(610))
                let matching = try await V2PostgresDeviceSessionService.matchingRevocationCapability(on: sql, userID: senderID, deviceID: localDevice, credential: issued.credential)
                #expect(matching?.expiresAt == issued.expiresAt)
                let stored = try await sql.raw("SELECT expires_at AS value FROM im_v2.device_revocation_capabilities WHERE device_id=\(bind: localDevice.uuidValue!)").first(decoding: RevocationClockDateRow.self)
                #expect(stored?.value == issued.expiresAt)
            }
        }
    }

    @Test("Revocation clock errors preserve state, recovery and exact expiry semantics")
    func revocationCapabilityRedeemClockBounds() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let clock = TestSequenceClock([base])
            let device = DeviceID(uuid: UUID()), operation = UUID()
            let service = V2PostgresDeviceSessionService(database: database, now: { clock.now() })
            // Isolated test session; no account assertions or access/refresh tokens.
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: senderUUID), \(bind: device.uuidValue!), \(bind: base), \(bind: base), \(bind: base.addingTimeInterval(60)))").run()
            let issued = try await database.transaction { transaction in
                guard let sql = transaction as? any SQLDatabase else { throw V2DeviceSessionServiceError.unavailable }
                return try await V2PostgresDeviceSessionService.issueRevocationCapability(on: sql, userID: senderID, deviceID: device, at: base)
            }
            func snapshot() async throws -> String {
                let row = try await sql.raw("""
                    SELECT jsonb_build_object(
                        'devices', (SELECT jsonb_agg(to_jsonb(r) ORDER BY device_id) FROM im_v2.auth_devices r),
                        'events', (SELECT jsonb_agg(to_jsonb(r) ORDER BY event_id) FROM im_v2.device_revocation_events r),
                        'operations', (SELECT jsonb_agg(to_jsonb(r) ORDER BY actor_user_id, operation_id) FROM im_v2.device_session_operations r),
                        'capabilities', (SELECT jsonb_agg(to_jsonb(r) - 'credential_digest' ORDER BY device_id) FROM im_v2.device_revocation_capabilities r)
                    )::text AS value
                    """).first(decoding: StringValueRow.self)
                guard let row else { throw V2DeviceSessionServiceError.malformedPersistence }
                return row.value
            }
            let initial = try await snapshot()
            let badSeconds: [Double] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12]
            for seconds in badSeconds {
                clock.set([Date(timeIntervalSince1970: seconds)])
                await #expect(throws: V2DeviceSessionServiceError.unavailable) { try await service.redeem(issued.credential, operationID: operation) }
                #expect(try await snapshot() == initial)
            }
            clock.set([issued.expiresAt])
            #expect(try await service.redeem(issued.credential, operationID: operation) == .expired)
            #expect(try await snapshot() == initial)
            clock.set([base.addingTimeInterval(1)])
            try await sql.raw("CREATE FUNCTION im_v2.test_redeem_clock_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'local operation failure'; END $$").run()
            try await sql.raw("CREATE TRIGGER test_redeem_clock_failure BEFORE INSERT ON im_v2.device_session_operations FOR EACH ROW EXECUTE FUNCTION im_v2.test_redeem_clock_failure()").run()
            await #expect(throws: (any Error).self) { try await service.redeem(issued.credential, operationID: operation) }
            #expect(try await snapshot() == initial)
            try await sql.raw("DROP TRIGGER test_redeem_clock_failure ON im_v2.device_session_operations").run()
            let outcomes = try await withThrowingTaskGroup(of: V2DeviceRevocationCapabilityOutcome.self) { group in
                for _ in 0..<8 { group.addTask { try await service.redeem(issued.credential, operationID: operation) } }
                var results: [V2DeviceRevocationCapabilityOutcome] = []
                for try await result in group { results.append(result) }
                return results
            }
            #expect(outcomes.filter { $0 == .applied }.count == 1)
            #expect(outcomes.filter { $0 == .idempotent }.count == 7)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 1)
            #expect(try await count("im_v2.device_session_operations", on: sql) == 1)
            let committed = try await snapshot()
            for seconds in badSeconds {
                clock.set([Date(timeIntervalSince1970: seconds)])
                await #expect(throws: V2DeviceSessionServiceError.unavailable) { try await service.redeem(issued.credential, operationID: operation) }
                #expect(try await snapshot() == committed)
            }
            clock.set([issued.expiresAt])
            #expect(try await service.redeem(issued.credential, operationID: operation) == .expired)
            #expect(try await snapshot() == committed)
            // A finite SQL timestamp can round up to the exclusive bound when
            // decoded into Date. Keep the existing binding and SQL constraints.
            try await sql.raw("UPDATE im_v2.auth_devices SET session_expires_at='294276-12-31 23:49:59.999999+00'::timestamptz WHERE device_id=\(bind: device.uuidValue!)").run()
            try await sql.raw("UPDATE im_v2.device_revocation_capabilities SET session_expires_at='294276-12-31 23:49:59.999999+00'::timestamptz, expires_at='294276-12-31 23:59:59.999999+00'::timestamptz WHERE device_id=\(bind: device.uuidValue!)").run()
            let malformed = try await snapshot()
            clock.set([base])
            await #expect(throws: V2DeviceSessionServiceError.malformedPersistence) { try await service.redeem(issued.credential, operationID: UUID()) }
            await #expect(throws: V2DeviceSessionServiceError.malformedPersistence) {
                try await V2PostgresDeviceSessionService.matchingRevocationCapability(on: sql, userID: senderID, deviceID: device, credential: issued.credential)
            }
            #expect(try await snapshot() == malformed)
        }
    }

    @Test("Password account writes reject invalid clocks and roll back failed audits")
    func passwordAccountClockBounds() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let clock = TestSequenceClock([base])
            let store = V2PostgresPasswordAccountStore(database: database, now: { clock.now() })
            let device = DeviceID(uuid: UUID())
            // Known local digest fixture; no assertions or device credentials are issued.
            @Sendable func register(_ handle: String, publicHandle: String) async throws -> UserID {
                try await store.register(accountHandle: handle, passwordHash: V2PasswordHashPolicy.dummyDigest,
                    publicHandle: publicHandle, displayName: "Clock fixture", deviceID: device)
            }
            func snapshot() async throws -> String {
                let row = try await sql.raw("""
                    SELECT jsonb_build_object(
                        'accounts', (SELECT jsonb_agg(jsonb_build_array(account_handle, user_id, created_at) ORDER BY account_handle) FROM im_v2.account_password_credentials),
                        'profiles', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id) FROM im_v2.public_user_profiles r),
                        'audit', (SELECT jsonb_agg(to_jsonb(r) ORDER BY event_id) FROM im_v2.account_password_authentication_audit r),
                        'limits', (SELECT jsonb_agg(to_jsonb(r) ORDER BY account_handle) FROM im_v2.account_password_login_rate_limits r)
                    )::text AS value
                    """).first(decoding: StringValueRow.self)
                guard let row else { throw V2PasswordAccountStoreError.unavailable }
                return row.value
            }
            let badSeconds: [Double] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12]
            let initial = try await snapshot()
            for seconds in badSeconds {
                clock.set([Date(timeIntervalSince1970: seconds)])
                await #expect(throws: V2PasswordAccountStoreError.unavailable) { try await register("clock-account", publicHandle: "clock_account") }
                #expect(try await snapshot() == initial)
            }
            clock.set([base])
            let user = try await register("clock-account", publicHandle: "clock_account")
            let expected = V2PasswordCredential(userID: user, passwordHash: V2PasswordHashPolicy.dummyDigest)
            try await sql.raw("INSERT INTO im_v2.account_password_login_rate_limits (account_handle, window_started_at, failure_count, updated_at) VALUES ('clock-account', \(bind: base), 1, \(bind: base))").run()
            let registered = try await snapshot()
            for seconds in badSeconds {
                clock.set([Date(timeIntervalSince1970: seconds)])
                await #expect(throws: V2PasswordAccountStoreError.unavailable) {
                    try await store.completeAuthentication(accountHandle: "clock-account", expected: expected, deviceID: device)
                }
                await #expect(throws: V2PasswordAccountStoreError.accountAlreadyExists) { try await register("clock-account", publicHandle: "clock_unused") }
                await #expect(throws: V2PasswordAccountStoreError.publicHandleAlreadyExists) { try await register("clock-unused", publicHandle: "clock_account") }
                #expect(try await snapshot() == registered)
            }
            clock.set([base])
            try await sql.raw("CREATE FUNCTION im_v2.test_password_clock_audit_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'local audit failure'; END $$").run()
            try await sql.raw("CREATE TRIGGER test_password_clock_audit_failure BEFORE INSERT ON im_v2.account_password_authentication_audit FOR EACH ROW EXECUTE FUNCTION im_v2.test_password_clock_audit_failure()").run()
            await #expect(throws: (any Error).self) { try await register("clock-other", publicHandle: "clock_other") }
            #expect(try await snapshot() == registered)
            await #expect(throws: (any Error).self) {
                try await store.completeAuthentication(accountHandle: "clock-account", expected: expected, deviceID: device)
            }
            #expect(try await snapshot() == registered)
            try await sql.raw("DROP TRIGGER test_password_clock_audit_failure ON im_v2.account_password_authentication_audit").run()
            // A backward wall-clock adjustment remains a valid timestamp.
            clock.set([base.addingTimeInterval(-30)])
            #expect(try await store.completeAuthentication(accountHandle: "clock-account", expected: expected, deviceID: device))
            #expect(try await count("im_v2.account_password_login_rate_limits", on: sql) == 0)
            #expect(try await count("im_v2.account_password_authentication_audit", on: sql) == 2)
            let success = try await sql.raw("SELECT occurred_at AS value FROM im_v2.account_password_authentication_audit WHERE outcome='assertion_succeeded'").first(decoding: RevocationClockDateRow.self)
            #expect(success?.value == base.addingTimeInterval(-30))
            let validSeconds: [Double] = [946_684_800 - 211_813_488_000, 946_684_800 + 9_223_371_331_200 - 10]
            for (index, seconds) in validSeconds.enumerated() {
                let date = Date(timeIntervalSince1970: seconds)
                clock.set([date])
                let handle = "clock-bound-\(index)"
                let boundaryUser = try await register(handle, publicHandle: "clock_bound_\(index)")
                #expect(try await store.completeAuthentication(accountHandle: handle,
                    expected: .init(userID: boundaryUser, passwordHash: V2PasswordHashPolicy.dummyDigest), deviceID: device))
                let dates = try await sql.raw("""
                    SELECT created_at AS value FROM im_v2.account_password_credentials WHERE user_id=\(bind: boundaryUser.uuidValue!)
                    UNION ALL SELECT created_at FROM im_v2.public_user_profiles WHERE user_id=\(bind: boundaryUser.uuidValue!)
                    UNION ALL SELECT updated_at FROM im_v2.public_user_profiles WHERE user_id=\(bind: boundaryUser.uuidValue!)
                    UNION ALL SELECT occurred_at FROM im_v2.account_password_authentication_audit WHERE user_id=\(bind: boundaryUser.uuidValue!)
                    """).all(decoding: RevocationClockDateRow.self)
                #expect(dates.count == 5)
                #expect(dates.allSatisfy { $0.value == date })
            }
        }
    }

    @Test("Every password audit outcome validates its database timestamp")
    func passwordAuditClockBounds() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { _, _, sql, _, _ in
            let device = DeviceID(uuid: UUID())
            let outcomes: [V2PasswordAuthenticationAuditOutcome] = [.registrationSucceeded, .assertionSucceeded, .assertionRejected]
            let badSeconds: [Double] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12]
            for outcome in outcomes {
                for seconds in badSeconds {
                    await #expect(throws: V2PasswordAuthenticationAuditError.invalidTimestamp) {
                        try await recordPasswordAuthenticationAudit(outcome: outcome,
                            userID: outcome == .assertionRejected ? nil : senderID, deviceID: device,
                            occurredAt: Date(timeIntervalSince1970: seconds), on: sql)
                    }
                }
            }
            #expect(try await count("im_v2.account_password_authentication_audit", on: sql) == 0)
            let validSeconds: [Double] = [946_684_800 - 211_813_488_000, 1_750_000_000, 946_684_800 + 9_223_371_331_200 - 10]
            for seconds in validSeconds {
                let date = Date(timeIntervalSince1970: seconds)
                for outcome in outcomes {
                    try await recordPasswordAuthenticationAudit(outcome: outcome,
                        userID: outcome == .assertionRejected ? nil : senderID, deviceID: device, occurredAt: date, on: sql)
                }
                let rows = try await sql.raw("SELECT occurred_at AS value FROM im_v2.account_password_authentication_audit WHERE occurred_at=\(bind: date)").all(decoding: RevocationClockDateRow.self)
                #expect(rows.count == 3)
                #expect(rows.allSatisfy { $0.value == date })
            }
        }
    }

    @Test("Registration samples its write clock after both uniqueness locks", arguments: ["account", "public"])
    func passwordRegistrationLockClock(lockKind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let clock = TestSequenceClock([Date(timeIntervalSince1970: 1_750_000_000)])
            let store = V2PostgresPasswordAccountStore(database: database, now: { clock.now() })
            let pending = Mutex<Task<UserID, any Error>?>(nil)
            do {
                let task = try await database.transaction { transaction in
                    guard let held = transaction as? any SQLDatabase else { throw V2PasswordAccountStoreError.unavailable }
                    let key = lockKind == "account" ? "v2-account:clock-lock" : "v2-public-handle:clock_lock"
                    try await held.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
                    let task = Task {
                        try await store.register(accountHandle: "clock-lock", passwordHash: V2PasswordHashPolicy.dummyDigest,
                            publicHandle: "clock_lock", displayName: "Clock lock fixture", deviceID: DeviceID(uuid: UUID()))
                    }
                    pending.withLock { $0 = task }
                    var waiting = false
                    for _ in 0..<200 {
                        let row = try await held.raw("SELECT count(*)::bigint AS value FROM pg_locks WHERE NOT granted AND locktype='advisory' AND database=(SELECT oid FROM pg_database WHERE datname=current_database())").first(decoding: CountRow.self)
                        if (row?.value ?? 0) > 0 { waiting = true; break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    #expect(waiting)
                    clock.set([Date(timeIntervalSince1970: .nan)])
                    return task
                }
                await #expect(throws: V2PasswordAccountStoreError.unavailable) { try await task.value }
            } catch {
                // The outer transaction has released its lock; always join the child.
                if let task = pending.withLock({ $0 }) { _ = await task.result }
                throw error
            }
            #expect(try await count("im_v2.account_password_credentials", on: sql) == 0)
            #expect(try await count("im_v2.public_user_profiles WHERE public_handle='clock_lock'", on: sql) == 0)
            #expect(try await count("im_v2.account_password_authentication_audit", on: sql) == 0)
        }
    }

    @Test("Session mutation clocks roll back every stage and preserve normal operation replay", arguments: ["current", "remote", "others"])
    func sessionMutationClockBounds(kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let clock = TestSequenceClock([base])
            let service = V2PostgresDeviceSessionService(database: database, now: { clock.now() })
            let devices = [UUID(), UUID(), UUID()]
            let current = DeviceID(uuid: devices[0]), remote = DeviceID(uuid: devices[1])
            let operation = UUID()
            func seed(user: UUID, devices: [UUID], at: Date) async throws {
                for device in devices {
                    // Device metadata and inert local endpoint fixtures; no credentials are issued.
                    try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: user), \(bind: device), \(bind: at), \(bind: at), \(bind: at.addingTimeInterval(1)))").run()
                    try await sql.raw("INSERT INTO im_v2.push_device_endpoints (device_id, provider, environment, endpoint_generation, encrypted_token, updated_at) VALUES (\(bind: device), 'apns', 'development', \(bind: UUID()), 'sealed-local-fixture', \(bind: at))").run()
                }
            }
            try await seed(user: senderUUID, devices: devices, at: base)
            if kind != "current" {
                let baseline = try await service.remoteRevocationBaseline(actorUserID: senderID, currentDeviceID: current)
                let command = try V2RemoteDeviceRevocationCommand(operationID: operation, baseline: baseline,
                    selection: kind == "remote" ? .device(remote) : .allObservedOthers,
                    firstSubmissionDeadlineMilliseconds: baseline.expiresAtMilliseconds)
                func remoteSnapshot() async throws -> String {
                    try #require(try await sql.raw("""
                        SELECT jsonb_build_object(
                            'devices',(SELECT jsonb_agg(to_jsonb(r) ORDER BY device_id) FROM im_v2.auth_devices r),
                            'endpoints',(SELECT jsonb_agg(to_jsonb(r) ORDER BY device_id) FROM im_v2.push_device_endpoints r),
                            'events',(SELECT jsonb_agg(to_jsonb(r) ORDER BY event_id) FROM im_v2.device_revocation_events r),
                            'proofs',(SELECT jsonb_agg(to_jsonb(r) ORDER BY operation_id) FROM im_v2.remote_device_revocation_receipts r),
                            'baselines',(SELECT jsonb_agg(to_jsonb(r) ORDER BY baseline_id) FROM im_v2.remote_device_revocation_baselines r),
                            'access_count',(SELECT count(*) FROM im_v2.device_access_tokens),
                            'refresh_count',(SELECT count(*) FROM im_v2.device_refresh_sessions)
                        )::text AS value
                        """).first(decoding: StringValueRow.self)).value
                }
                let initial = try await remoteSnapshot()
                let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
                for bad in badDates {
                    clock.set([bad])
                    await #expect(throws: (any Error).self) { _ = try await service.submitRemoteRevocation(command) }
                    #expect(try await remoteSnapshot() == initial)
                    await #expect(throws: V2DeviceSessionServiceError.unavailable) {
                        try await V2PostgresDeviceSessionService.revokeSession(sql, userID: senderUUID, deviceID: devices[1], at: bad)
                    }
                    #expect(try await remoteSnapshot() == initial)
                }
                clock.set([base])
                try await sql.raw("CREATE FUNCTION im_v2.test_session_clock_operation_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'local session operation failure'; END $$").run()
                try await sql.raw("CREATE TRIGGER test_session_clock_operation_failure BEFORE INSERT ON im_v2.remote_device_revocation_receipts FOR EACH ROW EXECUTE FUNCTION im_v2.test_session_clock_operation_failure()").run()
                await #expect(throws: (any Error).self) { _ = try await service.submitRemoteRevocation(command) }
                #expect(try await remoteSnapshot() == initial)
                try await sql.raw("DROP TRIGGER test_session_clock_operation_failure ON im_v2.remote_device_revocation_receipts").run()
                clock.set([base])
                let results = try await withThrowingTaskGroup(of: V2RemoteDeviceRevocationResult.self) { tasks in
                    for _ in 0..<8 { tasks.addTask { try await service.submitRemoteRevocation(command) } }
                    var values: [V2RemoteDeviceRevocationResult] = []
                    for try await value in tasks { values.append(value) }
                    return values
                }
                guard case .receipt(let proof) = try #require(results.first) else { throw V2DeviceSessionServiceError.malformedPersistence }
                #expect(proof.validates(command) && proof.outcome == .revoked)
                #expect(results.count == 8 && results.allSatisfy { $0 == .receipt(proof) })
                let expectedCount: Int64 = kind == "others" ? 2 : 1
                #expect(try await count("im_v2.device_revocation_events", on: sql) == expectedCount)
                #expect(try await count("im_v2.auth_devices WHERE revoked_at IS NOT NULL", on: sql) == expectedCount)
                #expect(try await count("im_v2.push_device_endpoints WHERE disabled_at IS NOT NULL", on: sql) == expectedCount)
                #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.auth_devices WHERE revoked_at = \(bind: base)").first(decoding: CountRow.self)?.value == expectedCount)
                #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.push_device_endpoints WHERE disabled_at = \(bind: base)").first(decoding: CountRow.self)?.value == expectedCount)
                #expect(try await count("im_v2.remote_device_revocation_receipts", on: sql) == 1)
                #expect(try await count("im_v2.device_session_operations", on: sql) == 0)
                let committed = try await remoteSnapshot()
                for bad in badDates {
                    clock.set([bad])
                    #expect(try await service.submitRemoteRevocation(command) == .receipt(proof))
                    #expect(try await service.recoverRemoteRevocation(.init(command: command, action: .query)) == .receipt(proof))
                    #expect(try await service.recoverRemoteRevocation(.init(command: command, action: .closeIfAbsent)) == .receipt(proof))
                    #expect(try await remoteSnapshot() == committed)
                }
                return
            }
            @Sendable func mutate(user: UserID, current: DeviceID, remote: DeviceID, operation: UUID) async throws -> V2DeviceSessionMutationOutcome {
                try await service.revokeCurrentDevice(actorUserID: user, currentDeviceID: current, operationID: operation)
            }
            @Sendable func apply() async throws -> V2DeviceSessionMutationOutcome {
                try await mutate(user: senderID, current: current, remote: remote, operation: operation)
            }
            func snapshot() async throws -> String {
                let row = try await sql.raw("""
                    SELECT jsonb_build_object(
                        'devices', (SELECT jsonb_agg(to_jsonb(r) ORDER BY device_id) FROM im_v2.auth_devices r),
                        'endpoints', (SELECT jsonb_agg(to_jsonb(r) ORDER BY device_id) FROM im_v2.push_device_endpoints r),
                        'events', (SELECT jsonb_agg(to_jsonb(r) ORDER BY event_id) FROM im_v2.device_revocation_events r),
                        'operations', (SELECT jsonb_agg(to_jsonb(r) ORDER BY actor_user_id, operation_id) FROM im_v2.device_session_operations r),
                        'access_count', (SELECT count(*) FROM im_v2.device_access_tokens),
                        'refresh_count', (SELECT count(*) FROM im_v2.device_refresh_sessions)
                    )::text AS value
                    """).first(decoding: StringValueRow.self)
                guard let row else { throw V2DeviceSessionServiceError.malformedPersistence }
                return row.value
            }
            let initial = try await snapshot()
            let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            let clockReads = kind == "remote" ? 3 : 2
            for bad in badDates {
                for stage in 0..<clockReads {
                    clock.set(Array(repeating: base, count: stage) + [bad])
                    await #expect(throws: V2DeviceSessionServiceError.unavailable) { try await apply() }
                    #expect(try await snapshot() == initial)
                }
                await #expect(throws: V2DeviceSessionServiceError.unavailable) { try await V2PostgresDeviceSessionService.revokeSession(sql, userID: senderUUID, deviceID: devices[1], at: bad) }
                #expect(try await snapshot() == initial)
            }
            clock.set([base])
            try await sql.raw("CREATE FUNCTION im_v2.test_session_clock_operation_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'local session operation failure'; END $$").run()
            try await sql.raw("CREATE TRIGGER test_session_clock_operation_failure BEFORE INSERT ON im_v2.device_session_operations FOR EACH ROW EXECUTE FUNCTION im_v2.test_session_clock_operation_failure()").run()
            await #expect(throws: (any Error).self) { try await apply() }
            #expect(try await snapshot() == initial)
            try await sql.raw("DROP TRIGGER test_session_clock_operation_failure ON im_v2.device_session_operations").run()
            clock.set([base.addingTimeInterval(-30)])
            let outcomes = try await withThrowingTaskGroup(of: V2DeviceSessionMutationOutcome.self) { group in
                for _ in 0..<8 { group.addTask { try await apply() } }
                var results: [V2DeviceSessionMutationOutcome] = []
                for try await result in group { results.append(result) }
                return results
            }
            #expect(outcomes.filter { $0 == .applied }.count == 1)
            #expect(outcomes.filter { $0 == .idempotent }.count == 7)
            let expectedCount: Int64 = kind == "others" ? 2 : 1
            #expect(try await count("im_v2.device_revocation_events", on: sql) == expectedCount)
            #expect(try await count("im_v2.device_session_operations", on: sql) == 1)
            #expect(try await count("im_v2.auth_devices WHERE revoked_at IS NOT NULL", on: sql) == expectedCount)
            #expect(try await count("im_v2.push_device_endpoints WHERE disabled_at IS NOT NULL", on: sql) == expectedCount)
            let committed = try await snapshot()
            for bad in badDates {
                // Current-device replay needs no fresh write. Other operations retain
                // the existing current-device check, then replay without reading a write clock.
                clock.set(kind == "current" ? [bad] : [base, bad])
                #expect(try await apply() == .idempotent)
                #expect(try await snapshot() == committed)
            }
            let expectedDevices = kind == "current" ? [devices[0]] : kind == "remote" ? [devices[1]] : [devices[1], devices[2]]
            struct DeviceState: Decodable { let deviceID: UUID; let revokedAt: Date?; let disabledAt: Date?
                enum CodingKeys: String, CodingKey { case deviceID = "device_id", revokedAt = "revoked_at", disabledAt = "disabled_at" }
            }
            let state = try await sql.raw("SELECT device.device_id, device.revoked_at, endpoint.disabled_at FROM im_v2.auth_devices device JOIN im_v2.push_device_endpoints endpoint USING (device_id) WHERE device.user_id = \(bind: senderUUID)").all(decoding: DeviceState.self)
            for device in state {
                let expected = expectedDevices.contains(device.deviceID) ? base.addingTimeInterval(-30) : nil
                #expect(device.revokedAt == expected)
                #expect(device.disabledAt == expected)
            }
            for valid in [Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000), Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)] {
                let user = UserID(uuid: UUID()), boundaryDevices = [UUID(), UUID(), UUID()]
                try await seed(user: user.uuidValue!, devices: boundaryDevices, at: valid)
                clock.set([valid])
                #expect(try await mutate(user: user, current: .init(uuid: boundaryDevices[0]), remote: .init(uuid: boundaryDevices[1]), operation: UUID()) == .applied)
                let dates = try await sql.raw("SELECT created_at AS value FROM im_v2.device_session_operations WHERE actor_user_id = \(bind: user.uuidValue!) UNION ALL SELECT created_at AS value FROM im_v2.device_revocation_events WHERE user_id = \(bind: user.uuidValue!)").all(decoding: RevocationClockDateRow.self)
                #expect(dates.count == Int(expectedCount) + 1)
                #expect(dates.allSatisfy { $0.value == valid })
            }
        }
    }

    @Test("Session inventory clocks reject unsafe queries and preserve normal pagination")
    func sessionInventoryClockBounds() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let clock = TestSequenceClock([base])
            let service = V2PostgresDeviceSessionService(database: database, now: { clock.now() })
            let devices = [UUID(), UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
            for (index, device) in devices.enumerated() {
                let activeAt = base.addingTimeInterval(index == 2 ? -1 : 0)
                try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at, display_name, platform) VALUES (\(bind: senderUUID), \(bind: device), \(bind: base.addingTimeInterval(-60)), \(bind: activeAt), \(bind: base.addingTimeInterval(60)), 'Local test device', 'test')").run()
            }
            func snapshot() async throws -> String {
                let row = try await sql.raw("SELECT jsonb_agg(to_jsonb(d) ORDER BY device_id)::text AS value FROM im_v2.auth_devices d").first(decoding: StringValueRow.self)
                guard let row else { throw V2DeviceSessionServiceError.malformedPersistence }
                return row.value
            }
            let first = try await service.sessions(for: senderID, cursor: nil, pageSize: 1)
            #expect(first.sessions.map(\.deviceID.uuidValue) == [devices[0]])
            let cursor = try #require(first.nextCursor)
            let initial = try await snapshot()
            let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            for bad in badDates {
                clock.set([bad])
                for value in [nil, Optional(cursor)] {
                    await #expect(throws: V2DeviceSessionServiceError.unavailable) { try await service.sessions(for: senderID, cursor: value, pageSize: 1) }
                }
                #expect(try await snapshot() == initial)
            }
            clock.set([base])
            struct LegacyCursor: Encodable { let lastActiveAt: Date; let deviceID: UUID }
            for bad in badDates where bad.timeIntervalSinceReferenceDate.isFinite {
                let stale = try JSONEncoder().encode(LegacyCursor(lastActiveAt: bad, deviceID: devices[0])).base64EncodedString()
                await #expect(throws: V2DeviceSessionServiceError.invalidRequest) { try await service.sessions(for: senderID, cursor: stale, pageSize: 1) }
                #expect(try await snapshot() == initial)
            }
            struct ExactCursor: Encodable { let lastActiveAt: Date; let deviceID: UUID; let lastActiveAtMicroseconds: Int64 }
            for microseconds: Int64 in [.min, .max, -211_813_488_000_000_001, 9_223_371_331_200_000_000] {
                let invalid = try JSONEncoder().encode(ExactCursor(lastActiveAt: base, deviceID: devices[0], lastActiveAtMicroseconds: microseconds)).base64EncodedString()
                await #expect(throws: V2DeviceSessionServiceError.invalidRequest) { try await service.sessions(for: senderID, cursor: invalid, pageSize: 1) }
                #expect(try await snapshot() == initial)
            }
            for size in [Int.min, -1, 0, 101, Int.max] {
                await #expect(throws: V2DeviceSessionServiceError.invalidRequest) { try await service.sessions(for: senderID, cursor: nil, pageSize: size) }
            }
            // A normal backwards clock adjustment preserves order and equal-time peers.
            clock.set([base.addingTimeInterval(-30)])
            let second = try await service.sessions(for: senderID, cursor: cursor, pageSize: 1)
            #expect(second.sessions.map(\.deviceID.uuidValue) == [devices[1]])
            let last = try await service.sessions(for: senderID, cursor: second.nextCursor, pageSize: 1)
            #expect(last.sessions.map(\.deviceID.uuidValue) == [devices[2]])
            #expect(last.nextCursor == nil)
            clock.set([base.addingTimeInterval(60)])
            #expect(try await service.sessions(for: senderID, cursor: nil, pageSize: 1).sessions.isEmpty)
            clock.set([base])
            #expect(try await snapshot() == initial)
            for column in ["created_at", "last_active_at"] {
                for literal in ["infinity", "-infinity", "294276-12-31 23:59:59.999999+00"] {
                    try await sql.raw("UPDATE im_v2.auth_devices SET \(unsafeRaw: column) = \(bind: literal)::timestamptz WHERE device_id = \(bind: devices[0])").run()
                    let before = try await snapshot()
                    await #expect(throws: V2DeviceSessionServiceError.malformedPersistence) { try await service.sessions(for: senderID, cursor: nil, pageSize: 100) }
                    #expect(try await snapshot() == before)
                }
                let restored = column == "created_at" ? base.addingTimeInterval(-60) : base
                try await sql.raw("UPDATE im_v2.auth_devices SET \(unsafeRaw: column) = \(bind: restored) WHERE device_id = \(bind: devices[0])").run()
            }
            #expect(try await snapshot() == initial)
            for valid in [Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000), Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)] {
                let user = UserID(uuid: UUID())
                let boundDevices = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
                for device in boundDevices {
                    try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: user.uuidValue!), \(bind: device), \(bind: valid), \(bind: valid), \(bind: valid.addingTimeInterval(1)))").run()
                }
                clock.set([valid])
                let head = try await service.sessions(for: user, cursor: nil, pageSize: 1)
                #expect(head.sessions.first?.createdAt == valid)
                #expect(head.sessions.first?.lastActiveAt == valid)
                let tail = try await service.sessions(for: user, cursor: head.nextCursor, pageSize: 1)
                #expect(head.sessions.map(\.deviceID.uuidValue) + tail.sessions.map(\.deviceID.uuidValue) == boundDevices.map(Optional.some))
                #expect(tail.nextCursor == nil)
            }
        }
    }

    @Test("Session inventory pagination preserves microsecond ties", arguments: ["2000-01-01 00:00:00.000001+00", "2025-06-15 15:06:40.123456+00"])
    func sessionInventoryCursorPrecision(timestamp: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let devices = [UUID(), UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
            for device in devices {
                try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, session_expires_at) VALUES (\(bind: senderUUID), \(bind: device), \(bind: base.addingTimeInterval(-60)), \(bind: timestamp)::timestamptz, \(bind: base.addingTimeInterval(60)))").run()
            }
            let service = V2PostgresDeviceSessionService(database: database, now: { base })
            var cursor: String?
            var seen: [UUID] = []
            for _ in 0..<4 {
                let page = try await service.sessions(for: senderID, cursor: cursor, pageSize: 1)
                seen.append(contentsOf: page.sessions.compactMap(\.deviceID.uuidValue))
                cursor = page.nextCursor
                if cursor == nil { break }
            }
            #expect(seen == devices)
            #expect(cursor == nil)
            struct LegacyCursor: Encodable { let lastActiveAt: Date; let deviceID: UUID }
            let first = try await service.sessions(for: senderID, cursor: nil, pageSize: 1)
            let firstSession = try #require(first.sessions.first)
            let legacy = try JSONEncoder().encode(LegacyCursor(lastActiveAt: firstSession.lastActiveAt, deviceID: devices[0])).base64EncodedString()
            await #expect(throws: V2DeviceSessionServiceError.invalidRequest) {
                _ = try await service.sessions(for: senderID, cursor: legacy, pageSize: 1)
            }
            let second = try await service.sessions(for: senderID, cursor: first.nextCursor, pageSize: 1)
            #expect(second.sessions.map(\.deviceID.uuidValue) == [devices[1]])
        }
    }

    @Test("Actor forwarding rejects invalid clocks atomically and replays committed results")
    func localForwardClockBounds() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(), clock = TestSequenceClock([Date()])
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=\(bind: base.addingTimeInterval(600))").run()
            let profile = try forwardImportTestProfile(), limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let write = PostgresV2RoomWriteStore(database: database)
            try await withRoomActivation(database: database, roomID: roomID) { token in
                let authorized = V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
                    store: write, shardID: "room-a", epoch: 0, activationToken: token)
                let sender = V2SendMessageService(store: authorized, capacityProfile: profile, limits: limits, now: { base })
                guard case .accepted(let source) = try await sender.send(.init(roomID: roomID, actorUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "forward clock")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
                let reference = try V2ForwardMessageReference(roomID: roomID, messageID: source.messageID, revision: .init(1))
                try await withFixturePolicyOwners(database: database, projectionDelivery: SuccessfulProjectionDelivery()) { owners in
                    let policies = V2RoomPolicyAuthorizationService(roomDatabase: database,
                        policyOwners: owners, endpoint: "forward-clock-test", maximumRooms: 1)
                    do {
                        let executor = V2ActorForwardPairDomainExecutor(database: database, write: write,
                            capacityProfile: profile, limits: limits, now: { clock.now() }).usingPolicyAuthorizations(policies)
                        let pair = V2ActorForwardPairWire(actorUserID: senderID, operationID: .init(uuid: UUID()),
                            source: reference, targetRoomID: roomID)
                        func snapshot() async throws -> String {
                            let row = try #require(try await sql.raw("""
                                SELECT jsonb_build_object(
                                    'operations', (SELECT jsonb_agg(to_jsonb(r) ORDER BY actor_user_id,operation_id,source_message_id,target_room_id) FROM im_v2.message_forward_operations r),
                                    'messages', (SELECT jsonb_agg(to_jsonb(r) ORDER BY message_id) FROM im_v2.messages r),
                                    'events', (SELECT jsonb_agg(to_jsonb(r) ORDER BY room_id,room_sequence) FROM im_v2.room_events r),
                                    'rooms', (SELECT jsonb_agg(to_jsonb(r) ORDER BY room_id) FROM im_v2.rooms r),
                                    'room_admission', (SELECT jsonb_agg(to_jsonb(r) ORDER BY room_id) FROM im_v2.room_admission r),
                                    'shard_admission', (SELECT jsonb_agg(to_jsonb(r) ORDER BY room_shard_id,capacity_profile_id) FROM im_v2.shard_admission_pools r),
                                    'completions', (SELECT jsonb_agg(to_jsonb(r) ORDER BY sender_user_id,client_message_id) FROM im_v2.message_send_completions r)
                                )::text AS value
                                """).first(decoding: StringValueRow.self))
                            return row.value
                        }
                        let invalidSeconds: [Double] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude,
                            -.greatestFiniteMagnitude, 1e14, -1e14, -1e12, -1, 281_474_976_710.656]
                        let postgresMinimum = Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000)
                        let postgresMaximum = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)
                        let badDates = invalidSeconds.map { Date(timeIntervalSince1970: $0) }
                            + [postgresMinimum, postgresMaximum]
                        let initial = try await snapshot()
                        for bad in badDates {
                            clock.set([bad])
                            await #expect(throws: (any Error).self) {
                                _ = try await executor.execute(pair, activationTokens: [token])
                            }
                            #expect(try await snapshot() == initial)
                        }
                        // Current acceptance reads one timestamp; there is no independently committed staging step.
                        clock.set([base.addingTimeInterval(-30), badDates[0]])
                        let accepted = try await executor.execute(pair, activationTokens: [token])
                        #expect(accepted.messageID != nil && accepted.errorCode == nil)
                        #expect(try await count("im_v2.messages", on: sql) == 2)
                        #expect(try await count("im_v2.message_send_completions", on: sql) == 2)
                        #expect(try await count("im_v2.message_forward_operations WHERE result_message_id IS NOT NULL", on: sql) == 1)
                        let committed = try await snapshot()
                        for bad in badDates {
                            clock.set([bad])
                            #expect(try await executor.execute(pair, activationTokens: [token]) == accepted)
                            #expect(try await snapshot() == committed)
                        }
                        let replayed = try await withThrowingTaskGroup(of: V2ActorForwardMessageResultWire.self) { group in
                            for _ in 0..<8 { group.addTask { try await executor.execute(pair, activationTokens: [token]) } }
                            var results: [V2ActorForwardMessageResultWire] = []
                            for try await result in group { results.append(result) }
                            return results
                        }
                        #expect(replayed.count == 8 && replayed.allSatisfy { $0 == accepted })
                        #expect(try await snapshot() == committed)

                        // A ledger update failure rolls back the message and completion in the same transaction.
                        let interrupted = V2ActorForwardPairWire(actorUserID: senderID, operationID: .init(uuid: UUID()),
                            source: reference, targetRoomID: roomID)
                        try await sql.raw("CREATE FUNCTION im_v2.test_forward_clock_result_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'local forward result write failure'; END $$").run()
                        try await sql.raw("CREATE TRIGGER test_forward_clock_result_failure BEFORE UPDATE ON im_v2.message_forward_operations FOR EACH ROW EXECUTE FUNCTION im_v2.test_forward_clock_result_failure()").run()
                        clock.set([base])
                        await #expect(throws: (any Error).self) {
                            _ = try await executor.execute(interrupted, activationTokens: [token])
                        }
                        #expect(try await snapshot() == committed)
                        try await sql.raw("DROP TRIGGER test_forward_clock_result_failure ON im_v2.message_forward_operations").run()
                        let repaired = try await executor.execute(interrupted, activationTokens: [token])
                        #expect(repaired.messageID != nil && repaired.errorCode == nil)
                        #expect(try await count("im_v2.messages", on: sql) == 3)
                        #expect(try await count("im_v2.message_send_completions", on: sql) == 3)
                        #expect(try await count("im_v2.message_forward_operations WHERE result_message_id IS NULL", on: sql) == 0)
                        clock.set([badDates[0]])
                        #expect(try await executor.execute(interrupted, activationTokens: [token]) == repaired)

                        // A failed new pair does not prevent an independent pair from succeeding.
                        let failedPair = V2ActorForwardPairWire(actorUserID: senderID, operationID: .init(uuid: UUID()),
                            source: reference, targetRoomID: roomID)
                        await #expect(throws: (any Error).self) {
                            _ = try await executor.execute(failedPair, activationTokens: [token])
                        }
                        clock.set([base])
                        let independent = V2ActorForwardPairWire(actorUserID: senderID, operationID: .init(uuid: UUID()),
                            source: reference, targetRoomID: roomID)
                        let result = try await executor.execute(independent, activationTokens: [token])
                        #expect(result.messageID != nil && result.errorCode == nil)
                        let retried = try await executor.execute(failedPair, activationTokens: [token])
                        #expect(retried.messageID != nil && retried.errorCode == nil)
                        #expect(try await executor.execute(independent, activationTokens: [token]) == result)
                        #expect(try await count("im_v2.messages", on: sql) == 5)
                        #expect(try await count("im_v2.message_send_completions", on: sql) == 5)
                        #expect(try await count("im_v2.message_forward_operations WHERE result_message_id IS NOT NULL", on: sql) == 4)
                        await policies.shutdown()
                    } catch {
                        await policies.shutdown()
                        throw error
                    }
                }
            }
        }
    }

    @Test("Revocation cursor clocks preserve startup watermarks and replay cleanup after failed acknowledgement")
    func revocationCursorClockBounds() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let clock = TestSequenceClock([base])
            let gatewayStore = V2PostgresDeviceRevocationEventStore(database: database)
            let cleanupStore = V2PostgresDeviceRevocationEventStore.projectionCleanup(database: database)
            let cleaner = V2PostgresRevokedDeviceProjectionStore(database: database)
            let node = "cluster"
            let users = [senderUUID, memberTwoUUID, memberThreeUUID]
            let devices = [UUID(), UUID(), UUID()]
            for index in 0..<3 {
                // Ordinary local device metadata; no access or refresh credentials are issued.
                try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at, revoked_at) VALUES (\(bind: users[index]), \(bind: devices[index]), \(bind: base), \(bind: base), \(bind: base))").run()
                try await sql.raw("INSERT INTO im_v2.device_sync_cursors (user_id, device_id, state, reset_generation, acknowledged_sequence) VALUES (\(bind: users[index]), \(bind: devices[index]), 'ready', 1, 7)").run()
            }
            for index in 0..<2 {
                try await sql.raw("INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at) VALUES (\(bind: users[index]), \(bind: devices[index]), \(bind: base))").run()
            }
            let events = try await gatewayStore.events(afterCursorFor: node, limit: 8)
            #expect(events.count == 2)
            let first = try #require(events.first)
            let last = try #require(events.last)
            func cursorSnapshot() async throws -> String {
                let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY worker_name, node_id), '[]'::jsonb)::text AS value FROM im_v2.gateway_worker_cursors c").first(decoding: StringValueRow.self)
                guard let row else { throw V2GatewayAuthenticationError.corruptPersistenceState }
                return row.value
            }
            func projectionSnapshot() async throws -> String {
                let row = try await sql.raw("""
                    SELECT jsonb_build_object(
                        'tombstones', (SELECT jsonb_agg(to_jsonb(t) ORDER BY user_id, device_id) FROM im_v2.revoked_device_projection_tombstones t),
                        'cursors', (SELECT jsonb_agg(to_jsonb(c) ORDER BY user_id, device_id) FROM im_v2.device_sync_cursors c)
                    )::text AS value
                    """).first(decoding: StringValueRow.self)
                guard let row else { throw V2GatewayAuthenticationError.corruptPersistenceState }
                return row.value
            }
            let invalidDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            let initialCursors = try await cursorSnapshot()
            let initialProjections = try await projectionSnapshot()
            for bad in invalidDates {
                for store in [gatewayStore, cleanupStore] {
                    await #expect(throws: V2GatewayAuthenticationError.corruptPersistenceState) { try await store.initializeCursorIfNeeded(nodeID: node, now: bad) }
                    await #expect(throws: V2GatewayAuthenticationError.corruptPersistenceState) { try await store.initializeCursorAtBeginningIfNeeded(nodeID: node, now: bad) }
                    await #expect(throws: V2GatewayAuthenticationError.corruptPersistenceState) { try await store.markProcessed(eventID: first.eventID, nodeID: node, now: bad) }
                }
                await #expect(throws: V2GatewayAuthenticationError.corruptPersistenceState) { try await cleaner.clean(userID: first.userID, deviceID: first.deviceID, revokedAt: bad) }
                #expect(try await cursorSnapshot() == initialCursors)
                #expect(try await projectionSnapshot() == initialProjections)
            }
            try await gatewayStore.initializeCursorIfNeeded(nodeID: node, now: base)
            // A cursor in the gateway namespace cannot satisfy cleanup initialization.
            await #expect(throws: V2GatewayAuthenticationError.corruptPersistenceState) { try await cleanupStore.initializeCursorAtBeginningIfNeeded(nodeID: node, now: invalidDates[0]) }
            try await cleanupStore.initializeCursorAtBeginningIfNeeded(nodeID: node, now: base)
            #expect(try await gatewayStore.events(afterCursorFor: node, limit: 8).isEmpty)
            #expect(try await cleanupStore.events(afterCursorFor: node, limit: 8) == events)
            let initializedCursors = try await cursorSnapshot()
            for bad in invalidDates {
                for store in [gatewayStore, cleanupStore] {
                    try await store.initializeCursorIfNeeded(nodeID: node, now: bad)
                    try await store.initializeCursorAtBeginningIfNeeded(nodeID: node, now: bad)
                    await #expect(throws: V2GatewayAuthenticationError.corruptPersistenceState) { try await store.markProcessed(eventID: last.eventID, nodeID: node, now: bad) }
                }
                #expect(try await cursorSnapshot() == initializedCursors)
            }
            for store in [gatewayStore, cleanupStore] {
                await #expect(throws: V2GatewayAuthenticationError.corruptPersistenceState) { try await store.initializeCursorIfNeeded(nodeID: "", now: base) }
                await #expect(throws: V2GatewayAuthenticationError.corruptPersistenceState) { try await store.initializeCursorAtBeginningIfNeeded(nodeID: "", now: base) }
                await #expect(throws: V2GatewayAuthenticationError.corruptPersistenceState) { try await store.events(afterCursorFor: "", limit: 8) }
                await #expect(throws: V2GatewayAuthenticationError.corruptPersistenceState) { try await store.markProcessed(eventID: first.eventID, nodeID: "", now: base) }
            }
            #expect(try await cursorSnapshot() == initializedCursors)

            let cleanupWorker = V2RevokedDeviceProjectionCleanupWorker(store: cleanupStore, cleaner: cleaner, now: { clock.now() })
            for bad in invalidDates {
                clock.set([bad])
                await #expect(throws: V2GatewayAuthenticationError.corruptPersistenceState) { try await cleanupWorker.runOnce(limit: 8) }
                // Cleanup committed, but the event remains pending until its cursor can commit.
                #expect(try await count("im_v2.revoked_device_projection_tombstones", on: sql) == 1)
                #expect(try await count("im_v2.device_sync_cursors", on: sql) == 2)
                #expect(try await cleanupStore.events(afterCursorFor: node, limit: 8) == events)
                #expect(try await cursorSnapshot() == initializedCursors)
            }
            let cleanedFirst = try await projectionSnapshot()
            for bad in invalidDates {
                await #expect(throws: V2GatewayAuthenticationError.corruptPersistenceState) { try await cleaner.clean(userID: first.userID, deviceID: first.deviceID, revokedAt: bad) }
                #expect(try await projectionSnapshot() == cleanedFirst)
            }
            clock.set([base.addingTimeInterval(-30)])
            try await sql.raw("CREATE FUNCTION im_v2.test_cursor_clock_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'local cursor acknowledgement failure'; END $$").run()
            try await sql.raw("CREATE TRIGGER test_cursor_clock_failure BEFORE UPDATE ON im_v2.gateway_worker_cursors FOR EACH ROW EXECUTE FUNCTION im_v2.test_cursor_clock_failure()").run()
            await #expect(throws: (any Error).self) { try await cleanupWorker.runOnce(limit: 8) }
            #expect(try await cursorSnapshot() == initializedCursors)
            #expect(try await projectionSnapshot() == cleanedFirst)
            try await sql.raw("DROP TRIGGER test_cursor_clock_failure ON im_v2.gateway_worker_cursors").run()
            #expect(try await cleanupWorker.runOnce(limit: 8) == 2)
            #expect(try await cleanupWorker.runOnce(limit: 8) == 0)
            #expect(try await count("im_v2.revoked_device_projection_tombstones", on: sql) == 2)
            #expect(try await count("im_v2.device_sync_cursors", on: sql) == 1)

            // Events committed after startup remain visible; bad acknowledgement clocks do not skip them.
            try await sql.raw("INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at) VALUES (\(bind: users[2]), \(bind: devices[2]), \(bind: base))").run()
            let pending = try await gatewayStore.events(afterCursorFor: node, limit: 8)
            let later = try #require(pending.first)
            #expect(pending.count == 1)
            let gatewayWorker = V2DeviceRevocationWorker(store: gatewayStore, registry: V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits), nodeID: node, now: { clock.now() })
            let beforeLater = try await cursorSnapshot()
            for bad in invalidDates {
                clock.set([bad])
                try await gatewayWorker.initializeForStartup()
                await #expect(throws: V2GatewayAuthenticationError.corruptPersistenceState) { try await gatewayWorker.runOnce(limit: 8) }
                #expect(try await gatewayStore.events(afterCursorFor: node, limit: 8) == pending)
                #expect(try await cursorSnapshot() == beforeLater)
            }
            clock.set([base])
            #expect(try await gatewayWorker.runOnce(limit: 8) == 1)

            // PostgreSQL infinities and its rounded upper endpoint cannot be rebound as Swift Dates.
            let beforeBadHistory = try await cursorSnapshot()
            let projectionsBeforeBadHistory = try await projectionSnapshot()
            for literal in ["infinity", "-infinity", "294276-12-31 23:59:59.999999+00"] {
                try await sql.raw("UPDATE im_v2.device_revocation_events SET created_at = \(bind: literal)::timestamptz WHERE event_id = \(bind: later.eventID)").run()
                await #expect(throws: V2GatewayAuthenticationError.corruptPersistenceState) { try await cleanupWorker.runOnce(limit: 8) }
                #expect(try await cursorSnapshot() == beforeBadHistory)
                #expect(try await projectionSnapshot() == projectionsBeforeBadHistory)
            }
            try await sql.raw("UPDATE im_v2.device_revocation_events SET created_at = \(bind: base) WHERE event_id = \(bind: later.eventID)").run()
            #expect(try await cleanupWorker.runOnce(limit: 8) == 1)
            #expect(try await count("im_v2.device_sync_cursors", on: sql) == 0)
            #expect(try await count("im_v2.revoked_device_projection_tombstones", on: sql) == 3)
            for store in [gatewayStore, cleanupStore] {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for index in 0..<8 {
                        group.addTask { try await store.markProcessed(eventID: index.isMultiple(of: 2) ? first.eventID : later.eventID, nodeID: node, now: base.addingTimeInterval(-60)) }
                    }
                    try await group.waitForAll()
                }
                #expect(try await store.events(afterCursorFor: node, limit: 8).isEmpty)
            }
            // Both finite database endpoints remain usable for every timestamp write path.
            let validDates = [Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000), Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)]
            for (index, valid) in validDates.enumerated() {
                let boundaryNode = "boundary-\(index)"
                try await gatewayStore.initializeCursorIfNeeded(nodeID: boundaryNode, now: valid)
                try await cleanupStore.initializeCursorAtBeginningIfNeeded(nodeID: boundaryNode, now: valid)
                let initializedTimes = try await sql.raw("SELECT updated_at AS value FROM im_v2.gateway_worker_cursors WHERE node_id = \(bind: boundaryNode)").all(decoding: RevocationClockDateRow.self)
                #expect(initializedTimes.count == 2)
                #expect(initializedTimes.allSatisfy { $0.value == valid })
                for store in [gatewayStore, cleanupStore] { try await store.markProcessed(eventID: later.eventID, nodeID: boundaryNode, now: valid) }
                let boundaryDeviceUUID = UUID()
                let boundaryDevice = try DeviceID(boundaryDeviceUUID.uuidString)
                try await cleaner.clean(userID: senderID, deviceID: boundaryDevice, revokedAt: valid)
                let times = try await sql.raw("SELECT updated_at AS value FROM im_v2.gateway_worker_cursors WHERE node_id = \(bind: boundaryNode) UNION ALL SELECT revoked_at AS value FROM im_v2.revoked_device_projection_tombstones WHERE device_id = \(bind: boundaryDeviceUUID)").all(decoding: RevocationClockDateRow.self)
                #expect(times.count == 3)
                #expect(times.allSatisfy { $0.value == valid })
            }
        }
    }

    @Test("Direct route clocks recover owner commits without publishing uncommitted cache entries", arguments: [false, true])
    func directRouteClockBounds(roomRouteExists: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let clock = TestSequenceClock([base])
            let directory = V2PostgresRoomShardRouter(database: control, now: { clock.now() })
            let cached = V2CachedRoomShardRouter(source: directory, capacity: 16, bucketCount: 2)
            let ownerStore = PostgresV2DirectMessagingStore(database: owner, identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery())
            let profile = try forwardImportTestProfile()
            let executor = try V2RoomBootstrapDomainExecutor(shardID: "room-b", direct: ownerStore,
                group: PostgresV2GroupMessagingStore(database: owner), capacityProfile: profile, now: { base })
            let port = V2ActorCreationBootstrapPort(execute: { command, _ in try await executor.execute(command) },
                stage: { intent, page, _ in try await executor.stage(intent: intent, page: page) })
            let service = PostgresV2DirectRoomOperationStore(database: control, routes: cached,
                selector: try .init(shardIDs: ["room-b"]), bootstrap: port)
            let operation = DirectRoomOperationID(uuid: UUID())
            let customer = UserID(uuid: memberTwoUUID)
            let command = try V2DirectRoomOperationCommand(actorUserID: senderID, operationID: operation, targetUserID: customer,
                firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(base))
            @Sendable func open() async throws -> V2DirectRoomOperationResult {
                try await service.submit(command, now: base, deadline: ContinuousClock.now.advanced(by: .seconds(10)))
            }
            if roomRouteExists {
                let prepared = try await V2DirectRoomOperationTestFixture(store: ownerStore, capacityProfile: profile,
                    roomShardID: "room-b", now: { base }).openedIdentity(actorUserID: senderID, operationID: operation,
                    targetUserID: customer, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(base))
                try await sql.raw("INSERT INTO im_v2.room_owner_routes(room_id, room_shard_id, route_epoch, created_at, updated_at) VALUES (\(bind: prepared.roomID.uuidValue!), 'room-b', 0, \(bind: base), \(bind: base)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id = EXCLUDED.room_shard_id, route_epoch = EXCLUDED.route_epoch, updated_at = EXCLUDED.updated_at").run()
            }
            func ownerRoom() async throws -> RoomID {
                let row = try #require(try await ownerSQL.raw("SELECT room_id AS value FROM im_v2.direct_room_pairs WHERE lower_user_id=\(bind: senderUUID) AND higher_user_id=\(bind: memberTwoUUID)").first(decoding: DirectFixtureRoomRow.self))
                return .init(uuid: row.value)
            }
            func directorySnapshot() async throws -> String {
                let row = try await sql.raw("""
                    SELECT jsonb_build_object(
                        'rooms', (SELECT jsonb_agg(to_jsonb(r) ORDER BY room_id) FROM im_v2.room_owner_routes r),
                        'pairs', (SELECT jsonb_agg(to_jsonb(r) ORDER BY room_id) FROM im_v2.direct_room_owner_routes r)
                    )::text AS value
                    """).first(decoding: StringValueRow.self)
                guard let row else { throw V2RoomShardRouteError.corruptPersistenceState }
                return row.value
            }
            func ownerSnapshot() async throws -> String {
                let row = try await ownerSQL.raw("""
                    SELECT jsonb_build_object(
                        'rooms', (SELECT jsonb_agg(to_jsonb(r) ORDER BY room_id) FROM im_v2.rooms r),
                        'pairs', (SELECT jsonb_agg(to_jsonb(r) ORDER BY room_id) FROM im_v2.direct_room_pairs r),
                        'operations', (SELECT jsonb_agg(to_jsonb(r) ORDER BY actor_user_id, operation_id) FROM im_v2.direct_room_owner_receipts r),
                        'members', (SELECT jsonb_agg(to_jsonb(r) ORDER BY room_id, user_id) FROM im_v2.room_memberships r),
                        'admission', (SELECT jsonb_agg(to_jsonb(r) ORDER BY room_id) FROM im_v2.room_admission r),
                        'sync', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id, user_sync_sequence) FROM im_v2.user_sync_log r)
                    )::text AS value
                    """).first(decoding: StringValueRow.self)
                guard let row else { throw V2RoomShardRouteError.corruptPersistenceState }
                return row.value
            }
            let before = try await directorySnapshot()
            var ownerCommitted: String?
            let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            for bad in badDates {
                clock.set([bad])
                await #expect(throws: V2RoomShardRouteError.corruptPersistenceState) { _ = try await open() }
                #expect(try await directorySnapshot() == before)
                #expect(try await count("im_v2.direct_room_pairs", on: ownerSQL) == 1)
                #expect(try await count("im_v2.direct_room_owner_receipts", on: ownerSQL) == 1)
                let current = try await ownerSnapshot()
                if let ownerCommitted { #expect(current == ownerCommitted) } else { ownerCommitted = current }
                if !roomRouteExists {
                    await #expect(throws: V2RoomShardRouteError.roomNotFound) { _ = try await cached.route(for: try await ownerRoom()) }
                    await #expect(throws: V2RoomShardRouteError.roomNotFound) { _ = try await cached.routes(for: [try await ownerRoom()]) }
                }
            }
            clock.set([base.addingTimeInterval(2)])
            try await sql.raw("CREATE FUNCTION im_v2.fail_direct_route_record() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test route record failure'; END $$").run()
            try await sql.raw("CREATE TRIGGER fail_direct_route_record BEFORE INSERT ON im_v2.direct_room_owner_routes FOR EACH ROW EXECUTE FUNCTION im_v2.fail_direct_route_record()").run()
            await #expect(throws: (any Error).self) { _ = try await open() }
            #expect(try await directorySnapshot() == before)
            #expect(try await ownerSnapshot() == ownerCommitted)
            if !roomRouteExists {
                await #expect(throws: V2RoomShardRouteError.roomNotFound) { _ = try await cached.route(for: try await ownerRoom()) }
            }
            try await sql.raw("DROP TRIGGER fail_direct_route_record ON im_v2.direct_room_owner_routes").run()
            try await sql.raw("DROP FUNCTION im_v2.fail_direct_route_record()").run()
            let results = try await withThrowingTaskGroup(of: V2DirectRoomOperationResult.self) { group in
                for _ in 0..<8 { group.addTask { try await open() } }
                var results: [V2DirectRoomOperationResult] = []
                for try await value in group { results.append(value) }
                return results
            }
            let result = try #require(results.first)
            guard case .receipt(let proof) = result, case .opened(let createdRoom, _) = proof.outcome else { throw V2DirectMessagingStoreError.corruptPersistenceState }
            let createdID = createdRoom.uuidValue!
            #expect(proof.validates(command: command) && results.count == 8)
            #expect(try await ownerRoom() == createdRoom)
            for value in results { #expect(value == result) }
            #expect(try await count("im_v2.room_owner_routes WHERE room_id = '\(createdID.uuidString)'::uuid", on: sql) == 1)
            #expect(try await count("im_v2.direct_room_owner_routes", on: sql) == 1)
            #expect(try await ownerSnapshot() == ownerCommitted)
            let committed = try await directorySnapshot()
            let expectedRoute = try V2RoomShardRoute(shardID: "room-b", epoch: 0)
            for bad in badDates {
                clock.set([bad])
                #expect(try await open() == result)
                #expect(try await directory.route(for: createdRoom) == expectedRoute)
                #expect(try await cached.routes(for: [createdRoom, createdRoom]) == [createdRoom: expectedRoute])
                #expect(try await directorySnapshot() == committed)
                #expect(try await ownerSnapshot() == ownerCommitted)
            }
            // A different target has a distinct identity and must never inherit
            // the original pair's completion or publish speculative room routing.
            let other = try V2DirectRoomOperationCommand(actorUserID: senderID, operationID: .init(uuid: UUID()),
                targetUserID: .init(uuid: UUID()), firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(base))
            _ = try await service.submit(other, now: base, deadline: ContinuousClock.now.advanced(by: .seconds(10)))
            #expect(try await directorySnapshot() == committed)
        }
    }


}

private struct DirectFixtureRoomRow: Decodable { let value: UUID }
