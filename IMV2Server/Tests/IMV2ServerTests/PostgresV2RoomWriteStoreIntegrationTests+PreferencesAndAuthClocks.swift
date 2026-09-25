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
    @Test("Live preferences validate saved time and use the current clock only for new facts")
    func livePreferenceReplayTimestampBounds() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let store = try PostgresV2LiveActivityStore(database: database)
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let minimum = Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000)
            let maximum = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)
            let invalidDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map(Date.init(timeIntervalSince1970:))
            let operation = UUID()
            let command = V2SetLiveActivityPreferencesCommand(actorUserID: senderID, operationID: .init(uuid: operation),
                allowsOnlinePresence: false, allowsTypingIndicators: false)
            func snapshot() async throws -> [String] {
                var result: [String] = []
                for table in ["user_live_activity_preferences", "user_live_activity_preference_operations", "user_live_presence_leases", "user_sync_sequences", "user_sync_log"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)
                    result.append(try #require(row).value)
                }
                return result
            }
            let empty = try await snapshot()
            for invalid in invalidDates {
                await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) { try await store.preferences(userID: senderID, now: invalid) }
                await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) { try await store.setPreferences(command: command, now: invalid) }
                #expect(try await snapshot() == empty)
            }
            for date in [minimum, maximum, base] {
                #expect(try await store.preferences(userID: senderID, now: date) == .init(allowsOnlinePresence: true, allowsTypingIndicators: true, updatedAt: date))
            }
            #expect(try await snapshot() == empty)
            let saved = V2LiveActivityPreferences(allowsOnlinePresence: false, allowsTypingIndicators: false, updatedAt: base)
            #expect(try await store.setPreferences(command: command, now: base) == .updated(saved))
            let initial = try await snapshot()
            for invalid in invalidDates {
                #expect(try await store.preferences(userID: senderID, now: invalid) == saved)
                #expect(try await store.setPreferences(command: command, now: invalid) == .idempotent(saved))
                let conflict = V2SetLiveActivityPreferencesCommand(actorUserID: senderID, operationID: .init(uuid: operation),
                    allowsOnlinePresence: true, allowsTypingIndicators: false)
                #expect(try await store.setPreferences(command: conflict, now: invalid) == .idempotencyConflict)
                let fresh = V2SetLiveActivityPreferencesCommand(actorUserID: senderID, operationID: .init(uuid: UUID()),
                    allowsOnlinePresence: true, allowsTypingIndicators: true)
                await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) { try await store.setPreferences(command: fresh, now: invalid) }
                #expect(try await snapshot() == initial)
            }
            for table in ["user_live_activity_preferences", "user_live_activity_preference_operations"] {
                for literal in ["infinity", "-infinity", "294276-12-31 23:59:59.999999+00"] {
                    try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET updated_at = \(bind: literal)::timestamptz").run()
                    let before = try await snapshot()
                    if table == "user_live_activity_preferences" {
                        await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) { try await store.preferences(userID: senderID, now: base) }
                        #expect(try await store.setPreferences(command: command, now: base) == .idempotent(saved))
                    } else {
                        await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) { try await store.setPreferences(command: command, now: base) }
                        #expect(try await store.preferences(userID: senderID, now: base) == saved)
                        let conflict = V2SetLiveActivityPreferencesCommand(actorUserID: senderID, operationID: .init(uuid: operation),
                            allowsOnlinePresence: false, allowsTypingIndicators: true)
                        #expect(try await store.setPreferences(command: conflict, now: base) == .idempotencyConflict)
                    }
                    #expect(try await snapshot() == before)
                }
                try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET updated_at = \(bind: base)").run()
            }
            for date in [minimum, maximum, base] {
                for table in ["user_live_activity_preferences", "user_live_activity_preference_operations"] {
                    try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET updated_at = \(bind: date)").run()
                }
                let before = try await snapshot()
                let expected = V2LiveActivityPreferences(allowsOnlinePresence: false, allowsTypingIndicators: false, updatedAt: date)
                #expect(try await store.preferences(userID: senderID, now: base) == expected)
                #expect(try await store.setPreferences(command: command, now: base) == .idempotent(expected))
                #expect(try await snapshot() == before)
            }
            #expect(try await snapshot() == initial)
        }
    }

    @Test("Presence responses validate the selected lease while preserving offline and hidden states")
    func livePresenceResponseTimestampBounds() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let direct = PostgresV2DirectMessagingStore(database: database)
            let live = try PostgresV2LiveActivityStore(database: database)
            let peer = UserID(uuid: memberTwoUUID)
            guard case .opened(let room) = try await direct.open(command: .init(actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: peer),
                capacityProfile: forwardImportTestProfile(), roomShardID: "room-a", roomID: .init(uuid: UUID()), now: base) else { throw CancellationError() }
            let device = UUID(), primary = UUID(), secondary = UUID()
            try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: memberTwoUUID), \(bind: device), \(bind: base), \(bind: base))").run()
            for (connection, expiry) in [(primary, base.addingTimeInterval(30)), (secondary, base.addingTimeInterval(90))] {
                try await sql.raw("INSERT INTO im_v2.user_live_presence_leases (connection_id, user_id, device_id, expires_at, updated_at) VALUES (\(bind: connection), \(bind: memberTwoUUID), \(bind: device), \(bind: expiry), \(bind: base))").run()
            }
            _ = try await live.setPreferences(command: .init(actorUserID: peer, operationID: .init(uuid: UUID()), allowsOnlinePresence: true, allowsTypingIndicators: true), now: base)
            func snapshot() async throws -> [String] {
                var result: [String] = []
                for table in ["auth_devices", "user_live_presence_leases", "user_live_activity_preferences", "user_live_activity_preference_operations", "user_sync_log"] {
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

    @Test("Preference conflicts bypass failed shadow forwarding while committed retries recover", arguments: ["conversation", "favorite"])
    func preferenceConflictShadowFailure(kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 946_684_800 + 0.00000125)
            let shadow = PreferenceReplayClockDelivery()
            let store = PostgresV2ConversationCapabilitiesStore(database: database, projectionDelivery: shadow)
            let sender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database),
                capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "preference forwarding")) else { throw CancellationError() }
            let operation = UUID()
            func perform(conflict: Bool, date: Date) async throws -> V2ConversationCapabilitiesOutcome<Date> {
                if kind == "conversation" {
                    switch try await store.setConversationState(actorUserID: senderID,
                        command: .init(operationID: .init(uuid: operation), roomID: roomID,
                            isPinned: !conflict, isArchived: true, muteUntil: nil), now: date) {
                    case .applied(let value): return .applied(value.updatedAt)
                    case .idempotent(let value): return .idempotent(value.updatedAt)
                    case .idempotencyConflict: return .idempotencyConflict
                    }
                }
                switch try await store.setMessageFavorite(actorUserID: senderID,
                    command: .init(operationID: .init(uuid: operation), roomID: roomID,
                        messageID: message.messageID, isFavorited: !conflict), now: date) {
                case .applied(let value): return .applied(value.updatedAt)
                case .idempotent(let value): return .idempotent(value.updatedAt)
                case .idempotencyConflict: return .idempotencyConflict
                }
            }
            func snapshot() async throws -> [String] {
                var values: [String] = []
                for table in ["user_room_preferences", "user_room_preference_operations", "user_message_favorites", "user_message_favorite_operations", "user_sync_sequences", "user_sync_log"] {
                    guard let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self) else { throw CancellationError() }
                    values.append(row.value)
                }
                return values
            }
            shadow.setFailure(true)
            await #expect(throws: PreferenceReplayClockDeliveryError.unavailable) { try await perform(conflict: false, date: now) }
            let expectedCall = PreferenceReplayClockDelivery.Call(userID: senderID, sourceEventID: .init(uuid: operation),
                kinds: [kind == "conversation" ? "conversation_state" : "message_favorite"])
            #expect(shadow.calls == [expectedCall])
            let table = kind == "conversation" ? "user_room_preference_operations" : "user_message_favorite_operations"
            let persisted = try #require(try await sql.raw("SELECT updated_at AS value FROM im_v2.\(unsafeRaw: table) WHERE actor_user_id = \(bind: senderUUID) AND operation_id = \(bind: operation)").first(decoding: RevocationClockDateRow.self)).value
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.user_sync_log WHERE user_id = \(bind: senderUUID) AND source_event_id = \(bind: operation) AND created_at = \(bind: now)").first(decoding: CountRow.self)?.value == 1)
            let committed = try await snapshot()
            for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity), now] {
                #expect((try? await perform(conflict: true, date: date)) == .idempotencyConflict)
                #expect(shadow.calls == [expectedCall])
                #expect(try await snapshot() == committed)
            }
            // Matching retries must still attempt the outstanding forwarding,
            // surface a dependency failure, and recover when it is available.
            await #expect(throws: PreferenceReplayClockDeliveryError.unavailable) {
                try await perform(conflict: false, date: Date(timeIntervalSince1970: .nan))
            }
            #expect(shadow.calls == [expectedCall, expectedCall])
            #expect(try await snapshot() == committed)
            shadow.setFailure(false)
            #expect(try await perform(conflict: false, date: Date(timeIntervalSince1970: .infinity)) == .idempotent(persisted))
            #expect(shadow.calls == [expectedCall, expectedCall, expectedCall])
            #expect(try await snapshot() == committed)
        }
    }

    @Test("Preference replays use committed time and preserve projection forwarding",
          arguments: ["conversation", "favorite", "receipts"])
    func preferenceReplayTimestampBounds(kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let shadow = PreferenceReplayClockDelivery()
            let conversations = PostgresV2ConversationCapabilitiesStore(database: database, projectionDelivery: shadow)
            let receipts = PostgresV2ReadReceiptStore(database: database, projectionDelivery: shadow)
            var messageID = MessageID(uuid: UUID())
            if kind == "favorite" {
                let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: try forwardImportTestProfile(),
                    limits: try .init(maxUTF8Bytes: 64), now: { base })
                guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "Favorite clock fixture")) else { throw CancellationError() }
                messageID = message.messageID
            }
            let operation = UUID()
            let projectionKind = kind == "conversation" ? "conversation_state" : kind == "favorite" ? "message_favorite" : "read_receipt_preferences"
            func invoke(_ id: UUID, at now: Date, replay: Bool = false, conflict: Bool = false) async throws -> Date? {
                switch kind {
                case "conversation":
                    let outcome = try await conversations.setConversationState(actorUserID: senderID,
                        command: .init(operationID: .init(uuid: id), roomID: roomID, isPinned: !conflict,
                            isArchived: true, muteUntil: base.addingTimeInterval(60)), now: now)
                    if conflict { #expect(outcome == .idempotencyConflict); return nil }
                    let value: V2ConversationState
                    switch outcome {
                    case .applied(let state): #expect(!replay); value = state
                    case .idempotent(let state): #expect(replay); value = state
                    default: throw CancellationError()
                    }
                    #expect(value.roomID == roomID && value.isPinned && value.isArchived && value.muteUntil == base.addingTimeInterval(60))
                    return value.updatedAt
                case "favorite":
                    let outcome = try await conversations.setMessageFavorite(actorUserID: senderID,
                        command: .init(operationID: .init(uuid: id), roomID: roomID, messageID: messageID, isFavorited: !conflict), now: now)
                    if conflict { #expect(outcome == .idempotencyConflict); return nil }
                    let value: V2MessageFavorite
                    switch outcome {
                    case .applied(let favorite): #expect(!replay); value = favorite
                    case .idempotent(let favorite): #expect(replay); value = favorite
                    default: throw CancellationError()
                    }
                    #expect(value.roomID == roomID && value.messageID == messageID && value.isFavorited)
                    return value.updatedAt
                default:
                    let outcome = try await receipts.setPreferences(command: .init(actorUserID: senderID,
                        operationID: .init(uuid: id), allowsDirectReadReceipts: conflict, allowsGroupReadReceipts: true), now: now)
                    if conflict { #expect(outcome == .idempotencyConflict); return nil }
                    let value: V2ReadReceiptPreferences
                    switch outcome {
                    case .updated(let preferences): #expect(!replay); value = preferences
                    case .idempotent(let preferences): #expect(replay); value = preferences
                    default: throw CancellationError()
                    }
                    #expect(!value.allowsDirectReadReceipts && value.allowsGroupReadReceipts)
                    return value.updatedAt
                }
            }
            func expectFailure(_ id: UUID, at now: Date) async {
                let calls = shadow.calls
                do {
                    _ = try await invoke(id, at: now, replay: id == operation)
                    Issue.record("Expected a typed persistence timestamp error")
                } catch {
                    if kind == "receipts" { #expect(error as? V2ReadReceiptStoreError == .corruptPersistenceState) }
                    else { #expect(error as? V2ConversationCapabilitiesStoreError == .corruptPersistenceState) }
                }
                #expect(shadow.calls == calls)
            }
            func snapshot() async throws -> [String] {
                var result: [String] = []
                for table in ["rooms", "room_memberships", "messages", "room_events",
                    "user_room_preferences", "user_room_preference_operations", "user_message_favorites", "user_message_favorite_operations",
                    "user_read_receipt_preferences", "read_receipt_preference_operations", "read_receipt_preference_propagation_outbox",
                    "user_sync_sequences", "user_sync_log"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)
                    result.append(try #require(row).value)
                }
                return result
            }
            #expect(try await invoke(operation, at: base) == base)
            #expect(shadow.calls == [.init(userID: senderID, sourceEventID: .init(uuid: operation), kinds: [projectionKind])])
            let initial = try await snapshot()
            for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12] {
                let invalid = Date(timeIntervalSince1970: seconds)
                let calls = shadow.calls
                #expect(try await invoke(operation, at: invalid, replay: true) == base)
                #expect(shadow.calls == calls + [.init(userID: senderID, sourceEventID: .init(uuid: operation), kinds: [projectionKind])])
                _ = try await invoke(operation, at: invalid, conflict: true)
                await expectFailure(UUID(), at: invalid)
                #expect(try await snapshot() == initial)
            }
            let table = kind == "conversation" ? "user_room_preference_operations" : kind == "favorite" ? "user_message_favorite_operations" : "read_receipt_preference_operations"
            for column in kind == "conversation" ? ["updated_at", "mute_until"] : ["updated_at"] {
                for literal in ["infinity", "-infinity", "294276-12-31 23:59:59.999999+00"] {
                    try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET \(unsafeRaw: column) = \(bind: literal)::timestamptz WHERE operation_id = \(bind: operation)").run()
                    let before = try await snapshot()
                    await expectFailure(operation, at: base)
                    _ = try await invoke(operation, at: base, conflict: true)
                    #expect(try await snapshot() == before)
                }
                let restored = column == "mute_until" ? base.addingTimeInterval(60) : base
                try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET \(unsafeRaw: column) = \(bind: restored) WHERE operation_id = \(bind: operation)").run()
            }
            for date in [Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000),
                         Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10), base] {
                try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET updated_at = \(bind: date) WHERE operation_id = \(bind: operation)").run()
                let before = try await snapshot()
                #expect(try await invoke(operation, at: base, replay: true) == date)
                #expect(try await snapshot() == before)
            }
            #expect(try await snapshot() == initial)
            if kind == "receipts" { #expect(try await count("im_v2.read_receipt_preference_propagation_outbox", on: sql) == 1) }
        }
    }

    @Test("Conversation mute retries compare the exact stored PostgreSQL timestamp")
    func conversationMuteReplayPrecision() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let store = PostgresV2ConversationCapabilitiesStore(database: database)
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let epoch = Date(timeIntervalSince1970: 946_684_800)
            let dates: [Date?] = [nil, epoch, epoch.addingTimeInterval(0.00000025), epoch.addingTimeInterval(0.00000075),
                epoch.addingTimeInterval(0.00000125), epoch.addingTimeInterval(0.00000275), base.addingTimeInterval(0.1234567), base.addingTimeInterval(0.001)]
            var precisionDifferences = 0
            for muteUntil in dates {
                let operation = UUID()
                let command = try V2ConversationStateCommand(operationID: .init(uuid: operation), roomID: roomID,
                    isPinned: true, isArchived: false, muteUntil: muteUntil)
                guard case .applied = try await store.setConversationState(actorUserID: senderID, command: command, now: base) else { throw CancellationError() }
                let stored: Date?
                if muteUntil != nil {
                    stored = try #require(try await sql.raw("SELECT mute_until AS value FROM im_v2.user_room_preference_operations WHERE operation_id = \(bind: operation)").first(decoding: RevocationClockDateRow.self)).value
                } else { stored = nil }
                if stored != muteUntil { precisionDifferences += 1 }
                let before = try #require(try await sql.raw("SELECT jsonb_agg(to_jsonb(r) ORDER BY user_sync_sequence)::text AS value FROM im_v2.user_sync_log r WHERE user_id = \(bind: senderUUID)").first(decoding: StringValueRow.self)).value
                let expected = V2ConversationState(roomID: roomID, isPinned: true, isArchived: false, muteUntil: stored, updatedAt: base)
                #expect(try await store.setConversationState(actorUserID: senderID, command: command, now: base.addingTimeInterval(1)) == .idempotent(expected))
                #expect(try await store.setConversationState(actorUserID: senderID, command: command, now: Date(timeIntervalSince1970: .nan)) == .idempotent(expected))
                for other in [muteUntil == nil ? epoch : nil, (muteUntil ?? epoch).addingTimeInterval(0.01)] {
                    let conflict = try V2ConversationStateCommand(operationID: .init(uuid: operation), roomID: roomID,
                        isPinned: true, isArchived: false, muteUntil: other)
                    #expect(try await store.setConversationState(actorUserID: senderID, command: conflict, now: base) == .idempotencyConflict)
                }
                let after = try #require(try await sql.raw("SELECT jsonb_agg(to_jsonb(r) ORDER BY user_sync_sequence)::text AS value FROM im_v2.user_sync_log r WHERE user_id = \(bind: senderUUID)").first(decoding: StringValueRow.self)).value
                #expect(after == before)
            }
            #expect(precisionDifferences > 0)
            #expect(try await count("im_v2.user_room_preference_operations", on: sql) == Int64(dates.count))
            #expect(try await count("im_v2.user_sync_log", on: sql) == Int64(dates.count))
        }
    }

    @Test("Direct and social replays validate committed timestamps independently of the current clock",
          arguments: ["direct", "stranger", "userAdd", "relationship", "block"])
    func directSocialReplayTimestampBounds(kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let direct = PostgresV2DirectMessagingStore(database: database)
            let social = PostgresV2SocialRelationshipStore(database: database)
            let profile = try forwardImportTestProfile()
            let createdRoom = RoomID(uuid: UUID()), operation = UUID()
            func invoke(_ id: UUID, at now: Date, replay: Bool = false, conflict: Bool = false) async throws -> Date? {
                let target = UserID(uuid: conflict ? memberThreeUUID : memberTwoUUID)
                switch kind {
                case "direct":
                    let outcome = try await direct.open(command: .init(actorUserID: senderID, operationID: .init(uuid: id), targetUserID: target),
                        capacityProfile: profile, roomShardID: "room-a", roomID: replay ? .init(uuid: UUID()) : createdRoom, now: now)
                    if conflict { #expect(outcome == .idempotencyConflict); return nil }
                    let value: V2DirectRoom
                    switch outcome {
                    case .opened(let room): #expect(!replay); value = room
                    case .idempotent(let room): #expect(replay); value = room
                    default: Issue.record("Expected a direct room result"); throw CancellationError()
                    }
                    #expect(value.roomID == createdRoom && value.actorUserID == senderID && value.targetUserID == target)
                    return value.createdAt
                case "stranger":
                    let outcome = try await direct.setStrangerMessagePermission(command: .init(actorUserID: senderID,
                        operationID: .init(uuid: id), permission: conflict ? .allow : .deny), now: now)
                    if conflict { #expect(outcome == .idempotencyConflict); return nil }
                    switch outcome {
                    case .updated(let permission, let date): #expect(!replay && permission == .deny); return date
                    case .idempotent(let permission, let date): #expect(replay && permission == .deny); return date
                    default: Issue.record("Expected a stranger preference result"); throw CancellationError()
                    }
                case "userAdd":
                    let outcome = try await direct.setUserAddPermission(command: .init(actorUserID: senderID,
                        operationID: .init(uuid: id), permission: conflict ? .allow : .deny), now: now)
                    if conflict { #expect(outcome == .idempotencyConflict); return nil }
                    switch outcome {
                    case .updated(let permission, let date): #expect(!replay && permission == .deny); return date
                    case .idempotent(let permission, let date): #expect(replay && permission == .deny); return date
                    default: Issue.record("Expected a user-add preference result"); throw CancellationError()
                    }
                case "relationship":
                    let outcome = try await social.changeRelationship(.init(actorUserID: senderID, operationID: .init(uuid: id),
                        targetUserID: target, action: .request), now: now)
                    if conflict { #expect(outcome == .idempotencyConflict); return nil }
                    let value: V2RelationshipChange
                    switch outcome {
                    case .changed(let change): #expect(!replay); value = change
                    case .idempotent(let change): #expect(replay); value = change
                    default: Issue.record("Expected a relationship result"); throw CancellationError()
                    }
                    #expect(value.actorUserID == senderID && value.targetUserID == target && value.action == .request && value.resultingState == .pending)
                    return value.updatedAt
                default:
                    let outcome = try await social.changeUserBlock(.init(actorUserID: senderID, operationID: .init(uuid: id),
                        targetUserID: target, action: .block), now: now)
                    if conflict { #expect(outcome == .idempotencyConflict); return nil }
                    let value: V2UserBlockChange
                    switch outcome {
                    case .changed(let change): #expect(!replay); value = change
                    case .idempotent(let change): #expect(replay); value = change
                    default: Issue.record("Expected a block result"); throw CancellationError()
                    }
                    #expect(value.actorUserID == senderID && value.targetUserID == target && value.action == .block && value.isBlocked)
                    return value.updatedAt
                }
            }
            func expectFailure(_ id: UUID, at now: Date) async {
                do {
                    _ = try await invoke(id, at: now, replay: id == operation)
                    Issue.record("Expected a typed timestamp error")
                } catch {
                    if kind == "relationship" || kind == "block" {
                        #expect(error as? V2SocialRelationshipStoreError == .corruptPersistenceState)
                    } else {
                        #expect(error as? V2DirectMessagingStoreError == .corruptPersistenceState)
                    }
                }
            }
            func snapshot() async throws -> [String] {
                var result: [String] = []
                // The fixture discards shadow forwarding; compare all primary
                // business state and projection records across failed/replayed work.
                for table in ["rooms", "room_memberships", "room_admission", "shard_admission_pools", "direct_room_pairs",
                    "direct_room_operations", "user_stranger_message_preferences", "stranger_message_preference_operations",
                    "user_add_preferences", "user_add_preference_operations", "user_relationships", "user_relationship_operations",
                    "user_blocks", "user_block_operations", "user_direct_send_policy_versions", "user_sync_sequences", "user_sync_log"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)
                    result.append(try #require(row).value)
                }
                return result
            }
            #expect(try await invoke(operation, at: base) == base)
            let initial = try await snapshot()
            for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12] {
                let bad = Date(timeIntervalSince1970: seconds)
                #expect(try await invoke(operation, at: bad, replay: true) == base)
                _ = try await invoke(operation, at: bad, conflict: true)
                await expectFailure(UUID(), at: bad)
                #expect(try await snapshot() == initial)
            }
            let table: String
            switch kind {
            case "direct": table = "direct_room_operations"
            case "stranger": table = "stranger_message_preference_operations"
            case "userAdd": table = "user_add_preference_operations"
            case "relationship": table = "user_relationship_operations"
            default: table = "user_block_operations"
            }
            let column = kind == "direct" ? "created_at" : "updated_at"
            for literal in ["infinity", "-infinity", "294276-12-31 23:59:59.999999+00"] {
                try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET \(unsafeRaw: column) = \(bind: literal)::timestamptz WHERE operation_id = \(bind: operation)").run()
                let before = try await snapshot()
                await expectFailure(operation, at: base)
                _ = try await invoke(operation, at: base, conflict: true)
                #expect(try await snapshot() == before)
            }
            for date in [Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000),
                         Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10), base] {
                try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET \(unsafeRaw: column) = \(bind: date) WHERE operation_id = \(bind: operation)").run()
                let before = try await snapshot()
                #expect(try await invoke(operation, at: base, replay: true) == date)
                #expect(try await snapshot() == before)
            }
            #expect(try await snapshot() == initial)
        }
    }

    @Test("Direct receipts commit owner outboxes and resolve control privacy across databases", arguments: [false, true])
    func directReceiptOwnerOutbox(batch: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { ownerDB, controlDB, ownerSQL, controlSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let room = RoomID(uuid: UUID())
            let profile = try forwardImportTestProfile()
            guard case .opened = try await PostgresV2DirectMessagingStore(database: ownerDB).open(
                command: .init(actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID)),
                capacityProfile: profile, roomShardID: "room-a", roomID: room, now: now) else { throw CancellationError() }
            let sender = V2SendMessageService(store: PostgresV2RoomWriteStore(database: ownerDB), capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted = try await sender.send(.init(roomID: room, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "read me")) else { throw CancellationError() }
            let store = PostgresV2ReadReceiptStore(database: ownerDB)
            let command = try V2RecordReadReceiptCommand(roomID: room, actorUserID: senderID,
                operationID: .init(uuid: UUID()), readThroughRoomSequence: 1)
            await #expect(throws: V2ReadReceiptStoreError.ownerChanged) {
                _ = try await store.recordOwnerValidated(command: command, ownerRoute: .init(shardID: "room-a", epoch: 99), now: now)
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
                let leases = try await outbox.claim(now: now.addingTimeInterval(1), leaseDuration: 30, limit: 100)
                    .filter { $0.event.kind == .ownReadWatermark || $0.event.kind == .directReadReceipt }
                #expect(leases.count == 2)
                for lease in leases {
                    let sequence = try await projector.project(lease.event)
                    #expect(try await projector.project(lease.event) == sequence)
                    #expect(try await outbox.acknowledge(lease, sequence: sequence, now: now.addingTimeInterval(2)))
                }
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
            let preferences = PostgresV2ReadReceiptStore(database: controlDB)
            _ = try await preferences.setPreferences(command: .init(actorUserID: senderID, operationID: .init(uuid: UUID()),
                allowsDirectReadReceipts: false, allowsGroupReadReceipts: true), now: now)
            let worker = V2ReadReceiptPreferencePropagationWorker(database: controlDB, now: { now })
            #expect(try await worker.runOnce(limit: 1) == .init(claimedOperationCount: 1, projectedRoomCount: 1, completedOperationCount: 0))
            #expect(try await worker.runOnce(limit: 1) == .init(claimedOperationCount: 1, projectedRoomCount: 1, completedOperationCount: 1))
            #expect(try await worker.runOnce(limit: 1).claimedOperationCount == 0)
            #expect(try await count("im_v2.direct_room_pairs", on: controlSQL) == 0)
            #expect(try await count("im_v2.user_state_event_outbox", on: controlSQL) == 4)
            #expect(try await controlSQL.raw("SELECT count(*) AS value FROM im_v2.user_sync_log WHERE projection_kind = 'direct_read_receipt'").first(decoding: CountRow.self)?.value == 0)
            _ = try await preferences.setPreferences(command: .init(actorUserID: senderID, operationID: .init(uuid: UUID()),
                allowsDirectReadReceipts: true, allowsGroupReadReceipts: true), now: now)
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
                let leases = try await outbox.claim(now: now, leaseDuration: 30, limit: 10)
                for lease in leases {
                    let sequence = try await projector.project(lease.event)
                    #expect(try await outbox.acknowledge(lease, sequence: sequence, now: now))
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
            let store = PostgresV2ReadReceiptStore(database: database)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let first = V2SetReadReceiptPreferencesCommand(actorUserID: senderID, operationID: .init(uuid: UUID()),
                allowsDirectReadReceipts: false, allowsGroupReadReceipts: true)
            let second = V2SetReadReceiptPreferencesCommand(actorUserID: senderID, operationID: .init(uuid: UUID()),
                allowsDirectReadReceipts: true, allowsGroupReadReceipts: true)
            guard case .updated(let saved) = try await store.setPreferences(command: first, now: now) else {
                throw CancellationError()
            }
            #expect(try await store.setPreferences(command: first, now: now.addingTimeInterval(10)) == .idempotent(saved))
            #expect(try await sql.raw("SELECT preference_revision AS value FROM im_v2.user_read_receipt_preferences WHERE user_id = \(bind: senderUUID)").first(decoding: CountRow.self)?.value == 1)
            guard case .updated = try await store.setPreferences(command: second, now: now.addingTimeInterval(-10)) else {
                throw CancellationError()
            }
            #expect(try await sql.raw("SELECT preference_revision AS value FROM im_v2.user_read_receipt_preferences WHERE user_id = \(bind: senderUUID)").first(decoding: CountRow.self)?.value == 2)
            #expect(try await sql.raw("""
                SELECT count(*)::bigint AS value FROM im_v2.read_receipt_preference_operations AS operation
                JOIN im_v2.user_sync_log AS log ON log.user_id = operation.actor_user_id
                  AND log.source_event_id = operation.operation_id AND log.projection_kind = 'read_receipt_preferences'
                WHERE operation.actor_user_id = \(bind: senderUUID)
                  AND (log.payload->>'preference_revision')::bigint = operation.preference_revision
                """).first(decoding: CountRow.self)?.value == 2)
            let conflicting = V2SetReadReceiptPreferencesCommand(actorUserID: senderID, operationID: first.operationID,
                allowsDirectReadReceipts: true, allowsGroupReadReceipts: true)
            #expect(try await store.setPreferences(command: conflicting, now: now) == .idempotencyConflict)
            try await sql.raw("UPDATE im_v2.user_read_receipt_preferences SET preference_revision = \(bind: Int64.max) WHERE user_id = \(bind: senderUUID)").run()
            let overflow = V2SetReadReceiptPreferencesCommand(actorUserID: senderID, operationID: .init(uuid: UUID()),
                allowsDirectReadReceipts: false, allowsGroupReadReceipts: true)
            await #expect(throws: V2ReadReceiptStoreError.corruptPersistenceState) {
                _ = try await store.setPreferences(command: overflow, now: now)
            }
            #expect(try await store.setPreferences(command: first, now: now) == .idempotent(saved))
            #expect(try await sql.raw("SELECT preference_revision AS value FROM im_v2.user_read_receipt_preferences WHERE user_id = \(bind: senderUUID) AND allows_direct_read_receipts = true").first(decoding: CountRow.self)?.value == Int64.max)
            #expect(try await count("im_v2.read_receipt_preference_operations", on: sql) == 2)
            #expect(try await count("im_v2.read_receipt_preference_propagation_outbox", on: sql) == 1)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 2)
        }
    }

    @Test("Direct room creation validates persisted pair and profile timestamps", arguments: ["pair", "profile"])
    func directRoomSourceTimestampBounds(kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, target, sql, targetSQL, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let store = PostgresV2DirectMessagingStore(database: database)
            let profile = try forwardImportTestProfile()
            let createdRoom = RoomID(uuid: UUID()), operation = UUID()
            func open(_ operation: UUID) async throws -> V2OpenDirectRoomOutcome {
                try await store.open(command: .init(actorUserID: senderID, operationID: .init(uuid: operation), targetUserID: .init(uuid: memberTwoUUID)),
                    capacityProfile: profile, roomShardID: "room-a", roomID: createdRoom, now: base)
            }
            if kind == "pair" { guard case .opened = try await open(UUID()) else { throw CancellationError() } }
            func snapshot() async throws -> [String] {
                var result: [String] = []
                for table in ["rooms", "room_memberships", "room_admission", "shard_admission_pools", "direct_room_pairs",
                    "direct_room_operations", "public_user_profiles", "user_direct_send_policy_versions", "user_sync_sequences", "user_sync_log", "user_state_event_outbox"] {
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
            guard case .opened(let room) = try await open(operation) else { throw CancellationError() }
            #expect(room.roomID == createdRoom && room.createdAt == base)
            #expect(try await open(operation) == .idempotent(room))
            #expect(try await count("im_v2.direct_room_pairs", on: sql) == 1)
            #expect(try await count("im_v2.direct_room_operations", on: sql) == (kind == "pair" ? 2 : 1))
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
            #expect(try await count("im_v2.user_state_event_outbox", on: sql) == 1)
            let outbox = try PostgresV2UserStateEventOutbox(database: database)
            let projector = try PostgresV2UserStateEventProjector(database: target)
            let leases = try await outbox.claim(now: base, leaseDuration: 1, limit: 10)
            #expect(leases.count == 1)
            for lease in leases {
                let sequence = try await projector.project(lease.event)
                #expect(try await projector.project(lease.event) == sequence)
                #expect(try await outbox.acknowledge(lease, sequence: sequence, now: base))
            }
            #expect(try await count("im_v2.user_sync_log", on: targetSQL) == 1)
        }
    }

    @Test("Mutation replay uses its committed timestamp while new work requires a valid clock",
          arguments: ["edit", "withdrawal", "membership", "reaction", "pin", "announcement", "permissions", "role"])
    func mutationReplayTimestampBounds(kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
            if kind == "role" {
                // Role changes require a positive observed membership fence;
                // the shared legacy seed starts at zero.
                try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1 WHERE room_id = \(bind: roomUUID)").run()
            }
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64), now: { base })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "before")) else { throw CancellationError() }
            let edits = PostgresV2MessageEditStore(database: database)
            let withdrawals = PostgresV2MessageWithdrawalStore(database: database)
            let memberships = PostgresV2RoomMembershipStore(database: database)
            let reactions = PostgresV2MessageReactionStore(database: database)
            let groups = PostgresV2GroupCapabilitiesStore(database: database)
            let expectedDate: Date? = ["permissions", "role"].contains(kind) ? nil : base
            let operation = UUID()
            func invoke(_ operation: UUID, at now: Date) async throws -> (date: Date?, event: EventID?, sequence: UInt64, replay: Bool) {
                let event = EventID(uuid: UUID())
                switch kind {
                case "edit":
                    let outcome = try await edits.edit(command: .init(roomID: roomID, actorUserID: senderID,
                        operationID: .init(uuid: operation), messageID: message.messageID, expectedMessageRevision: 1,
                        text: "after", maximumUTF8Bytes: 64), capacityProfile: profile, eventID: event, now: now)
                    switch outcome {
                    case .edited(let value): return (value.createdAt, value.eventID, value.roomSequence, false)
                    case .idempotent(let value): return (value.createdAt, value.eventID, value.roomSequence, true)
                    default: throw CancellationError()
                    }
                case "withdrawal":
                    let outcome = try await withdrawals.withdraw(command: .init(roomID: roomID, actorUserID: senderID,
                        operationID: .init(uuid: operation), messageID: message.messageID, expectedMessageRevision: 1),
                        capacityProfile: profile, eventID: event, now: now)
                    switch outcome {
                    case .withdrawn(let value): return (value.createdAt, value.eventID, value.roomSequence, false)
                    case .idempotent(let value): return (value.createdAt, value.eventID, value.roomSequence, true)
                    default: throw CancellationError()
                    }
                case "reaction":
                    let outcome = try await reactions.change(command: .init(roomID: roomID, actorUserID: senderID,
                        operationID: .init(uuid: operation), messageID: message.messageID, reaction: "👍", action: .add),
                        capacityProfile: profile, eventID: event, now: now)
                    switch outcome {
                    case .changed(let value): return (value.createdAt, value.eventID, value.roomSequence, false)
                    case .idempotent(let value): return (value.createdAt, value.eventID, value.roomSequence, true)
                    default: throw CancellationError()
                    }
                case "pin":
                    let outcome = try await groups.setPinnedMessage(actorUserID: senderID,
                        command: .init(operationID: .init(uuid: operation), roomID: roomID, messageID: message.messageID, isPinned: true),
                        capacityProfile: profile, eventID: event, now: now)
                    switch outcome {
                    case .applied(let value): return (value.updatedAt, nil, value.roomSequence, false)
                    case .idempotent(let value): return (value.updatedAt, nil, value.roomSequence, true)
                    default: throw CancellationError()
                    }
                case "announcement":
                    let outcome = try await groups.setAnnouncement(actorUserID: senderID,
                        command: .init(operationID: .init(uuid: operation), roomID: roomID, body: "Clock boundary", expectedRevision: 0),
                        capacityProfile: profile, eventID: event, now: now)
                    switch outcome {
                    case .applied(let value): return (value.updatedAt, nil, value.roomSequence, false)
                    case .idempotent(let value): return (value.updatedAt, nil, value.roomSequence, true)
                    default: throw CancellationError()
                    }
                case "permissions":
                    let outcome = try await groups.setRolePermissions(actorUserID: senderID,
                        command: .init(operationID: .init(uuid: operation), roomID: roomID, role: .member, permissions: [], expectedRevision: 1),
                        capacityProfile: profile, eventID: event, now: now)
                    switch outcome {
                    case .applied(let value): return (nil, nil, value.roomSequence, false)
                    case .idempotent(let value): return (nil, nil, value.roomSequence, true)
                    default: throw CancellationError()
                    }
                case "role":
                    let outcome = try await groups.changeMemberRole(actorUserID: senderID,
                        command: .init(operationID: .init(uuid: operation), roomID: roomID,
                            targetUserID: .init(uuid: memberTwoUUID), role: .admin, expectedMembershipRevision: 1),
                        capacityProfile: profile, eventID: event, now: now)
                    switch outcome {
                    case .applied(let value): return (nil, nil, value.roomSequence, false)
                    case .idempotent(let value): return (nil, nil, value.roomSequence, true)
                    default: throw CancellationError()
                    }
                default:
                    let outcome = try await memberships.change(command: .init(roomID: roomID, actorUserID: senderID,
                        operationID: .init(uuid: operation), targetUserID: .init(uuid: memberTwoUUID), action: .remove,
                        expectedMembershipRevision: 0), capacityProfile: profile, eventID: event, now: now)
                    switch outcome {
                    case .changed(let value): return (value.createdAt, value.eventID, value.roomSequence, false)
                    case .idempotent(let value): return (value.createdAt, value.eventID, value.roomSequence, true)
                    default: throw CancellationError()
                    }
                }
            }
            func expectClockFailure(_ operation: UUID, at now: Date) async {
                do {
                    _ = try await invoke(operation, at: now)
                    Issue.record("Expected a typed persistence timestamp error")
                } catch {
                    switch kind {
                    case "edit": #expect(error as? V2MessageEditStoreError == .corruptPersistenceState)
                    case "withdrawal": #expect(error as? V2MessageWithdrawalStoreError == .corruptPersistenceState)
                    case "membership": #expect(error as? V2RoomMembershipStoreError == .corruptPersistenceState)
                    case "reaction": #expect(error as? V2MessageReactionStoreError == .corruptPersistenceState)
                    default: #expect(error as? V2GroupCapabilitiesStoreError == .corruptPersistenceState)
                    }
                }
            }
            func snapshot() async throws -> [String] {
                var values: [String] = []
                for table in ["rooms", "room_memberships", "messages", "room_admission", "shard_admission_pools",
                    "room_events", "message_edit_operations",
                    "message_withdrawal_operations", "room_membership_operations", "message_reactions", "message_reaction_operations",
                    "room_pinned_messages", "room_pinned_message_operations", "group_announcements", "group_announcement_operations",
                    "group_role_permissions", "group_role_policies", "group_permission_operations", "group_role_operations"] {
                    let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)
                    guard let row else { throw CancellationError() }
                    values.append(row.value)
                }
                return values
            }
            let accepted = try await invoke(operation, at: base)
            #expect(!accepted.replay && accepted.date == expectedDate && accepted.sequence == 2)
            let initial = try await snapshot()
            for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12] {
                let bad = Date(timeIntervalSince1970: seconds)
                let replay = try await invoke(operation, at: bad)
                #expect(replay.replay && replay.date == expectedDate && replay.event == accepted.event && replay.sequence == accepted.sequence)
                #expect(try await snapshot() == initial)
                await expectClockFailure(UUID(), at: bad)
                #expect(try await snapshot() == initial)
            }
            // These two response types contain no timestamp. Their replay
            // identity and persisted state were verified above.
            if expectedDate == nil { return }
            let table: String
            switch kind {
            case "membership": table = "room_membership_operations"
            case "pin": table = "room_pinned_message_operations"
            case "announcement": table = "group_announcement_operations"
            default: table = "message_" + kind + "_operations"
            }
            for literal in ["infinity", "-infinity", "294276-12-31 23:59:59.999999+00"] {
                try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET created_at = \(bind: literal)::timestamptz WHERE operation_id = \(bind: operation)").run()
                let before = try await snapshot()
                await expectClockFailure(operation, at: base)
                #expect(try await snapshot() == before)
            }
            for date in [Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000),
                         Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10), base] {
                try await sql.raw("UPDATE im_v2.\(unsafeRaw: table) SET created_at = \(bind: date) WHERE operation_id = \(bind: operation)").run()
                let before = try await snapshot()
                let replay = try await invoke(operation, at: base)
                #expect(replay.replay && replay.date == date && replay.event == accepted.event && replay.sequence == accepted.sequence)
                #expect(try await snapshot() == before)
            }
            #expect(try await snapshot() == initial)
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
            @Sendable func mutate(user: UserID, current: DeviceID, remote: DeviceID, operation: UUID) async throws -> V2DeviceSessionMutationOutcome {
                switch kind {
                case "current": return try await service.revokeCurrentDevice(actorUserID: user, currentDeviceID: current, operationID: operation)
                case "remote": return try await service.revokeDevice(actorUserID: user, currentDeviceID: current, targetDeviceID: remote, operationID: operation)
                default: return try await service.revokeOtherDevices(actorUserID: user, currentDeviceID: current, operationID: operation)
                }
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

    @Test("Local forwarding clocks isolate failed pairs and preserve durable retries", arguments: [false, true])
    func localForwardClockBounds(ownerValidated: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let clock = TestSequenceClock([base])
            let profile = try forwardImportTestProfile(), limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let write = PostgresV2RoomWriteStore(database: database)
            let sender = V2SendMessageService(store: write, capacityProfile: profile, limits: limits, now: { base })
            guard case .accepted(let source) = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "forward clock")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let reference = try V2ForwardMessageReference(roomID: roomID, messageID: source.messageID, revision: .init(1))
            let command = try V2ForwardMessagesCommand(operationID: .init(uuid: UUID()), sources: [reference], targetRoomIDs: [roomID])
            let service = V2ForwardMessagesService(database: database, writeStore: write, capacityProfile: profile, limits: limits, now: { clock.now() })
            @Sendable func forward(_ command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult] {
                if ownerValidated {
                    return try await service.forwardOwnerValidated(actorUserID: senderID, command: command, ownerRoutes: [roomID: .init(shardID: "room-a", epoch: 0)])
                }
                return try await service.forward(actorUserID: senderID, command: command)
            }
            func snapshot(includeOperations: Bool = true) async throws -> String {
                let row = try await sql.raw("""
                    SELECT jsonb_build_object(
                        'operations', CASE WHEN \(bind: includeOperations) THEN (SELECT jsonb_agg(to_jsonb(r) ORDER BY actor_user_id, operation_id, source_message_id, target_room_id) FROM im_v2.message_forward_operations r) END,
                        'messages', (SELECT jsonb_agg(to_jsonb(r) ORDER BY message_id) FROM im_v2.messages r),
                        'events', (SELECT jsonb_agg(to_jsonb(r) ORDER BY room_id, room_sequence) FROM im_v2.room_events r),
                        'rooms', (SELECT jsonb_agg(to_jsonb(r) ORDER BY room_id) FROM im_v2.rooms r),
                        'room_admission', (SELECT jsonb_agg(to_jsonb(r) ORDER BY room_id) FROM im_v2.room_admission r),
                        'shard_admission', (SELECT jsonb_agg(to_jsonb(r) ORDER BY room_shard_id, capacity_profile_id) FROM im_v2.shard_admission_pools r),
                        'completions', (SELECT jsonb_agg(to_jsonb(r) ORDER BY sender_user_id, client_message_id) FROM im_v2.message_send_completions r)
                    )::text AS value
                    """).first(decoding: StringValueRow.self)
                guard let row else { throw V2RoomWriteStoreError.corruptPersistenceState }
                return row.value
            }
            let unavailable = try V2ForwardMessageResult(sourceMessageID: source.messageID, targetRoomID: roomID, messageID: nil, roomSequence: nil, errorCode: "UNAVAILABLE")
            let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            let initial = try await snapshot()
            for bad in badDates {
                clock.set([bad])
                #expect(try await forward(command) == [unavailable])
                #expect(try await snapshot() == initial)
            }
            // The staging transaction succeeds, then the acceptance clock becomes invalid.
            let initialBusiness = try await snapshot(includeOperations: false)
            clock.set([base, badDates[0]])
            #expect(try await forward(command) == [unavailable])
            #expect(try await count("im_v2.message_forward_operations WHERE result_message_id IS NULL", on: sql) == 1)
            #expect(try await snapshot(includeOperations: false) == initialBusiness)
            let staged = try await snapshot()
            let invalidAcceptanceDates = badDates + [Date(timeIntervalSince1970: -1), Date(timeIntervalSince1970: 281_474_976_710.656), Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000), Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)]
            for bad in invalidAcceptanceDates {
                clock.set([bad])
                #expect(try await forward(command) == [unavailable])
                #expect(try await snapshot() == staged)
            }
            // A recovered clock and concurrent normal retries accept exactly one message.
            clock.set([base.addingTimeInterval(-30)])
            let recovered = try await withThrowingTaskGroup(of: [V2ForwardMessageResult].self) { group in
                for _ in 0..<8 { group.addTask { try await forward(command) } }
                var results: [[V2ForwardMessageResult]] = []
                for try await result in group { results.append(result) }
                return results
            }
            let accepted = try #require(recovered.first)
            #expect(accepted.count == 1)
            #expect(accepted.first?.errorCode == nil)
            #expect(accepted.first?.messageID != nil)
            #expect(recovered.allSatisfy { $0 == accepted })
            #expect(try await count("im_v2.messages", on: sql) == 2)
            #expect(try await count("im_v2.message_forward_operations WHERE result_message_id IS NOT NULL", on: sql) == 1)
            let committed = try await snapshot()
            for bad in badDates {
                clock.set([bad])
                #expect(try await forward(command) == accepted)
                #expect(try await snapshot() == committed)
            }

            guard case .accepted(let secondSource) = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "second clock source")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let secondReference = try V2ForwardMessageReference(roomID: roomID, messageID: secondSource.messageID, revision: .init(1))
            let multi = try V2ForwardMessagesCommand(operationID: .init(uuid: UUID()), sources: [reference, secondReference], targetRoomIDs: [roomID])
            clock.set([badDates[0], base, base])
            let partial = try await forward(multi)
            #expect(partial.count == 2)
            #expect(partial.first == unavailable)
            #expect(partial.last?.sourceMessageID == secondSource.messageID)
            #expect(partial.last?.messageID != nil)
            #expect(partial.last?.errorCode == nil)
            #expect(try await count("im_v2.messages", on: sql) == 4)
            clock.set([base])
            let completed = try await forward(multi)
            #expect(completed.count == 2)
            #expect(completed.allSatisfy { $0.errorCode == nil && $0.messageID != nil })
            #expect(completed.last == partial.last)
            #expect(try await count("im_v2.messages", on: sql) == 5)

            // An accepted message also survives a failed result-marker transaction.
            let interrupted = try V2ForwardMessagesCommand(operationID: .init(uuid: UUID()), sources: [reference], targetRoomIDs: [roomID])
            try await sql.raw("CREATE FUNCTION im_v2.test_forward_clock_result_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'local forward result write failure'; END $$").run()
            try await sql.raw("CREATE TRIGGER test_forward_clock_result_failure BEFORE UPDATE ON im_v2.message_forward_operations FOR EACH ROW EXECUTE FUNCTION im_v2.test_forward_clock_result_failure()").run()
            #expect(try await forward(interrupted) == [unavailable])
            #expect(try await count("im_v2.messages", on: sql) == 6)
            #expect(try await count("im_v2.message_forward_operations WHERE result_message_id IS NULL", on: sql) == 1)
            try await sql.raw("DROP TRIGGER test_forward_clock_result_failure ON im_v2.message_forward_operations").run()
            clock.set([badDates[0]])
            let repaired = try await forward(interrupted)
            #expect(repaired.first?.messageID != nil)
            #expect(repaired.first?.errorCode == nil)
            #expect(try await count("im_v2.messages", on: sql) == 6)
            #expect(try await count("im_v2.message_forward_operations WHERE result_message_id IS NULL", on: sql) == 0)

            // Staging accepts the full finite PostgreSQL range, independently of message acceptance.
            for valid in [Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000), Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)] {
                let boundary = try V2ForwardMessagesCommand(operationID: .init(uuid: UUID()), sources: [reference], targetRoomIDs: [roomID])
                clock.set([valid, badDates[0]])
                #expect(try await forward(boundary) == [unavailable])
                let row = try await sql.raw("SELECT created_at AS value FROM im_v2.message_forward_operations WHERE operation_id = \(bind: boundary.operationID.uuidValue!)").first(decoding: RevocationClockDateRow.self)
                #expect(row?.value == valid)
                #expect(try await count("im_v2.messages", on: sql) == 6)
            }
            clock.set([base])
            // New ordinary traffic remains usable after every invalid-clock path above.
            let normal = try V2ForwardMessagesCommand(operationID: .init(uuid: UUID()), sources: [reference], targetRoomIDs: [roomID])
            let result = try await forward(normal)
            #expect(result.first?.messageID != nil)
            #expect(result.first?.errorCode == nil)
            #expect(try await count("im_v2.messages", on: sql) == 7)
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
            let gatewayWorker = V2DeviceRevocationWorker(store: gatewayStore, registry: V2DeviceConnectionRegistry(), nodeID: node, now: { clock.now() })
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
            let ownerStore = PostgresV2DirectMessagingStore(database: owner, projectionDelivery: SuccessfulProjectionDelivery())
            let routed = try V2RoutedDirectMessagingStore(router: cached, ownerStores: ["room-b": ownerStore], controlStore: PostgresV2DirectMessagingStore(database: control, projectionDelivery: SuccessfulProjectionDelivery()))
            let profile = try forwardImportTestProfile()
            let createdID = UUID()
            let createdRoom = RoomID(uuid: createdID)
            let ids = V2DirectMessagingIDFactory(makeUUID: { createdID })
            let service = try V2DirectMessagingService(store: routed, capacityProfile: profile, roomShardID: "room-b", identifiers: ids, now: { base })
            let operation = DirectRoomOperationID(uuid: UUID())
            let customer = UserID(uuid: memberTwoUUID)
            @Sendable func open() async throws -> V2OpenDirectRoomOutcome {
                try await service.open(actorUserID: senderID, operationID: operation, targetUserID: customer)
            }
            if roomRouteExists {
                let direct = try V2DirectMessagingService(store: ownerStore, capacityProfile: profile, roomShardID: "room-b", identifiers: ids, now: { base })
                guard case .opened = try await direct.open(actorUserID: senderID, operationID: operation, targetUserID: customer) else { throw V2DirectMessagingStoreError.corruptPersistenceState }
                try await sql.raw("INSERT INTO im_v2.room_owner_routes(room_id, room_shard_id, route_epoch, created_at, updated_at) VALUES (\(bind: createdID), 'room-b', 0, \(bind: base), \(bind: base)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id = EXCLUDED.room_shard_id, route_epoch = EXCLUDED.route_epoch, updated_at = EXCLUDED.updated_at").run()
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
                        'operations', (SELECT jsonb_agg(to_jsonb(r) ORDER BY actor_user_id, operation_id) FROM im_v2.direct_room_operations r),
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
                #expect(try await count("im_v2.direct_room_operations", on: ownerSQL) == 1)
                let current = try await ownerSnapshot()
                if let ownerCommitted { #expect(current == ownerCommitted) } else { ownerCommitted = current }
                if !roomRouteExists {
                    await #expect(throws: V2RoomShardRouteError.roomNotFound) { _ = try await cached.route(for: createdRoom) }
                    await #expect(throws: V2RoomShardRouteError.roomNotFound) { _ = try await cached.routes(for: [createdRoom]) }
                }
            }
            clock.set([base.addingTimeInterval(2)])
            try await sql.raw("CREATE FUNCTION im_v2.fail_direct_route_record() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test route record failure'; END $$").run()
            try await sql.raw("CREATE TRIGGER fail_direct_route_record BEFORE INSERT ON im_v2.direct_room_owner_routes FOR EACH ROW EXECUTE FUNCTION im_v2.fail_direct_route_record()").run()
            await #expect(throws: (any Error).self) { _ = try await open() }
            #expect(try await directorySnapshot() == before)
            #expect(try await ownerSnapshot() == ownerCommitted)
            if !roomRouteExists {
                await #expect(throws: V2RoomShardRouteError.roomNotFound) { _ = try await cached.route(for: createdRoom) }
            }
            try await sql.raw("DROP TRIGGER fail_direct_route_record ON im_v2.direct_room_owner_routes").run()
            try await sql.raw("DROP FUNCTION im_v2.fail_direct_route_record()").run()
            let results = try await withThrowingTaskGroup(of: V2OpenDirectRoomOutcome.self) { group in
                for _ in 0..<8 { group.addTask { try await open() } }
                var results: [V2OpenDirectRoomOutcome] = []
                for try await value in group { results.append(value) }
                return results
            }
            let result = try #require(results.first)
            guard case .idempotent(let room) = result else { throw V2DirectMessagingStoreError.corruptPersistenceState }
            #expect(room.roomID == createdRoom && results.count == 8)
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
            // An ordinary unavailable result has no room to record and must
            // remain usable without a directory timestamp.
            #expect(try await service.open(actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: UUID())) == .unavailable)
            #expect(try await directorySnapshot() == committed)
            for (actor, target, valid) in [(senderID, UserID(uuid: memberThreeUUID), Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000)), (customer, UserID(uuid: memberThreeUUID), Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10))] {
                clock.set([valid])
                let next = try V2DirectMessagingService(store: routed, capacityProfile: profile, roomShardID: "room-b", now: { base })
                guard case .opened(let room) = try await next.open(actorUserID: actor, operationID: .init(uuid: UUID()), targetUserID: target) else { throw V2DirectMessagingStoreError.corruptPersistenceState }
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.room_owner_routes WHERE room_id = \(bind: room.roomID.uuidValue!) AND created_at = \(bind: valid) AND updated_at = \(bind: valid)").first(decoding: CountRow.self)?.value == 1)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.direct_room_owner_routes WHERE room_id = \(bind: room.roomID.uuidValue!) AND created_at = \(bind: valid) AND updated_at = \(bind: valid)").first(decoding: CountRow.self)?.value == 1)
            }
        }
    }


}
