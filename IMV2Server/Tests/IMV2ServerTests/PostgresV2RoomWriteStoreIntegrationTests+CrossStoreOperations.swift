import Crypto
import FluentKit
import FluentPostgresDriver
import Foundation
import HTTPTypes
#if os(macOS)
import Darwin
#endif
import IMV2Core
import IMV2ServerHTTP
import PostgresNIO
@testable import IMV2Server
import SQLKit
import Synchronization
import Testing
import Vapor
import VaporTesting


extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("Concurrent conversation preferences and favorites replay one committed timestamp and projection",
          arguments: ["conversation", "favorite-add", "favorite-remove"], [false, true])
    func personalPreferenceConcurrentReplay(path: String, mismatch: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let baseline = Date(timeIntervalSince1970: 1_750_000_000)
            let sender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database),
                capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { baseline })
            guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "preference replay")) else { throw CancellationError() }
            if path == "favorite-remove" {
                try await sql.raw("INSERT INTO im_v2.user_message_favorites (user_id, message_id, room_id, created_at) VALUES (\(bind: senderUUID), \(bind: message.messageID.uuidValue!), \(bind: roomUUID), \(bind: baseline))").run()
            }
            let now = Date(timeIntervalSince1970: 946_684_800 + 0.00000125)
            let operation = UUID()
            let store = PostgresV2ConversationCapabilitiesStore(database: database, shadowForwarder: SuccessfulProjectionShadowForwarder())
            func perform(changed: Bool, date: Date) async throws -> V2ConversationCapabilitiesOutcome<Date> {
                if path == "conversation" {
                    let command = try V2ConversationStateCommand(operationID: .init(uuid: operation), roomID: roomID,
                        isPinned: !changed, isArchived: true, muteUntil: now.addingTimeInterval(600))
                    switch try await store.setConversationState(actorUserID: senderID, command: command, now: date) {
                    case .applied(let value): return .applied(value.updatedAt)
                    case .idempotent(let value): return .idempotent(value.updatedAt)
                    case .idempotencyConflict: return .idempotencyConflict
                    }
                }
                let command = V2MessageFavoriteCommand(operationID: .init(uuid: operation), roomID: roomID,
                    messageID: message.messageID, isFavorited: (path == "favorite-add") != changed)
                switch try await store.setMessageFavorite(actorUserID: senderID, command: command, now: date) {
                case .applied(let value): return .applied(value.updatedAt)
                case .idempotent(let value): return .idempotent(value.updatedAt)
                case .idempotencyConflict: return .idempotencyConflict
                }
            }
            let gate = PostgreSQLTransactionGate()
            let holder = Task {
                try await database.transaction { transaction in
                    let held = try #require(transaction as? any SQLDatabase)
                    try await held.raw("SELECT room_id FROM im_v2.rooms WHERE room_id = \(bind: roomUUID) FOR UPDATE").run()
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()
            func waitForWriters(_ expected: Int64) async throws {
                for _ in 0..<500 {
                    let waiting = try await sql.raw("SELECT COUNT(*) AS value FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND (query LIKE '%FROM im_v2.rooms%' OR query LIKE '%pg_advisory_xact_lock%')").first(decoding: CountRow.self)?.value ?? 0
                    if waiting == expected { return }
                    try await Task.sleep(for: .milliseconds(10))
                }
                Issue.record("Expected overlapping preference writers to wait on database locks")
                throw CancellationError()
            }
            let first = Task { try await perform(changed: false, date: now) }
            var second: Task<V2ConversationCapabilitiesOutcome<Date>, Error>?
            do {
                try await waitForWriters(1)
                second = Task { try await perform(changed: mismatch, date: baseline) }
                try await waitForWriters(2)
                await gate.releaseTransaction()
                try await holder.value
                let operationTable = path == "conversation" ? "user_room_preference_operations" : "user_message_favorite_operations"
                guard case .applied(let appliedAt) = try await first.value else { throw CancellationError() }
                #expect(try await #require(second).value == (mismatch ? .idempotencyConflict : .idempotent(appliedAt)))
                #expect(try await sql.raw("SELECT updated_at AS value FROM im_v2.\(unsafeRaw: operationTable) WHERE actor_user_id = \(bind: senderUUID) AND operation_id = \(bind: operation)").first(decoding: RevocationClockDateRow.self)?.value == appliedAt)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: operationTable) op JOIN im_v2.user_sync_log log ON log.user_id = op.actor_user_id AND log.source_event_id = op.operation_id WHERE op.actor_user_id = \(bind: senderUUID) AND op.operation_id = \(bind: operation) AND op.updated_at = \(bind: now) AND log.created_at = op.updated_at").first(decoding: CountRow.self)?.value == 1)
                func snapshot() async throws -> [String] {
                    var values: [String] = []
                    for table in ["user_room_preferences", "user_room_preference_operations", "user_message_favorites", "user_message_favorite_operations", "user_sync_sequences", "user_sync_log"] {
                        guard let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self) else { throw CancellationError() }
                        values.append(row.value)
                    }
                    return values
                }
                let committed = try await snapshot()
                for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity), baseline] {
                    #expect(try await perform(changed: false, date: date) == .idempotent(appliedAt))
                    #expect(try await perform(changed: true, date: date) == .idempotencyConflict)
                    #expect(try await snapshot() == committed)
                }
                #expect(try await count("im_v2." + operationTable, on: sql) == 1)
                #expect(try await sql.raw("SELECT next_sequence AS value FROM im_v2.user_sync_sequences WHERE user_id = \(bind: senderUUID)").first(decoding: CountRow.self)?.value == 1)
                #expect(try await count("im_v2.user_message_favorites", on: sql) == (path == "favorite-add" ? 1 : 0))
            } catch {
                first.cancel()
                second?.cancel()
                await gate.releaseTransaction()
                _ = await holder.result
                _ = await first.result
                if let second { _ = await second.result }
                throw error
            }
        }
    }

    @Test("Personal sequence boundaries preserve control transactions and room outbox recovery",
          arguments: ["conversation", "favorite", "stranger", "user-add", "receipt-preferences", "relationship", "block-remove", "direct-open", "direct-receipt"])
    func personalProjectionSequenceBoundary(path: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, userDatabase, sql, userSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let operation = UUID(), target = UserID(uuid: memberTwoUUID), createdRoom = RoomID(uuid: UUID())
            let profile = try forwardImportTestProfile()
            let direct = PostgresV2DirectMessagingStore(database: database, shadowForwarder: SuccessfulProjectionShadowForwarder())
            let personal = PostgresV2ConversationCapabilitiesStore(database: database, shadowForwarder: SuccessfulProjectionShadowForwarder())
            let receipts = PostgresV2ReadReceiptStore(database: database, shadowForwarder: SuccessfulProjectionShadowForwarder())
            let social = PostgresV2SocialRelationshipStore(database: database, shadowForwarder: SuccessfulProjectionShadowForwarder())
            var messageRoom = roomID
            if path == "direct-receipt" {
                guard case .opened(let opened) = try await direct.open(command: .init(actorUserID: senderID,
                    operationID: .init(uuid: UUID()), targetUserID: target), capacityProfile: profile,
                    roomShardID: "room-a", roomID: createdRoom, now: now) else { throw CancellationError() }
                messageRoom = opened.roomID
            }
            let sender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database),
                capacityProfile: profile, limits: .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await sender.send(.init(roomID: messageRoom, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "personal sequence boundary")) else { throw CancellationError() }
            if path == "block-remove" {
                try await sql.raw("INSERT INTO im_v2.user_relationships (lower_user_id, higher_user_id, state, requested_by_user_id, updated_at) VALUES (LEAST(\(bind: senderUUID), \(bind: memberTwoUUID)), GREATEST(\(bind: senderUUID), \(bind: memberTwoUUID)), 'accepted', \(bind: senderUUID), \(bind: now))").run()
            }
            func perform() async throws -> Bool {
                switch path {
                case "conversation":
                    switch try await personal.setConversationState(actorUserID: senderID, command: .init(operationID: .init(uuid: operation), roomID: roomID, isPinned: true, isArchived: true, muteUntil: nil), now: now) {
                    case .applied: return false
                    case .idempotent: return true
                    default: throw CancellationError()
                    }
                case "favorite":
                    switch try await personal.setMessageFavorite(actorUserID: senderID, command: .init(operationID: .init(uuid: operation), roomID: roomID, messageID: message.messageID, isFavorited: true), now: now) {
                    case .applied: return false
                    case .idempotent: return true
                    default: throw CancellationError()
                    }
                case "stranger":
                    switch try await direct.setStrangerMessagePermission(command: .init(actorUserID: senderID, operationID: .init(uuid: operation), permission: .deny), now: now) {
                    case .updated: return false
                    case .idempotent: return true
                    default: throw CancellationError()
                    }
                case "user-add":
                    switch try await direct.setUserAddPermission(command: .init(actorUserID: senderID, operationID: .init(uuid: operation), permission: .deny), now: now) {
                    case .updated: return false
                    case .idempotent: return true
                    default: throw CancellationError()
                    }
                case "receipt-preferences":
                    switch try await receipts.setPreferences(command: .init(actorUserID: senderID, operationID: .init(uuid: operation), allowsDirectReadReceipts: false, allowsGroupReadReceipts: true), now: now) {
                    case .updated: return false
                    case .idempotent: return true
                    default: throw CancellationError()
                    }
                case "relationship":
                    switch try await social.changeRelationship(.init(actorUserID: senderID, operationID: .init(uuid: operation), targetUserID: target, action: .request), now: now) {
                    case .changed: return false
                    case .idempotent: return true
                    default: throw CancellationError()
                    }
                case "block-remove":
                    switch try await social.changeUserBlock(.init(actorUserID: senderID, operationID: .init(uuid: operation), targetUserID: target, action: .block), now: now) {
                    case .changed: return false
                    case .idempotent: return true
                    default: throw CancellationError()
                    }
                case "direct-open":
                    switch try await direct.open(command: .init(actorUserID: senderID, operationID: .init(uuid: operation), targetUserID: target), capacityProfile: profile, roomShardID: "room-a", roomID: createdRoom, now: now) {
                    case .opened: return false
                    case .idempotent: return true
                    default: throw CancellationError()
                    }
                default:
                    switch try await receipts.record(command: .init(roomID: messageRoom, actorUserID: target, operationID: .init(uuid: operation), readThroughRoomSequence: message.roomSequence), now: now) {
                    case .recorded: return false
                    case .idempotent: return true
                    default: throw CancellationError()
                    }
                }
            }
            let needed: Int64 = path == "block-remove" ? 2 : 1
            try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: senderUUID), \(bind: Int64.max - needed + 1)) ON CONFLICT (user_id) DO UPDATE SET next_sequence = EXCLUDED.next_sequence").run()
            func snapshot() async throws -> [String] {
                var result = [try await crossStoreClockState(on: sql)]
                for table in ["user_room_preferences", "user_room_preference_operations", "user_message_favorites", "user_message_favorite_operations", "user_stranger_message_preferences", "stranger_message_preference_operations", "user_add_preferences", "user_add_preference_operations", "user_read_receipt_preferences", "read_receipt_preference_operations", "read_receipt_preference_propagation_outbox", "room_read_receipts", "read_receipt_operations", "user_relationships", "user_relationship_operations", "user_blocks", "user_block_operations", "rooms", "room_memberships", "direct_room_pairs", "direct_room_operations", "user_direct_send_policy_versions", "room_admission", "shard_admission_pools", "user_state_event_outbox"] {
                    guard let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self) else { throw CancellationError() }
                    result.append(row.value)
                }
                return result
            }
            if path == "direct-open" || path == "direct-receipt" {
                struct Fence: V2UserShardRouteFencing {
                    let database: any Database
                    func withCurrentRoute<Result: Sendable>(for userID: UserID,
                        _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result) async throws -> Result {
                        try await database.transaction { transaction in
                            try await operation(.init(bucket: "user", observedRouterEpoch: 1), transaction)
                        }
                    }
                }
                let outbox = try PostgresV2UserStateEventOutbox(database: database)
                let projector = try V2RoutedUserStateEventProjector(routeFence: Fence(database: database),
                    registry: V2StaticUserShardStorageRegistry(locations: [.init(bucket: "user", database: userDatabase, schema: "im_v2")]))
                try await userSQL.raw("INSERT INTO im_v2.user_sync_sequences(user_id, next_sequence) VALUES (\(bind: senderUUID), \(bind: Int64.max))").run()
                #expect(try await perform() == false)
                let sourceEventCount: Int64 = path == "direct-open" ? 1 : 2
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_state_event_outbox WHERE source_event_id = \(bind: operation)").first(decoding: CountRow.self)?.value == sourceEventCount)
                let committed = try await snapshot()
                #expect(try await perform())
                #expect(try await snapshot() == committed)
                let leases = try await outbox.claim(now: now, leaseDuration: 30, limit: 100)
                    .filter { $0.event.sourceEventID.uuidValue == operation }
                #expect(leases.count == Int(sourceEventCount))
                for lease in leases {
                    if lease.event.userID == senderID {
                        await #expect(throws: V2UserStateEventError.corruptPersistenceState) {
                            _ = try await projector.project(lease.event)
                        }
                        try await outbox.retry(lease, disposition: .pause)
                    } else {
                        let sequence = try await projector.project(lease.event)
                        #expect(try await outbox.acknowledge(lease, sequence: sequence, now: now))
                    }
                }
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_state_event_outbox WHERE source_event_id = \(bind: operation) AND state = 'paused'").first(decoding: CountRow.self)?.value == 1)
                #expect(try await userSQL.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE user_id = \(bind: senderUUID)").first(decoding: CountRow.self)?.value == 0)
                try await userSQL.raw("UPDATE im_v2.user_sync_sequences SET next_sequence = \(bind: Int64.max - 1) WHERE user_id = \(bind: senderUUID)").run()
                try await sql.raw("UPDATE im_v2.user_state_event_outbox SET state = 'pending', next_attempt_at = \(bind: now) WHERE source_event_id = \(bind: operation) AND state = 'paused'").run()
                let recovery = try await outbox.claim(now: now, leaseDuration: 30, limit: 100)
                #expect(recovery.count == 1)
                for lease in recovery {
                    #expect(try await projector.project(lease.event) == UInt64(Int64.max))
                    #expect(try await projector.project(lease.event) == UInt64(Int64.max))
                    #expect(try await outbox.acknowledge(lease, sequence: UInt64(Int64.max), now: now))
                }
                #expect(try await perform())
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_state_event_outbox WHERE source_event_id = \(bind: operation) AND state = 'delivered'").first(decoding: CountRow.self)?.value == sourceEventCount)
                #expect(try await userSQL.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE user_id = \(bind: senderUUID) AND user_sync_sequence = \(bind: Int64.max)").first(decoding: CountRow.self)?.value == 1)
                return
            }
            let before = try await snapshot()
            for _ in 0..<2 {
                do { _ = try await perform(); Issue.record("Expected a sequence-exhaustion domain error") }
                catch {
                    switch path {
                    case "conversation", "favorite": #expect(error as? V2ConversationCapabilitiesStoreError == .corruptPersistenceState)
                    case "receipt-preferences", "direct-receipt": #expect(error as? V2ReadReceiptStoreError == .corruptPersistenceState)
                    case "relationship", "block-remove": #expect(error as? V2SocialRelationshipStoreError == .corruptPersistenceState)
                    default: #expect(error as? V2DirectMessagingStoreError == .corruptPersistenceState)
                    }
                }
                #expect(try await snapshot() == before)
            }
            try await sql.raw("UPDATE im_v2.user_sync_sequences SET next_sequence = \(bind: Int64.max - needed) WHERE user_id = \(bind: senderUUID)").run()
            #expect(try await perform() == false)
            #expect(try await sql.raw("SELECT next_sequence AS value FROM im_v2.user_sync_sequences WHERE user_id = \(bind: senderUUID)").first(decoding: CountRow.self)?.value == Int64.max)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE user_id = \(bind: senderUUID) AND user_sync_sequence > \(bind: Int64.max - needed)").first(decoding: CountRow.self)?.value == needed)
            let committed = try await snapshot()
            for _ in 0..<2 { #expect(try await perform()); #expect(try await snapshot() == committed) }
        }
    }

    @Test("Personal sequence exhaustion rolls back new effects while committed records remain replayable")
    func crossStoreSequenceReservationBoundary() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { _, database, controlSQL, sql, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let user = UserID(uuid: UUID()), old = EventID(uuid: UUID()), pending = EventID(uuid: UUID())
            let userUUID = try #require(user.uuidValue)
            let projector = try PostgresV2UserProjectionStore(database: database, schema: "im_v2")
            func write(_ event: EventID) async throws -> UInt64 {
                try await projector.projectAllocated(userID: user, sourceEventID: event, projectionKind: "stranger_permission", payloadJSON: "{}", createdAt: now)
            }
            #expect(try await write(old) == 1)
            try await sql.raw("UPDATE im_v2.user_sync_sequences SET next_sequence = \(bind: Int64.max) WHERE user_id = \(bind: userUUID)").run()
            let before = try await crossStoreClockState(on: sql)
            let sourceBefore = try await crossStoreClockState(on: controlSQL)
            for _ in 0..<2 {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await write(pending) }
                #expect(try await write(old) == 1)
                #expect(try await crossStoreClockState(on: sql) == before)
            }
            try await sql.raw("UPDATE im_v2.user_sync_sequences SET next_sequence = \(bind: Int64.max - 1) WHERE user_id = \(bind: userUUID)").run()
            #expect(try await write(pending) == UInt64(Int64.max))
            let committed = try await crossStoreClockState(on: sql)
            for _ in 0..<2 {
                #expect(try await write(pending) == UInt64(Int64.max))
                #expect(try await write(old) == 1)
                #expect(try await crossStoreClockState(on: sql) == committed)
            }
            #expect(try await crossStoreClockState(on: controlSQL) == sourceBefore)
        }

    }

    internal func crossStoreClockState(on sql: any SQLDatabase) async throws -> String {
        struct State: Decodable { let value: String }
        return try #require(try await sql.raw("""
            SELECT jsonb_build_object(
                'sequences', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id) FROM im_v2.user_sync_sequences r),
                'sync', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id, user_sync_sequence) FROM im_v2.user_sync_log r),
                'effects', (SELECT jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text) FROM im_v2.user_projection_effects r),
                'ready', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id) FROM im_v2.user_projection_ready r),
                'checkpoints', (SELECT jsonb_agg(to_jsonb(r) ORDER BY user_id) FROM im_v2.user_projection_checkpoints r)
            )::text AS value
            """).first(decoding: State.self)).value
    }

    @Test("Projection clocks reject invalid work and retry dates without consuming failure state", arguments: [false, true])
    func projectionWorkerTimestampBoundaries(poisoned: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let user = UUID(), event = UUID(), target = UUID()
            let payload = "{\"target_user_id\":\"\(target.uuidString.lowercased())\",\"state\":\"accepted\",\"updated_at_ms\":1750000000000}"
            try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: user), 1)").run()
            let storedPayload = poisoned ? "[]" : payload
            try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: user), 1, \(bind: event), 'relationship', \(bind: storedPayload)::jsonb, \(bind: now))").run()
            let worker = PostgresV2UserProjectionWorker(database: database, retryPolicy: .init(initialDelay: 2, maximumDelay: 2, maximumAttempts: 2, jitterFraction: 0))
            let versions = PostgresV2ProjectionVersionGCWorker(database: database)
            let states = PostgresV2MessageProjectionStateGCWorker(database: database, retention: 60)
            for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12] {
                let invalid = Date(timeIntervalSince1970: seconds)
                await #expect(throws: V2UserProjectionWorkerError.corruptPersistence) { try await worker.runOnce(now: invalid) }
                await #expect(throws: V2ProjectionVersionGCError.corruptPersistence) { try await versions.runOnce(now: invalid) }
                await #expect(throws: V2MessageProjectionStateGCError.corruptPersistence) { try await states.runOnce(now: invalid) }
            }
            let lower = Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000 + 30)
            await #expect(throws: V2MessageProjectionStateGCError.corruptPersistence) { try await states.runOnce(now: lower) }
            for duration in [Double.greatestFiniteMagnitude, .leastNonzeroMagnitude] {
                let invalidGC = PostgresV2MessageProjectionStateGCWorker(database: database, retention: duration)
                await #expect(throws: V2MessageProjectionStateGCError.corruptPersistence) { try await invalidGC.runOnce(now: now) }
            }
            if poisoned {
                // The clock is encodable and the row really fails projection,
                // but the derived retry time is not a usable database date.
                let upper = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 0.5)
                #expect(v2PostgresTimestampCanEncode(upper))
                await #expect(throws: V2UserProjectionWorkerError.corruptPersistence) { try await worker.runOnce(now: upper) }
                for duration in [Double.greatestFiniteMagnitude, .leastNonzeroMagnitude] {
                    let invalidRetry = PostgresV2UserProjectionWorker(database: database, retryPolicy: .init(initialDelay: duration, maximumDelay: duration, maximumAttempts: 2, jitterFraction: 0))
                    await #expect(throws: V2UserProjectionWorkerError.corruptPersistence) { try await invalidRetry.runOnce(now: now) }
                }
            }
            #expect(try await count("im_v2.user_projection_checkpoints WHERE state = 'ready' AND projected_sequence = 0 AND failure_count = 0 AND failed_sequence IS NULL AND next_attempt_at IS NULL AND paused_at IS NULL", on: sql) == 1)
            #expect(try await count("im_v2.user_projection_ready", on: sql) == 1)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 1)
            #expect(try await count("im_v2.user_projection_versions", on: sql) == 0)
            if poisoned {
                #expect(try await worker.runOnce(now: now) == .init(claimed: true, appliedRecordCount: 0, failedRecordCount: 1))
                #expect(try await count("im_v2.user_projection_checkpoints WHERE state = 'ready' AND projected_sequence = 0 AND failure_count = 1 AND failed_sequence = 1 AND paused_at IS NULL", on: sql) == 1)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_projection_ready WHERE available_at = \(bind: now.addingTimeInterval(2))").first(decoding: CountRow.self)?.value == 1)
                #expect(try await worker.runOnce(now: now.addingTimeInterval(1)).claimed == false)
                try await sql.raw("UPDATE im_v2.user_sync_log SET payload = \(bind: payload)::jsonb WHERE user_id = \(bind: user) AND source_event_id = \(bind: event)").run()
            }
            let resumedAt = poisoned ? now.addingTimeInterval(2) : now
            #expect(try await worker.runOnce(now: resumedAt) == .init(claimed: true, appliedRecordCount: 1))
            #expect(try await worker.runOnce(now: resumedAt).claimed == false)
            #expect(try await count("im_v2.user_projection_checkpoints WHERE state = 'ready' AND projected_sequence = 1 AND failure_count = 0 AND failed_sequence IS NULL AND next_attempt_at IS NULL AND paused_at IS NULL", on: sql) == 1)
            #expect(try await count("im_v2.user_projection_ready", on: sql) == 0)
            #expect(try await count("im_v2.user_projection_versions", on: sql) == 1)
            #expect(try await versions.runOnce(now: resumedAt) == 0)
            #expect(try await states.runOnce(now: resumedAt) == 0)
        }
    }

    @Test("Room-log read bounds reject invalid requests before SQL or cache lookup", arguments: [false, true])
    func roomLogReadIntegerBounds(cached: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .large) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let cache = V2DirectRoomLogEventCache(configuration: .init(maximumEvents: 16, maximumBytes: 65_536, maximumEventsPerRoom: 16, shardCount: 1))
            let sender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { now })
            for text in ["one", "two"] {
                guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: text)) else { throw V2RoomWriteStoreError.corruptPersistenceState }
                if cached { await cache.recordCommittedPlainDirectMessage(message) }
            }
            let reader = PostgresV2GroupEventLogStore(database: database, directRoomLogEventCache: cached ? cache : nil)
            let preparedCache = V2PreparedGroupEventPageCache(configuration: .init(maximumEntries: 8, maximumBytes: 65_536, shardCount: 1))
            let context = V2PreparedGroupEventPageEncodingContext(requestID: 7, frameVersion: 21, compression: nil, maximumUncompressedPayloadBytes: 65_536, compressionThresholdBytes: 1_024, maximumExpansionRatio: 64, maximumGroupEventPagePayloadBytes: 48 * 1_024, cache: preparedCache)
            let cacheBefore = await cache.snapshot()
            for size in [Int.min, -1, 0, V2GroupEventLogService.maximumPageSize + 1, Int.max] {
                await #expect(throws: V2GroupEventLogError.invalidRequest) { try await reader.pull(roomID: roomID, actorUserID: senderID, afterRoomSequence: 0, pageSize: size) }
                await #expect(throws: V2GroupEventLogError.invalidRequest) { try await reader.pullPrepared(roomID: roomID, actorUserID: senderID, afterRoomSequence: 0, pageSize: size, context: context) }
            }
            for sequence in [UInt64(Int64.max) + 1, UInt64.max] {
                await #expect(throws: V2GroupEventLogError.invalidRequest) { try await reader.pull(roomID: roomID, actorUserID: senderID, afterRoomSequence: sequence, pageSize: 1) }
                await #expect(throws: V2GroupEventLogError.invalidRequest) { try await reader.pullPrepared(roomID: roomID, actorUserID: senderID, afterRoomSequence: sequence, pageSize: 1, context: context) }
            }
            let cacheAfter = await cache.snapshot()
            #expect(cacheBefore.cachedEvents == cacheAfter.cachedEvents && cacheBefore.hits == cacheAfter.hits && cacheBefore.misses == cacheAfter.misses)
            let first = try await reader.pull(roomID: roomID, actorUserID: senderID, afterRoomSequence: 0, pageSize: 1)
            #expect(first.events.map(\.roomSequence) == [1] && first.hasMore && first.nextRoomSequence == 1)
            let last = try await reader.pull(roomID: roomID, actorUserID: senderID, afterRoomSequence: first.nextRoomSequence, pageSize: 1)
            #expect(last.events.map(\.roomSequence) == [2] && !last.hasMore && last.nextRoomSequence == 2)
            for _ in 0..<2 {
                let prepared = try await reader.pullPrepared(roomID: roomID, actorUserID: senderID, afterRoomSequence: 0, pageSize: V2GroupEventLogService.maximumPageSize, context: context)
                switch prepared {
                case .prepared(let response):
                    #expect(cached)
                    let decoded = try V2ServerProtobufFrameCodec.decode(response.frame)
                    #expect(decoded.requestID == 7)
                    #expect(decoded.groupEventPage.events.map(\.roomSequence) == [1, 2])
                    #expect(!decoded.groupEventPage.hasMore_p && decoded.groupEventPage.nextRoomSequence == 2)
                case .page(let page):
                    #expect(!cached)
                    #expect(page.events.map(\.roomSequence) == [1, 2] && !page.hasMore && page.nextRoomSequence == 2)
                case .eventTooLarge: throw V2GroupEventLogError.corruptPersistenceState
                }
            }
            if cached { #expect(preparedCache.snapshot().hits == 1) }
            let exhausted = try await reader.pull(roomID: roomID, actorUserID: senderID, afterRoomSequence: UInt64(Int64.max), pageSize: 1)
            #expect(exhausted.events.isEmpty && exhausted.nextRoomSequence == UInt64(Int64.max) && !exhausted.hasMore)
            #expect(try await count("im_v2.room_events", on: sql) == 2)
            await cache.finish()
        }
    }

    @Test("Snapshot building and log compaction reject invalid clocks and recover at the retention boundary")
    func snapshotMaintenanceTimestampBoundaries() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let userUUID = UUID(), deviceUUID = UUID()
            let user = UserID(uuid: userUUID), device = DeviceID(uuid: deviceUUID)
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: userUUID), \(bind: deviceUUID), \(bind: now), \(bind: now))").run()
            try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: userUUID), 2)").run()
            for (index, age) in [(1, 120.0), (2, 30.0)] {
                let payload = "{\"allows_stranger_messages\":true,\"updated_at_ms\":\(1_750_000_000_000 + index)}"
                try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: userUUID), \(bind: index), \(bind: UUID()), 'stranger_message_permission', \(bind: payload)::jsonb, \(bind: now.addingTimeInterval(-age)))").run()
            }
            try await drainV3Projection(database: database)
            let sync = PostgresV2SyncStore(database: database, capabilityLifetime: 600)
            guard case .resetPreparing(let snapshot, let generation, _) = try await sync.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 20, requireSnapshot: true, now: now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            #expect(generation == 2)
            let builder = PostgresV2SnapshotArtifactBuilder(database: database, leaseDuration: 30)
            let compactor = PostgresV2UserSyncLogCompactionWorker(database: database, minimumLogAge: 60)
            let invalidDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            for invalid in invalidDates {
                await #expect(throws: V2SnapshotArtifactBuilderError.corruptPersistence) { try await builder.runOnce(now: invalid) }
                await #expect(throws: V2UserSyncLogCompactionError.corruptPersistence) { try await compactor.runOnce(now: invalid, userLimit: 1, rowLimit: 10) }
            }
            let upper = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 15)
            await #expect(throws: V2SnapshotArtifactBuilderError.corruptPersistence) { try await builder.runOnce(now: upper) }
            let lower = Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000 + 30)
            await #expect(throws: V2UserSyncLogCompactionError.corruptPersistence) { try await compactor.runOnce(now: lower, userLimit: 1, rowLimit: 10) }
            for duration in [Double.infinity, .greatestFiniteMagnitude, .leastNonzeroMagnitude] {
                let invalidBuilder = PostgresV2SnapshotArtifactBuilder(database: database, leaseDuration: duration)
                await #expect(throws: V2SnapshotArtifactBuilderError.corruptPersistence) { try await invalidBuilder.runOnce(now: now) }
            }
            for duration in [Double.greatestFiniteMagnitude, .leastNonzeroMagnitude] {
                let invalidCompactor = PostgresV2UserSyncLogCompactionWorker(database: database, minimumLogAge: duration)
                await #expect(throws: V2UserSyncLogCompactionError.corruptPersistence) { try await invalidCompactor.runOnce(now: now, userLimit: 1, rowLimit: 10) }
            }
            #expect(try await count("im_v2.sync_snapshot_artifacts WHERE state = 'building' AND lease_token IS NULL AND lease_expires_at IS NULL AND next_page_index = 0 AND item_count = 0", on: sql) == 1)
            #expect(try await count("im_v2.sync_snapshot_pages", on: sql) == 0)
            #expect(try await count("im_v2.device_sync_cursors WHERE state = 'reset_preparing' AND reset_generation = 2 AND acknowledged_sequence = 0", on: sql) == 1)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 2)
            #expect(try await count("im_v2.user_sync_retention WHERE compacted_through_sequence = 0", on: sql) == 1)
            #expect(try await builder.runOnce(now: now) == .init(claimed: true, published: false, pageCount: 1, itemCount: 1))
            #expect(try await compactor.runOnce(now: now, userLimit: 1, rowLimit: 10).deletedLogRowCount == 1)
            #expect(try await count("im_v2.user_sync_log WHERE user_sync_sequence = 2", on: sql) == 1)
            #expect(try await count("im_v2.user_sync_retention WHERE compacted_through_sequence = 1", on: sql) == 1)
            #expect(try await compactor.runOnce(now: now.addingTimeInterval(29), userLimit: 1, rowLimit: 10).deletedLogRowCount == 0)
            #expect(try await compactor.runOnce(now: now.addingTimeInterval(30), userLimit: 1, rowLimit: 10).deletedLogRowCount == 1)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
            #expect(try await count("im_v2.user_sync_retention WHERE compacted_through_sequence = 2", on: sql) == 1)
            #expect(try await builder.runOnce(now: now.addingTimeInterval(31)) == .init(claimed: true, published: true, pageCount: 1, itemCount: 1))
            let manifest = try await sync.fetchSnapshotManifest(userID: user, deviceID: device, snapshotID: snapshot, generation: 2, now: now.addingTimeInterval(31))
            #expect(manifest.baseSequence == 2 && manifest.totalItems == 1)
            _ = try await sync.fetchSnapshotPage(userID: user, deviceID: device, snapshotID: snapshot, generation: 2, rootDigest: manifest.rootDigest, index: 0, now: now.addingTimeInterval(31))
            try await sync.acknowledgeSnapshot(userID: user, deviceID: device, snapshotID: snapshot, generation: 2, baseSequence: 2, receipt: manifest.receipt, now: now.addingTimeInterval(31))
            guard case .ready(let resumed, let records, _, _, _) = try await sync.pull(userID: user, deviceID: device, syncToken: manifest.nextSyncToken, maxRecords: 20, now: now.addingTimeInterval(31)) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            #expect(resumed == 2 && records.isEmpty)
            #expect(try await builder.runOnce(now: now.addingTimeInterval(31)).claimed == false)
        }
    }

    @Test("Sync clocks reject invalid dates before cursors, capabilities and reset assignments change")
    func syncTimestampBoundaries() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let userUUID = UUID(), deviceUUID = UUID()
            let user = UserID(uuid: userUUID), device = DeviceID(uuid: deviceUUID)
            let missingSnapshot = SnapshotID(uuid: UUID()), missingReceipt = try V2SyncReceipt("unused")
            let store = PostgresV2SyncStore(database: database, capabilityLifetime: 60)
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: userUUID), \(bind: deviceUUID), \(bind: now), \(bind: now))").run()
            let invalidDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            for invalid in invalidDates {
                for reset in [false, true] {
                    await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                        try await store.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 20, requireSnapshot: reset, now: invalid)
                    }
                }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.acknowledge(userID: user, deviceID: device, generation: 1, highestContiguousSequence: 0, receipt: missingReceipt, now: invalid) }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.fetchSnapshotManifest(userID: user, deviceID: device, snapshotID: missingSnapshot, generation: 2, now: invalid) }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.fetchSnapshotPage(userID: user, deviceID: device, snapshotID: missingSnapshot, generation: 2, rootDigest: "unused", index: 0, now: invalid) }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.acknowledgeSnapshot(userID: user, deviceID: device, snapshotID: missingSnapshot, generation: 2, baseSequence: 0, receipt: missingReceipt, now: invalid) }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                    try await PostgresV2SnapshotResetStager.stage(sql: sql, schema: "im_v2", userID: userUUID, deviceID: deviceUUID, currentGeneration: 1, retainedFloor: 0, capabilityProfile: "base", capabilityLifetime: 60, now: invalid, makeUUID: UUID.init)
                }
            }
            let upper = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 30)
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 20, now: upper) }
            for interval in [Double.infinity, .greatestFiniteMagnitude, .leastNonzeroMagnitude] {
                let invalidStore = PostgresV2SyncStore(database: database, capabilityLifetime: interval)
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await invalidStore.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 20, now: now) }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                    try await PostgresV2SnapshotResetStager.stage(sql: sql, schema: "im_v2", userID: userUUID, deviceID: deviceUUID, currentGeneration: 1, retainedFloor: 0, capabilityProfile: "base", capabilityLifetime: interval, now: now, makeUUID: UUID.init)
                }
            }
            for limit in [Int.min, 0, Int.max] {
                await #expect(throws: V2SyncStoreError.invalidRecordLimit) { try await store.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: limit, now: now) }
            }
            for table in ["device_sync_cursors", "sync_tokens", "sync_receipts", "device_snapshot_resets", "sync_snapshot_artifacts", "user_projection_checkpoints"] { #expect(try await count("im_v2." + table, on: sql) == 0) }
            try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: userUUID), 1)").run()
            try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: userUUID), 1, \(bind: UUID()), 'stranger_message_permission', '{\"allows_stranger_messages\":true,\"updated_at_ms\":1750000000000}'::jsonb, \(bind: now))").run()
            try await drainV3Projection(database: database)
            guard case .ready(let generation, let records, let token, let receipt, _) = try await store.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 20, now: now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            #expect(generation == 1 && records.count == 1)
            for invalid in invalidDates {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.acknowledge(userID: user, deviceID: device, generation: 1, highestContiguousSequence: 1, receipt: receipt, now: invalid) }
            }
            #expect(try await count("im_v2.device_sync_cursors WHERE state = 'ready' AND acknowledged_sequence = 0", on: sql) == 1)
            #expect(try await count("im_v2.sync_tokens", on: sql) == 1)
            #expect(try await count("im_v2.sync_receipts", on: sql) == 1)
            try await store.acknowledge(userID: user, deviceID: device, generation: 1, highestContiguousSequence: 1, receipt: receipt, now: now)
            try await store.acknowledge(userID: user, deviceID: device, generation: 1, highestContiguousSequence: 1, receipt: receipt, now: now)
            guard case .ready(_, let remaining, _, _, _) = try await store.pull(userID: user, deviceID: device, syncToken: token, maxRecords: 20, now: now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            #expect(remaining.isEmpty)
            guard case .resetPreparing(let snapshot, let resetGeneration, _) = try await store.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 20, requireSnapshot: true, now: now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            #expect(resetGeneration == 2)
            let builder = PostgresV2SnapshotArtifactBuilder(database: database)
            while try await builder.runOnce(now: now).claimed { try Task.checkCancellation() }
            let manifest = try await store.fetchSnapshotManifest(userID: user, deviceID: device, snapshotID: snapshot, generation: 2, now: now)
            #expect(manifest.totalItems == 1)
            _ = try await store.fetchSnapshotPage(userID: user, deviceID: device, snapshotID: snapshot, generation: 2, rootDigest: manifest.rootDigest, index: 0, now: now)
            for invalid in invalidDates {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await store.acknowledgeSnapshot(userID: user, deviceID: device, snapshotID: snapshot, generation: 2, baseSequence: 1, receipt: manifest.receipt, now: invalid) }
            }
            #expect(try await count("im_v2.device_sync_cursors WHERE state = 'reset_pending' AND acknowledged_sequence = 1", on: sql) == 1)
            for _ in 0..<2 { try await store.acknowledgeSnapshot(userID: user, deviceID: device, snapshotID: snapshot, generation: 2, baseSequence: 1, receipt: manifest.receipt, now: now) }
            guard case .ready(let resumed, let tail, _, _, _) = try await store.pull(userID: user, deviceID: device, syncToken: manifest.nextSyncToken, maxRecords: 20, now: now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            #expect(resumed == 2 && tail.isEmpty)
        }
    }

    @Test("Operator snapshot retries report existing state without calculating a new deadline",
          arguments: ["preparing", "ready", "acknowledged"])
    func operatorSnapshotReplayClockBoundary(state: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let user = UUID(), device = UUID(), sibling = UUID()
            let command = V2DeviceSnapshotResetCommand(operationID: UUID(), userID: .init(uuid: user), deviceID: .init(uuid: device))
            let fresh = V2DeviceSnapshotResetCommand(operationID: UUID(), userID: .init(uuid: user), deviceID: .init(uuid: sibling))
            for id in [device, sibling] {
                try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: user), \(bind: id), \(bind: now), \(bind: now))").run()
            }
            let route = try V2UserShardRoute(bucket: "control", observedRouterEpoch: 1)
            let registry = try V2StaticUserShardStorageRegistry(locations: [.init(bucket: route.bucket, database: database, schema: "im_v2")])
            func service(at date: Date) throws -> V2PostgresDeviceSnapshotResetService {
                try .init(registry: registry, deviceAvailability: V2PostgresDeviceAvailabilityChecker(database: database),
                    routeFence: V2FixedUserShardRouteFence(route: route, database: database), capabilityProfile: "base",
                    capabilityLifetime: 60, now: { date })
            }
            #expect(try await service(at: now).stage(command) == .init(generation: 2, state: .preparing, wasIdempotent: false))
            if state != "preparing" {
                let builder = PostgresV2SnapshotArtifactBuilder(database: database)
                while try await builder.runOnce(now: now).claimed { try Task.checkCancellation() }
            }
            if state == "acknowledged" {
                let store = PostgresV2SyncStore(database: database)
                let snapshot = SnapshotID(uuid: command.operationID)
                let manifest = try await store.fetchSnapshotManifest(userID: command.userID, deviceID: command.deviceID,
                    snapshotID: snapshot, generation: 2, now: now)
                try await store.acknowledgeSnapshot(userID: command.userID, deviceID: command.deviceID,
                    snapshotID: snapshot, generation: 2, baseSequence: manifest.baseSequence, receipt: manifest.receipt, now: now)
            }
            func snapshot() async throws -> [String] {
                var result: [String] = []
                for table in ["device_sync_cursors", "sync_tokens", "sync_receipts", "device_snapshot_resets", "sync_snapshot_artifacts", "user_projection_checkpoints"] {
                    guard let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self) else { throw CancellationError() }
                    result.append(row.value)
                }
                return result
            }
            let before = try await snapshot()
            let expected = V2DeviceSnapshotResetResult(generation: 2, state: state == "preparing" ? .preparing : .ready, wasIdempotent: true)
            let dates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
                1e14, -1e14, -1e12, 946_684_800 + 9_223_371_331_200 - 30].map { Date(timeIntervalSince1970: $0) }
            for date in dates {
                for replayClock in [date, now, date] {
                    #expect((try? await service(at: replayClock).stage(command)) == expected)
                    #expect(try await snapshot() == before)
                }
                await #expect(throws: V2DeviceSnapshotResetError.unavailable) { try await service(at: date).stage(fresh) }
                #expect(try await snapshot() == before)
            }
            #expect(try await service(at: now).stage(fresh) == .init(generation: 2, state: .preparing, wasIdempotent: false))
        }
    }

    @Test("Operator snapshot reset rejects invalid lifetimes without consuming its operation ID")
    func operatorSnapshotTimestampBoundaries() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let user = UUID(), device = UUID()
            let command = V2DeviceSnapshotResetCommand(operationID: UUID(), userID: .init(uuid: user), deviceID: .init(uuid: device))
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: user), \(bind: device), \(bind: now), \(bind: now))").run()
            let route = try V2UserShardRoute(bucket: "control", observedRouterEpoch: 1)
            let registry = try V2StaticUserShardStorageRegistry(locations: [.init(bucket: route.bucket, database: database, schema: "im_v2")])
            func service(at date: Date, lifetime: TimeInterval = 60) throws -> V2PostgresDeviceSnapshotResetService {
                try .init(registry: registry, deviceAvailability: V2PostgresDeviceAvailabilityChecker(database: database),
                    routeFence: V2FixedUserShardRouteFence(route: route, database: database), capabilityProfile: "base", capabilityLifetime: lifetime, now: { date })
            }
            let invalidDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) } + [Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 30)]
            for invalid in invalidDates {
                await #expect(throws: V2DeviceSnapshotResetError.unavailable) { try await service(at: invalid).stage(command) }
            }
            for lifetime in [Double.infinity, .greatestFiniteMagnitude, .leastNonzeroMagnitude] {
                await #expect(throws: V2DeviceSnapshotResetError.unavailable) { try await service(at: now, lifetime: lifetime).stage(command) }
            }
            for table in ["device_sync_cursors", "sync_tokens", "device_snapshot_resets", "sync_snapshot_artifacts", "user_projection_checkpoints"] { #expect(try await count("im_v2." + table, on: sql) == 0) }
            let reset = try service(at: now)
            #expect(try await reset.stage(command) == .init(generation: 2, state: .preparing, wasIdempotent: false))
            #expect(try await reset.stage(command) == .init(generation: 2, state: .preparing, wasIdempotent: true))
            for table in ["device_sync_cursors", "sync_tokens", "device_snapshot_resets", "sync_snapshot_artifacts", "user_projection_checkpoints"] { #expect(try await count("im_v2." + table, on: sql) == 1) }
        }
    }

    @Test("Profile writes reject unsupported clocks but completed operations remain replayable", arguments: ["profile", "alias", "nickname"], [false, true])
    func profileWriteTimestampBoundaries(kind: String, change: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let operation = UUID()
            let target = UserID(uuid: memberTwoUUID)
            let before = try await PostgresV2ProfileUpdateStore(database: database).currentProfile(for: senderID)
            let original = kind == "profile" ? try #require(before.publicIdentity).displayName : "original"
            let name = change ? "changed" : original
            let revision = try #require(V2ProfileRevision(rawValue: 1))
            if kind == "alias" {
                try await sql.raw("INSERT INTO im_v2.user_relationships (lower_user_id, higher_user_id, state, requested_by_user_id, updated_at) VALUES (\(bind: senderUUID), \(bind: memberTwoUUID), 'accepted', \(bind: senderUUID), \(bind: now))").run()
                try await sql.raw("INSERT INTO im_v2.user_contact_aliases (owner_user_id, target_user_id, remark_name, revision, updated_at) VALUES (\(bind: senderUUID), \(bind: memberTwoUUID), 'original', 1, \(bind: now))").run()
            } else if kind == "nickname" {
                try await sql.raw("INSERT INTO im_v2.room_member_nicknames (room_id, user_id, nickname, revision, updated_at) VALUES (\(bind: roomUUID), \(bind: senderUUID), 'original', 1, \(bind: now))").run()
            }
            let command = try V2ProfileUpdateCommand(actorUserID: senderID, operationID: .init(uuid: operation), expectedRevision: before.revision, displayName: name, avatar: nil)
            func update(at date: Date) async throws -> V2ProfileRevision {
                if kind == "profile" {
                    let result = try await PostgresV2ProfileUpdateStore(database: database, now: { date }).update(command)
                    switch result {
                    case .updated(let view), .idempotent(let view): return view.revision
                    }
                }
                let store = PostgresV2ProfilePresentationStore(database: database, now: { date })
                if kind == "alias" {
                    return try await store.updateContactAlias(ownerUserID: senderID, targetUserID: target, operationID: .init(uuid: operation), expectedRevision: revision, remarkName: name).revision
                }
                return try await store.updateOwnGroupNickname(actorUserID: senderID, roomID: roomID, operationID: .init(uuid: operation), expectedRevision: revision, nickname: name).revision
            }
            let invalidDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            for invalid in invalidDates {
                if kind == "profile" {
                    await #expect(throws: V2ProfileUpdateError.corruptPersistenceState) { try await update(at: invalid) }
                } else {
                    await #expect(throws: V2ProfilePresentationError.corruptPersistenceState) { try await update(at: invalid) }
                }
            }
            let operations = ["public_profile_update_operations", "user_contact_alias_operations", "room_member_nickname_operations"]
            for table in operations + ["public_profile_update_outbox"] { #expect(try await count("im_v2." + table, on: sql) == 0) }
            #expect(try await PostgresV2ProfileUpdateStore(database: database).currentProfile(for: senderID) == before)
            if kind != "profile" {
                let table = kind == "alias" ? "user_contact_aliases" : "room_member_nicknames"
                #expect(try await sql.raw("SELECT revision AS value FROM im_v2.\(unsafeRaw: table)").first(decoding: CountRow.self)?.value == 1)
            }
            #expect(try await update(at: now).signedValue == (change ? 2 : 1))
            // The original ledger response needs no new timestamp, so it is
            // still available while a later server clock is invalid.
            for invalid in invalidDates { #expect(try await update(at: invalid).signedValue == (change ? 2 : 1)) }
            let selected = kind == "profile" ? operations[0] : (kind == "alias" ? operations[1] : operations[2])
            for table in operations { #expect(try await count("im_v2." + table, on: sql) == (table == selected ? 1 : 0)) }
            #expect(try await count("im_v2.public_profile_update_outbox", on: sql) == (kind == "profile" && change ? 1 : 0))
        }
    }

    @Test("Group creation checks timestamps across inline, staged and control manifest paths", arguments: ["inline", "control-inline", "staged", "control-staged"])
    func groupCreationTimestampBoundaries(path: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let store = PostgresV2GroupMessagingStore(database: database)
            let control = PostgresV2GroupRoomCreationIntentStore(database: database)
            let operation = GroupRoomOperationID(uuid: UUID())
            let newRoom = RoomID(uuid: UUID()), event = EventID(uuid: UUID())
            let command = try V2CreateGroupRoomCommand(actorUserID: senderID, operationID: operation, title: "clock group", capacityClass: .standard, initialMemberUserIDs: [.init(uuid: memberTwoUUID)])
            let staged = try V2StagedGroupRoomCommand(actorUserID: senderID, operationID: operation, title: command.title, capacityClass: command.capacityClass, stagedMemberCount: 1)
            let intent = try V2GroupRoomCreationIntent(actorUserID: senderID, operationID: operation, roomID: newRoom, eventID: event, roomShardID: "room-a", routeEpoch: 0, requestFingerprint: Data(repeating: 0x12, count: 32), audienceMemberCount: 2)
            let page = try V2GroupRoomCreationManifestPage(pageNumber: 0, memberUserIDs: command.allMemberUserIDs, isFinal: true)
            func create(at date: Date, operationOverride: GroupRoomOperationID? = nil, titleOverride: String? = nil) async throws -> V2CreateGroupRoomOutcome {
                let requested = try V2CreateGroupRoomCommand(actorUserID: senderID, operationID: operationOverride ?? operation,
                    title: titleOverride ?? command.title, capacityClass: command.capacityClass, initialMemberUserIDs: command.initialMemberUserIDs)
                let requestedStaged = try V2StagedGroupRoomCommand(actorUserID: senderID, operationID: requested.operationID,
                    title: requested.title, capacityClass: requested.capacityClass, stagedMemberCount: 1)
                let requestedIntent = try V2GroupRoomCreationIntent(actorUserID: senderID, operationID: requested.operationID,
                    roomID: newRoom, eventID: event, roomShardID: "room-a", routeEpoch: 0,
                    requestFingerprint: intent.requestFingerprint, audienceMemberCount: 2)
                switch path {
                case "inline": return try await store.create(command: requested, capacityProfile: profile, roomShardID: "room-a", roomID: newRoom, eventID: event, now: date)
                case "control-inline": return try await store.createControlValidated(command: requested, validatedMemberUserIDs: requested.allMemberUserIDs, capacityProfile: profile, roomShardID: "room-a", roomID: newRoom, eventID: event, now: date)
                case "staged": return try await store.createStaged(command: requestedStaged, capacityProfile: profile, roomShardID: "room-a", roomID: newRoom, eventID: event, now: date)
                default: return try await store.createControlValidatedStaged(command: requestedStaged, intent: requestedIntent, capacityProfile: profile, now: date)
                }
            }
            let invalidDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            let routesBefore = try await count("im_v2.room_owner_routes", on: sql)
            for invalid in invalidDates {
                await #expect(throws: V2GroupMessagingStoreError.corruptPersistenceState) { try await create(at: invalid) }
                await #expect(throws: V2GroupMessagingStoreError.corruptPersistenceState) { try await store.stageControlValidatedAudience(intent: intent, page: page, now: invalid) }
                await #expect(throws: V2GroupRoomCreationIntentStoreError.corruptPersistenceState) { try await control.prepare(intent, memberUserIDs: command.allMemberUserIDs, now: invalid) }
                await #expect(throws: V2GroupRoomCreationIntentStoreError.corruptPersistenceState) { try await control.prepareStaged(intent, command: staged, now: invalid) }
                await #expect(throws: V2GroupRoomCreationIntentStoreError.corruptPersistenceState) { try await control.finalizeCommitted(intent, now: invalid) }
            }
            for table in ["group_room_operations", "room_events", "user_state_event_outbox", "group_room_creation_intents", "group_room_creation_intent_members", "group_room_creation_intent_pages"] {
                #expect(try await count("im_v2." + table, on: sql) == 0)
            }
            #expect(try await count("im_v2.rooms", on: sql) == 1)
            #expect(try await count("im_v2.room_memberships", on: sql) == 3)
            #expect(try await count("im_v2.room_owner_routes", on: sql) == routesBefore)
            if path == "staged" || path == "control-staged" {
                let drafts = PostgresV2GroupAudienceImportStore(database: database)
                let policy = V2GroupAudienceImportPolicy(maximumStagedMembersPerActor: 10)
                _ = try await drafts.begin(actorUserID: senderID, operationID: operation, title: command.title, policy: policy, now: now)
                _ = try await drafts.append(actorUserID: senderID, operationID: operation, memberUserIDs: command.initialMemberUserIDs, maximumMembers: 10, policy: policy, now: now)
                _ = try await drafts.freeze(actorUserID: senderID, operationID: operation, policy: policy, now: now)
            }
            if path == "control-staged" {
                #expect(try await control.prepareStaged(intent, command: staged, now: now) == .prepared(intent))
                try await store.stageControlValidatedAudience(intent: intent, page: page, now: now)
                try await store.stageControlValidatedAudience(intent: intent, page: page, now: now)
            } else if path == "control-inline" {
                #expect(try await control.prepare(intent, memberUserIDs: command.allMemberUserIDs, now: now) == .prepared(intent))
            }
            guard case .created(let created) = try await create(at: now) else { throw V2GroupMessagingStoreError.corruptPersistenceState }
            #expect(created.roomID == newRoom && created.createdAt == now && created.memberCount == 2)
            #expect(try await create(at: now.addingTimeInterval(1)) == .idempotent(created))
            func snapshot() async throws -> [String] {
                var values: [String] = []
                for table in ["rooms", "group_rooms", "room_memberships", "group_room_operations", "room_events",
                    "user_state_event_outbox", "room_admission", "shard_admission_pools", "room_owner_routes",
                    "group_room_creation_drafts", "group_room_creation_draft_members", "group_room_creation_intents",
                    "group_room_creation_intent_members", "group_room_creation_intent_pages"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)
                    values.append(try #require(row).value)
                }
                return values
            }
            let committedState = try await snapshot()
            for invalid in invalidDates {
                #expect(try await create(at: invalid) == .idempotent(created))
                #expect(try await create(at: invalid, titleOverride: "different group") == .idempotencyConflict)
                await #expect(throws: V2GroupMessagingStoreError.corruptPersistenceState) {
                    try await create(at: invalid, operationOverride: .init(uuid: UUID()))
                }
                #expect(try await snapshot() == committedState)
            }
            let operationUUID = try #require(UUID(uuidString: operation.rawValue))
            for literal in ["infinity", "-infinity", "294276-12-31 23:59:59.999999+00"] {
                try await sql.raw("UPDATE im_v2.group_room_operations SET created_at = \(bind: literal)::timestamptz WHERE operation_id = \(bind: operationUUID)").run()
                let before = try await snapshot()
                await #expect(throws: V2GroupMessagingStoreError.corruptPersistenceState) { try await create(at: now) }
                #expect(try await create(at: now, titleOverride: "different group") == .idempotencyConflict)
                #expect(try await snapshot() == before)
            }
            for date in [Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000),
                         Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10), now] {
                try await sql.raw("UPDATE im_v2.group_room_operations SET created_at = \(bind: date) WHERE operation_id = \(bind: operationUUID)").run()
                let before = try await snapshot()
                let expected = try V2GroupRoom(roomID: created.roomID, ownerUserID: created.ownerUserID, title: created.title,
                    capacityClass: created.capacityClass, memberUserIDs: created.memberUserIDs, memberCount: created.memberCount, createdAt: date)
                #expect(try await create(at: now) == .idempotent(expected))
                #expect(try await snapshot() == before)
            }
            #expect(try await snapshot() == committedState)
            if path.hasPrefix("control-") {
                // An owner may already have committed before the control
                // clock fails. A retry must still publish the original route.
                for invalid in invalidDates {
                    await #expect(throws: V2GroupRoomCreationIntentStoreError.corruptPersistenceState) { try await control.finalizeCommitted(intent, now: invalid) }
                }
                #expect(try await count("im_v2.room_owner_routes", on: sql) == routesBefore)
                let committed = try await control.finalizeCommitted(intent, now: now)
                #expect(committed.state == .committed && committed.roomID == newRoom)
                #expect(try await control.finalizeCommitted(intent, now: now.addingTimeInterval(1)) == committed)
                #expect(try await count("im_v2.room_owner_routes", on: sql) == routesBefore + 1)
            }
            for table in ["group_room_operations", "room_events"] { #expect(try await count("im_v2." + table, on: sql) == 1) }
            #expect(try await count("im_v2.user_state_event_outbox", on: sql) == 2)
            #expect(try await count("im_v2.rooms", on: sql) == 2)
            #expect(try await count("im_v2.room_memberships", on: sql) == 5)
            #expect(try await sql.raw("SELECT (payload->>'created_at_ms')::bigint AS value FROM im_v2.room_events").first(decoding: CountRow.self)?.value == 1_750_000_000_000)
        }
    }

    @Test("Direct room and preference timestamps are rejected before durable writes")
    func directMessagingTimestampBoundaries() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let store = PostgresV2DirectMessagingStore(database: resources.database(.psql))
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3))
            let open = try V2OpenDirectRoomCommand(actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID))
            let stranger = V2SetStrangerMessagePermissionCommand(actorUserID: senderID, operationID: .init(uuid: UUID()), permission: .deny)
            let userAdd = V2SetUserAddPermissionCommand(actorUserID: senderID, operationID: .init(uuid: UUID()), permission: .deny)
            let newRoom = RoomID(uuid: UUID())
            for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12] {
                let invalid = Date(timeIntervalSince1970: seconds)
                await #expect(throws: V2DirectMessagingStoreError.corruptPersistenceState) { try await store.open(command: open, capacityProfile: profile, roomShardID: "room-a", roomID: newRoom, now: invalid) }
                await #expect(throws: V2DirectMessagingStoreError.corruptPersistenceState) { try await store.setStrangerMessagePermission(command: stranger, now: invalid) }
                await #expect(throws: V2DirectMessagingStoreError.corruptPersistenceState) { try await store.setUserAddPermission(command: userAdd, now: invalid) }
            }
            let tables = ["direct_room_pairs", "direct_room_operations", "user_stranger_message_preferences", "stranger_message_preference_operations", "user_add_preferences", "user_add_preference_operations"]
            for table in tables { #expect(try await count("im_v2." + table, on: sql) == 0) }
            #expect(try await count("im_v2.rooms", on: sql) == 1)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
            guard case .opened(let opened) = try await store.open(command: open, capacityProfile: profile, roomShardID: "room-a", roomID: newRoom, now: now) else { throw CancellationError() }
            #expect(opened.roomID == newRoom && opened.createdAt == now)
            #expect(try await store.open(command: open, capacityProfile: profile, roomShardID: "room-a", roomID: .init(uuid: UUID()), now: now.addingTimeInterval(1)) == .idempotent(opened))
            #expect(try await store.setStrangerMessagePermission(command: stranger, now: now) == .updated(permission: .deny, updatedAt: now))
            #expect(try await store.setStrangerMessagePermission(command: stranger, now: now.addingTimeInterval(1)) == .idempotent(permission: .deny, updatedAt: now))
            #expect(try await store.setUserAddPermission(command: userAdd, now: now) == .updated(permission: .deny, updatedAt: now))
            #expect(try await store.setUserAddPermission(command: userAdd, now: now.addingTimeInterval(1)) == .idempotent(permission: .deny, updatedAt: now))
            for table in tables { #expect(try await count("im_v2." + table, on: sql) == 1) }
            #expect(try await count("im_v2.rooms", on: sql) == 2)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 2)
            #expect(try await count("im_v2.user_state_event_outbox", on: sql) == 1)
            let outbox = try PostgresV2UserStateEventOutbox(database: resources.database(.psql))
            let projector = try PostgresV2UserStateEventProjector(database: resources.database(.psql))
            let leases = try await outbox.claim(now: now, leaseDuration: 1, limit: 10)
            #expect(leases.count == 1)
            for lease in leases {
                let sequence = try await projector.project(lease.event)
                #expect(try await projector.project(lease.event) == sequence)
                #expect(try await outbox.acknowledge(lease, sequence: sequence, now: now))
            }
            #expect(try await count("im_v2.user_sync_log", on: sql) == 3)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("Group audience timestamps preserve staging, recovery and completion after rejection")
    func groupAudienceTimestampBoundaries() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let store = PostgresV2GroupAudienceImportStore(database: resources.database(.psql))
            let policy = V2GroupAudienceImportPolicy(maximumStagedMembersPerActor: 10, stagingLifetime: 60, completedRetention: 120, finalizingRecoveryInterval: 10)
            let operation = GroupRoomOperationID(uuid: UUID())
            let members = [UserID(uuid: memberTwoUUID)]
            _ = try await store.begin(actorUserID: senderID, operationID: operation, title: "clock", policy: policy, now: now)
            #expect(try await store.append(actorUserID: senderID, operationID: operation, memberUserIDs: members, maximumMembers: 10, policy: policy, now: now).stagedMemberCount == 1)
            for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12] {
                let invalid = Date(timeIntervalSince1970: seconds)
                await #expect(throws: V2GroupAudienceImportError.corruptPersistenceState) { try await store.begin(actorUserID: senderID, operationID: operation, title: "clock", policy: policy, now: invalid) }
                await #expect(throws: V2GroupAudienceImportError.corruptPersistenceState) { try await store.append(actorUserID: senderID, operationID: operation, memberUserIDs: members, maximumMembers: 10, policy: policy, now: invalid) }
                await #expect(throws: V2GroupAudienceImportError.corruptPersistenceState) { try await store.freeze(actorUserID: senderID, operationID: operation, policy: policy, now: invalid) }
                await #expect(throws: V2GroupAudienceImportError.corruptPersistenceState) { try await store.complete(actorUserID: senderID, operationID: operation, roomID: roomID, policy: policy, now: invalid) }
                await #expect(throws: V2GroupAudienceImportError.corruptPersistenceState) { try await store.cancel(actorUserID: senderID, operationID: operation, now: invalid) }
                await #expect(throws: V2GroupAudienceImportError.corruptPersistenceState) { try await store.purgeExpired(now: invalid, limit: 8) }
                await #expect(throws: V2GroupAudienceImportError.corruptPersistenceState) { try await store.recoverableFinalizing(now: invalid, staleAfter: 10, limit: 8) }
            }
            let upper = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 30)
            #expect(v2PostgresTimestampCanEncode(upper))
            #expect(!v2PostgresTimestampCanEncode(upper.addingTimeInterval(60)))
            await #expect(throws: V2GroupAudienceImportError.corruptPersistenceState) { try await store.begin(actorUserID: senderID, operationID: operation, title: "clock", policy: policy, now: upper) }
            await #expect(throws: V2GroupAudienceImportError.corruptPersistenceState) { try await store.append(actorUserID: senderID, operationID: operation, memberUserIDs: members, maximumMembers: 10, policy: policy, now: upper) }
            await #expect(throws: V2GroupAudienceImportError.corruptPersistenceState) { try await store.freeze(actorUserID: senderID, operationID: operation, policy: policy, now: upper) }
            await #expect(throws: V2GroupAudienceImportError.corruptPersistenceState) { try await store.complete(actorUserID: senderID, operationID: operation, roomID: roomID, policy: policy, now: upper) }
            let lower = Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000 + 5)
            #expect(v2PostgresTimestampCanEncode(lower))
            await #expect(throws: V2GroupAudienceImportError.corruptPersistenceState) { try await store.recoverableFinalizing(now: lower, staleAfter: 10, limit: 8) }
            for duration in [Double.infinity, .greatestFiniteMagnitude, 0.0000001] {
                let invalidPolicy = V2GroupAudienceImportPolicy(maximumStagedMembersPerActor: 10, stagingLifetime: duration, completedRetention: duration)
                await #expect(throws: V2GroupAudienceImportError.corruptPersistenceState) { try await store.begin(actorUserID: senderID, operationID: operation, title: "clock", policy: invalidPolicy, now: now) }
                await #expect(throws: V2GroupAudienceImportError.corruptPersistenceState) { try await store.complete(actorUserID: senderID, operationID: operation, roomID: roomID, policy: invalidPolicy, now: now) }
            }
            for interval in [Double.infinity, .greatestFiniteMagnitude, .leastNonzeroMagnitude] {
                await #expect(throws: V2GroupAudienceImportError.corruptPersistenceState) { try await store.recoverableFinalizing(now: now, staleAfter: interval, limit: 8) }
            }
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.group_room_creation_drafts WHERE state = 'staging' AND updated_at = \(bind: now) AND expires_at = \(bind: now.addingTimeInterval(60))").first(decoding: CountRow.self)?.value == 1)
            #expect(try await count("im_v2.group_room_creation_draft_members", on: sql) == 1)
            #expect(try await store.begin(actorUserID: senderID, operationID: operation, title: "clock", policy: policy, now: now).stagedMemberCount == 1)
            #expect(try await store.append(actorUserID: senderID, operationID: operation, memberUserIDs: members, maximumMembers: 10, policy: policy, now: now).stagedMemberCount == 1)
            #expect(try await store.freeze(actorUserID: senderID, operationID: operation, policy: policy, now: now.addingTimeInterval(1)).stagedMemberCount == 1)
            await #expect(throws: V2GroupAudienceImportError.corruptPersistenceState) {
                try await store.recoverableFinalizing(now: now.addingTimeInterval(12), staleAfter: .leastNonzeroMagnitude, limit: 8)
            }
            #expect(try await store.recoverableFinalizing(now: now.addingTimeInterval(5), staleAfter: 10, limit: 8).isEmpty)
            let recovery = try await store.recoverableFinalizing(now: now.addingTimeInterval(12), staleAfter: 10, limit: 8)
            #expect(recovery == [.init(actorUserID: senderID, operationID: operation)])
            #expect(try await store.recoverableFinalizing(now: now.addingTimeInterval(12), staleAfter: 10, limit: 8).isEmpty)
            try await store.complete(actorUserID: senderID, operationID: operation, roomID: roomID, policy: policy, now: now.addingTimeInterval(13))
            try await store.complete(actorUserID: senderID, operationID: operation, roomID: roomID, policy: policy, now: now.addingTimeInterval(13))
            #expect(try await store.purgeExpired(now: now.addingTimeInterval(132), limit: 8) == 0)
            #expect(try await store.purgeExpired(now: now.addingTimeInterval(133), limit: 8) == 1)
            #expect(try await count("im_v2.group_room_creation_draft_members", on: sql) == 0)
            let cancelled = GroupRoomOperationID(uuid: UUID()), discarded = GroupRoomOperationID(uuid: UUID())
            _ = try await store.begin(actorUserID: senderID, operationID: cancelled, title: "cancel", policy: policy, now: now.addingTimeInterval(140))
            try await store.cancel(actorUserID: senderID, operationID: cancelled, now: now.addingTimeInterval(141))
            try await store.cancel(actorUserID: senderID, operationID: cancelled, now: now.addingTimeInterval(141))
            _ = try await store.begin(actorUserID: senderID, operationID: discarded, title: "discard", policy: policy, now: now.addingTimeInterval(142))
            _ = try await store.freeze(actorUserID: senderID, operationID: discarded, policy: policy, now: now.addingTimeInterval(143))
            // Discarding an explicitly frozen draft does not bind or compare
            // a clock; this cleanup remains available independently of it.
            try await store.discardFrozen(actorUserID: senderID, operationID: discarded, now: Date(timeIntervalSince1970: .nan))
            #expect(try await count("im_v2.group_room_creation_drafts", on: sql) == 0)
            #expect(try await count("im_v2.group_room_creation_draft_members", on: sql) == 0)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("Small control housekeeping budgets reach late cleanup categories", arguments: [0, 60, 600, 3_600])
    func housekeepingSmallBudgetDoesNotStarve(interval: Int) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            let user = UUID(), device = UUID()
            let retention = V2IdempotencyPolicy.minimumServerRetention
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let old = base.addingTimeInterval(-retention - 86_400)
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: user), \(bind: device), \(bind: old), \(bind: old))").run()
            try await sql.raw("INSERT INTO im_v2.user_live_presence_leases (user_id, device_id, connection_id, updated_at, expires_at) VALUES (\(bind: user), \(bind: device), \(bind: UUID()), \(bind: old), \(bind: old))").run()
            try await sql.raw("INSERT INTO im_v2.user_live_activity_preference_operations (actor_user_id, operation_id, allows_online_presence, allows_typing_indicators, updated_at) VALUES (\(bind: user), \(bind: UUID()), true, true, \(bind: old))").run()
            if interval == 0 {
                try await V2SchemaReadiness.verify(database: resources.database(.psql))
                try await sql.raw("DELETE FROM im_v2.control_housekeeping_cursor").run()
                await #expect(throws: V2SchemaReadinessError.self) {
                    try await V2SchemaReadiness.verify(database: resources.database(.psql))
                }
                try await sql.raw("INSERT INTO im_v2.control_housekeeping_cursor VALUES (true, 8)").run()
                let store = PostgresV2ControlPlaneHousekeepingStore(database: resources.database(.psql))
                try await sql.raw("CREATE FUNCTION im_v2.fail_housekeeping() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'cleanup rollback fixture'; END; $$").run()
                try await sql.raw("CREATE TRIGGER fail_housekeeping BEFORE DELETE ON im_v2.user_live_presence_leases FOR EACH ROW EXECUTE FUNCTION im_v2.fail_housekeeping()").run()
                await #expect(throws: (any Error).self) {
                    try await store.purgeTerminal(now: base, retention: 60, idempotencyRetention: retention, limit: 1)
                }
                #expect(try await count("im_v2.control_housekeeping_cursor WHERE rotation = 8", on: sql) == 1)
                #expect(try await count("im_v2.user_live_presence_leases", on: sql) == 1)
                try await sql.raw("DROP TRIGGER fail_housekeeping ON im_v2.user_live_presence_leases").run()
                try await sql.raw("UPDATE im_v2.control_housekeeping_cursor SET rotation = 0").run()
                async let first = store.purgeTerminal(now: base, retention: 60, idempotencyRetention: retention, limit: 1)
                async let second = PostgresV2ControlPlaneHousekeepingStore(database: resources.database(.psql)).purgeTerminal(now: base, retention: 60, idempotencyRetention: retention, limit: 1)
                _ = try await (first, second)
                #expect(try await count("im_v2.control_housekeeping_cursor WHERE rotation = 2", on: sql) == 1)
                try await sql.raw("UPDATE im_v2.control_housekeeping_cursor SET rotation = 0").run()
            }
            var leases = 0, operations = 0
            // Recreate the store every pass; fairness belongs to committed
            // database state, even for frozen clocks or hourly scheduling.
            for pass in 0..<300 {
                let store = PostgresV2ControlPlaneHousekeepingStore(database: resources.database(.psql))
                let report = try await store.purgeTerminal(now: base.addingTimeInterval(Double(pass * interval)),
                    retention: 60, idempotencyRetention: retention, limit: 1)
                #expect(report.deletedRows <= 1)
                leases += report.purgedExpiredConnectionLeaseRows
                operations += report.purgedIdempotencyRows
                if leases == 1 && operations == 1 { break }
            }
            #expect(leases == 1)
            #expect(operations == 1)
            #expect(try await count("im_v2.user_live_presence_leases", on: sql) == 0)
            #expect(try await count("im_v2.user_live_activity_preference_operations", on: sql) == 0)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("Housekeeping validates all cutoffs before deletion and recovers after bad clocks", arguments: [Date(timeIntervalSince1970: 1_750_000_000), Date(timeIntervalSince1970: -3_600.5)])
    func housekeepingTimestampBoundaries(now: Date) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            let user = UUID(), device = UUID()
            let retention = V2IdempotencyPolicy.minimumServerRetention
            let old = now.addingTimeInterval(-retention - 60)
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: user), \(bind: device), \(bind: old), \(bind: old))").run()
            try await sql.raw("INSERT INTO im_v2.device_sync_cursors (user_id, device_id, state, reset_generation, acknowledged_sequence) VALUES (\(bind: user), \(bind: device), 'ready', 1, 7)").run()
            try await sql.raw("INSERT INTO im_v2.user_live_activity_preferences (user_id, updated_at) VALUES (\(bind: user), \(bind: old))").run()
            for (label, date, expiry) in [("old", old, now.addingTimeInterval(-1)), ("live", now, now.addingTimeInterval(60))] {
                try await sql.raw("INSERT INTO im_v2.user_live_presence_leases (user_id, device_id, connection_id, updated_at, expires_at) VALUES (\(bind: user), \(bind: device), \(bind: UUID()), \(bind: date), \(bind: expiry))").run()
                try await sql.raw("INSERT INTO im_v2.sync_tokens (token, user_id, device_id, reset_generation, watermark, expires_at, created_at) VALUES (\(bind: label + "-token"), \(bind: user), \(bind: device), 1, 7, \(bind: expiry), \(bind: date))").run()
                try await sql.raw("INSERT INTO im_v2.sync_receipts (receipt, user_id, device_id, reset_generation, first_sequence, last_sequence, expires_at, created_at) VALUES (\(bind: label + "-receipt"), \(bind: user), \(bind: device), 1, 7, 7, \(bind: expiry), \(bind: date))").run()
                try await sql.raw("INSERT INTO im_v2.user_live_activity_preference_operations (actor_user_id, operation_id, allows_online_presence, allows_typing_indicators, updated_at) VALUES (\(bind: user), \(bind: UUID()), true, true, \(bind: date))").run()
            }
            let control = PostgresV2ControlPlaneHousekeepingStore(database: resources.database(.psql))
            let sync = PostgresV2SyncHousekeepingStore(database: resources.database(.psql))
            // This clock and its short terminal cutoff are valid, but the
            // longer replay/effect retention crosses PostgreSQL's lower bound.
            let lower = Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000 + 120)
            #expect(v2PostgresTimestampCanEncode(lower))
            #expect(v2PostgresTimestampCanEncode(lower.addingTimeInterval(-60)))
            #expect(!v2PostgresTimestampCanEncode(lower.addingTimeInterval(-retention)))
            let invalidDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12, Double(Int.min) * 60].map { Date(timeIntervalSince1970: $0) } + [lower]
            for invalid in invalidDates {
                await #expect(throws: V2ControlPlaneHousekeepingError.corruptPersistenceState) {
                    try await V2ControlPlaneHousekeepingWorker(store: control, retention: 60, now: { invalid }).runOnce(limit: 1_024)
                }
                await #expect(throws: V2SyncHousekeepingError.corruptPersistenceState) {
                    try await V2SyncHousekeepingWorker(store: sync, now: { invalid }).runOnce(limit: 8)
                }
            }
            await #expect(throws: V2ControlPlaneHousekeepingError.corruptPersistenceState) {
                try await control.purgeTerminal(now: now, retention: .greatestFiniteMagnitude, idempotencyRetention: retention, limit: 1_024)
            }
            await #expect(throws: V2ControlPlaneHousekeepingError.corruptPersistenceState) {
                try await control.purgeTerminal(now: now, retention: 60, idempotencyRetention: .greatestFiniteMagnitude, limit: 1_024)
            }
            await #expect(throws: V2SyncHousekeepingError.corruptPersistenceState) {
                try await sync.purgeExpired(now: now, projectionEffectRetention: .greatestFiniteMagnitude, limit: 8)
            }
            let tables = ["user_live_presence_leases", "user_live_activity_preference_operations", "sync_tokens", "sync_receipts"]
            for table in tables { #expect(try await count("im_v2." + table, on: sql) == 2) }
            #expect(try await count("im_v2.device_sync_cursors WHERE state = 'ready' AND acknowledged_sequence = 7", on: sql) == 1)
            let controlReport = try await V2ControlPlaneHousekeepingWorker(store: control, retention: 60, now: { now }).runOnce(limit: 1_024)
            #expect(controlReport == .init(deletedRows: 2, purgedIdempotencyRows: 1, purgedExpiredConnectionLeaseRows: 1))
            let syncReport = try await V2SyncHousekeepingWorker(store: sync, now: { now }).runOnce(limit: 8)
            #expect(syncReport == .init(expiredTokenCount: 1, expiredReceiptCount: 1, recoveredResetCount: 0, purgedSnapshotCount: 0))
            for table in tables { #expect(try await count("im_v2." + table, on: sql) == 1) }
            #expect(try await count("im_v2.user_live_activity_preferences", on: sql) == 1)
            #expect(try await count("im_v2.device_sync_cursors WHERE state = 'ready' AND acknowledged_sequence = 7", on: sql) == 1)
            #expect(try await control.purgeTerminal(now: now, retention: 60, idempotencyRetention: retention, limit: 1_024).didWork == false)
            #expect(try await sync.purgeExpired(now: now, projectionEffectRetention: retention, limit: 8).didWork == false)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("Vanished presence durations leave no leases or renewal mutations and allow corrected lifetimes")
    func liveLeaseVanishedDuration() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let valid = try PostgresV2LiveActivityStore(database: database, onlineLease: 0.5)
            let tiny = try PostgresV2LiveActivityStore(database: database, onlineLease: 1e-12)
            let policy = V2AuthenticatedConnectionAdmissionPolicy(maximumConnectionsPerDevice: 2, maximumConnectionsPerUser: 8)
            for seconds in [Double(-1.0005), -1_000_000_000.1255, -210_866_803_199.1255, 1_750_000_000.1255] {
                let now = Date(timeIntervalSince1970: seconds)
                let user = UUID(), device = UUID(), connection = UUID(), newConnection = UUID()
                try await sql.raw("""
                    INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at)
                    VALUES (\(bind: user), \(bind: device), \(bind: now), \(bind: now))
                    """).run()
                let identity = V2AuthenticatedConnection(userID: .init(uuid: user), deviceID: .init(uuid: device), capabilityProfile: "base")
                guard case .accepted = try await valid.admitConnection(identity: identity, connectionID: connection, policy: policy, now: now) else {
                    Issue.record("Expected a usable half-second presence lease")
                    throw CancellationError()
                }
                func snapshot() async throws -> String {
                    let row = try await sql.raw("""
                        SELECT COALESCE(jsonb_agg(to_jsonb(lease) ORDER BY connection_id), '[]'::jsonb)::text AS value
                        FROM im_v2.user_live_presence_leases lease WHERE user_id = \(bind: user)
                        """).first(decoding: StringValueRow.self)
                    return try #require(row).value
                }
                let before = try await snapshot()
                let observed = now.addingTimeInterval(0.125)
                #expect(observed.addingTimeInterval(1e-12) == observed)
                await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) {
                    _ = try await tiny.admitConnection(identity: identity, connectionID: newConnection, policy: policy, now: observed)
                }
                await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) {
                    _ = try await tiny.renewConnection(identity: identity, connectionID: connection, now: observed)
                }
                let rejected = try await tiny.renewConnections([connection, newConnection].map {
                    .init(identity: identity, connectionID: $0, now: observed)
                })
                for value in rejected.values { #expect(value == .init(outcome: .rejected, allowsOnlinePresence: false)) }
                #expect(rejected.count == 2)
                #expect(try await snapshot() == before)

                guard case .accepted = try await valid.renewConnection(identity: identity, connectionID: connection, now: observed) else {
                    Issue.record("Expected scalar renewal after correcting the configured lifetime")
                    throw CancellationError()
                }
                let later = now.addingTimeInterval(0.25)
                let renewed = try await valid.renewConnections([.init(identity: identity, connectionID: connection, now: later)])
                guard case .accepted? = renewed[connection]?.outcome else {
                    Issue.record("Expected batch renewal after correcting the configured lifetime")
                    throw CancellationError()
                }
                #expect(try await sql.raw("""
                    SELECT COUNT(*)::bigint AS value FROM im_v2.user_live_presence_leases
                    WHERE user_id = \(bind: user) AND connection_id = \(bind: connection)
                      AND expires_at > updated_at AND updated_at = \(bind: later)
                      AND expires_at = \(bind: later.addingTimeInterval(0.5))
                    """).first(decoding: CountRow.self)?.value == 1)
            }
        }
    }

    @Test("Presence leases validate database bounds and never regress on older heartbeats")
    func liveLeaseTimestampBoundaries() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let users = [UUID(), UUID()], devices = [UUID(), UUID()], connections = [UUID(), UUID()]
            var identities: [V2AuthenticatedConnection] = []
            for (user, device) in zip(users, devices) {
                try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: user), \(bind: device), \(bind: now), \(bind: now))").run()
                identities.append(.init(userID: .init(uuid: user), deviceID: .init(uuid: device), capabilityProfile: "base"))
            }
            for duration in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, 0, -1, Double(Int64.max) / 1_000_000] {
                #expect(throws: V2LiveActivityConfigurationError.invalidOnlineLease) {
                    try PostgresV2LiveActivityStore(database: resources.database(.psql), onlineLease: duration)
                }
            }
            let store = try PostgresV2LiveActivityStore(database: resources.database(.psql))
            let policy = V2AuthenticatedConnectionAdmissionPolicy(maximumConnectionsPerDevice: 2, maximumConnectionsPerUser: 8)
            let upper = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 45)
            #expect(v2PostgresTimestampCanEncode(upper))
            #expect(!v2PostgresTimestampCanEncode(upper.addingTimeInterval(90)))
            let invalidDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) } + [upper]
            for invalid in invalidDates {
                await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) {
                    try await store.admitConnection(identity: identities[0], connectionID: connections[0], policy: policy, now: invalid)
                }
                await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) {
                    try await store.renewConnection(identity: identities[0], connectionID: connections[0], now: invalid)
                }
                let batch = try await store.renewConnections([.init(identity: identities[0], connectionID: connections[0], now: invalid)])
                #expect(batch[connections[0]] == .init(outcome: .rejected, allowsOnlinePresence: false))
            }
            let tiny = try PostgresV2LiveActivityStore(database: resources.database(.psql), onlineLease: 0.0000001)
            await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) {
                try await tiny.admitConnection(identity: identities[0], connectionID: connections[0], policy: policy, now: now)
            }
            #expect(try await count("im_v2.user_live_presence_leases", on: sql) == 0)
            for index in identities.indices {
                #expect(try await store.admitConnection(identity: identities[index], connectionID: connections[index], policy: policy, now: now) == .accepted(expiresAt: now.addingTimeInterval(90)))
            }
            // A bad clock during cleanup must neither bind an invalid date
            // nor partially delete the still-owned lease.
            for invalid in invalidDates.dropLast() {
                await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) {
                    try await store.removePresence(identity: identities[0], connectionID: connections[0], now: invalid)
                }
            }
            #expect(try await count("im_v2.user_live_presence_leases", on: sql) == 2)
            #expect(try await store.renewConnection(identity: identities[0], connectionID: connections[0], now: now.addingTimeInterval(20)) == .accepted(expiresAt: now.addingTimeInterval(110)))
            #expect(try await store.renewConnection(identity: identities[0], connectionID: connections[0], now: now.addingTimeInterval(10)) == .accepted(expiresAt: now.addingTimeInterval(110)))
            #expect(try await store.admitConnection(identity: identities[0], connectionID: connections[0], policy: policy, now: now.addingTimeInterval(5)) == .accepted(expiresAt: now.addingTimeInterval(110)))
            _ = try await store.setPreferences(command: .init(actorUserID: identities[1].userID, operationID: .init(uuid: UUID()), allowsOnlinePresence: false, allowsTypingIndicators: true), now: now)
            let invalidConnection = UUID()
            let mixed = try await store.renewConnections([
                .init(identity: identities[0], connectionID: connections[0], now: Date(timeIntervalSince1970: .nan)),
                .init(identity: identities[0], connectionID: connections[0], now: now.addingTimeInterval(30)),
                .init(identity: identities[1], connectionID: invalidConnection, now: Date(timeIntervalSince1970: -1e12)),
                .init(identity: identities[1], connectionID: connections[1], now: now.addingTimeInterval(40)),
                .init(identity: identities[0], connectionID: connections[0], now: now.addingTimeInterval(15)),
                .init(identity: identities[1], connectionID: connections[1], now: Date(timeIntervalSince1970: 1e14))
            ])
            #expect(mixed.count == 3)
            #expect(mixed[connections[0]] == .init(outcome: .accepted(expiresAt: now.addingTimeInterval(120)), allowsOnlinePresence: true))
            #expect(mixed[connections[1]] == .init(outcome: .accepted(expiresAt: now.addingTimeInterval(130)), allowsOnlinePresence: false))
            #expect(mixed[invalidConnection] == .init(outcome: .rejected, allowsOnlinePresence: false))
            let stale = try await store.renewConnections(identities.indices.map { .init(identity: identities[$0], connectionID: connections[$0], now: now.addingTimeInterval(1)) })
            #expect(stale[connections[0]] == mixed[connections[0]])
            #expect(stale[connections[1]] == mixed[connections[1]])
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_live_presence_leases WHERE (connection_id = \(bind: connections[0]) AND updated_at = \(bind: now.addingTimeInterval(30)) AND expires_at = \(bind: now.addingTimeInterval(120))) OR (connection_id = \(bind: connections[1]) AND updated_at = \(bind: now.addingTimeInterval(40)) AND expires_at = \(bind: now.addingTimeInterval(130)))").first(decoding: CountRow.self)?.value == 2)
            #expect(try await store.renewConnection(identity: identities[1], connectionID: connections[1], now: now.addingTimeInterval(130)) == .rejected)
            let expired = try await store.renewConnections(identities.indices.map { .init(identity: identities[$0], connectionID: connections[$0], now: now.addingTimeInterval(130)) })
            for value in expired.values { #expect(value.outcome == .rejected) }
            for index in identities.indices {
                #expect(try await store.removePresence(identity: identities[index], connectionID: connections[index], now: now.addingTimeInterval(131)) == false)
            }
            #expect(try await count("im_v2.user_live_presence_leases", on: sql) == 0)
            // A valid database date before Date.distantPast must not be
            // discarded by the duplicate-heartbeat selection default.
            let historical = Date(timeIntervalSince1970: -100_000_000_000)
            #expect(historical < Date.distantPast)
            #expect(try await store.admitConnection(identity: identities[0], connectionID: connections[0], policy: policy, now: historical) == .accepted(expiresAt: historical.addingTimeInterval(90)))
            let historicalBatch = try await store.renewConnections([.init(identity: identities[0], connectionID: connections[0], now: historical.addingTimeInterval(1))])
            #expect(historicalBatch[connections[0]]?.outcome == .accepted(expiresAt: historical.addingTimeInterval(91)))
            #expect(try await store.removePresence(identity: identities[0], connectionID: connections[0], now: historical.addingTimeInterval(2)) == false)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("Membership timestamps are checked in standalone, routed and composed transactions")
    func membershipTimestampBoundaries() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3))
            let target = UserID(uuid: memberTwoUUID)
            let remove = try V2ChangeRoomMembershipCommand(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: target, action: .remove, expectedMembershipRevision: 0)
            let add = try V2ChangeRoomMembershipCommand(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: target, action: .add, expectedMembershipRevision: 1)
            let store = PostgresV2RoomMembershipStore(database: resources.database(.psql))
            let identity = try await V2PostgresMembershipIdentitySnapshotValidator(database: resources.database(.psql)).snapshot(actorUserID: senderID, targetUserID: target)
            let route = try V2RoomShardRoute(shardID: "room-a", epoch: 0)
            let eventID = EventID(uuid: UUID())
            for command in [remove, add] {
                for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14] {
                    let invalid = Date(timeIntervalSince1970: seconds)
                    await #expect(throws: V2RoomMembershipStoreError.corruptPersistenceState) {
                        try await store.change(command: command, capacityProfile: profile, eventID: eventID, now: invalid)
                    }
                    await #expect(throws: V2RoomMembershipStoreError.corruptPersistenceState) {
                        try await store.changeControlValidated(command: command, ownerRoute: route, identitySnapshot: identity, capacityProfile: profile, eventID: eventID, now: invalid)
                    }
                    await #expect(throws: V2RoomMembershipStoreError.corruptPersistenceState) {
                        try await resources.database(.psql).transaction { transaction in
                            let transactionSQL = try #require(transaction as? any SQLDatabase)
                            return try await PostgresV2RoomMembershipStore.change(in: transactionSQL, command: command, capacityProfile: profile, eventID: eventID, now: invalid)
                        }
                    }
                }
            }
            for table in ["room_membership_operations", "room_events", "user_state_event_outbox"] { #expect(try await count("im_v2." + table, on: sql) == 0) }
            #expect(try await count("im_v2.room_memberships WHERE left_revision IS NULL", on: sql) == 3)
            #expect(try await count("im_v2.rooms WHERE membership_revision = 0 AND room_sequence = 0", on: sql) == 1)
            for command in [remove, add] {
                guard case .changed(let changed) = try await store.changeControlValidated(command: command, ownerRoute: route, identitySnapshot: identity, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now) else { throw CancellationError() }
                #expect(try await store.change(command: command, capacityProfile: profile, eventID: eventID, now: now) == .idempotent(changed))
            }
            for table in ["room_membership_operations", "room_events", "user_state_event_outbox"] { #expect(try await count("im_v2." + table, on: sql) == 2) }
            #expect(try await count("im_v2.room_memberships WHERE left_revision IS NULL", on: sql) == 3)
            #expect(try await count("im_v2.rooms WHERE membership_revision = 2 AND room_sequence = 2", on: sql) == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("Live preferences and presence queries reject invalid clocks and recover without duplicate writes")
    func liveActivityQueryTimestampBoundaries() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            // A direct room with two active members and no live leases.
            try await sql.raw("DELETE FROM im_v2.group_rooms WHERE room_id = \(bind: roomUUID)").run()
            try await sql.raw("UPDATE im_v2.rooms SET room_kind = 'direct' WHERE room_id = \(bind: roomUUID)").run()
            try await sql.raw("DELETE FROM im_v2.room_memberships WHERE user_id = \(bind: memberThreeUUID)").run()
            try await sql.raw("UPDATE im_v2.room_admission SET eligible_member_count = 2 WHERE room_id = \(bind: roomUUID)").run()
            try await sql.raw("INSERT INTO im_v2.direct_room_pairs (room_id, lower_user_id, higher_user_id, created_at) VALUES (\(bind: roomUUID), LEAST(\(bind: senderUUID), \(bind: memberTwoUUID)), GREATEST(\(bind: senderUUID), \(bind: memberTwoUUID)), \(bind: now))").run()
            let store = try PostgresV2LiveActivityStore(database: resources.database(.psql))
            let viewer = UserID(uuid: memberTwoUUID)
            let command = V2SetLiveActivityPreferencesCommand(actorUserID: senderID, operationID: .init(uuid: UUID()), allowsOnlinePresence: false, allowsTypingIndicators: false)
            for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14] {
                let invalid = Date(timeIntervalSince1970: seconds)
                await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) { try await store.setPreferences(command: command, now: invalid) }
                await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) { try await store.preferences(userID: senderID, now: invalid) }
                await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) { try await store.presence(roomID: roomID, viewerUserID: viewer, now: invalid) }
            }
            for table in ["user_live_activity_preferences", "user_live_activity_preference_operations", "user_live_presence_leases", "user_sync_log", "room_events"] { #expect(try await count("im_v2." + table, on: sql) == 0) }
            let defaults = try await store.preferences(userID: senderID, now: now)
            #expect(defaults.allowsOnlinePresence && defaults.allowsTypingIndicators && defaults.updatedAt == now)
            let offline = try await store.presence(roomID: roomID, viewerUserID: viewer, now: now)
            #expect(!offline.isOnline && offline.targetUserID == senderID && offline.expiresAt == now)
            guard case .updated(let updated) = try await store.setPreferences(command: command, now: now) else { throw CancellationError() }
            #expect(try await store.setPreferences(command: command, now: now.addingTimeInterval(1)) == .idempotent(updated))
            #expect(try await store.preferences(userID: senderID, now: now.addingTimeInterval(1)) == updated)
            #expect(try await store.presence(roomID: roomID, viewerUserID: viewer, now: now) == offline)
            for table in ["user_live_activity_preferences", "user_live_activity_preference_operations"] { #expect(try await count("im_v2." + table, on: sql) == 1) }
            for table in ["user_live_presence_leases", "user_sync_log", "room_events"] { #expect(try await count("im_v2." + table, on: sql) == 0) }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("Group controls reject invalid timestamps before writes and recover with stable replay")
    func groupControlTimestampBoundaries() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1 WHERE room_id = \(bind: roomUUID)").run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3))
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: resources.database(.psql)), capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "group clock")) else { throw CancellationError() }
            let store = PostgresV2GroupCapabilitiesStore(database: resources.database(.psql))
            let route = try V2RoomShardRoute(shardID: "room-a", epoch: 0)
            let eventID = EventID(uuid: UUID())
            let pin = V2PinnedMessageCommand(operationID: .init(uuid: UUID()), roomID: roomID, messageID: message.messageID, isPinned: true)
            let announcement = try V2GroupAnnouncementCommand(operationID: .init(uuid: UUID()), roomID: roomID, body: "clock recovered", expectedRevision: 0)
            let permissions = try V2GroupRolePermissionsCommand(operationID: .init(uuid: UUID()), roomID: roomID, role: .member, permissions: [.sendMessages], expectedRevision: 1)
            let role = try V2GroupMemberRoleCommand(operationID: .init(uuid: UUID()), roomID: roomID, targetUserID: .init(uuid: memberTwoUUID), role: .admin, expectedMembershipRevision: 1)
            let operationTables = ["room_pinned_message_operations", "group_announcement_operations", "group_permission_operations", "group_role_operations"]
            for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14] {
                let invalid = Date(timeIntervalSince1970: seconds)
                await #expect(throws: V2GroupCapabilitiesStoreError.corruptPersistenceState) {
                    try await store.setPinnedMessage(actorUserID: senderID, command: pin, capacityProfile: profile, eventID: eventID, now: invalid)
                }
                await #expect(throws: V2GroupCapabilitiesStoreError.corruptPersistenceState) {
                    try await store.setPinnedMessageOwnerValidated(actorUserID: senderID, command: pin, ownerRoute: route, capacityProfile: profile, eventID: eventID, now: invalid)
                }
                await #expect(throws: V2GroupCapabilitiesStoreError.corruptPersistenceState) {
                    try await store.setAnnouncement(actorUserID: senderID, command: announcement, capacityProfile: profile, eventID: eventID, now: invalid)
                }
                await #expect(throws: V2GroupCapabilitiesStoreError.corruptPersistenceState) {
                    try await store.setAnnouncementOwnerValidated(actorUserID: senderID, command: announcement, ownerRoute: route, capacityProfile: profile, eventID: eventID, now: invalid)
                }
                await #expect(throws: V2GroupCapabilitiesStoreError.corruptPersistenceState) {
                    try await store.setRolePermissions(actorUserID: senderID, command: permissions, capacityProfile: profile, eventID: eventID, now: invalid)
                }
                await #expect(throws: V2GroupCapabilitiesStoreError.corruptPersistenceState) {
                    try await store.setRolePermissionsOwnerValidated(actorUserID: senderID, command: permissions, ownerRoute: route, capacityProfile: profile, eventID: eventID, now: invalid)
                }
                await #expect(throws: V2GroupCapabilitiesStoreError.corruptPersistenceState) {
                    try await store.changeMemberRole(actorUserID: senderID, command: role, capacityProfile: profile, eventID: eventID, now: invalid)
                }
                await #expect(throws: V2GroupCapabilitiesStoreError.corruptPersistenceState) {
                    try await store.changeMemberRoleOwnerValidated(actorUserID: senderID, command: role, ownerRoute: route, capacityProfile: profile, eventID: eventID, now: invalid)
                }
            }
            for table in operationTables { #expect(try await count("im_v2." + table, on: sql) == 0) }
            #expect(try await count("im_v2.room_events", on: sql) == 1)
            guard case .applied(let pinResult) = try await store.setPinnedMessage(actorUserID: senderID, command: pin, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now) else { throw CancellationError() }
            #expect(try await store.setPinnedMessageOwnerValidated(actorUserID: senderID, command: pin, ownerRoute: route, capacityProfile: profile, eventID: eventID, now: now) == .idempotent(pinResult))
            guard case .applied(let announcementResult) = try await store.setAnnouncement(actorUserID: senderID, command: announcement, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now) else { throw CancellationError() }
            #expect(try await store.setAnnouncementOwnerValidated(actorUserID: senderID, command: announcement, ownerRoute: route, capacityProfile: profile, eventID: eventID, now: now) == .idempotent(announcementResult))
            guard case .applied(let permissionsResult) = try await store.setRolePermissions(actorUserID: senderID, command: permissions, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now) else { throw CancellationError() }
            #expect(try await store.setRolePermissionsOwnerValidated(actorUserID: senderID, command: permissions, ownerRoute: route, capacityProfile: profile, eventID: eventID, now: now) == .idempotent(permissionsResult))
            guard case .applied(let roleResult) = try await store.changeMemberRole(actorUserID: senderID, command: role, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now) else { throw CancellationError() }
            #expect(try await store.changeMemberRoleOwnerValidated(actorUserID: senderID, command: role, ownerRoute: route, capacityProfile: profile, eventID: eventID, now: now) == .idempotent(roleResult))
            for table in operationTables { #expect(try await count("im_v2." + table, on: sql) == 1) }
            #expect(try await count("im_v2.room_events", on: sql) == 5)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("Receipt timestamp failures stay per-item and preserve batch order and valid writes", arguments: ["groups", "owner", "batch"])
    func receiptTimestampBoundaries(kind: String) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("UPDATE im_v2.rooms SET room_sequence = 2 WHERE room_id = \(bind: roomUUID)").run()
            let store = PostgresV2ReadReceiptStore(database: resources.database(.psql))
            let route = try V2RoomShardRoute(shardID: "room-a", epoch: 0)
            let stale = try V2RoomShardRoute(shardID: "room-a", epoch: 1)
            let command = try V2RecordReadReceiptCommand(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), readThroughRoomSequence: 1)
            let preferences = V2SetReadReceiptPreferencesCommand(actorUserID: senderID, operationID: .init(uuid: UUID()), allowsDirectReadReceipts: false, allowsGroupReadReceipts: true)
            for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14] {
                let invalid = Date(timeIntervalSince1970: seconds)
                await #expect(throws: V2ReadReceiptStoreError.corruptPersistenceState) { try await store.record(command: command, now: invalid) }
                await #expect(throws: V2ReadReceiptStoreError.corruptPersistenceState) { try await store.recordGroup(command: command, now: invalid) }
                await #expect(throws: V2ReadReceiptStoreError.corruptPersistenceState) { try await store.recordGroupOwnerValidated(command: command, ownerRoute: route, now: invalid) }
                await #expect(throws: V2ReadReceiptStoreError.corruptPersistenceState) { try await store.setPreferences(command: preferences, now: invalid) }
            }
            for table in ["read_receipt_operations", "room_read_receipts", "read_receipt_preference_operations", "user_read_receipt_preferences", "user_sync_log", "read_receipt_preference_propagation_outbox"] {
                #expect(try await count("im_v2." + table, on: sql) == 0)
            }
            let commands = try [senderUUID, memberTwoUUID, memberThreeUUID, senderUUID].map { user in
                try V2RecordReadReceiptCommand(roomID: roomID, actorUserID: .init(uuid: user), operationID: .init(uuid: UUID()), readThroughRoomSequence: 1)
            }
            let requests = zip(commands, [Date(timeIntervalSince1970: .nan), now, Date(timeIntervalSince1970: 1e14), now]).map { V2ReadReceiptRecordRequest(command: $0.0, now: $0.1) }
            let results: [V2GroupReadReceiptBatchResult]
            switch kind {
            case "owner":
                results = try await store.recordGroupsOwnerValidated(zip(requests, [stale, route, stale, stale]).map { .init(request: $0.0, ownerRoute: $0.1) })
            case "batch":
                results = try await store.recordBatch(requests).map { result in
                    switch result { case .success(let outcome): .success(.handled(outcome)); case .failure(let error): .failure(error) }
                }
            default:
                results = try await store.recordGroups(requests)
            }
            #expect(results.count == 4)
            #expect(results[0] == .failure(.corruptPersistenceState))
            #expect(results[2] == .failure(.corruptPersistenceState))
            guard case .success(.handled(.recorded(let valid))) = results[1] else { throw CancellationError() }
            #expect(valid.userID == commands[1].actorUserID)
            if kind == "owner" {
                #expect(results[3] == .failure(.ownerChanged))
            } else {
                guard case .success(.handled(.recorded(let last))) = results[3] else { throw CancellationError() }
                #expect(last.userID == commands[3].actorUserID)
            }
            #expect(try await count("im_v2.read_receipt_operations", on: sql) == (kind == "owner" ? 1 : 2))
            // Clock recovery reuses failed operation IDs; successful members
            // of the earlier batch retain their original replay results.
            let recovered = try await store.recordGroupsOwnerValidated(commands.map { .init(request: .init(command: $0, now: now), ownerRoute: route) })
            guard case .success(.handled(.recorded)) = recovered[0],
                  case .success(.handled(.idempotent(let replay))) = recovered[1],
                  case .success(.handled(.recorded)) = recovered[2] else { throw CancellationError() }
            #expect(replay == valid)
            #expect(try await count("im_v2.read_receipt_operations", on: sql) == 4)
            let replayed = try await store.recordBatch(commands.map { .init(command: $0, now: now) })
            for result in replayed { guard case .success(.idempotent) = result else { throw CancellationError() } }
            #expect(try await count("im_v2.read_receipt_operations", on: sql) == 4)
            await #expect(throws: V2ReadReceiptStoreError.invalidRequest) {
                try await store.recordGroups([requests[0], .init(command: commands[0], now: now)])
            }
            guard case .updated(let updated) = try await store.setPreferences(command: preferences, now: now) else { throw CancellationError() }
            #expect(try await store.setPreferences(command: preferences, now: now) == .idempotent(updated))
            #expect(try await count("im_v2.read_receipt_preference_operations", on: sql) == 1)
            #expect(try await count("im_v2.read_receipt_preference_propagation_outbox", on: sql) == 1)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("Message mutations and moderation reject invalid clocks without durable side effects")
    func messageMutationTimestampBoundaries() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let limits = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3)
            let profile = try V2CapacityProfile(id: "standard", limits: limits)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: resources.database(.psql)), capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "before")) else { throw CancellationError() }
            let edits = PostgresV2MessageEditStore(database: resources.database(.psql))
            let reactions = PostgresV2MessageReactionStore(database: resources.database(.psql))
            let withdrawals = PostgresV2MessageWithdrawalStore(database: resources.database(.psql))
            let moderation = PostgresV2ModerationStore(database: resources.database(.psql))
            let edit = try V2EditMessageCommand(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), messageID: message.messageID, expectedMessageRevision: 1, text: "after", maximumUTF8Bytes: 64)
            let reaction = try V2ChangeMessageReactionCommand(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), messageID: message.messageID, reaction: "👍", action: .add)
            let withdrawal = try V2WithdrawMessageCommand(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), messageID: message.messageID, expectedMessageRevision: 2)
            let mute = try V2ModerationCommand(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), action: .muteMember, targetUserID: .init(uuid: memberTwoUUID), muteUntil: now.addingTimeInterval(60), reasonCode: .init("abuse_spam"))
            let removal = try V2ModerationCommand(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), action: .removeMember, targetUserID: .init(uuid: memberTwoUUID), reasonCode: .init("abuse_spam"))
            let redaction = try V2ModerationCommand(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), action: .redactMessage, messageID: message.messageID, reasonCode: .init("abuse_spam"))
            let freeze = try V2ModerationCommand(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), action: .freezeRoom, reasonCode: .init("abuse_spam"))
            let unfreeze = try V2ModerationCommand(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), action: .unfreezeRoom, reasonCode: .init("abuse_spam"))
            let route = try V2RoomShardRoute(shardID: "room-a", epoch: 0)
            let eventID = EventID(uuid: UUID())
            let tables = ["message_edit_operations", "message_reaction_operations", "message_withdrawal_operations", "moderation_operations", "moderation_audit_entries", "room_member_mutes", "room_events", "user_sync_log"]
            var before: [Int64] = []
            for table in tables { before.append(try await count("im_v2." + table, on: sql)) }
            for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14] {
                let invalid = Date(timeIntervalSince1970: seconds)
                await #expect(throws: V2MessageEditStoreError.corruptPersistenceState) {
                    try await edits.edit(command: edit, capacityProfile: profile, eventID: eventID, now: invalid)
                }
                await #expect(throws: V2MessageEditStoreError.corruptPersistenceState) {
                    try await edits.editOwnerValidated(command: edit, ownerRoute: route, capacityProfile: profile, eventID: eventID, now: invalid)
                }
                await #expect(throws: V2MessageReactionStoreError.corruptPersistenceState) {
                    try await reactions.change(command: reaction, capacityProfile: profile, eventID: eventID, now: invalid)
                }
                await #expect(throws: V2MessageReactionStoreError.corruptPersistenceState) {
                    try await reactions.changeOwnerValidated(command: reaction, ownerRoute: route, capacityProfile: profile, eventID: eventID, now: invalid)
                }
                await #expect(throws: V2MessageWithdrawalStoreError.corruptPersistenceState) {
                    try await withdrawals.withdraw(command: withdrawal, capacityProfile: profile, eventID: eventID, now: invalid)
                }
                await #expect(throws: V2MessageWithdrawalStoreError.corruptPersistenceState) {
                    try await withdrawals.withdrawOwnerValidated(command: withdrawal, ownerRoute: route, capacityProfile: profile, eventID: eventID, now: invalid)
                }
            }
            // The current timestamp fits PostgreSQL, but its 180-day audit
            // deadline does not. Checking only `now` misses this boundary.
            let nearUpper = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 179 * 86_400)
            #expect(v2PostgresTimestampCanEncode(nearUpper))
            #expect(!v2PostgresTimestampCanEncode(nearUpper.addingTimeInterval(180 * 86_400)))
            for invalid in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14].map({ Date(timeIntervalSince1970: $0) }) + [nearUpper] {
                for command in [mute, removal, redaction] {
                    await #expect(throws: V2ModerationStoreError.corruptPersistenceState) {
                        try await moderation.apply(command: command, capacityProfile: profile, eventID: eventID, now: invalid)
                    }
                    await #expect(throws: V2ModerationStoreError.corruptPersistenceState) {
                        try await moderation.applyOwnerValidated(command: command, ownerRoute: route, capacityProfile: profile, eventID: eventID, now: invalid)
                    }
                }
                for command in [redaction, freeze, unfreeze] {
                    await #expect(throws: V2ModerationStoreError.corruptPersistenceState) {
                        try await moderation.applyTrustedSafety(command: command, capacityProfile: profile, eventID: eventID, now: invalid)
                    }
                    await #expect(throws: V2ModerationStoreError.corruptPersistenceState) {
                        try await moderation.applyTrustedSafetyOwnerValidated(command: command, ownerRoute: route, capacityProfile: profile, eventID: eventID, now: invalid)
                    }
                }
            }
            for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14] {
                let invalidMute = try V2ModerationCommand(roomID: roomID, actorUserID: senderID, operationID: mute.operationID, action: .muteMember, targetUserID: mute.targetUserID, muteUntil: Date(timeIntervalSince1970: seconds), reasonCode: mute.reasonCode)
                await #expect(throws: V2ModerationValidationError.invalidMuteExpiry) {
                    try await moderation.apply(command: invalidMute, capacityProfile: profile, eventID: eventID, now: now)
                }
                await #expect(throws: V2ModerationValidationError.invalidMuteExpiry) {
                    try await moderation.applyOwnerValidated(command: invalidMute, ownerRoute: route, capacityProfile: profile, eventID: eventID, now: now)
                }
            }
            for (index, table) in tables.enumerated() { #expect(try await count("im_v2." + table, on: sql) == before[index]) }
            // Reuse rejected operation IDs after clock recovery; each write
            // must commit once and retain its normal replay semantics.
            guard case .edited(let edited) = try await edits.edit(command: edit, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now),
                  case .changed(let reacted) = try await reactions.change(command: reaction, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now),
                  case .withdrawn(let withdrawn) = try await withdrawals.withdraw(command: withdrawal, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now),
                  case .applied(let muted) = try await moderation.apply(command: mute, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now) else {
                Issue.record("Normal writes did not recover after invalid timestamps"); throw CancellationError()
            }
            #expect(try await edits.edit(command: edit, capacityProfile: profile, eventID: eventID, now: now) == .idempotent(edited))
            #expect(try await reactions.change(command: reaction, capacityProfile: profile, eventID: eventID, now: now) == .idempotent(reacted))
            #expect(try await withdrawals.withdraw(command: withdrawal, capacityProfile: profile, eventID: eventID, now: now) == .idempotent(withdrawn))
            // Expired mutes still replay their original result.
            #expect(try await moderation.apply(command: mute, capacityProfile: profile, eventID: eventID, now: now.addingTimeInterval(61)) == .idempotent(muted))
            for table in tables.prefix(6) { #expect(try await count("im_v2." + table, on: sql) == 1) }
            #expect(try await count("im_v2.room_events", on: sql) == before[6] + 4)
            #expect(try await count("im_v2.moderation_audit_entries WHERE retain_until = occurred_at + INTERVAL '180 days'", on: sql) == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("Personal preference and social writes reject unencodable dates before any mutation")
    func personalWriteTimestampBoundaries() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000.125)
            let actor = UserID(uuid: senderUUID), target = UserID(uuid: memberTwoUUID)
            let room = RoomID(uuid: roomUUID), message = MessageID(uuid: UUID())
            try await sql.raw("""
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence, sender_user_id, client_message_id, text_body, created_at)
                VALUES (\(bind: message.uuidValue!), \(bind: roomUUID), 1, 1, \(bind: senderUUID), \(bind: UUID()), 'boundary', \(bind: now))
                """).run()
            let preferences = PostgresV2ConversationCapabilitiesStore(database: resources.database(.psql))
            let social = PostgresV2SocialRelationshipStore(database: resources.database(.psql))
            let state = try V2ConversationStateCommand(operationID: .init(uuid: UUID()), roomID: room,
                isPinned: true, isArchived: true, muteUntil: now.addingTimeInterval(60))
            let favorite = V2MessageFavoriteCommand(operationID: .init(uuid: UUID()), roomID: room, messageID: message, isFavorited: true)
            let relationship = try V2ChangeRelationshipCommand(actorUserID: actor, operationID: .init(uuid: UUID()), targetUserID: target, action: .request)
            let block = try V2ChangeUserBlockCommand(actorUserID: actor, operationID: .init(uuid: UUID()), targetUserID: target, action: .block)
            for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14] {
                let invalid = Date(timeIntervalSince1970: seconds)
                await #expect(throws: V2ConversationCapabilitiesStoreError.corruptPersistenceState) {
                    try await preferences.setConversationState(actorUserID: actor, command: state, now: invalid)
                }
                await #expect(throws: V2ConversationCapabilitiesStoreError.corruptPersistenceState) {
                    try await preferences.setMessageFavorite(actorUserID: actor, command: favorite, now: invalid)
                }
                await #expect(throws: V2SocialRelationshipStoreError.corruptPersistenceState) {
                    try await social.changeRelationship(relationship, now: invalid)
                }
                await #expect(throws: V2SocialRelationshipStoreError.corruptPersistenceState) {
                    try await social.changeUserBlock(block, now: invalid)
                }
            }
            // This is valid Int64 wire milliseconds but cannot be bound as
            // PostgreSQL's Int64 microseconds from its different epoch.
            let oversizedMute = try V2ConversationStateCommand(operationID: .init(uuid: UUID()), roomID: room,
                isPinned: false, isArchived: false, muteUntil: Date(timeIntervalSince1970: 1e14))
            await #expect(throws: V2ConversationCapabilitiesStoreError.invalidTimestamp) {
                try await preferences.setConversationState(actorUserID: actor, command: oversizedMute, now: now)
            }
            let operationTables = ["user_room_preference_operations", "user_message_favorite_operations", "user_relationship_operations", "user_block_operations"]
            for table in operationTables { #expect(try await count("im_v2." + table, on: sql) == 0) }
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
            guard case .applied = try await preferences.setConversationState(actorUserID: actor, command: state, now: now),
                  case .applied = try await preferences.setMessageFavorite(actorUserID: actor, command: favorite, now: now),
                  case .changed = try await social.changeRelationship(relationship, now: now),
                  case .changed = try await social.changeUserBlock(block, now: now) else {
                Issue.record("Valid writes did not recover after rejected timestamps"); throw CancellationError()
            }
            let projectionCount = try await count("im_v2.user_sync_log", on: sql)
            guard case .idempotent = try await preferences.setConversationState(actorUserID: actor, command: state, now: now),
                  case .idempotent = try await preferences.setMessageFavorite(actorUserID: actor, command: favorite, now: now),
                  case .idempotent = try await social.changeRelationship(relationship, now: now),
                  case .idempotent = try await social.changeUserBlock(block, now: now) else {
                Issue.record("Valid operation replay failed"); throw CancellationError()
            }
            for table in operationTables { #expect(try await count("im_v2." + table, on: sql) == 1) }
            #expect(projectionCount == 7)
            #expect(try await count("im_v2.user_sync_log", on: sql) == projectionCount)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }





    @Test("registration cancellation HTTP commits the proof fence and rejects unsafe requests before storage")
    func registrationCancellationHTTP() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        let app = try await Application(.testing)
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            let issuer = try V2PostgresDeviceCredentialService(database: resources.database(.psql), tokenHMACKey: .init(rawBytes: Data(repeating: 0x6b, count: 32)), replayEnvelopeKey: .init(rawBytes: Data(repeating: 0x6c, count: 32)), now: { start })
            let assertionIssuer = try V2HMACAccountAssertionIssuer(rawKey: Data(repeating: 0x6d, count: 32), now: { start })
            let edge = Data(repeating: 0x69, count: 32).base64EncodedString()
            app.middleware.use(V2AccountEdgeAuthenticationMiddleware(secret: try .init(base64Encoded: edge)))
            app.middleware.use(V2AccountEdgeClientRateLimitMiddleware(limiter: V2PostgresAccountEdgeClientRateLimiter(
                database: resources.database(.psql), policy: try .init(maximumRequests: 50, window: 60),
                key: try .init(base64Encoded: Data(repeating: 0x6a, count: 32).base64EncodedString()), now: { start }),
                limitedPaths: [V2VaporDeviceRegistrationCancellationRoutes.path, "/v2/device-credentials"]))
            V2VaporDeviceRegistrationCancellationRoutes(service: V2PostgresDeviceRegistrationCancellationService(database: resources.database(.psql), now: { start })).register(on: app)
            V2VaporDeviceCredentialRoutes(assertionVerifier: assertionIssuer, issuer: issuer).register(on: app)
            let cancellation = try V2DeviceRegistrationCancellation(deviceID: DeviceID(UUID().uuidString), operationID: UUID(), proof: .generate(), issueBeforeMilliseconds: Int64(start.timeIntervalSince1970 * 1_000) + 60_000)
            let body = try JSONEncoder().encode(V2DeviceRegistrationCancellationHTTPRequest(cancellation))
            func send(_ body: Data, expected: HTTPResponse.Status, trusted: Bool = true, path: String = V2VaporDeviceRegistrationCancellationRoutes.path) async throws {
                try await app.testing { client in
                    let response = try await client.send(.post, to: URI(string: path), beforeSend: { request in
                    if trusted {
                        request.headers[V2AccountEdgeAuthenticationMiddleware.headerName] = edge
                        request.headers[V2AccountEdgeAuthenticationMiddleware.clientAddressHeaderName] = "192.0.2.17"
                    }
                    request.headers.contentType = .json
                    request.body = .init(data: body)
                    })
                    #expect(response.status == expected)
                    if expected == .noContent || expected == .gone {
                        #expect((try await response.body.data() ?? Data()).isEmpty)
                        #expect(response.headers[.cacheControl] == "no-store")
                    }
                }
            }
            try await send(body, expected: .forbidden, trusted: false)
            var forged = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            forged["userID"] = NSNull()
            try await send(JSONSerialization.data(withJSONObject: forged), expected: .badRequest)
            let tooFar = try V2DeviceRegistrationCancellation(deviceID: cancellation.deviceID, operationID: cancellation.operationID, proof: cancellation.proof, issueBeforeMilliseconds: cancellation.issueBeforeMilliseconds + 86_400_000)
            try await send(JSONEncoder().encode(tooFar), expected: .badRequest)
            #expect(try await count("im_v2.device_registration_cancellations", on: sql) == 0)
            try await send(body, expected: .noContent)
            try await send(body, expected: .noContent)
            #expect(try await count("im_v2.device_registration_cancellations WHERE cancelled_at IS NOT NULL", on: sql) == 1)
            let user = try UserID(UUID().uuidString)
            // Signed assertions carry revision 1; issuance verifies the durable account revision.
            let accountUser = try #require(user.uuidValue)
            try await sql.raw("""
                INSERT INTO im_v2.account_password_credentials(account_handle,user_id,password_hash,credential_revision,created_at)
                VALUES ('cancellation-http', \(bind: accountUser), repeat('x',60), 1, \(bind: start))
                """).run()
            func issueBody(_ proof: V2DeviceRegistrationCancellation) throws -> Data {
                try JSONEncoder().encode(V2DeviceCredentialIssueHTTPRequest(accountAssertion: assertionIssuer.issue(userID: user, deviceID: proof.deviceID),
                    deviceID: proof.deviceID.rawValue, operationID: proof.operationID, cancellation: proof))
            }
            try await send(issueBody(cancellation), expected: .forbidden, path: "/v2/device-credentials")
            let issuedProof = try V2DeviceRegistrationCancellation(deviceID: DeviceID(UUID().uuidString), operationID: UUID(), proof: .generate(), issueBeforeMilliseconds: cancellation.issueBeforeMilliseconds)
            // The HTTP status is checked, but the entire credential response
            // body is ignored. Cancellation uses only the pre-request proof.
            try await send(issueBody(issuedProof), expected: .ok, path: "/v2/device-credentials")
            try await sql.raw("CREATE FUNCTION im_v2.test_cancel_http_rollback() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic HTTP rollback'; END $$").run()
            try await sql.raw("CREATE TRIGGER test_cancel_http_rollback AFTER INSERT ON im_v2.device_revocation_events FOR EACH ROW EXECUTE FUNCTION im_v2.test_cancel_http_rollback()").run()
            let issuedBody = try JSONEncoder().encode(issuedProof)
            try await send(issuedBody, expected: .serviceUnavailable)
            #expect(try await count("im_v2.device_registration_cancellations WHERE user_id IS NOT NULL AND cancelled_at IS NOT NULL", on: sql) == 0)
            #expect(try await count("im_v2.device_access_tokens WHERE revoked_at IS NULL", on: sql) == 1)
            try await sql.raw("DROP TRIGGER test_cancel_http_rollback ON im_v2.device_revocation_events").run()
            try await send(issuedBody, expected: .noContent)
            try await send(issuedBody, expected: .noContent)
            #expect(try await count("im_v2.device_access_tokens WHERE revoked_at IS NULL", on: sql) == 0)
            #expect(try await count("im_v2.device_refresh_sessions WHERE revoked_at IS NULL", on: sql) == 0)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 1)
            let expired = try V2DeviceRegistrationCancellation(deviceID: DeviceID(UUID().uuidString), operationID: UUID(), proof: .generate(), issueBeforeMilliseconds: Int64(start.timeIntervalSince1970 * 1_000))
            try await send(JSONEncoder().encode(expired), expected: .gone)
            #expect(try await count("im_v2.device_registration_cancellations", on: sql) == 2)
            try await sql.raw("UPDATE im_v2.account_edge_client_rate_limits SET request_count=50").run()
            try await send(body, expected: .tooManyRequests)
            #expect(try await count("im_v2.device_registration_cancellations", on: sql) == 2)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.shutdown(); try await resources.shutdown()
        } catch { try? await app.shutdown(); try? await resources.shutdown(); throw error }
    }

    @Test("registration issue and cancellation read their deadline after waiting for the device row", arguments: [false, true])
    func registrationCancellationDeadlineAfterLock(cancelling: Bool) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            // One connection holds the device row, one runs the request, and
            // a third observes the server-side lock waiter.
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 3), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            let clock = Mutex(start)
            let userID = UUID(), deviceID = UUID()
            let request = try V2DeviceRegistrationCancellation(deviceID: DeviceID(deviceID.uuidString), operationID: UUID(),
                proof: .generate(), issueBeforeMilliseconds: Int64(start.timeIntervalSince1970 * 1_000) + 1_000)
            let trusted = try V2CancellableDeviceRegistration(registration: .init(userID: UserID(userID.uuidString),
                deviceID: request.deviceID, operationID: request.operationID), cancellation: request)
            let issuer = try V2PostgresDeviceCredentialService(database: resources.database(.psql), tokenHMACKey: .init(rawBytes: Data(repeating: 0x67, count: 32)),
                replayEnvelopeKey: .init(rawBytes: Data(repeating: 0x68, count: 32)), maximumSessionLifetime: 120,
                now: { clock.withLock { $0 } })
            if cancelling {
                guard case .issued = try await issuer.register(trusted) else { Issue.record("expected issued session"); return }
            } else {
                try await sql.raw("INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at,session_expires_at) VALUES (\(bind: userID),\(bind: deviceID),\(bind: start),\(bind: start),\(bind: start.addingTimeInterval(120)))").run()
            }
            let canceller = V2PostgresDeviceRegistrationCancellationService(database: resources.database(.psql), now: { clock.withLock { $0 } })
            let gate = PostgreSQLTransactionGate()
            let blocker = Task {
                try await resources.database(.psql).transaction { transaction in
                    let locked = try #require(transaction as? any SQLDatabase)
                    try await locked.raw("SELECT device_id FROM im_v2.auth_devices WHERE device_id=\(bind: deviceID) FOR UPDATE").run()
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()
            let waiting = Task {
                if cancelling { return try await canceller.cancel(request) == .expired }
                return try await issuer.register(trusted) == .deviceUnavailable
            }
            do {
                var blocked = false
                for _ in 0..<500 {
                    blocked = try await sql.raw("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%auth_devices%' AND query LIKE '%FOR UPDATE%') AS exists").first(decoding: ExistsRow.self)?.exists == true
                    if blocked { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(blocked, "production request must actually wait on the held device row")
                clock.withLock { $0 = start.addingTimeInterval(cancelling ? 720 : 2) }
                await gate.releaseTransaction()
                try await blocker.value
                #expect(try await waiting.value)
            } catch {
                await gate.releaseTransaction()
                _ = try? await blocker.value
                _ = try? await waiting.value
                throw error
            }
            #expect(try await count("im_v2.device_registration_cancellations WHERE cancelled_at IS NOT NULL", on: sql) == 0)
            #expect(try await count("im_v2.device_credential_operations", on: sql) == (cancelling ? 1 : 0))
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 0)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await resources.shutdown()
            throw error
        }
    }

}
