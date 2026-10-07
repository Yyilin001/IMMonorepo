@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2Core
import PostgresNIO
import SQLKit
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
struct V2GroupNicknameEventPostgresTests {
    @Test("nickname changes append content-free events atomically and share room admission", arguments: ["standard", "large"])
    func eventsAndAdmission(capacityClass: String) async throws {
        try await withFixture(capacityClass: capacityClass) { f in
            let originalOperation = GroupNicknameOperationID(uuid: UUID())
            let first = try await f.store.updateOwnGroupNickname(.init(actorUserID: f.user, roomID: f.room,
                operationID: originalOperation, expectedRevision: nil, nickname: "Secret first name",firstSubmissionDeadlineMilliseconds:UInt64(Int64.max))).committedValue
            let noOp = try await f.store.updateOwnGroupNickname(.init(actorUserID: f.user, roomID: f.room,
                operationID: .init(uuid: UUID()), expectedRevision: first.revision, nickname: first.groupNickname,firstSubmissionDeadlineMilliseconds:UInt64(Int64.max))).committedValue
            #expect(noOp.revision.rawValue == 2 && noOp.groupNickname == first.groupNickname)
            let second = try await f.store.updateOwnGroupNickname(.init(actorUserID: f.user, roomID: f.room,
                operationID: .init(uuid: UUID()), expectedRevision: noOp.revision, nickname: "Secret second name",firstSubmissionDeadlineMilliseconds:UInt64(Int64.max))).committedValue
            let third = try await f.store.updateOwnGroupNickname(.init(actorUserID: f.user, roomID: f.room,
                operationID: .init(uuid: UUID()), expectedRevision: second.revision, nickname: nil,firstSubmissionDeadlineMilliseconds:UInt64(Int64.max))).committedValue
            #expect(third.revision.rawValue == 4 && third.groupNickname == nil)
            await #expect(throws: V2RoomCallFailure.rolledBack(.overloaded)) {
                _ = try await f.store.updateOwnGroupNickname(.init(actorUserID: f.user, roomID: f.room,
                    operationID: .init(uuid: UUID()), expectedRevision: third.revision, nickname: "Must roll back",firstSubmissionDeadlineMilliseconds:UInt64(Int64.max))).committedValue
            }
            #expect(try await f.store.updateOwnGroupNickname(.init(actorUserID: f.user, roomID: f.room,
                operationID: originalOperation, expectedRevision: nil, nickname: "Secret first name",firstSubmissionDeadlineMilliseconds:UInt64(Int64.max))).committedValue == first)
            let state = try await f.state()
            #expect(state.sequence == 4 && state.used == 4 && state.operations == 4 && state.revision == 4)
            #expect(state.nickname == nil)
            let log = PostgresV2GroupEventLogStore(database: f.database)
            let page = try await log.pull(roomID: f.room, actorUserID: f.user, afterRoomSequence: 0, pageSize: 10)
            #expect(page.events.count == 4 && page.nextRoomSequence == 4)
            for (index, event) in page.events.enumerated() {
                #expect(event.projectionKind == "group_capability" && event.roomSequence == UInt64(index + 1))
                let payload = try #require(JSONSerialization.jsonObject(with: event.payload) as? [String: Any])
                #expect(Set(payload.keys) == ["event_type", "room_id", "target_user_id", "revision", "room_sequence", "server_created_at_ms"])
                #expect(payload["event_type"] as? String == "group.nickname_changed")
                #expect(payload["target_user_id"] as? String == f.user.rawValue)
                #expect(payload["revision"] as? Int == index + 1)
            }
            let fanout = try #require(try await f.sql.raw("SELECT COUNT(*)::bigint AS value FROM im_v2.user_sync_log WHERE source_event_id IN (SELECT event_id FROM im_v2.room_events WHERE room_id=\(bind: f.room.uuidValue!))").first(decoding: NicknameCount.self))
            #expect(fanout.value == 0)
        }
    }

    @Test("a failed event insertion rolls back nickname, operation receipt, sequence and credits")
    func atomicRollback() async throws {
        try await withFixture(capacityClass: "large") { f in
            let event = EventID(uuid: UUID())
            let now = f.now
            let store = PostgresV2ProfilePresentationStore(database: f.database, nicknameCapacityProfile: f.profile,
                                                         makeEventID: { event }, now: { now })
            let first = try await store.updateOwnGroupNickname(.init(actorUserID: f.user, roomID: f.room,
                operationID: .init(uuid: UUID()), expectedRevision: nil, nickname: "Original",firstSubmissionDeadlineMilliseconds:UInt64(Int64.max))).committedValue
            await #expect(throws: (any Error).self) {
                _ = try await store.updateOwnGroupNickname(.init(actorUserID: f.user, roomID: f.room,
                    operationID: .init(uuid: UUID()), expectedRevision: first.revision, nickname: "Failed",firstSubmissionDeadlineMilliseconds:UInt64(Int64.max))).committedValue
            }
            let state = try await f.state()
            #expect(state.sequence == 1 && state.used == 1 && state.operations == 1 && state.revision == 1)
            #expect(state.nickname == "Original")
            try await f.sql.raw("UPDATE im_v2.rooms SET membership_revision=2 WHERE room_id=\(bind: f.room.uuidValue!)").run()
            try await f.sql.raw("UPDATE im_v2.room_memberships SET left_revision=2 WHERE room_id=\(bind: f.room.uuidValue!) AND user_id=\(bind: f.user.uuidValue!)").run()
            await #expect(throws: V2ProfilePresentationError.forbidden) {
                _ = try await f.store.updateOwnGroupNickname(.init(actorUserID: f.user, roomID: f.room,
                    operationID: .init(uuid: UUID()), expectedRevision: first.revision, nickname: "Departed",firstSubmissionDeadlineMilliseconds:UInt64(Int64.max))).committedValue
            }
            let denied = try await f.state()
            #expect(denied.sequence == state.sequence && denied.used == state.used && denied.revision == state.revision)
            #expect(denied.nickname == state.nickname && denied.operations == state.operations + 1)
        }
    }

    private func withFixture(capacityClass: String, _ body: (NicknameFixture) async throws -> Void) async throws {
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
            let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), lease = UUID(), now = Date()
            let shard = "nickname-" + UUID().uuidString
            let profile = try V2CapacityProfile(id: "nickname-test", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 4, retryAfterSeconds: 1))
            let handle = "nickname" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
            try await sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,revision,created_at,updated_at) VALUES(\(bind: user.uuidValue!),\(bind: handle), 'Member',1,\(bind: now),\(bind: now))").run()
            try await sql.raw("INSERT INTO im_v2.rooms(room_id,room_shard_id,capacity_profile_id,capacity_class,membership_revision) VALUES(\(bind: room.uuidValue!),\(bind: shard),\(bind: profile.id),\(bind: capacityClass),1)").run()
            try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision,role) VALUES(\(bind: room.uuidValue!),\(bind: user.uuidValue!),1,'member')").run()
            try await sql.raw("INSERT INTO im_v2.shard_admission_pools(room_shard_id,capacity_profile_id,lease_id,generation,valid_until,command_window_limit) VALUES(\(bind: shard),\(bind: profile.id),\(bind: lease),1,\(bind: now.addingTimeInterval(300)),4)").run()
            try await sql.raw("INSERT INTO im_v2.room_admission(room_id,eligible_member_count,command_window_limit,shard_lease_id,shard_lease_generation) VALUES(\(bind: room.uuidValue!),1,4,\(bind: lease),1)").run()
            let store = PostgresV2ProfilePresentationStore(database: database, nicknameCapacityProfile: profile, now: { now })
            try await body(.init(database: database, sql: sql, user: user, room: room, store: store, profile: profile, now: now))
            try await resources.shutdown()
        } catch {
            if let failure = error as? PSQLError {
                print("Nickname fixture SQL: \(failure.serverInfo?[.message] ?? "unknown"), constraint: \(failure.serverInfo?[.constraintName] ?? "none")")
            }
            try? await resources.shutdown(); throw error
        }
    }
}

private struct NicknameFixture {
    let database: any Database; let sql: any SQLDatabase
    let user: UserID; let room: RoomID; let store: PostgresV2ProfilePresentationStore
    let profile: V2CapacityProfile; let now: Date
    func state() async throws -> NicknameState {
        try #require(try await sql.raw("""
            SELECT r.room_sequence AS sequence, a.command_window_used AS used, n.revision, n.nickname,
                   (SELECT COUNT(*) FROM im_v2.group_nickname_operation_receipts WHERE room_id=r.room_id) AS operations
            FROM im_v2.rooms r JOIN im_v2.room_admission a ON a.room_id=r.room_id
            JOIN im_v2.room_member_nicknames n ON n.room_id=r.room_id AND n.user_id=\(bind: user.uuidValue!)
            WHERE r.room_id=\(bind: room.uuidValue!)
            """).first(decoding: NicknameState.self))
    }
}
private struct NicknameState: Decodable, Equatable { let sequence: Int64; let used: Int; let revision: Int64; let nickname: String?; let operations: Int64 }
private struct NicknameCount: Decodable { let value: Int64 }
