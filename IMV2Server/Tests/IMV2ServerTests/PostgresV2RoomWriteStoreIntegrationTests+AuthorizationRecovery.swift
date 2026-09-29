@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
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
            let service = try V2PostgresAccountDisableService(database: database, operatorPrincipal: "revision-maintenance", now: { now })
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
            #expect(try await service.disable(command) == .disabled(disabledAt: now))
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
                #expect(try await service.disable(command) == .idempotent(disabledAt: now))
                #expect(try await service.disable(other) == .alreadyDisabled(disabledAt: now))
                #expect(try await snapshot() == committed)
            }
        }
    }

    @Test("Account disable returns the persisted timestamp consistently on first response and replay",
          arguments: [0, 1, 2, 3, 4, 5, 6])
    func accountDisableResponseTimestampPrecision(clockIndex: Int) async throws {
        let dates: [Double] = [946_684_800 - 0.00000075, 946_684_800 + 0.00000125, 1_750_000_000 + 0.1234567,
                               1_750_000_000 + 0.99999975, -0.00075, -210_866_803_200, 9_224_318_015_990]
        let seconds = dates[clockIndex]
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: seconds)
            let service = try V2PostgresAccountDisableService(database: database, operatorPrincipal: "timestamp-maintenance", now: { now })
            let command = try V2AccountDisableCommand(userID: senderID, operationID: UUID(), reason: .userRequested)
            let outcome = try await service.disable(command)
            let row = try await sql.raw("SELECT disabled_at AS value FROM im_v2.account_disables WHERE operation_id = \(bind: command.operationID)").first(decoding: RevocationClockDateRow.self)
            let persisted = try #require(row).value
            #expect(outcome == .disabled(disabledAt: persisted))
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.account_disables d JOIN im_v2.public_profile_update_outbox o ON o.source_event_id = d.operation_id JOIN im_v2.public_user_profiles p ON p.user_id = d.user_id JOIN im_v2.user_direct_send_policy_versions v ON v.user_id = d.user_id WHERE d.operation_id = \(bind: command.operationID) AND d.disabled_at = \(bind: now) AND o.profile_updated_at = d.disabled_at AND o.created_at = d.disabled_at AND p.updated_at = d.disabled_at AND v.updated_at = d.disabled_at").first(decoding: CountRow.self)?.value == 1)
            let other = try V2AccountDisableCommand(userID: senderID, operationID: UUID(), reason: .userRequested)
            for clock in [Double.nan, .infinity, seconds] {
                let retry = try V2PostgresAccountDisableService(database: database, operatorPrincipal: "timestamp-maintenance",
                    now: { Date(timeIntervalSince1970: clock) })
                #expect(try await retry.disable(command) == .idempotent(disabledAt: persisted))
                #expect(try await retry.disable(other) == .alreadyDisabled(disabledAt: persisted))
            }
            #expect(try await count("im_v2.account_disables", on: sql) == 1)
            #expect(try await count("im_v2.public_profile_update_outbox", on: sql) == 1)
        }
    }

    @Test("Account-disable clocks reject partial writes and preserve committed replay")
    func accountDisableClockBounds() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let committedAt = base.addingTimeInterval(1)
            let clock = TestSequenceClock([base])
            let service = try V2PostgresAccountDisableService(database: database, operatorPrincipal: "clock-maintenance", now: { clock.now() })
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
            let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            for bad in badDates {
                clock.set([bad])
                await #expect(throws: V2AccountDisableError.unavailable) { _ = try await service.disable(command) }
                #expect(try await snapshot() == initial)
            }
            clock.set([committedAt])
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
            #expect(results.count == 8)
            #expect(results.filter { $0 == .disabled(disabledAt: committedAt) }.count == 1)
            #expect(results.filter { $0 == .idempotent(disabledAt: committedAt) }.count == 7)
            #expect(try await count("im_v2.account_disables", on: sql) == 1)
            #expect(try await count("im_v2.public_user_profiles WHERE state = 'suspended'", on: sql) == 1)
            #expect(try await count("im_v2.public_profile_update_outbox", on: sql) == 1)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.account_disables WHERE user_id = \(bind: senderUUID) AND disabled_at = \(bind: committedAt)").first(decoding: CountRow.self)?.value == 1)
            let committed = try await snapshot()
            for bad in badDates {
                clock.set([bad])
                #expect(try await service.disable(command) == .idempotent(disabledAt: committedAt))
                #expect(try await service.disable(otherOperation) == .alreadyDisabled(disabledAt: committedAt))
                await #expect(throws: V2AccountDisableError.operationConflict) { _ = try await service.disable(conflicting) }
                #expect(try await snapshot() == committed)
            }
            // The other two fixture profiles exercise legitimate database
            // timestamp endpoints without acquiring or issuing credentials.
            for (user, valid) in [(memberTwoUUID, Date(timeIntervalSince1970: 946_684_800 - 211_813_488_000)), (memberThreeUUID, Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10))] {
                clock.set([valid])
                let next = try V2AccountDisableCommand(userID: .init(uuid: user), operationID: UUID(), reason: .userRequested)
                #expect(try await service.disable(next) == .disabled(disabledAt: valid))
                #expect(try await service.disable(next) == .idempotent(disabledAt: valid))
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.account_disables WHERE user_id = \(bind: user) AND disabled_at = \(bind: valid)").first(decoding: CountRow.self)?.value == 1)
            }
            #expect(try await count("im_v2.account_disables", on: sql) == 3)
            #expect(try await count("im_v2.public_profile_update_outbox", on: sql) == 3)
            #expect(try await count("im_v2.auth_devices", on: sql) == 0)
            #expect(try await count("im_v2.device_refresh_sessions", on: sql) == 0)
            #expect(try await count("im_v2.device_access_tokens", on: sql) == 0)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 0)
        }
    }

    @Test("Admission credit clocks reject partial reservations and retire expired tokens", arguments: [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12])
    func admissionCreditClockBounds(seconds: Double) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let bad = Date(timeIntervalSince1970: seconds)
            let expiry = base.addingTimeInterval(100)
            func state(until: Date = expiry, id: UUID = leaseUUID, generation: UInt64 = 1) throws -> ShardAdmissionState {
                try .init(lease: .init(id: .init(id.uuidString), generation: generation, validUntil: until, commandWindow: .init(limit: 10)))
            }
            let valid = try state()
            let invalid = try state(until: bad)
            let shard = V2ShardAdmissionCommandCreditPool(database: database, batchSize: 5)
            let room = V2RoomAdmissionCommandCreditPool(database: database, batchSize: 5)
            func shardRequest(_ now: Date, _ value: ShardAdmissionState = valid) -> V2ShardAdmissionCommandCreditPool.BatchRequest {
                .init(roomShardID: "room-a", capacityProfileID: "standard", shardState: value, now: now)
            }
            func roomRequest(_ now: Date, _ value: ShardAdmissionState = valid) -> V2RoomAdmissionCommandCreditPool.BatchRequest {
                .init(roomID: roomUUID, shardState: value, now: now)
            }
            func durableSnapshot() async throws -> String {
                try #require(try await sql.raw("""
                    SELECT jsonb_build_object(
                        'shard', (SELECT to_jsonb(r) FROM im_v2.shard_admission_pools r WHERE room_shard_id = 'room-a'),
                        'room', (SELECT to_jsonb(r) FROM im_v2.room_admission r WHERE room_id = \(bind: roomUUID))
                    )::text AS value
                    """).first(decoding: StringValueRow.self)).value
            }
            func rejectClocksWithoutMutation() async throws {
                let shardBefore = await shard.snapshot()
                let roomBefore = await room.snapshot()
                let databaseBefore = try await durableSnapshot()
                await #expect(throws: V2ShardAdmissionCommandCreditError.self) {
                    _ = try await shard.acquire(roomShardID: "room-a", capacityProfileID: "standard", shardState: valid, now: bad)
                }
                await #expect(throws: V2RoomAdmissionCommandCreditError.self) {
                    _ = try await room.acquire(roomID: roomUUID, shardState: valid, now: bad)
                }
                await #expect(throws: V2ShardAdmissionCommandCreditError.self) {
                    _ = try await shard.acquire(roomShardID: "room-a", capacityProfileID: "standard", shardState: invalid, now: base)
                }
                await #expect(throws: V2RoomAdmissionCommandCreditError.self) {
                    _ = try await room.acquire(roomID: roomUUID, shardState: invalid, now: base)
                }
                for batch in [[shardRequest(base), shardRequest(bad)], [shardRequest(bad), shardRequest(base)], [shardRequest(base), shardRequest(base, invalid)]] {
                    await #expect(throws: V2ShardAdmissionCommandCreditError.self) { _ = try await shard.acquire(batch) }
                }
                for batch in [[roomRequest(base), roomRequest(bad)], [roomRequest(bad), roomRequest(base)], [roomRequest(base), roomRequest(base, invalid)]] {
                    await #expect(throws: V2RoomAdmissionCommandCreditError.self) { _ = try await room.acquire(batch) }
                }
                #expect(await shard.snapshot() == shardBefore)
                #expect(await room.snapshot() == roomBefore)
                #expect(try await durableSnapshot() == databaseBefore)
            }
            func acquireBoth(at now: Date, using value: ShardAdmissionState = valid) async throws -> (V2ShardAdmissionCommandCreditPool.Token, V2RoomAdmissionCommandCreditPool.Token) {
                guard case .granted(let shardToken, _) = try await shard.acquire(roomShardID: "room-a", capacityProfileID: "standard", shardState: value, now: now),
                      case .granted(let roomToken) = try await room.acquire(roomID: roomUUID, shardState: value, now: now)
                else { throw V2RoomWriteStoreError.corruptPersistenceState }
                return (shardToken, roomToken)
            }
            // Invalid prefixes and suffixes must neither precharge PostgreSQL
            // nor discard credits that belong to another in-flight message.
            try await rejectClocksWithoutMutation()
            let first = try await acquireBoth(at: base)
            let second = try await acquireBoth(at: base)
            try await rejectClocksWithoutMutation()
            let reserved = try await durableSnapshot()
            await shard.release(first.0, now: bad)
            await room.release(first.1, now: bad)
            let afterInvalidShard = await shard.snapshot()
            let afterInvalidRoom = await room.snapshot()
            #expect(afterInvalidShard.activeCredits == 3 && afterInvalidShard.inFlightCredits == 1 && afterInvalidShard.expiredCreditsDiscarded == 1)
            #expect(afterInvalidRoom.activeCredits == 3 && afterInvalidRoom.inFlightCredits == 1 && afterInvalidRoom.expiredCreditsDiscarded == 1)
            await shard.release(first.0, now: base)
            await room.release(first.1, now: base)
            #expect(await shard.snapshot() == afterInvalidShard)
            #expect(await room.snapshot() == afterInvalidRoom)
            await shard.commit(second.0)
            await room.commit(second.1)
            // A representable clock rollback can still reuse an already paid
            // credit in the same lease. Returning it never refunds PostgreSQL.
            let rolledBack = try await acquireBoth(at: base.addingTimeInterval(-1))
            await shard.release(rolledBack.0, now: base)
            await room.release(rolledBack.1, now: base)
            let shardBatch = try await shard.acquire([shardRequest(base), shardRequest(base)])
            let roomBatch = try await room.acquire([roomRequest(base), roomRequest(base)])
            let shardTokens = shardBatch.compactMap { result -> V2ShardAdmissionCommandCreditPool.Token? in
                guard case .granted(let token, _) = result else { return nil }; return token
            }
            let roomTokens = roomBatch.compactMap { result -> V2RoomAdmissionCommandCreditPool.Token? in
                guard case .granted(let token) = result else { return nil }; return token
            }
            try #require(shardTokens.count == 2 && roomTokens.count == 2)
            #expect(try await durableSnapshot() == reserved)
            // One remaining available credit and both outstanding tokens
            // expire together. Late acknowledgements must stay harmless.
            await shard.release(shardTokens[0], now: expiry)
            await room.release(roomTokens[0], now: expiry)
            let expiredShard = await shard.snapshot()
            let expiredRoom = await room.snapshot()
            #expect(expiredShard == .init(activeCredits: 0, inFlightCredits: 0, batchReservations: 1, databaseCreditsReserved: 5, committedCredits: 1, returnedCredits: 1, expiredCreditsDiscarded: 4, capacityRejections: 0))
            #expect(expiredRoom == .init(activeCredits: 0, inFlightCredits: 0, batchReservations: 1, databaseCreditsReserved: 5, committedCredits: 1, returnedCredits: 1, expiredCreditsDiscarded: 4, capacityRejections: 0, promotedHotRooms: 0))
            await shard.commit(shardTokens[1])
            await room.commit(roomTokens[1])
            await shard.release(shardTokens[1], now: base)
            await room.release(roomTokens[1], now: base)
            #expect(await shard.snapshot() == expiredShard)
            #expect(await room.snapshot() == expiredRoom)
            guard case .unavailable(.expiredShardLease) = try await shard.acquire(roomShardID: "room-a", capacityProfileID: "standard", shardState: valid, now: expiry),
                  case .unavailable(.expiredShardLease) = try await room.acquire(roomID: roomUUID, shardState: valid, now: expiry)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            #expect(try await durableSnapshot() == reserved)
            // Advance the owned fixture to the next lease generation. Old
            // token completion cannot consume or return the new lease's credit.
            let nextID = UUID()
            let nextExpiry = expiry.addingTimeInterval(100)
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET lease_id = \(bind: nextID), generation = 2, valid_until = \(bind: nextExpiry), command_window_used = 0 WHERE room_shard_id = 'room-a'").run()
            try await sql.raw("UPDATE im_v2.room_admission SET shard_lease_id = \(bind: nextID), shard_lease_generation = 2, command_window_used = 0 WHERE room_id = \(bind: roomUUID)").run()
            let next = try await acquireBoth(at: expiry, using: state(until: nextExpiry, id: nextID, generation: 2))
            await shard.commit(next.0)
            await room.commit(next.1)
            let nextShard = await shard.snapshot()
            let nextRoom = await room.snapshot()
            #expect(nextShard.activeCredits == 4 && nextShard.inFlightCredits == 0 && nextShard.committedCredits == 2 && nextShard.databaseCreditsReserved == 10)
            #expect(nextRoom.activeCredits == 4 && nextRoom.inFlightCredits == 0 && nextRoom.committedCredits == 2 && nextRoom.databaseCreditsReserved == 10)
            await shard.release(shardTokens, now: expiry)
            await room.release(roomTokens.map { (token: $0, now: expiry) })
            #expect(await shard.snapshot() == nextShard)
            #expect(await room.snapshot() == nextRoom)
        }
    }

    #if os(macOS)
    @Test("authorization survives SIGKILL before and after both durable commits", .timeLimit(.minutes(3)),
          arguments: ["send", "forward"], ["before-reservation", "after-reservation", "after-owner", "after-ack"])
    func directAuthorizationProcessCrash(kind: String, checkpoint: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000), profile = try forwardImportTestProfile()
            let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner, identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()), capacityProfile: profile, roomShardID: "room-b", now: { now })
            var rooms: [UUID] = [], operations: [UUID] = []
            for recipient in [memberTwoUUID] {
                let room = try await direct.openedIdentity(actorUserID: senderID,
                    operationID: .init(uuid: UUID()), targetUserID: .init(uuid: recipient), firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                rooms.append(room.roomID.uuidValue!); operations.append(UUID())
            }
            var forward: V2ForwardExport?
            if kind == "forward" {
                let source = V2SendMessageService(store: PostgresV2RoomWriteStore(database: control), capacityProfile: profile,
                    limits: try .init(maxUTF8Bytes: 64), now: { now })
                guard case .accepted(let message) = try await source.send(.init(roomID: roomID, actorUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "crash authorization")) else { throw CancellationError() }
                let export = try await PostgresV2ForwardExportStore(database: control).prepare(actorUserID: senderID,
                    operationID: .init(uuid: UUID()), source: .init(roomID: roomID, messageID: message.messageID, revision: .init(1)),
                    sourceRoute: .init(shardID: "room-a", epoch: 0), targetRoomID: .init(uuid: rooms[0]), targetRoute: .init(shardID: "room-b", epoch: 0), now: now)
                try await PostgresV2ForwardInboxStore(database: owner).receive(export, now: now)
                operations[0] = export.intent.targetClientMessageID; forward = export
            }
            let spec = DirectAuthorizationCrashSpec(kind: kind, checkpoint: checkpoint, rooms: rooms, operations: operations,
                payload: forward?.payload, digest: forward?.digest)
            let directory = FileManager.default.temporaryDirectory.appending(path: "imv2-auth-crash-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let specURL = directory.appending(path: "input.json")
            try JSONEncoder().encode(spec).write(to: specURL)
            let lockKey = Int64.random(in: 1...Int64.max)
            if checkpoint == "before-reservation" || checkpoint == "after-owner" {
                try await sql.raw("""
                    CREATE FUNCTION im_v2.test_pause_authorization() RETURNS trigger LANGUAGE plpgsql AS $$
                    BEGIN PERFORM pg_advisory_xact_lock(\(unsafeRaw: String(lockKey))); RETURN NEW; END; $$
                    """).run()
                let event = checkpoint == "before-reservation" ? "BEFORE INSERT" : "BEFORE UPDATE OF disposition"
                try await sql.raw("CREATE TRIGGER test_pause_authorization \(unsafeRaw: event) ON im_v2.direct_authorization_intents FOR EACH ROW EXECUTE FUNCTION im_v2.test_pause_authorization()").run()
            }
            let gate = PostgreSQLTransactionGate()
            let blockingDatabase = checkpoint == "after-reservation" ? owner : control
            let holder = Task {
                try await blockingDatabase.transaction { transaction in
                    let heldSQL = try #require(transaction as? any SQLDatabase)
                    if checkpoint == "after-reservation" {
                        try await heldSQL.raw("SELECT room_id FROM im_v2.rooms WHERE room_id = \(bind: spec.rooms[0]) FOR UPDATE").run()
                    } else { try await heldSQL.raw("SELECT pg_advisory_xact_lock(\(bind: lockKey))").run() }
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()
            let (process, output) = try authorizationCrashProcess(specURL: specURL, mode: "crash", log: directory.appending(path: "crash.log"))
            defer { try? output.close() }
            let exited = Task { try await waitAuthorizationCrashProcess(process) }
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled && process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            defer { watchdog.cancel() }
            do {
                if checkpoint != "after-ack" {
                    let observationSQL = checkpoint == "after-reservation" ? ownerSQL : sql
                    let query = checkpoint == "after-reservation" ? "%owner_epoch%" : "%direct_authorization_intents%"
                    var reached = false
                    for _ in 0..<1000 {
                        let waiters = try await observationSQL.raw("""
                            SELECT count(*) AS value FROM pg_stat_activity WHERE datname = current_database()
                            AND wait_event_type = 'Lock' AND query LIKE \(bind: query)
                            """).first(decoding: CountRow.self)?.value ?? 0
                        if waiters > 0 { reached = true; break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    try #require(reached && process.isRunning)
                    try #require(kill(process.processIdentifier, SIGKILL) == 0)
                }
                try await exited.value
                try #require(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL)
                if checkpoint == "after-ack" { try #require(FileManager.default.fileExists(atPath: specURL.appendingPathExtension("ready").path)) }
                await gate.releaseTransaction(); try await holder.value
                if checkpoint == "before-reservation" || checkpoint == "after-owner" {
                    try await sql.raw("DROP TRIGGER test_pause_authorization ON im_v2.direct_authorization_intents").run()
                    try await sql.raw("DROP FUNCTION im_v2.test_pause_authorization()").run()
                }
                let amount = Int64(spec.operations.count)
                #expect(try await count("im_v2.direct_authorization_intents", on: sql) == (checkpoint == "before-reservation" ? 0 : amount))
                #expect(try await count("im_v2.messages", on: ownerSQL) == (["after-owner", "after-ack"].contains(checkpoint) ? amount : 0))
                let (recovery, recoveryOutput) = try authorizationCrashProcess(specURL: specURL, mode: "recover", log: directory.appending(path: "recover.log"))
                defer { try? recoveryOutput.close() }
                try await waitAuthorizationCrashProcess(recovery)
                try #require(recovery.terminationReason == .exit && recovery.terminationStatus == 0)
                let report = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: specURL.appendingPathExtension("report")))
                let recoveryCount = ["after-reservation", "after-owner"].contains(checkpoint) ? spec.operations.count : 0
                #expect(report["claimed"] == recoveryCount && report["resolved"] == recoveryCount && report["deferred"] == 0)
                #expect(try await count("im_v2.messages", on: ownerSQL) == amount)
                let generation: Int64 = checkpoint == "after-reservation" ? 2 : 1
                #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.direct_authorization_intents WHERE disposition = 'accepted' AND generation = \(bind: generation)").first(decoding: CountRow.self)?.value == amount)
                #expect(try await count("im_v2.direct_authorization_receipts", on: ownerSQL) == amount * generation)
                for index in spec.operations.indices {
                    #expect(try await ownerSQL.raw("SELECT count(*) AS value FROM im_v2.messages WHERE room_id = \(bind: spec.rooms[index]) AND client_message_id = \(bind: spec.operations[index])").first(decoding: CountRow.self)?.value == 1)
                }
                print("Authorization SIGKILL evidence: \(directory.path); kind=\(kind); checkpoint=\(checkpoint); recovery=\(report)")
            } catch {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = await exited.result
                await gate.releaseTransaction(); _ = await holder.result
                throw error
            }
        }
    }

    @Test("isolated authorization process crash and restart",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_AUTHORIZATION_CRASH_SPEC"] != nil))
    func directAuthorizationProcessCrashChild() async throws {
        let specURL = URL(fileURLWithPath: try #require(Environment.get("IMV2_AUTHORIZATION_CRASH_SPEC")))
        let spec = try JSONDecoder().decode(DirectAuthorizationCrashSpec.self, from: Data(contentsOf: specURL))
        let mode = try #require(Environment.get("IMV2_AUTHORIZATION_CRASH_MODE"))
        let primary = try #require(Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"))
        let secondary = try #require(Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"))
        try #require(Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" && primary != secondary)
        try #require(!spec.rooms.isEmpty && spec.rooms.count == spec.operations.count)
        let resources = makeV2DatabaseTestResources()
        do {
            let ownerID = DatabaseID(string: "crash-owner"), reservationID = DatabaseID(string: "crash-reservation")
            resources.databases.use(try .postgres(url: primary, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            resources.databases.use(try .postgres(url: primary, maxConnectionsPerEventLoop: 1), as: reservationID)
            resources.databases.use(try .postgres(url: secondary, maxConnectionsPerEventLoop: 4), as: ownerID)
            let control = resources.database(.psql), owner = resources.database(ownerID)
            let initial = Date(timeIntervalSince1970: 1_750_000_000)
            if mode == "recover" {
                let result = try await V2DirectAuthorizationCoordinator(controlDatabase: control, ownerDatabases: ["room-b": owner]).recover(limit: 8, now: initial.addingTimeInterval(31))
                try JSONEncoder().encode(["claimed": result.claimed, "resolved": result.resolved, "deferred": result.deferred]).write(to: specURL.appendingPathExtension("report"))
            }
            let now = mode == "recover" ? initial.addingTimeInterval(32) : initial
            let writer = PostgresV2RoomWriteStore(database: owner,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled,
                shardAdmissionCommandCreditPool: .init(database: owner, batchSize: 2))
                .usingControlDatabase(resources.database(reservationID), authorizationResolutionDatabase: control)
            let profile = try forwardImportTestProfile()
            if spec.kind == "forward" {
                let export = try V2ForwardExport(payload: #require(spec.payload), digest: #require(spec.digest))
                guard case .accepted = try await writer.importForwardExport(export, capacityProfile: profile,
                    limits: .init(maxUTF8Bytes: 64), identifiers: V2AcceptanceIDFactory().make(at: now), now: now) else { throw CancellationError() }
            } else {
                let requests: [V2RoomWriteRequest] = try spec.operations.indices.map { index in
                    .init(command: try .init(roomID: .init(uuid: spec.rooms[index]), senderUserID: senderID,
                        clientMessageID: .init(uuid: spec.operations[index]), text: "crash authorization", limits: .init(maxUTF8Bytes: 64)),
                        capacityProfile: profile, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
                }
                try #require(requests.count == 1)
                let outcome = try await writer.accept(
                    command: requests[0].command, capacityProfile: profile,
                    identifiers: requests[0].identifiers, now: now
                )
                switch outcome {
                case .accepted, .idempotent: break
                default: throw CancellationError()
                }
            }
            if mode == "crash" {
                try #require(spec.checkpoint == "after-ack")
                try Data("acknowledged".utf8).write(to: specURL.appendingPathExtension("ready"))
                kill(getpid(), SIGKILL); fatalError("SIGKILL must terminate the child")
            }
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }

    private func authorizationCrashProcess(specURL: URL, mode: String, log: URL) throws -> (Process, FileHandle) {
        let process = Process(), host = URL(fileURLWithPath: CommandLine.arguments[0])
        let binary = try #require(Bundle(for: GroupJoinQuotaCrashBundleMarker.self).executableURL)
        try #require(host.lastPathComponent == "swiftpm-testing-helper")
        process.executableURL = host
        process.arguments = ["--test-bundle-path", binary.path, binary.path, "--testing-library", "swift-testing", "--filter", "directAuthorizationProcessCrashChild"]
        var environment = ProcessInfo.processInfo.environment
        environment["IMV2_AUTHORIZATION_CRASH_SPEC"] = specURL.path
        environment["IMV2_AUTHORIZATION_CRASH_MODE"] = mode
        process.environment = environment
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        process.standardOutput = output; process.standardError = output
        return (process, output)
    }

    private func waitAuthorizationCrashProcess(_ process: Process) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    @Test("control connection loss must not allow an owner append after revocation",
          .timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func directControlConnectionLoss(warm: Bool, isForward: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { _, _, _, _, _ in
            let report = FileManager.default.temporaryDirectory.appending(path: "imv2-control-loss-\(UUID()).json")
            let childLog = report.deletingPathExtension().appendingPathExtension("log")
            FileManager.default.createFile(atPath: childLog.path, contents: nil)
            let output = try FileHandle(forWritingTo: childLog)
            defer { try? output.close() }
            let binary = try #require(Bundle(for: GroupJoinQuotaCrashBundleMarker.self).executableURL)
            let host = URL(fileURLWithPath: CommandLine.arguments[0])
            try #require(host.lastPathComponent == "swiftpm-testing-helper")
            let process = Process()
            process.executableURL = host
            process.arguments = ["--test-bundle-path", binary.path, binary.path, "--testing-library", "swift-testing",
                "--filter", "directControlConnectionLossChild"]
            var environment = ProcessInfo.processInfo.environment
            environment["IMV2_DIRECT_CONTROL_FAULT_CHILD"] = "1"
            environment["IMV2_DIRECT_CONTROL_FAULT_WARM"] = warm ? "1" : "0"
            environment["IMV2_DIRECT_CONTROL_FAULT_FORWARD"] = isForward ? "1" : "0"
            environment["IMV2_DIRECT_CONTROL_FAULT_REPORT"] = report.path
            process.environment = environment
            process.standardOutput = output
            process.standardError = output
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled && process.isRunning { process.terminate() }
            }
            defer { watchdog.cancel() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
            try #require(process.terminationStatus == 0)
            let values = try JSONDecoder().decode([String: Int64].self, from: Data(contentsOf: report))
            print("Control-loss probe report: \(report.path); warm=\(warm); forward=\(isForward); observation=\(values)")
            #expect(values["controlBlocks"] == 1)
            #expect(values["blocksWhileOwnerHeld"] == 0)
            #expect(values["ownerAtRevocation"] == 1)
            #expect(values["ownerCommitted"] == 1)
            #expect(values["callbackSettled"] == 1)
        }
    }

    @Test("isolated control connection loss probe",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_DIRECT_CONTROL_FAULT_CHILD"] == "1"))
    func directControlConnectionLossChild() async throws {
        let report = try #require(Environment.get("IMV2_DIRECT_CONTROL_FAULT_REPORT"))
        let primary = try #require(Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"))
        let secondary = try #require(Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"))
        try #require(Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" && primary != secondary)
        let resources = makeV2DatabaseTestResources()
        let ownerID = DatabaseID(string: "fault-owner")
        resources.databases.use(try .postgres(url: primary, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
        resources.databases.use(try .postgres(url: secondary, maxConnectionsPerEventLoop: 4), as: ownerID)
        let reservationID = DatabaseID(string: "fault-reservation")
        resources.databases.use(try .postgres(url: primary, maxConnectionsPerEventLoop: 1), as: reservationID)
        let reservation = resources.database(reservationID)
        let reservationSQL = try #require(reservation as? any SQLDatabase)
        let backend = try #require(try await reservationSQL.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: CountRow.self)).value
        let control = resources.database(.psql), owner = resources.database(ownerID)
        let sql = try #require(control as? any SQLDatabase), ownerSQL = try #require(owner as? any SQLDatabase)
        try await runDirectControlLossProbe(control: control, reservation: reservation, backend: backend, owner: owner, sql: sql, ownerSQL: ownerSQL,
            warm: Environment.get("IMV2_DIRECT_CONTROL_FAULT_WARM") == "1",
            isForward: Environment.get("IMV2_DIRECT_CONTROL_FAULT_FORWARD") == "1", reportPath: report)
    }

    private func runDirectControlLossProbe(control: any Database, reservation: any Database, backend: Int64, owner: any Database,
        sql: any SQLDatabase, ownerSQL: any SQLDatabase, warm: Bool, isForward: Bool, reportPath: String
    ) async throws {
            let now = Date(timeIntervalSince1970: 1_750_000_000), profile = try forwardImportTestProfile()
            let recipient = UserID(uuid: memberTwoUUID)
            let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner, identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: profile, roomShardID: "room-b", now: { now })
            let room = try await direct.openedIdentity(actorUserID: senderID,
                operationID: .init(uuid: UUID()), targetUserID: recipient, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let writer = PostgresV2RoomWriteStore(database: owner,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
                contentReviewMode: .disabled,
                shardAdmissionCommandCreditPool: warm ? .init(database: owner, batchSize: 2) : nil)
                .usingControlDatabase(reservation, authorizationResolutionDatabase: control)
            let service = V2SendMessageService(store: writer, capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64), now: { now })
            if warm {
                for _ in 0..<2 {
                    guard case .accepted = try await service.send(.init(roomID: room.roomID, actorUserID: senderID,
                        clientMessageID: .init(uuid: UUID()), text: "warm")) else { throw CancellationError() }
                }
            }
            let forward: V2ForwardExport?
            if isForward {
                let source = V2SendMessageService(store: PostgresV2RoomWriteStore(database: control), capacityProfile: profile,
                    limits: try .init(maxUTF8Bytes: 64), now: { now })
                guard case .accepted(let message) = try await source.send(.init(roomID: roomID, actorUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "forward connection loss")) else { throw CancellationError() }
                let export = try await PostgresV2ForwardExportStore(database: control).prepare(actorUserID: senderID,
                    operationID: .init(uuid: UUID()), source: .init(roomID: roomID, messageID: message.messageID, revision: .init(1)),
                    sourceRoute: .init(shardID: "room-a", epoch: 0), targetRoomID: room.roomID,
                    targetRoute: .init(shardID: "room-b", epoch: 0), now: now)
                // Receive before holding the owner room. This metadata step is
                // not acceptance; the formal import must still reserve its grant.
                try await PostgresV2ForwardInboxStore(database: owner).receive(export, now: now)
                forward = export
            } else { forward = nil }
            let operation = ClientMessageID(uuid: forward?.intent.targetClientMessageID ?? UUID())
            let gate = PostgreSQLTransactionGate()
            let holder = Task {
                try await owner.transaction { transaction in
                    let heldSQL = try #require(transaction as? any SQLDatabase)
                    try await heldSQL.raw("SELECT room_id FROM im_v2.rooms WHERE room_id = \(bind: room.roomID.uuidValue!) FOR UPDATE").run()
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()
            let settled = Mutex(false)
            let pending = Task {
                defer { settled.withLock { $0 = true } }
                if let forward {
                    guard case .accepted = try await writer.importForwardExport(forward, capacityProfile: profile,
                        limits: .init(maxUTF8Bytes: 64), identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
                    else { return false }
                } else {
                    guard case .accepted = try await service.send(.init(roomID: room.roomID, actorUserID: senderID,
                        clientMessageID: operation, text: "must not commit after lost authority")) else { return false }
                }
                return true
            }
            do {
                var waiting = false
                for _ in 0..<500 {
                    let count = try await ownerSQL.raw("""
                        SELECT count(*) AS value FROM pg_stat_activity WHERE datname = current_database()
                        AND wait_event_type = 'Lock'
                        AND (query LIKE '%SELECT room_id, room_shard_id, owner_epoch%'
                            OR query LIKE '%SELECT room_shard_id, owner_epoch%')
                        """).first(decoding: CountRow.self)?.value ?? 0
                    if count > 0 { waiting = true; break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(waiting)
                // Only this test-owned, one-connection reservation pool is
                // terminated. Its grant must already be committed while owner
                // acceptance is waiting for the room lock.
                try #require(try await sql.raw("SELECT count(*) AS value FROM im_v2.direct_authorization_intents WHERE client_message_id = \(bind: operation.uuidValue!) AND disposition IS NULL").first(decoding: CountRow.self)?.value == 1)
                struct Terminated: Decodable { let value: Bool }
                try #require(try await sql.raw("SELECT pg_terminate_backend(\(bind: backend)::int4) AS value")
                    .first(decoding: Terminated.self)?.value == true)
                let revocation = Task {
                    _ = try await PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(),
                        authorizationCoordinator: .init(controlDatabase: control, ownerDatabases: ["room-b": owner]))
                        .executeSocialFixture(actorUserID: recipient, targetUserID: senderID, operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now:  now)
                    return try await ownerSQL.raw("SELECT count(*) AS value FROM im_v2.messages WHERE client_message_id = \(bind: operation.uuidValue!)")
                        .first(decoding: CountRow.self)?.value ?? -1
                }
                var revocationWaiting = false
                for _ in 0..<500 {
                    let count = try await ownerSQL.raw("""
                        SELECT count(*) AS value FROM pg_stat_activity WHERE datname = current_database()
                        AND wait_event_type = 'Lock' AND query LIKE '%pg_advisory_xact_lock(%'
                        """).first(decoding: CountRow.self)?.value ?? 0
                    if count > 0 { revocationWaiting = true; break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(revocationWaiting)
                let blocksWhileHeld = try await count("im_v2.user_blocks", on: sql)
                try #require(blocksWhileHeld == 0)
                try #require(try await ownerSQL.raw("SELECT count(*) AS value FROM im_v2.messages WHERE client_message_id = \(bind: operation.uuidValue!)")
                    .first(decoding: CountRow.self)?.value == 0)
                await gate.releaseTransaction()
                try await holder.value
                try #require(try await pending.value)
                let ownerAtRevocation = try await revocation.value
                let committed = try await ownerSQL.raw("SELECT count(*) AS value FROM im_v2.messages WHERE client_message_id = \(bind: operation.uuidValue!)")
                    .first(decoding: CountRow.self)?.value ?? -1
                guard case .denied = try await service.send(.init(roomID: room.roomID, actorUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "new request sees block")) else { throw CancellationError() }
                if let forward {
                    // Terminal replay after revocation cannot reserve a new
                    // generation or create a second forwarded message.
                    guard case .accepted = try await writer.importForwardExport(forward, capacityProfile: profile,
                        limits: .init(maxUTF8Bytes: 1), identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
                    else { throw CancellationError() }
                    try #require(try await sql.raw("SELECT count(*) AS value FROM im_v2.direct_authorization_intents WHERE client_message_id = \(bind: operation.uuidValue!) AND generation = 1 AND disposition = 'accepted'").first(decoding: CountRow.self)?.value == 1)
                    try #require(try await ownerSQL.raw("SELECT count(*) AS value FROM im_v2.messages WHERE client_message_id = \(bind: operation.uuidValue!)").first(decoding: CountRow.self)?.value == 1)
                }
                let report: [String: Int64] = ["ownerCommitted": committed,
                    "blocksWhileOwnerHeld": blocksWhileHeld, "ownerAtRevocation": ownerAtRevocation,
                    "controlBlocks": try await count("im_v2.user_blocks", on: sql),
                    "callbackSettled": settled.withLock { $0 } ? 1 : 0]
                try JSONEncoder().encode(report).write(to: URL(fileURLWithPath: reportPath), options: .atomic)
                // This process owns no fixture cleanup. The parent waits for
                // exit, records the evidence and drops its disposable schemas.
                // Do not await a driver callback whose connection was killed.
                Darwin._exit(0)
            } catch {
                pending.cancel()
                await gate.releaseTransaction()
                _ = await holder.result
                throw error
            }
    }
    #endif


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
                let now = Date(timeIntervalSince1970: 1_750_000_000), profile = try forwardImportTestProfile()
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
                let write = PostgresV2RoomWriteStore(database: owner).usingControlDatabase(control)
                // The live Actor path grants a room turn before this writer runs;
                // this regression targets its owner/control database authority.
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
                _ = try await PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery())
                    .executeSocialFixture(actorUserID: recipient, targetUserID: senderID, operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now:  now)
                guard case .denied = try await service.send(.init(roomID: room.roomID, actorUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "blocked")) else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
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
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, _, ownerSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000), profile = try forwardImportTestProfile()
            let limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let actor = UserID(uuid: memberTwoUUID), recipient = UserID(uuid: memberThreeUUID)
            let sourceSend = V2SendMessageService(store: PostgresV2RoomWriteStore(database: control).usingControlDatabase(control),
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
            let write = PostgresV2RoomWriteStore(database: owner).usingControlDatabase(control).usingWorkloadDatabase(owner)
            @Sendable func receive(_ value: V2ForwardExport) async throws -> V2ForwardImportOutcome {
                try await write.importForwardExport(value, capacityProfile: profile, limits: limits,
                    identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
            }
            let original = try await prepare(), accepted = try await receive(original)
            guard case .accepted = accepted else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let social = PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery())
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

    @Test("real policy writers drain durable direct grants before revocation", arguments:
        ["block", "relationship", "preference", "disable"], ["configured", "missing", "unreachable"])
    func directDurablePolicyWriters(kind: String, mode: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000), profile = try forwardImportTestProfile()
            let recipient = UserID(uuid: memberTwoUUID)
            for database in [control, owner] {
                let social = PostgresV2SocialRelationshipStore(database: database, projectionDelivery: SuccessfulProjectionDelivery())
                _ = try await social.executeSocialFixture(actorUserID: senderID, targetUserID: recipient, operation: .relationship(.init(uuid: UUID())), action: .relationship(.request), now:  now)
                _ = try await social.executeSocialFixture(actorUserID: recipient, targetUserID: senderID, operation: .relationship(.init(uuid: UUID())), action: .relationship(.accept), now:  now)
            }
            let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner, identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()), capacityProfile: profile, roomShardID: "room-b", now: { now })
            let room = try await direct.openedIdentity(actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: recipient, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let command = try V2SendMessageCommand(roomID: room.roomID, senderUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "before revocation", limits: .init(maxUTF8Bytes: 64))
            let grant = try await directAuthorizationGrant(command, recipient: recipient, control: control, now: now)
            let writer = try PostgresV2RoomWriteStore(database: owner).usingAuthorizationGrants([grant], now: now)
            let intents = PostgresV2DirectAuthorizationIntentStore(database: control)
            let coordinator = V2DirectAuthorizationCoordinator(controlDatabase: control, ownerDatabases: ["room-b": owner])
            let unavailable = V2DirectAuthorizationCoordinator(controlDatabase: control, ownerDatabases: [:])
            let operationID = UUID()
            let originalSocial: V2SocialOperationCommand?
            if kind == "block" || kind == "relationship" {
                originalSocial = try await PostgresV2SocialRelationshipStore(database: control,
                    projectionDelivery: SuccessfulProjectionDelivery()).freezeSocialFixture(
                        actorUserID: recipient, targetUserID: senderID,
                        operation: kind == "block" ? .userBlock(.init(uuid: operationID)) : .relationship(.init(uuid: operationID)),
                        action: kind == "block" ? .userBlock(.block) : .relationship(.remove), now: now)
            } else { originalSocial = nil }
            let originalPreference: V2AccountPreferenceCommand?
            if kind == "preference" {
                originalPreference = try await PostgresV2AccountPreferenceOperationStore(database: control,
                    projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator: coordinator)
                    .freezePreferenceFixture(owner: recipient, operation: .strangerMessagePreference(.init(uuid: operationID)),
                        value: .strangerMessage(.deny), now: now)
            } else { originalPreference = nil }
            @Sendable func revoke(_ handler: V2DirectAuthorizationCoordinator?) async throws {
                switch kind {
                case "block", "relationship":
                    _ = try await PostgresV2SocialRelationshipStore(database: control,
                        projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator: handler)
                        .submitSocialOperation(try #require(originalSocial), now: now)
                case "preference":
                    _ = try await PostgresV2AccountPreferenceOperationStore(database: control,
                        projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator: handler ?? unavailable)
                        .submit(try #require(originalPreference), now: now)
                default:
                    _ = try await V2PostgresAccountDisableService(database: control, operatorPrincipal: "authorization-test", authorizationCoordinator: handler, now: { now })
                        .disable(.init(userID: recipient, operationID: operationID, reason: .userRequested))
                }
            }
            @Sendable func send() async throws -> V2SendMessageOutcome {
                try await writer.accept(command: command, capacityProfile: profile, identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
            }
            if mode == "configured" {
                try await revoke(coordinator)
                await #expect(throws: V2DirectAuthorizationReceiptError.attemptAborted) { try await send() }
                #expect(try await count("im_v2.messages", on: ownerSQL) == 0)
            } else {
                if kind == "disable" {
                    await #expect(throws: V2AccountDisableError.unavailable) {
                        try await revoke(mode == "missing" ? nil : unavailable)
                    }
                } else {
                    await #expect(throws: V2DirectAuthorizationCoordinationError.ownerUnavailable) {
                        try await revoke(mode == "missing" ? nil : unavailable)
                    }
                }
                for table in ["user_blocks", "user_stranger_message_preferences", "account_disables"] {
                    #expect(try await count("im_v2." + table, on: sql) == 0)
                }
                #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.user_relationships WHERE state = 'accepted'").first(decoding: CountRow.self)?.value == 1)
                #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.direct_authorization_intents WHERE disposition IS NULL").first(decoding: CountRow.self)?.value == 1)
                // A failed revocation has not changed policy. If this request
                // commits now, the retry must acknowledge its accepted proof.
                guard case .accepted = try await send() else { throw CancellationError() }
                try await revoke(coordinator)
                guard case .idempotent = try await send() else { throw CancellationError() }
                #expect(try await count("im_v2.messages", on: ownerSQL) == 1)
            }
            #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.direct_authorization_intents WHERE disposition IS NULL").first(decoding: CountRow.self)?.value == 0)
            let freshCommand = try V2SendMessageCommand(roomID: room.roomID, senderUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "new policy", limits: .init(maxUTF8Bytes: 64))
            let fresh = try await directAuthorizationGrant(freshCommand, recipient: recipient, control: control, now: now)
            switch kind {
            case "block": #expect(fresh.policy.blocked)
            case "relationship": #expect(!fresh.policy.isFriend)
            case "preference": #expect(!fresh.policy.allowsStrangers)
            default: #expect(!fresh.policy.recipient.isActive)
            }
            // Exact policy operation replay is read-only and must not cancel
            // a later authorization just because its caller retried the reply.
            try await revoke(coordinator)
            let held = try await control.transaction { transaction in
                try await intents.held(in: .user(memberTwoUUID), limit: 10, transaction: transaction)
            }
            #expect(held.count == 1 && held.first?.attempt == fresh.attempt)
        }
    }

    @Test("automatic authorization ACK failure retains committed messages and consumed credits", arguments: [false, true])
    func directAutomaticAuthorizationAcknowledgementFailure(warm: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000), profile = try forwardImportTestProfile()
            let recipient = UserID(uuid: memberTwoUUID)
            let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner, identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: profile, roomShardID: "room-b", now: { now })
            let room = try await direct.openedIdentity(actorUserID: senderID,
                operationID: .init(uuid: UUID()), targetUserID: recipient, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let credits = V2ShardAdmissionCommandCreditPool(database: owner, batchSize: 2)
            let cache = V2DirectRoomLogFastAppendCache()
            let writer = PostgresV2RoomWriteStore(database: owner,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
                contentReviewMode: .disabled,
                directRoomLogFastAppendCache: cache, shardAdmissionCommandCreditPool: credits)
                .usingControlDatabase(control, authorizationResolutionDatabase: control)
            func command(_ id: ClientMessageID = .init(uuid: UUID()), text: String = "automatic grant") throws -> V2SendMessageCommand {
                try .init(roomID: room.roomID, senderUserID: senderID, clientMessageID: id, text: text, limits: .init(maxUTF8Bytes: 64))
            }
            @Sendable func send(_ command: V2SendMessageCommand) async throws -> V2SendMessageOutcome {
                try await writer.accept(command: command, capacityProfile: profile, identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
            }
            if warm { for _ in 0..<2 { guard case .accepted = try await send(command()) else { throw CancellationError() } } }
            @Sendable func consumed() async throws -> Int64 {
                let used = try #require(try await ownerSQL.raw("SELECT command_window_used AS value FROM im_v2.shard_admission_pools WHERE room_shard_id = 'room-b'").first(decoding: CountRow.self)).value
                let local = await credits.snapshot()
                return used - Int64(local.activeCredits) - Int64(local.inFlightCredits)
            }
            let input = try command(), before = await credits.snapshot(), cacheBefore = await cache.snapshot()
            let consumedBefore = try await consumed()
            try await sql.raw("ALTER TABLE im_v2.direct_authorization_intents ADD CONSTRAINT test_reject_ack CHECK (disposition IS NULL) NOT VALID").run()
            await #expect(throws: V2DirectAuthorizationCoordinationError.ownerUnavailable) { try await send(input) }
            let after = await credits.snapshot()
            #expect(after.committedCredits == before.committedCredits + (warm ? 1 : 0))
            #expect(try await consumed() == consumedBefore + 1)
            #expect(after.inFlightCredits == 0)
            if warm { #expect(await cache.snapshot().committedAppends == cacheBefore.committedAppends + 1) }
            #expect(try await ownerSQL.raw("SELECT count(*) AS value FROM im_v2.messages WHERE client_message_id = \(bind: input.clientMessageID.uuidValue!)").first(decoding: CountRow.self)?.value == 1)
            #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.direct_authorization_intents WHERE disposition IS NULL").first(decoding: CountRow.self)?.value == 1)
            try await sql.raw("ALTER TABLE im_v2.direct_authorization_intents DROP CONSTRAINT test_reject_ack").run()
            guard case .idempotent = try await send(input) else { throw CancellationError() }
            #expect(await credits.snapshot().committedCredits == after.committedCredits)
            #expect(await credits.snapshot().inFlightCredits == 0)
            #expect(try await consumed() == consumedBefore + 1)
            #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.direct_authorization_intents WHERE disposition IS NULL").first(decoding: CountRow.self)?.value == 0)
            guard case .idempotencyConflict = try await send(command(input.clientMessageID, text: "changed")) else { throw CancellationError() }
            #expect(await credits.snapshot().committedCredits == after.committedCredits)
            #expect(await credits.snapshot().inFlightCredits == 0)
            #expect(try await consumed() == consumedBefore + 1)
        }
    }

    @Test("formal direct acceptance persists authorization proof atomically", arguments:
        ["accepted", "denied", "aborted", "proof-failure"], [false, true])
    func directDurableOwnerAcceptance(kind: String, warm: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, _, ownerSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000), profile = try forwardImportTestProfile()
            let recipient = UserID(uuid: memberTwoUUID)
            let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner, identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: profile, roomShardID: "room-b", now: { now })
            let room = try await direct.openedIdentity(actorUserID: senderID,
                operationID: .init(uuid: UUID()), targetUserID: recipient, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let cache = V2DirectRoomLogFastAppendCache()
            let base = PostgresV2RoomWriteStore(database: owner,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
                contentReviewMode: .disabled,
                directRoomLogFastAppendCache: cache,
                shardAdmissionCommandCreditPool: warm ? .init(database: owner, batchSize: 2) : nil)
                .usingControlDatabase(control)
            func command() throws -> V2SendMessageCommand {
                try .init(roomID: room.roomID, senderUserID: senderID, clientMessageID: .init(uuid: UUID()),
                    text: "durable owner", limits: .init(maxUTF8Bytes: 64))
            }
            if warm {
                for _ in 0..<2 {
                    guard case .accepted = try await base.accept(command: command(), capacityProfile: profile,
                        identifiers: V2AcceptanceIDFactory().make(at: now), now: now) else { throw CancellationError() }
                }
            }
            if kind == "denied" {
                _ = try await PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery())
                    .executeSocialFixture(actorUserID: recipient, targetUserID: senderID, operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now:  now)
            }
            let input = try command()
            let grant = try await directAuthorizationGrant(input, recipient: recipient, control: control, now: now)
            let writer = try base.usingAuthorizationGrants([grant], now: now)
            let before = try await count("im_v2.messages", on: ownerSQL)
            let beforeSequence = try #require(try await ownerSQL.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id = \(bind: room.roomID.uuidValue!)").first(decoding: CountRow.self)).value
            @Sendable func send(_ store: PostgresV2RoomWriteStore) async throws -> V2SendMessageOutcome {
                try await store.acceptOwnerValidated(request: .init(command: input, capacityProfile: profile,
                    identifiers: V2AcceptanceIDFactory().make(at: now), now: now), ownerRoute: .init(shardID: "room-b", epoch: 0))
            }
            if kind == "aborted" {
                let aborted = try await PostgresV2DirectAuthorizationReceiptStore().abort(grant.attempt, now: now, database: owner)
                await #expect(throws: V2DirectAuthorizationReceiptError.attemptAborted) { try await send(writer) }
                #expect(try await count("im_v2.messages", on: ownerSQL) == before)
                #expect(try await ownerSQL.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id = \(bind: room.roomID.uuidValue!)").first(decoding: CountRow.self)?.value == beforeSequence)
                try await PostgresV2DirectAuthorizationIntentStore(database: control).resolve(grant.attempt, receipt: aborted, now: now)
                let renewed = try await directAuthorizationGrant(input, recipient: recipient, control: control, now: now)
                #expect(renewed.attempt.generation == 2)
                guard case .accepted = try await send(base.usingAuthorizationGrants([renewed], now: now)) else { throw CancellationError() }
                await #expect(throws: V2DirectAuthorizationReceiptError.attemptAborted) { try await send(writer) }
                #expect(try await count("im_v2.messages", on: ownerSQL) == before + 1)
                return
            }
            if kind == "proof-failure" {
                try await ownerSQL.raw("ALTER TABLE im_v2.direct_authorization_receipts ADD CONSTRAINT test_reject_proof CHECK (false) NOT VALID").run()
                await #expect(throws: (any Error).self) { try await send(writer) }
                #expect(try await count("im_v2.messages", on: ownerSQL) == before)
                #expect(try await ownerSQL.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id = \(bind: room.roomID.uuidValue!)").first(decoding: CountRow.self)?.value == beforeSequence)
                #expect(try await count("im_v2.direct_authorization_receipts", on: ownerSQL) == (warm ? 2 : 0))
                try await ownerSQL.raw("ALTER TABLE im_v2.direct_authorization_receipts DROP CONSTRAINT test_reject_proof").run()
            }
            let result = try await send(writer)
            if kind == "denied" {
                guard case .denied = result else { throw CancellationError() }
                #expect(try await count("im_v2.messages", on: ownerSQL) == before)
            } else {
                guard case .accepted = result else { throw CancellationError() }
                #expect(try await count("im_v2.messages", on: ownerSQL) == before + 1)
                if warm { #expect(await cache.snapshot().committedAppends > 0) }
            }
            let disposition = try await ownerSQL.raw("SELECT disposition AS value FROM im_v2.direct_authorization_receipts WHERE client_message_id = \(bind: input.clientMessageID.uuidValue!)")
                .first(decoding: StringValueRow.self)?.value
            #expect(disposition == (kind == "denied" ? "denied" : "accepted"))
            let replay = try await send(writer)
            if kind == "denied" { #expect(replay == result) }
            else { guard case .idempotent = replay else { throw CancellationError() }; #expect(replay.acceptanceReceipt == result.acceptanceReceipt) }
            #expect(try await count("im_v2.direct_authorization_receipts", on: ownerSQL) == (warm ? 3 : 1))
        }
    }

    @Test("atomic warm direct authorization abort rolls back every message", arguments: [false, true])
    func directDurableOwnerBatch(abortFirst: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, _, ownerSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 100, retryAfterSeconds: 3))
            try await ownerSQL.raw("UPDATE im_v2.shard_admission_pools SET command_window_limit = 100").run()
            let recipients = [UserID(uuid: memberTwoUUID), UserID(uuid: memberThreeUUID)]
            let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner, identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()), capacityProfile: profile, roomShardID: "room-b", now: { now })
            let cache = V2DirectRoomLogFastAppendCache()
            let base = PostgresV2RoomWriteStore(database: owner,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 20, window: 86_400), contentReviewMode: .disabled,
                directRoomLogFastAppendCache: cache,
                shardAdmissionCommandCreditPool: .init(database: owner, batchSize: 2)).usingControlDatabase(control)
            var requests: [V2RoomWriteRequest] = [], grants: [V2DirectAuthorizationGrant] = []
            for recipient in recipients {
                let room = try await direct.openedIdentity(actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: recipient, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                let warmCommand = try V2SendMessageCommand(roomID: room.roomID, senderUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "warm", limits: .init(maxUTF8Bytes: 64))
                guard case .accepted = try await base.accept(command: warmCommand, capacityProfile: profile,
                    identifiers: V2AcceptanceIDFactory().make(at: now), now: now) else { throw CancellationError() }
                let command = try V2SendMessageCommand(roomID: room.roomID, senderUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "durable batch", limits: .init(maxUTF8Bytes: 64))
                requests.append(.init(command: command, capacityProfile: profile, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now))
                grants.append(try await directAuthorizationGrant(command, recipient: recipient, control: control, now: now))
            }
            let batch = requests, initial = grants
            let target = abortFirst ? 0 : 1
            let aborted = try await PostgresV2DirectAuthorizationReceiptStore().abort(initial[target].attempt, now: now, database: owner)
            let before = try await count("im_v2.messages", on: ownerSQL)
            await #expect(throws: V2DirectAuthorizationReceiptError.attemptAborted) {
                try await base.usingAuthorizationGrants(initial, now: now).acceptAtomically(requests: batch)
            }
            #expect(try await count("im_v2.messages", on: ownerSQL) == before)
            #expect(try await count("im_v2.direct_authorization_receipts", on: ownerSQL) == 3)
            try await PostgresV2DirectAuthorizationIntentStore(database: control).resolve(initial[target].attempt, receipt: aborted, now: now)
            grants[target] = try await directAuthorizationGrant(batch[target].command, recipient: recipients[target], control: control, now: now)
            let outcomes = try await base.usingAuthorizationGrants(grants, now: now).acceptAtomically(requests: batch)
            #expect(outcomes.count == 2 && outcomes.allSatisfy { if case .accepted = $0 { true } else { false } })
            #expect(try await count("im_v2.messages", on: ownerSQL) == before + 2)
            #expect(try await count("im_v2.direct_authorization_receipts", on: ownerSQL) == 5)
            #expect(await cache.snapshot().committedAppends == 2)
        }
    }

    @Test("forward entry reserves only ready commands and recovers terminal authorization", arguments:
        ["accepted", "denied", "invalid", "ack-accepted", "ack-denied", "finalization", "admission", "revoked", "media-window"], [false, true])
    func directForwardAutomaticAuthorization(scenario: String, hasMedia: Bool) async throws {
        let useMedia = hasMedia || scenario == "media-window"
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000), profile = try forwardImportTestProfile()
            let limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let actor = UserID(uuid: memberTwoUUID), recipient = UserID(uuid: memberThreeUUID)
            let root = FileManager.default.temporaryDirectory.appending(path: "forward-auth-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let transferClock = TestSequenceClock([now])
            let binding = try V2StorageBinding(id: "forward-authorization", configurationRevision: 1)
            let storage = try V2LocalResourceStorage(root: root.appending(path: "objects"), binding: binding)
            let registry = try V2ResourceStorageRegistry(storages: [storage], defaultBinding: binding)
            var media: [V2MediaReference] = []
            if useMedia {
                let id = MediaID(uuid: UUID()), bytes = Data("authorization media".utf8)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let input = root.appending(path: "source-input")
                try bytes.write(to: input)
                let facts = try await storage.write(storage.allocate(), byteCount: Int64(bytes.count),
                    sha256: Data(SHA256.hash(data: bytes)), bytes: V2LocalResourceStorage.stream(file: input))
                try FileManager.default.removeItem(at: input)
                try await sql.raw("""
                    INSERT INTO im_v2.media_objects (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at)
                    VALUES (\(bind: id.uuidValue!), \(bind: senderUUID), 'application/octet-stream', \(bind: Int64(bytes.count)), 'available', \(bind: UUID()), \(bind: now.addingTimeInterval(600)), \(bind: now), \(bind: now))
                    """).run()
                try await sql.raw("INSERT INTO im_v2.resource_catalog(media_id,home_kind,home_id,usage_kind,created_at) VALUES(\(bind:id.uuidValue!),'room',\(bind:roomID.uuidValue!),'message_attachment',\(bind:now))").run()
                let referenceJSON = String(decoding: try JSONEncoder().encode(facts.reference), as: UTF8.self)
                try await sql.raw("""
                    INSERT INTO im_v2.resource_blob_placements(placement_id,media_id,generation,reference_json,byte_count,sha256,state,verified_at)
                    VALUES(\(bind:facts.reference.placementID),\(bind:id.uuidValue!),1,\(bind:referenceJSON)::jsonb,\(bind:facts.byteCount),\(bind:facts.sha256),'active',\(bind:now))
                    """).run()
                media = [.init(mediaID: id)]
            }
            let source = V2SendMessageService(store: PostgresV2RoomWriteStore(database: control), capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let original) = try await source.send(.init(roomID: roomID, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "durable forward", media: media)) else { throw CancellationError() }
            let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner, identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()), capacityProfile: profile, roomShardID: "room-b", now: { now })
            let room = try await direct.openedIdentity(actorUserID: actor, operationID: .init(uuid: UUID()), targetUserID: recipient, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let export = try await PostgresV2ForwardExportStore(database: control).prepare(actorUserID: actor, operationID: .init(uuid: UUID()),
                source: .init(roomID: roomID, messageID: original.messageID, revision: .init(1)), sourceRoute: .init(shardID: "room-a", epoch: 0),
                targetRoomID: room.roomID, targetRoute: .init(shardID: "room-b", epoch: 0), now: now)
            let writer = PostgresV2RoomWriteStore(database: owner).usingControlDatabase(control, authorizationResolutionDatabase: control).usingWorkloadDatabase(owner)
            @Sendable func deliver(_ maxBytes: Int = 64) async throws -> V2ForwardImportOutcome {
                try await writer.importForwardExport(export, capacityProfile: profile, limits: .init(maxUTF8Bytes: maxBytes),
                    identifiers: V2AcceptanceIDFactory().make(at: transferClock.now()), now: transferClock.now())
            }
            if useMedia {
                #expect(try await deliver() == .pending(.media))
                #expect(try await count("im_v2.direct_authorization_intents", on: sql) == 0)
                #expect(try await count("im_v2.direct_authorization_receipts", on: ownerSQL) == 0)
            }
            let denied = scenario == "denied" || scenario == "ack-denied" || scenario == "revoked"
            if denied && scenario != "revoked" {
                _ = try await PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(),
                    authorizationCoordinator: .init(controlDatabase: control, ownerDatabases: ["room-b": owner]))
                    .executeSocialFixture(actorUserID: recipient, targetUserID: actor, operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now:  now)
            }
            if useMedia {
                let importer = try PostgresV2ForwardMediaImportStore(database: owner)
                let copier = try V2ResourceForwardMediaCopier(sources: ["room-a": control], target: importer,
                    registry: registry, maximumBytes: 1024, allocate: { _ in try storage.allocate() }, now: { transferClock.now() })
                let worker = try V2ForwardMediaImportWorker(store: importer, copier: copier,
                    scanner: V2PlacementMediaScanner(database: owner, registry: registry, scanner: V2LocalResourceScanner()), now: { transferClock.now() })
                #expect(try await worker.runOnce(exportID: export.intent.exportID) == .ready)
                #expect(try await count("im_v2.direct_authorization_intents", on: sql) == 0)
            }
            if scenario == "media-window" {
                let gate = PostgreSQLTransactionGate()
                let key = "account-state:" + actor.uuidValue!.uuidString
                let holder = Task {
                    try await control.transaction { transaction in
                        let heldSQL = try #require(transaction as? any SQLDatabase)
                        try await heldSQL.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
                        await gate.holdTransaction()
                    }
                }
                await gate.waitUntilHeld()
                let pending = Task { try await deliver() }
                do {
                    var waiting = false
                    for _ in 0..<500 {
                        waiting = try await sql.raw("SELECT count(*) AS value FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE '%pg_advisory_xact_lock_shared%'").first(decoding: CountRow.self)?.value ?? 0 > 0
                        if waiting { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    try #require(waiting)
                    try #require(try await count("im_v2.direct_authorization_intents", on: sql) == 0)
                    // Preflight has committed; the blocked control reservation cannot
                    // protect owner media. Exercise state and timestamp independently.
                    if hasMedia {
                        try await ownerSQL.raw("UPDATE im_v2.media_objects SET state = 'expired' WHERE state = 'available'").run()
                    } else {
                        try await ownerSQL.raw("UPDATE im_v2.media_objects SET expires_at = \(bind: now) WHERE state = 'available'").run()
                    }
                    await gate.releaseTransaction(); try await holder.value
                    await #expect(throws: V2MediaStoreError.mediaUnavailable) { try await pending.value }
                    #expect(try await count("im_v2.messages", on: ownerSQL) == 0)
                    #expect(try await count("im_v2.message_media_references", on: ownerSQL) == 0)
                    #expect(try await count("im_v2.direct_authorization_receipts", on: ownerSQL) == 0)
                    #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.direct_authorization_intents WHERE disposition IS NULL").first(decoding: CountRow.self)?.value == 1)
                    #expect(try await V2DirectAuthorizationCoordinator(controlDatabase: control, ownerDatabases: ["room-b": owner])
                        .recover(limit: 8, now: now.addingTimeInterval(31)) == .init(claimed: 1, resolved: 1, deferred: 0))
                    #expect(try await sql.raw("SELECT disposition AS value FROM im_v2.direct_authorization_intents").first(decoding: StringValueRow.self)?.value == "aborted")
                    #expect(try await ownerSQL.raw("SELECT disposition AS value FROM im_v2.direct_authorization_receipts").first(decoding: StringValueRow.self)?.value == "aborted")
                } catch {
                    await gate.releaseTransaction(); _ = await holder.result
                    _ = await pending.result
                    throw error
                }
                return
            }
            if scenario == "admission" || scenario == "revoked" {
                try await ownerSQL.raw("UPDATE im_v2.room_admission SET command_window_used = command_window_limit WHERE room_id = \(bind: room.roomID.uuidValue!)").run()
                #expect(try await deliver() == .pending(.admission))
                #expect(try await count("im_v2.direct_authorization_receipts", on: ownerSQL) == 0)
                #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.direct_authorization_intents WHERE disposition IS NULL").first(decoding: CountRow.self)?.value == 1)
                if scenario == "revoked" {
                    let grant = try #require(try await PostgresV2DirectAuthorizationIntentStore(database: control)
                        .existing(roomID: room.roomID.uuidValue!, senderID: actor.uuidValue!, clientMessageID: export.intent.targetClientMessageID))
                    _ = try await PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(),
                        authorizationCoordinator: .init(controlDatabase: control, ownerDatabases: ["room-b": owner]))
                        .executeSocialFixture(actorUserID: recipient, targetUserID: actor, operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now:  now)
                    try #require(try await sql.raw("SELECT disposition AS value FROM im_v2.direct_authorization_intents").first(decoding: StringValueRow.self)?.value == "aborted")
                    try #require(try await count("im_v2.user_blocks", on: sql) == 1)
                    // The block drain records its post-lock clock; a subsequent user retry must not go backwards.
                    transferClock.set([now.addingTimeInterval(1)])
                    try await ownerSQL.raw("UPDATE im_v2.room_admission SET command_window_used = 0 WHERE room_id = \(bind: room.roomID.uuidValue!)").run()
                    let stale = try writer.usingAuthorizationGrants([grant], now: transferClock.now())
                    await #expect(throws: V2DirectAuthorizationReceiptError.attemptAborted) {
                        try await stale.importForwardExport(export, capacityProfile: profile, limits: limits,
                            identifiers: V2AcceptanceIDFactory().make(at: transferClock.now()), now: transferClock.now())
                    }
                    #expect(try await count("im_v2.messages", on: ownerSQL) == 0)
                    #expect(try await count("im_v2.message_media_references", on: ownerSQL) == 0)
                }
                try await ownerSQL.raw("UPDATE im_v2.room_admission SET command_window_used = 0 WHERE room_id = \(bind: room.roomID.uuidValue!)").run()
            }
            if scenario == "finalization" {
                try await ownerSQL.raw("ALTER TABLE im_v2.message_forward_inbox ADD CONSTRAINT test_reject_completion CHECK (state <> 'completed') NOT VALID").run()
                await #expect(throws: (any Error).self) { try await deliver() }
                #expect(try await count("im_v2.messages", on: ownerSQL) == 1)
                #expect(try await count("im_v2.direct_authorization_receipts", on: ownerSQL) == 1)
                try await ownerSQL.raw("ALTER TABLE im_v2.message_forward_inbox DROP CONSTRAINT test_reject_completion").run()
            }
            if scenario.hasPrefix("ack-") {
                try await sql.raw("ALTER TABLE im_v2.direct_authorization_intents ADD CONSTRAINT test_reject_forward_ack CHECK (disposition IS NULL) NOT VALID").run()
                await #expect(throws: V2DirectAuthorizationCoordinationError.ownerUnavailable) { try await deliver() }
                #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.direct_authorization_intents WHERE disposition IS NULL").first(decoding: CountRow.self)?.value == 1)
                try await sql.raw("ALTER TABLE im_v2.direct_authorization_intents DROP CONSTRAINT test_reject_forward_ack").run()
                #expect(try await PostgresV2ForwardInboxCompactor(database: owner).runOnce(now: now.addingTimeInterval(PostgresV2ForwardInboxCompactor.retentionSeconds), limit: 1) == 1)
                #expect(try await ownerSQL.raw("SELECT payload IS NULL AS exists FROM im_v2.message_forward_inbox").first(decoding: ExistsRow.self)?.exists == true)
            }
            let result = try await deliver(scenario == "invalid" || scenario == "finalization" ? 1 : 64)
            if scenario == "invalid" { #expect(result == .rejected(code: "INVALID_ARGUMENT")) }
            else if denied { #expect(result == .rejected(code: "DIRECT_MESSAGE_RESTRICTED")) }
            else { guard case .accepted = result else { throw CancellationError() } }
            #expect(try await deliver(1) == result)
            if scenario == "invalid" {
                #expect(try await V2DirectAuthorizationCoordinator(controlDatabase: control, ownerDatabases: ["room-b": owner])
                    .recover(limit: 8, now: now.addingTimeInterval(31)) == .init(claimed: 1, resolved: 1, deferred: 0))
                #expect(try await deliver() == result)
            }
            #expect(try await count("im_v2.messages", on: ownerSQL) == (denied || scenario == "invalid" ? 0 : 1))
            #expect(try await count("im_v2.direct_authorization_intents", on: sql) == 1)
            let expectedGeneration: Int64 = scenario == "revoked" ? 2 : 1
            #expect(try await count("im_v2.direct_authorization_receipts", on: ownerSQL) == expectedGeneration)
            #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.direct_authorization_intents WHERE generation = \(bind: expectedGeneration) AND disposition IS NOT NULL").first(decoding: CountRow.self)?.value == 1)
            if scenario == "revoked" {
                #expect(try await sql.raw("SELECT disposition AS value FROM im_v2.direct_authorization_intents").first(decoding: StringValueRow.self)?.value == "denied")
                #expect(try await count("im_v2.message_media_references", on: ownerSQL) == 0)
            }
            if useMedia && !denied && scenario != "invalid" {
                #expect(try await count("im_v2.message_media_references", on: ownerSQL) == 1)
            }
        }
    }

    @Test("forward import participates in durable authorization", arguments: [false, true])
    func directDurableOwnerForward(abort: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, _, ownerSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000), profile = try forwardImportTestProfile()
            let limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let actor = UserID(uuid: memberTwoUUID), recipient = UserID(uuid: memberThreeUUID)
            let source = V2SendMessageService(store: PostgresV2RoomWriteStore(database: control), capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let message) = try await source.send(.init(roomID: roomID, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "durable forward")) else { throw CancellationError() }
            let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner, identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()), capacityProfile: profile, roomShardID: "room-b", now: { now })
            let room = try await direct.openedIdentity(actorUserID: actor, operationID: .init(uuid: UUID()), targetUserID: recipient, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let export = try await PostgresV2ForwardExportStore(database: control).prepare(actorUserID: actor, operationID: .init(uuid: UUID()),
                source: .init(roomID: roomID, messageID: message.messageID, revision: .init(1)), sourceRoute: .init(shardID: "room-a", epoch: 0),
                targetRoomID: room.roomID, targetRoute: .init(shardID: "room-b", epoch: 0), now: now)
            let command = try ForwardInboxAuthorization(export: export, mediaIDs: []).command(limits: limits)
            let grant = try await directAuthorizationGrant(command, recipient: recipient, control: control, now: now)
            let writer = try PostgresV2RoomWriteStore(database: owner).usingControlDatabase(control)
                .usingAuthorizationGrants([grant], now: now).usingWorkloadDatabase(owner)
            if abort {
                _ = try await PostgresV2DirectAuthorizationReceiptStore().abort(grant.attempt, now: now, database: owner)
                await #expect(throws: V2DirectAuthorizationReceiptError.attemptAborted) {
                    try await writer.importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
                }
                #expect(try await count("im_v2.messages", on: ownerSQL) == 0)
            } else {
                let accepted = try await writer.importForwardExport(export, capacityProfile: profile, limits: limits,
                    identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
                guard case .accepted = accepted else { throw CancellationError() }
                #expect(try await writer.importForwardExport(export, capacityProfile: profile, limits: limits,
                    identifiers: V2AcceptanceIDFactory().make(at: now), now: now) == accepted)
                #expect(try await count("im_v2.messages", on: ownerSQL) == 1)
                #expect(try await ownerSQL.raw("SELECT disposition AS value FROM im_v2.direct_authorization_receipts")
                    .first(decoding: StringValueRow.self)?.value == "accepted")
            }
        }
    }

    private func directAuthorizationGrant(_ command: V2SendMessageCommand, recipient: UserID, control: any Database, now: Date) async throws -> V2DirectAuthorizationGrant {
        let request = V2DirectAuthorizationRequest(roomID: command.roomID.uuidValue!, senderID: command.senderUserID.uuidValue!,
            clientMessageID: command.clientMessageID.uuidValue!, recipientID: recipient.uuidValue!, ownerShardID: "room-b",
            ownerEpoch: 0, fingerprint: command.fingerprint.digest)
        return try #require(try await PostgresV2DirectAuthorizationIntentStore(database: control).reserve([request], now: now).first)
    }

    @Test("atomic warm direct batches apply control authority to every room before any append",
          arguments: [false, true])
    func directBatchControlAuthority(blockedFirst: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, _, ownerSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 100, retryAfterSeconds: 3))
            try await ownerSQL.raw("UPDATE im_v2.shard_admission_pools SET command_window_limit = 100").run()
            let batchClock = TestSequenceClock([now])
            let recipients = [UserID(uuid: memberTwoUUID), UserID(uuid: memberThreeUUID)]
            let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner, identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: profile, roomShardID: "room-b", now: { now })
            var rooms: [RoomID] = []
            for recipient in recipients {
                let room = try await direct.openedIdentity(actorUserID: senderID,
                    operationID: .init(uuid: UUID()), targetUserID: recipient, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                rooms.append(room.roomID)
            }
            let cache = V2DirectRoomLogFastAppendCache()
            let writer = PostgresV2RoomWriteStore(database: owner,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 20, window: 86_400),
                contentReviewMode: .disabled,
                directRoomLogFastAppendCache: cache,
                shardAdmissionCommandCreditPool: .init(database: owner, batchSize: 2)).usingControlDatabase(control)
            let roomIDs = rooms
            @Sendable func requests(reversed: Bool = false) throws -> [V2OwnerValidatedRoomWriteRequest] {
                let ordered = reversed ? Array(roomIDs.reversed()) : roomIDs
                return try ordered.map { room in
                    .init(request: .init(command: try .init(roomID: room, senderUserID: senderID,
                        clientMessageID: .init(uuid: UUID()), text: "batch control",
                        limits: .init(maxUTF8Bytes: 64)), capacityProfile: profile,
                        identifiers: try V2AcceptanceIDFactory().make(at: batchClock.now()), now: batchClock.now()),
                        ownerRoute: try .init(shardID: "room-b", epoch: 0))
                }
            }
            for item in try requests() {
                guard case .accepted = try await writer.acceptOwnerValidated(request: item.request,
                    ownerRoute: item.ownerRoute) else {
                    Issue.record("warm-up failed"); return
                }
            }
            let first = try await writer.acceptAtomicallyOwnerValidated(requests: requests())
            #expect(first.count == 2)
            #expect(first.allSatisfy { if case .accepted = $0 { true } else { false } })
            #expect(await cache.snapshot().committedAppends == 2)
            // Reverse arrival order across concurrent batches while sharing a sender.
            let forwardInputs = try requests(), reverseInputs = try requests(reversed: true)
            async let forward = writer.acceptAtomicallyOwnerValidated(requests: forwardInputs)
            async let reverse = writer.acceptAtomicallyOwnerValidated(requests: reverseInputs)
            let concurrent = try await forward + reverse
            #expect(concurrent.count == 4)
            #expect(concurrent.allSatisfy { if case .accepted = $0 { true } else { false } })
            let before = try await count("im_v2.messages", on: ownerSQL)
            let blocked = recipients[blockedFirst ? 0 : 1]
            let social = PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator: .init(controlDatabase: control, ownerDatabases: ["room-b": owner]))
            _ = try await social.executeSocialFixture(actorUserID: blocked, targetUserID: senderID, operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now:  now)
            // Each later action follows the previous authority drain, retaining the original command IDs.
            batchClock.set([now.addingTimeInterval(1)])
            #expect(try await count("im_v2.user_blocks", on: ownerSQL) == 0)
            let rejected = try requests()
            await #expect(throws: V2AtomicRoomWriteBatchError.self) {
                try await writer.acceptAtomicallyOwnerValidated(requests: rejected)
            }
            #expect(try await count("im_v2.messages", on: ownerSQL) == before)
            for item in rejected {
                #expect(try await ownerSQL.raw("SELECT count(*) AS value FROM im_v2.messages WHERE client_message_id = \(bind: item.request.command.clientMessageID.uuidValue!)")
                    .first(decoding: CountRow.self)?.value == 0)
            }
            _ = try await social.executeSocialFixture(actorUserID: blocked, targetUserID: senderID, operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.unblock), now: now.addingTimeInterval(2))
            batchClock.set([now.addingTimeInterval(3)])
            let resumed = try rejected.map { item in
                V2OwnerValidatedRoomWriteRequest(request: .init(command: item.request.command,
                    capacityProfile: profile, identifiers: try V2AcceptanceIDFactory().make(at: batchClock.now()),
                    now: batchClock.now()), ownerRoute: item.ownerRoute)
            }
            let restored = try await writer.acceptAtomicallyOwnerValidated(requests: resumed)
            #expect(restored.allSatisfy { if case .accepted = $0 { true } else { false } })
            #expect(try await count("im_v2.messages", on: ownerSQL) == before + 2)
            let fence = V2DirectSendControlPolicyFence(database: control)
            await #expect(throws: V2DirectSendControlPolicyError.invalidBatch) {
                try await fence.withLockedPolicies(pairs: []) { _, _ in Issue.record("empty scope accepted") }
            }
            await #expect(throws: V2DirectSendControlPolicyError.invalidBatch) {
                try await fence.withLockedPolicies(pairs: Array(repeating: .init(sender: senderUUID, recipient: memberTwoUUID), count: 129)) {
                    _, _ in Issue.record("oversized scope accepted")
                }
            }
        }
    }

    @Test("actual direct sends refresh control authority despite stale owner policies", arguments:
        ["block", "concurrent-block", "relationship", "preference", "disable-sender", "disable-recipient"], [false, true])
    func directSendControlAuthority(kind: String, warm: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let recipient = UserID(uuid: memberTwoUUID), profile = try forwardImportTestProfile()
            let coordinator = V2DirectAuthorizationCoordinator(controlDatabase: control, ownerDatabases: ["room-b": owner])
            let social = PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator: coordinator)
            let directControl = PostgresV2DirectMessagingStore(database: control, identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery())
            if kind == "relationship" {
                for database in [control, owner] {
                    let store = PostgresV2SocialRelationshipStore(database: database, projectionDelivery: SuccessfulProjectionDelivery())
                    _ = try await store.executeSocialFixture(actorUserID: senderID, targetUserID: recipient, operation: .relationship(.init(uuid: UUID())), action: .relationship(.request), now:  now)
                    _ = try await store.executeSocialFixture(actorUserID: recipient, targetUserID: senderID, operation: .relationship(.init(uuid: UUID())), action: .relationship(.accept), now:  now)
                }
                _ = try await PostgresV2AccountPreferenceOperationStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator: .init(controlDatabase: control, ownerDatabases: [:])).executePreferenceFixture(owner: recipient, operation: .strangerMessagePreference(.init(uuid: UUID())), value: .strangerMessage(.deny), now: now)
            }
            let direct = try V2DirectRoomOperationTestFixture(store: PostgresV2DirectMessagingStore(database: owner, identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: profile, roomShardID: "room-b", now: { now })
            let room = try await direct.openedIdentity(actorUserID: senderID,
                operationID: .init(uuid: UUID()), targetUserID: recipient, firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let cache = V2DirectRoomLogFastAppendCache()
            let writer = PostgresV2RoomWriteStore(database: owner,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
                contentReviewMode: .disabled,
                directRoomLogFastAppendCache: cache,
                shardAdmissionCommandCreditPool: warm ? .init(database: owner, batchSize: 2) : nil,
                roomAdmissionCommandCreditPool: warm ? .init(database: owner, batchSize: 2) : nil).usingControlDatabase(control)
            func request() throws -> V2RoomWriteRequest {
                .init(command: try .init(roomID: room.roomID, senderUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "control authority",
                    limits: .init(maxUTF8Bytes: 64)), capacityProfile: profile,
                    identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
            }
            @Sendable func send(_ input: V2RoomWriteRequest) async throws -> V2SendMessageOutcome {
                try await writer.acceptOwnerValidated(request: input,
                    ownerRoute: .init(shardID: "room-b", epoch: 0))
            }
            let original = try request()
            let accepted = try await send(original)
            guard case .accepted = accepted else { Issue.record("expected initial acceptance"); return }
            if warm {
                for _ in 0..<2 {
                    guard case .accepted = try await send(request()) else { Issue.record("warm send rejected"); return }
                }
                #expect(await cache.snapshot().committedAppends > 0)
                let cached = try #require(await cache.value(for: .init(roomID: room.roomID.uuidValue!, senderID: senderUUID)))
                #expect(cached.policy.allowsStrangers) // owner truth; control denies this in relationship case
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
                    #expect(try await waitForLock(ownerSQL, query: "%SELECT room_id, room_shard_id, owner_epoch%"))
                    let revocation = Task {
                        try await social.executeSocialFixture(actorUserID: recipient, targetUserID: senderID, operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now:  now)
                    }
                    do {
                        #expect(try await waitForLock(ownerSQL, query: "%pg_advisory_xact_lock(%"))
                        await gate.releaseTransaction()
                        try await holder.value
                        let outcome = try await pending.value
                        if case .accepted = outcome {} else { Issue.record("fenced send did not commit") }
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
                _ = try await PostgresV2AccountPreferenceOperationStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator: .init(controlDatabase: control, ownerDatabases: [:])).executePreferenceFixture(owner: recipient, operation: .strangerMessagePreference(.init(uuid: UUID())), value: .strangerMessage(.deny), now: now)
            default:
                _ = try await V2PostgresAccountDisableService(database: control, operatorPrincipal: "send-policy-test", now: { now })
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
            guard case .idempotent(let receipt) = replay else { Issue.record("expected original receipt"); return }
            #expect(receipt == accepted.acceptanceReceipt)
            let deniedRequest = try request()
            if kind == "disable-sender" {
                await #expect(throws: V2RoomWriteStoreError.actorNotEligible) { try await send(deniedRequest) }
            } else {
                guard case .denied = try await send(deniedRequest) else { Issue.record("control revocation ignored"); return }
            }
            #expect(try await count("im_v2.messages", on: ownerSQL) == before)
            if kind == "block" || kind == "concurrent-block" {
                _ = try await social.executeSocialFixture(actorUserID: recipient, targetUserID: senderID, operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.unblock), now:  now)
            } else if kind == "relationship" || kind == "preference" {
                _ = try await PostgresV2AccountPreferenceOperationStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator: .init(controlDatabase: control, ownerDatabases: [:])).executePreferenceFixture(owner: recipient, operation: .strangerMessagePreference(.init(uuid: UUID())), value: .strangerMessage(.allow), now: now)
            } else { return }
            guard case .accepted = try await send(request()) else { Issue.record("control permission restoration ignored"); return }
            #expect(try await count("im_v2.messages", on: ownerSQL) == before + 1)
            // Previously committed denial remains idempotent after permissions change.
            guard case .denied = try await send(deniedRequest) else { Issue.record("denial replay changed"); return }
        }
    }

    @Test("control direct policies remain locked through a cross-database callback", arguments: ["block", "relationship", "preference", "disable"])
    func directControlPolicyFence(kind: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, _, sql, ownerSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let recipient = UserID(uuid: memberTwoUUID)
            let social = PostgresV2SocialRelationshipStore(database: control, projectionDelivery: SuccessfulProjectionDelivery())
            let direct = PostgresV2DirectMessagingStore(database: control, identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery())
            if kind == "relationship" {
                _ = try await social.executeSocialFixture(actorUserID: senderID, targetUserID: recipient, operation: .relationship(.init(uuid: UUID())), action: .relationship(.request), now:  now)
                _ = try await social.executeSocialFixture(actorUserID: recipient, targetUserID: senderID, operation: .relationship(.init(uuid: UUID())), action: .relationship(.accept), now:  now)
            }
            try await ownerSQL.raw("CREATE TABLE im_v2.control_policy_test_commits (value int NOT NULL)").run()
            let fence = V2DirectSendControlPolicyFence(database: control)
            let gate = PostgreSQLTransactionGate()
            let reader = Task {
                try await fence.withLockedPolicies(pairs: [.init(sender: senderUUID, recipient: memberTwoUUID)]) { _, policies in
                    let policy = try #require(policies[.init(sender: senderUUID, recipient: memberTwoUUID)])
                    #expect(policy.sender.isActive && policy.recipient.isActive)
                    #expect(!policy.blocked && policy.allowsStrangers)
                    #expect(policy.isFriend == (kind == "relationship"))
                    await gate.holdTransaction()
                    try await ownerSQL.raw("INSERT INTO im_v2.control_policy_test_commits VALUES (1)").run()
                }
            }
            await gate.waitUntilHeld()
            let writer = Task {
                switch kind {
                case "block":
                    _ = try await social.executeSocialFixture(actorUserID: recipient, targetUserID: senderID, operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now:  now)
                case "relationship":
                    _ = try await social.executeSocialFixture(actorUserID: recipient, targetUserID: senderID, operation: .relationship(.init(uuid: UUID())), action: .relationship(.remove), now:  now)
                case "preference":
                    _ = try await PostgresV2AccountPreferenceOperationStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator: .init(controlDatabase: control, ownerDatabases: [:])).executePreferenceFixture(owner: recipient, operation: .strangerMessagePreference(.init(uuid: UUID())), value: .strangerMessage(.deny), now: now)
                default:
                    _ = try await V2PostgresAccountDisableService(database: control, operatorPrincipal: "test-policy", now: { now })
                        .disable(.init(userID: recipient, operationID: UUID(), reason: .userRequested))
                }
            }
            do {
                var observed = false
                for _ in 0..<500 {
                    let waiting = try await sql.raw("""
                        SELECT count(*) AS value FROM pg_stat_activity
                        WHERE datname = current_database() AND wait_event_type = 'Lock'
                          AND query LIKE '%pg_advisory_xact_lock(%'
                        """).first(decoding: CountRow.self)?.value ?? 0
                    if waiting > 0 { observed = true; break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(observed)
                #expect(try await count("im_v2.control_policy_test_commits", on: ownerSQL) == 0)
                await gate.releaseTransaction()
                try await reader.value
                try await writer.value
            } catch {
                writer.cancel()
                await gate.releaseTransaction()
                _ = await reader.result
                _ = await writer.result
                throw error
            }
            #expect(try await count("im_v2.control_policy_test_commits", on: ownerSQL) == 1)
            try await fence.withLockedPolicies(pairs: [.init(sender: senderUUID, recipient: memberTwoUUID)]) { _, policies in
                    let policy = try #require(policies[.init(sender: senderUUID, recipient: memberTwoUUID)])
                #expect(policy.blocked == (kind == "block"))
                #expect(!policy.isFriend)
                #expect(policy.allowsStrangers == (kind != "preference"))
                #expect(policy.recipient.isActive == (kind != "disable"))
            }
            // Target-local copies are deliberately unchanged: only control is authoritative.
            #expect(try await count("im_v2.user_blocks", on: ownerSQL) == 0)
            #expect(try await count("im_v2.account_disables", on: ownerSQL) == 0)
            await #expect(throws: CancellationError.self) {
                try await fence.withLockedPolicies(pairs: [.init(sender: senderUUID, recipient: memberTwoUUID)]) { _, _ in throw CancellationError() }
            }
            let pairKey = [senderUUID, memberTwoUUID].map { $0.uuidString.lowercased() }.sorted().joined(separator: "|")
            try await control.transaction { transaction in
                let check = try #require(transaction as? any SQLDatabase)
                struct Row: Decodable { let value: Bool }
                for key in [pairKey, "account-state:" + memberTwoUUID.uuidString,
                            "v2-stranger-message-preference:" + memberTwoUUID.uuidString.lowercased()] {
                    #expect(try await check.raw("SELECT pg_try_advisory_xact_lock(hashtextextended(\(bind: key), 0)) AS value")
                        .first(decoding: Row.self)?.value == true)
                }
            }
            try await fence.withLockedPolicies(pairs: [.init(sender: senderUUID, recipient: UUID())]) { _, policies in
                let policy = try #require(policies.values.first)
                #expect(!policy.recipient.isActive)
            }
            await #expect(throws: V2DirectSendControlPolicyError.invalidPair) {
                try await fence.withLockedPolicies(pairs: [.init(sender: senderUUID, recipient: senderUUID)]) { _, _ in Issue.record("invalid pair entered callback") }
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
            let messages = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: profile, limits: .init(maxUTF8Bytes: 64), now: { base.addingTimeInterval(1) })
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
                let sender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: profile, limits: .init(maxUTF8Bytes: 64), now: { time })
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
            let preferences = PostgresV2AccountPreferenceOperationStore(database: control, projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator: V2DirectAuthorizationCoordinator(controlDatabase: control, ownerDatabases: [:]))
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

private struct DirectAuthorizationCrashSpec: Codable, Sendable {
    let kind: String; let checkpoint: String
    let rooms: [UUID]; let operations: [UUID]
    let payload: Data?; let digest: Data?
}
