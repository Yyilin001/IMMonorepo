import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2Core
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("room permission changes share their actual commit", .serialized, .timeLimit(.minutes(2)))
struct PostgresV2RoomPermissionCommitTests {
    @Test("member removal installs its committed cut without a postcommit database read")
    func removalInstallsWithoutPostcommitRead() async throws {
        try await Self.withDatabase { database, _, sql, _, _ in
            try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE room_id=\(bind: roomUUID) AND user_id=\(bind: senderUUID)").run()
            try await withRoomActivationLifetime(database: database, roomID: roomID) { token, lifetime in
                let target = UserID(uuid: memberTwoUUID)
                let source = try PostgresV2RoomSubscriptionSource(database: database, activation: token, lifetime: lifetime)
                let owner = try await V2RoomSubscriptionOwner.restore(source: source, roomID: roomID,
                    owner: token.owner, activation: token, deadline: .now + .seconds(10), trackedUserIDs: [target])
                let command = try await Self.removal(database: database, token: token)
                let result = try await owner.withPermissionMutation(token: token, deadline: .now + .seconds(10)) { users, version in
                    let commit = try V2RoomPermissionCommit(database: database, token: token, lifetime: lifetime,
                        trackedUserIDs: users, baseVersion: version, requiresReceiveReset: true)
                    let result = try await PostgresV2MemberAdministrationStore(database: database, clock: { Self.mutationTime })
                        .usingPermissionCommit(commit).submit(command, token: token,
                            capacityProfile: PostgresV2RoomWriteStoreIntegrationTests().forwardImportTestProfile(), eventID: .init(uuid: UUID()))
                    let effect = try #require(commit.effect())
                    #expect(effect.snapshot.members.count == 1 && !effect.snapshot.members[0].authorized)
                    #expect(effect.snapshot.roomControlVersion > version)
                    // Hide the table after COMMIT. Any old restoration/read path
                    // during the Owner's installation now fails deterministically.
                    try await sql.raw("ALTER TABLE im_v2.rooms RENAME TO permission_test_hidden_rooms").run()
                    return .init(result: result, effect: effect)
                }
                try await sql.raw("ALTER TABLE im_v2.permission_test_hidden_rooms RENAME TO rooms").run()
                guard case .receipt(let receipt) = result, case .applied(.removed) = receipt.outcome else {
                    Issue.record("member removal did not commit"); try await owner.close(); return
                }
                #expect(await owner.consumedSequence() == 1)
                // The new version is already installed: this does not need SQL.
                #expect(try await owner.processControlCut(expectedVersion: 0, token: token, deadline: .now + .seconds(5)))
                try await owner.close()
            }
        }
    }

    enum FailurePoint: String, Sendable, CaseIterable { case body, commit }
    @Test("rollback or uncertain COMMIT publishes no cut and retires old authorization", arguments: FailurePoint.allCases)
    func failedTransactionPublishesNoCut(point: FailurePoint) async throws {
        try await Self.withDatabase { database, _, sql, _, _ in
            try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE room_id=\(bind: roomUUID) AND user_id=\(bind: senderUUID)").run()
            try await withRoomActivationLifetime(database: database, roomID: roomID) { token, lifetime in
                let target = UserID(uuid: memberTwoUUID)
                let source = try PostgresV2RoomSubscriptionSource(database: database, activation: token, lifetime: lifetime)
                let cut = try await source.snapshot(roomID: roomID, owner: token.owner, trackedUserIDs: [target])
                let owner = try await V2RoomSubscriptionOwner.restore(source: source, roomID: roomID,
                    owner: token.owner, activation: token, deadline: .now + .seconds(10), trackedUserIDs: [target])
                let command = try await Self.removal(database: database, token: token)
                let commit = try V2RoomPermissionCommit(database: database, token: token, lifetime: lifetime,
                    trackedUserIDs: [target], baseVersion: cut.roomControlVersion, requiresReceiveReset: true)
                try await sql.raw("""
                    CREATE FUNCTION im_v2.permission_test_failure() RETURNS trigger LANGUAGE plpgsql AS $$
                    BEGIN RAISE EXCEPTION 'injected permission transaction failure' USING ERRCODE='23514'; END $$
                    """).run()
                if point == .commit {
                    try await sql.raw("""
                        CREATE CONSTRAINT TRIGGER permission_test_failure AFTER UPDATE ON im_v2.rooms
                        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION im_v2.permission_test_failure()
                        """).run()
                } else {
                    try await sql.raw("""
                        CREATE TRIGGER permission_test_failure AFTER UPDATE ON im_v2.rooms
                        FOR EACH ROW EXECUTE FUNCTION im_v2.permission_test_failure()
                        """).run()
                }
                await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
                    try await owner.withPermissionMutation(token: token, deadline: .now + .seconds(10)) { _, _ in
                        let result = try await PostgresV2MemberAdministrationStore(database: database, clock: { Self.mutationTime })
                            .usingPermissionCommit(commit).submit(command, token: token,
                                capacityProfile: PostgresV2RoomWriteStoreIntegrationTests().forwardImportTestProfile(), eventID: .init(uuid: UUID()))
                        return .init(result: result, effect: commit.effect())
                    }
                }
                #expect(commit.effect() == nil)
                let persisted = try #require(try await sql.raw("SELECT membership_revision, room_sequence FROM im_v2.rooms WHERE room_id=\(bind: roomUUID)")
                    .first(decoding: RoomState.self))
                #expect(persisted.membership_revision == 0 && persisted.room_sequence == 0)
                let recovered = try await source.snapshot(roomID: roomID, owner: token.owner, trackedUserIDs: [target])
                #expect(recovered.members == cut.members && recovered.roomControlVersion == cut.roomControlVersion)
                await #expect(throws: V2RoomSubscriptionOwnerError.closed) {
                    try await owner.drain(token: token, deadline: .now + .seconds(5))
                }
                try await owner.close()
            }
        }
    }

    private static func withDatabase(_ body: (any Database, any Database, any SQLDatabase, any SQLDatabase, RoomID) async throws -> Void) async throws {
        try await PostgresV2RoomWriteStoreIntegrationTests().withForwardOwnerDatabases(mode: .standard) { database, secondary, sql, secondarySQL, target in
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let journal = try String(contentsOf: root.appending(path: "IMV2/sql/realtime-change-journal.sql"), encoding: .utf8)
            for statement in postgresStatements(in: journal) where !statement.isEmpty && statement != "BEGIN" && statement != "COMMIT" {
                try await sql.raw("\(unsafeRaw: statement)").run()
            }
            try await body(database, secondary, sql, secondarySQL, target)
        }
    }

    private struct RoomState: Decodable { let membership_revision: Int64; let room_sequence: Int64 }
    private static let mutationTime = Date(timeIntervalSince1970: 1_750_000_000)
    private static func removal(database: any Database, token: V2RoomActivationToken) async throws -> V2MemberAdministrationCommand {
        let intent = try V2MemberAdministrationIntent(roomID: roomID, actorUserID: senderID,
            operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID), action: .remove,
            reasonCode: .init("abuse_spam"), expectedMembershipRevision: 0,
            confirmedUntilMilliseconds: 1_750_000_120_000)
        guard case .admitted(let admission) = try await PostgresV2MemberAdministrationStore(database: database, clock: { Self.mutationTime })
            .admit(intent, token: token) else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        return try .init(intent: intent, admission: admission)
    }
}
