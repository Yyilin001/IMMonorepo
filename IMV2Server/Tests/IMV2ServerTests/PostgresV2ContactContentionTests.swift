import Foundation
import FluentKit
import IMV2Core
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("compare independent and shared-target friend requests through policy owners",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_CONTACT_BENCHMARK"] == "1"))
    func contactRequestContentionBenchmark() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            try await withFixturePolicyOwners(database: database, projectionDelivery: SuccessfulProjectionDelivery()) { owners in
                let store = PostgresV2SocialRelationshipStore(database: database, projectionDelivery: SuccessfulProjectionDelivery(), policyOwners: owners)
                let workers = 4, perWorker = 40
                for round in 0..<3 {
                    for popular in [false, true] {
                        let pairs = (0..<(workers * perWorker)).map { _ in (UUID(), UUID()) }
                        let users = pairs.flatMap { [$0.0.uuidString, $0.1.uuidString] }
                        let json = String(decoding: try JSONEncoder().encode(users), as: UTF8.self)
                        try await sql.raw("""
                            INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,revision,created_at,updated_at)
                            SELECT id::uuid,replace(lower(id),'-',''),'成员',1,now(),now()
                            FROM jsonb_array_elements_text(\(bind: json)::jsonb) AS t(id)
                            """).run()
                        let start = DispatchTime.now().uptimeNanoseconds
                        let times = try await withThrowingTaskGroup(of: [Double].self) { group in
                            for worker in 0..<workers {
                                group.addTask {
                                    var times = [Double]()
                                    for index in (worker * perWorker)..<((worker + 1) * perWorker) {
                                        let sender = UserID(uuid: pairs[index].0)
                                        let target = UserID(uuid: pairs[popular ? 0 : index].1)
                                        let begin = DispatchTime.now().uptimeNanoseconds
                                        let result = try await store.executeSocialFixture(actorUserID: sender,
                                            targetUserID: target, operation: .relationship(.init(uuid: UUID())),
                                            action: .relationship(.request), now: Date())
                                        guard case .receipt(let receipt) = result,
                                              receipt.outcome == .applied(.relationship(state: .pending, revision: 1))
                                        else { throw CancellationError() }
                                        times.append(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e6)
                                    }
                                    return times
                                }
                            }
                            var result = [Double]()
                            for try await times in group { result += times }
                            return result.sorted()
                        }
                        let rate = Double(times.count) * 1e9 / Double(DispatchTime.now().uptimeNanoseconds - start)
                        print("CONTACT round=\(round) popular=\(popular) count=\(times.count) rate=\(rate) p99ms=\(times[Int(ceil(Double(times.count)*0.99))-1])")
                        let gaps = try await sql.raw("""
                            SELECT count(*) AS value FROM (
                                SELECT user_id FROM im_v2.user_sync_log WHERE projection_kind='relationship'
                                GROUP BY user_id HAVING min(user_sync_sequence) <> 1 OR max(user_sync_sequence) <> count(*)
                            ) AS gaps
                            """).first(decoding: CountRow.self)
                        #expect(gaps?.value == 0)
                        #expect(try await count("im_v2.user_sync_log", on: sql) == Int64((2 * round + (popular ? 2 : 1)) * pairs.count * 2))
                    }
                }
            }
        }
    }
}

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("concurrent requests share the preference read lock and see a committed denial after waiting")
    func contactRequestPreferenceOrdering() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, _, _, _ in
            let target = UserID(uuid: memberTwoUUID)
            let delivery = SuccessfulProjectionDelivery()
            try await withFixturePolicyOwners(database: database, projectionDelivery: delivery) { owners in
                let social = PostgresV2SocialRelationshipStore(database: database, projectionDelivery: delivery, policyOwners: owners)
                let first = try await social.freezeSocialFixture(actorUserID: senderID, targetUserID: target,
                    operation: .relationship(.init(uuid: UUID())), action: .relationship(.request), now: Date())
                let next = try await social.freezeSocialFixture(actorUserID: .init(uuid: memberThreeUUID), targetUserID: target,
                    operation: .relationship(.init(uuid: UUID())), action: .relationship(.request), now: Date())

                let applied = try await database.transaction { tx in
                    let sql = try #require(tx as? any SQLDatabase)
                    // Bound a regression to an exclusive lock: the independent request would wait for this transaction.
                    try await sql.raw("SET LOCAL idle_in_transaction_session_timeout = '5s'").run()
                    let key = "v2-user-add-preference:" + target.rawValue.lowercased()
                    try await sql.raw("SELECT pg_advisory_xact_lock_shared(hashtextextended(\(bind: key), 0))").run()
                    let result = try await social.submitSocialOperation(first)
                    guard case .receipt(let receipt) = result else { throw CancellationError() }
                    #expect(receipt.outcome == .applied(.relationship(state: .pending, revision: 1)))
                    return result
                }

                let settings = PostgresV2DirectMessagingStore(database: database,
                    identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: delivery)
                let pending = try await database.transaction { tx in
                    let sql = try #require(tx as? any SQLDatabase)
                    _ = try await settings.applyUserAddPermission(command: .init(actorUserID: target,
                        operationID: .init(uuid: UUID()), permission: .deny), transaction: tx, now: Date())
                    let request = Task { try await social.submitSocialOperation(next) }
                    // Observe the actual blocked reader before releasing the uncommitted setting.
                    try await expectBlockedContact(on: sql, mode: "ShareLock")
                    return request
                }
                guard case .receipt(let denied) = try await pending.value else { throw CancellationError() }
                #expect(denied.outcome == .rejected(.permissionDenied))
                #expect(try await social.submitSocialOperation(first) == applied)
            }
        }
    }
}

private func expectBlockedContact(on sql: any SQLDatabase, mode: String) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    repeat {
        let blocked = try await sql.raw("""
            SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype='advisory'
                AND NOT granted AND mode=\(bind: mode) AND pg_backend_pid()=ANY(pg_blocking_pids(pid))) AS exists
            """).first(decoding: ExistsRow.self)?.exists == true
        if blocked { return }
        try await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    Issue.record("Expected a waiting contact operation with lock mode \(mode)")
}

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("a block waiting behind direct room creation advances the new room policy revision")
    func contactBlockDuringDirectRoomCreation() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let peer = UserID(uuid: memberTwoUUID)
            let delivery = SuccessfulProjectionDelivery()
            let identity = PostgresV2DirectRoomIdentityReader(database: database)
            let direct = PostgresV2DirectMessagingStore(database: database, identityReader: identity, projectionDelivery: delivery)
            let snapshot = try await identity.read(actorUserID: senderID, targetUserID: peer)
            try await withFixturePolicyOwners(database: database, projectionDelivery: delivery) { owners in
                let social = PostgresV2SocialRelationshipStore(database: database, projectionDelivery: delivery, policyOwners: owners)
                let block = try await social.freezeSocialFixture(actorUserID: peer, targetUserID: senderID,
                    operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now: Date())
                let roomID = RoomID(uuid: UUID())
                let waiting = try await database.transaction { tx in
                    let connection = try #require(tx as? any SQLDatabase)
                    let outcome = try await direct.applyOpen(command: .init(actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: peer),
                        capacityProfile: forwardImportTestProfile(), roomShardID: "room-a", roomID: roomID,
                        identitySnapshot: snapshot, transaction: tx, now: Date(timeIntervalSince1970: 1_750_000_000))
                    guard case .opened = outcome else { throw CancellationError() }
                    let request = Task { try await social.submitSocialOperation(block) }
                    try await expectBlockedContact(on: connection, mode: "ExclusiveLock")
                    return request
                }
                guard case .receipt(let receipt) = try await waiting.value else { throw CancellationError() }
                #expect(receipt.outcome == .applied(.userBlock(isBlocked: true, revision: 1)))
                let row = try await sql.raw("SELECT direct_policy_revision AS value FROM im_v2.direct_room_pairs WHERE room_id=\(bind: roomID.uuidValue!)")
                    .first(decoding: CountRow.self)
                #expect(row?.value == 2)
            }
        }
    }
}
