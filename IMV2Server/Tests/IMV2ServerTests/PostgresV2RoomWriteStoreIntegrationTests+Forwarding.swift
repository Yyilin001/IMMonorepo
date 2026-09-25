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
    @Test("direct room-log room credits preserve the room command window across local token reuse")
    func directRoomLogRoomCommandCreditsPreserveRoomCapacity() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1),
                as: .psql, isDefault: true
            )
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists")
                .first(decoding: ExistsRow.self))?.exists == false
            else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_202_000)
            let roomID = UUID(uuidString: "00000000-0000-0000-0000-00000000c201")!
            let leaseID = UUID(uuidString: "00000000-0000-0000-0000-00000000c202")!
            try await sql.raw("""
                INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id, capacity_class)
                VALUES (\(bind: roomID), 'rooms-room-credit-test', 'room-credit-test', 'standard')
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
                VALUES ('rooms-room-credit-test', 'room-credit-test', \(bind: leaseID), 1, \(bind: now.addingTimeInterval(600)), 10)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_admission
                    (room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation)
                VALUES (\(bind: roomID), 2, 2, \(bind: leaseID), 1)
                """).run()
            let state = try ShardAdmissionState(
                lease: .init(
                    id: try .init(leaseID.uuidString), generation: 1,
                    validUntil: now.addingTimeInterval(600),
                    commandWindow: try .init(limit: 10)))
            let heatClock = Mutex(ContinuousClock.now)
            let credits = V2RoomAdmissionCommandCreditPool(
                database: resources.database(.psql), batchSize: 32,
                monotonicNow: { heatClock.withLock { $0 } }
            )
            let promotionNow = Date()
            #expect(await credits.shouldUseCredits(roomID: roomID, now: promotionNow) == false)
            for _ in 0 ..< 4 {
                await credits.recordNormalAdmissionCommit(roomID: roomID, now: promotionNow)
            }
            #expect(await credits.shouldUseCredits(roomID: roomID, now: promotionNow) == true)
            heatClock.withLock { $0 = $0.advanced(by: .seconds(6)) }
            #expect(await credits.shouldUseCredits(
                roomID: roomID,
                now: promotionNow.addingTimeInterval(6)
            ) == false)
            for _ in 0 ..< 4 {
                await credits.recordNormalAdmissionCommit(roomID: roomID, now: Date())
            }

            let first = try await credits.acquire(roomID: roomID, shardState: state, now: now)
            guard case .granted(let firstToken) = first else {
                Issue.record("expected the first durable room command credit")
                return
            }
            // A failed canonical write returns the process-local token. It
            // must not decrement the durable reservation, which is what keeps
            // a crash/retry from ever exceeding the room's command window.
            await credits.release(firstToken, now: now)

            for _ in 0 ..< 2 {
                let acquisition = try await credits.acquire(roomID: roomID, shardState: state, now: now)
                guard case .granted(let token) = acquisition else {
                    Issue.record("expected a previously charged room credit")
                    return
                }
                await credits.commit(token)
            }
            let exhausted = try await credits.acquire(roomID: roomID, shardState: state, now: now)
            guard case .rateLimited = exhausted else {
                Issue.record("the room credit pool oversold the room command window")
                return
            }
            let persisted = try #require(try await sql.raw("""
                SELECT command_window_used
                FROM im_v2.room_admission
                WHERE room_id = \(bind: roomID)
                """).first(decoding: CapacityRow.self))
            #expect(persisted.commandWindowUsed == 2)
            #expect(await credits.snapshot() == .init(
                activeCredits: 0, inFlightCredits: 0,
                batchReservations: 1, databaseCreditsReserved: 2,
                committedCredits: 2, returnedCredits: 1,
                expiredCreditsDiscarded: 0, capacityRejections: 1,
                promotedHotRooms: 1
            ))

            // The accelerated append path resolves one whole micro-batch with
            // one actor entry. A partial capacity result preserves order, and
            // returning the granted prefix cannot restore durable capacity.
            let batchRoomID = UUID(
                uuidString: "00000000-0000-0000-0000-00000000c203"
            )!
            try await sql.raw("""
                INSERT INTO im_v2.rooms
                    (room_id, room_shard_id, capacity_profile_id, capacity_class)
                VALUES (
                    \(bind: batchRoomID),
                    'rooms-room-credit-test',
                    'room-credit-test',
                    'standard'
                )
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_admission
                    (room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation)
                VALUES (\(bind: batchRoomID), 2, 2, \(bind: leaseID), 1)
                """).run()
            let batchCredits = V2RoomAdmissionCommandCreditPool(
                database: resources.database(.psql), batchSize: 32
            )
            let batchRequest = V2RoomAdmissionCommandCreditPool.BatchRequest(
                roomID: batchRoomID,
                shardState: state,
                now: now
            )
            let firstBatch = try await batchCredits.acquire(
                [batchRequest, batchRequest, batchRequest]
            )
            let grantedPrefix: [V2RoomAdmissionCommandCreditPool.Token] =
                firstBatch.compactMap { acquisition in
                    guard case .granted(let token) = acquisition else { return nil }
                    return token
                }
            #expect(grantedPrefix.count == 2)
            guard case .rateLimited = firstBatch[2] else {
                Issue.record("the batched room credit pool oversold the room window")
                return
            }
            await batchCredits.release(grantedPrefix.map { ($0, now) })

            let reusedBatch = try await batchCredits.acquire([batchRequest, batchRequest])
            let reusedTokens: [V2RoomAdmissionCommandCreditPool.Token] =
                reusedBatch.compactMap { acquisition in
                    guard case .granted(let token) = acquisition else { return nil }
                    return token
                }
            #expect(reusedTokens.count == 2)
            await batchCredits.commit(reusedTokens)
            guard case .rateLimited = try await batchCredits.acquire(
                roomID: batchRoomID,
                shardState: state,
                now: now
            ) else {
                Issue.record("returned room credits were durably oversold")
                return
            }
            #expect(await batchCredits.snapshot() == .init(
                activeCredits: 0, inFlightCredits: 0,
                batchReservations: 1, databaseCreditsReserved: 2,
                committedCredits: 2, returnedCredits: 2,
                expiredCreditsDiscarded: 0, capacityRejections: 2,
                promotedHotRooms: 0
            ))

            try await assertAllAcceptedMessagesHaveCompletions(sql: sql)
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

    @Test("a 100k hybrid group persists ordinary messages as room-log events and fans out only explicit mentions")
    func acceptsOneHundredThousandMemberHybridRoomWithoutGlobalFanout() async throws {
        guard Environment.get("IMV2_RUN_HYBRID_100K_CAPACITY") == "1",
              let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let startedAt = Date()
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            let schemaElapsed = v2LocalElapsedMilliseconds(since: startedAt)

            let room = UUID(uuidString: "00000000-0000-0000-0000-00000000b001")!
            let sender = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let mentioned = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            let lease = UUID(uuidString: "00000000-0000-0000-0000-00000000b002")!
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("""
                INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id, capacity_class)
                VALUES (\(bind: room), 'hybrid-100k', 'hybrid-100k', 'large')
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
                VALUES (\(bind: room), \(bind: sender), '十万混合群', \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
                VALUES ('hybrid-100k', 'hybrid-100k', \(bind: lease), 1, \(bind: now.addingTimeInterval(600)), 1_000)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_admission
                    (room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation)
                VALUES (\(bind: room), 100000, 1_000, \(bind: lease), 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision)
                SELECT \(bind: room),
                       ('00000000-0000-0000-0000-' || lpad(to_hex(member_number), 12, '0'))::uuid,
                       CASE WHEN member_number = 1 THEN 'owner' ELSE 'member' END,
                       0
                FROM generate_series(1, 100000) AS member_number
                """).run()
            let seedElapsed = v2LocalElapsedMilliseconds(since: startedAt) - schemaElapsed

            let profile = try RoomCapacityProfile(maxEligibleMembers: 100000, maxCommandsPerWindow: 1_000,    retryAfterSeconds: 1)
            let service = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: resources.database(.psql)),
                capacityProfile: try .init(id: "hybrid-100k", limits: profile),
                limits: try .init(maxUTF8Bytes: 64), now: { now }
            )
            let ordinaryStart = Date()
            guard case .accepted(let ordinary) = try await service.send(.init(roomID: try .init(room.uuidString), actorUserID: try .init(sender.uuidString), clientMessageID: try .init("00000000-0000-0000-0000-00000000b003"), text: "普通大群消息")) else {
                Issue.record("expected hybrid ordinary message acceptance")
                return
            }
            let ordinaryElapsed = v2LocalElapsedMilliseconds(since: ordinaryStart)

            let groupLog = V2GroupEventLogService(store: PostgresV2GroupEventLogStore(database: resources.database(.psql)))
            let pullStart = Date()
            let ordinaryPage = try await groupLog.pull(roomID: try .init(room.uuidString), actorUserID: try .init(sender.uuidString), afterRoomSequence: 0, pageSize: 10)
            let pullElapsed = v2LocalElapsedMilliseconds(since: pullStart)

            let mentionStart = Date()
            guard case .accepted(let mentionedMessage) = try await service.send(.init(
                roomID: try .init(room.uuidString), actorUserID: try .init(sender.uuidString),
                clientMessageID: try .init("00000000-0000-0000-0000-00000000b004"), text: "@指定成员",
                mentions: [.user(try .init(mentioned.uuidString))]
            )) else {
                Issue.record("expected hybrid mention message acceptance")
                return
            }
            let mentionElapsed = v2LocalElapsedMilliseconds(since: mentionStart)

            let verificationElapsed = v2LocalElapsedMilliseconds(since: startedAt) - schemaElapsed - seedElapsed - ordinaryElapsed - pullElapsed - mentionElapsed

            #expect(ordinary.roomSequence == 1)
            #expect(ordinaryPage.events.count == 1)
            #expect(ordinaryPage.events.first?.roomSequence == ordinary.roomSequence)
            #expect(ordinaryPage.events.first?.projectionKind == "message")
            #expect(mentionedMessage.roomSequence == 2)
            print("V2_LOCAL_HYBRID_100K_TIMING total_wall_ms=\(v2LocalElapsedMilliseconds(since: startedAt)) schema_ms=\(schemaElapsed) seed_ms=\(seedElapsed) ordinary_accept_ms=\(ordinaryElapsed) first_pull_ms=\(pullElapsed) mention_accept_ms=\(mentionElapsed) verification_ms=\(max(0, verificationElapsed)) ordinary_fanout_targets=0 mention_fanout_targets=0")

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("finalizing audience recovery claims each stale draft once before replay")
    func claimsStaleFinalizingAudienceRecoveryWork() async throws {
        guard Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1",
              let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL")
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            let recoveryIndex = try #require(try await sql.raw("""
                SELECT COUNT(*) AS value
                FROM pg_indexes
                WHERE schemaname = 'im_v2'
                  AND tablename = 'group_room_creation_drafts'
                  AND indexname = 'group_room_creation_drafts_finalizing_recovery_idx'
                """).first(decoding: CountRow.self))
            #expect(recoveryIndex.value == 1)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let stale = now.addingTimeInterval(-31)
            let actor = UUID(uuidString: "00000000-0000-0000-0000-00000000c101")!
            let first = UUID(uuidString: "00000000-0000-0000-0000-00000000c102")!
            let second = UUID(uuidString: "00000000-0000-0000-0000-00000000c103")!
            try await sql.raw("""
                INSERT INTO im_v2.group_room_creation_drafts
                    (actor_user_id, operation_id, title, state, created_at, updated_at, expires_at)
                VALUES
                    (\(bind: actor), \(bind: first), '恢复一', 'finalizing', \(bind: stale), \(bind: stale), \(bind: now.addingTimeInterval(86_400))),
                    (\(bind: actor), \(bind: second), '恢复二', 'finalizing', \(bind: stale), \(bind: stale), \(bind: now.addingTimeInterval(86_400)))
                """).run()
            let store = PostgresV2GroupAudienceImportStore(database: resources.database(.psql))

            let firstClaim = try await store.recoverableFinalizing(now: now, staleAfter: 30, limit: 1)
            let secondClaim = try await store.recoverableFinalizing(now: now, staleAfter: 30, limit: 2)
            let repeatedClaim = try await store.recoverableFinalizing(now: now, staleAfter: 30, limit: 2)

            #expect(firstClaim.count == 1)
            #expect(secondClaim.count == 1)
            #expect(Set((firstClaim + secondClaim).map(\.operationID)) == Set([try GroupRoomOperationID(first.uuidString), try GroupRoomOperationID(second.uuidString)]))
            #expect(repeatedClaim.isEmpty)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("disabled content review creates no job for message acceptance or editing")
    func disabledContentReviewSkipsDurableJobs() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10,
                  retryAfterSeconds: 3
            ))
            let sender = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: resources.database(.psql), contentReviewMode: .disabled),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            guard case .accepted(let accepted) = try await sender.send(.init(
                roomID: roomID,
                actorUserID: senderID,
                clientMessageID: clientMessageID,
                text: "review lane disabled"
            )) else {
                Issue.record("expected accepted message")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            #expect(try await count("im_v2.content_review_jobs", on: sql) == 0)

            let editor = V2MessageEditService(
                store: PostgresV2MessageEditStore(database: resources.database(.psql), contentReviewMode: .disabled),
                capacityProfile: profile,
                maximumTextUTF8Bytes: 64,
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000da1")! }),
                now: { now.addingTimeInterval(1) }
            )
            guard case .edited = try await editor.edit(.init(
                roomID: roomID,
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-000000000da2"),
                messageID: accepted.messageID,
                expectedMessageRevision: 1,
                text: "still not reviewed"
            )) else {
                Issue.record("expected edited message")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            #expect(try await count("im_v2.content_review_jobs", on: sql) == 0)

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

    @Test("content review jobs commit with messages, fence expired leases, and persist review decisions")
    func contentReviewJobsAreTransactionalLeaseFencedAndDurablyResolved() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10,
                  retryAfterSeconds: 3
            ))
            let sender = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: resources.database(.psql)),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            guard case .accepted(let accepted) = try await sender.send(.init(
                roomID: roomID,
                actorUserID: senderID,
                clientMessageID: clientMessageID,
                text: "needs review"
            )) else {
                Issue.record("expected accepted message")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let messageUUID = try #require(UUID(uuidString: accepted.messageID.rawValue))
            let initial = try #require(try await sql.raw("""
                SELECT state, expected_content_revision, decision
                FROM im_v2.content_review_jobs WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewJobAssertionRow.self))
            #expect(initial.state == "pending")
            #expect(initial.revision == 1)
            #expect(initial.decision == nil)

            let oldToken = UUID(uuidString: "00000000-0000-0000-0000-000000000d01")!
            let newToken = UUID(uuidString: "00000000-0000-0000-0000-000000000d02")!
            let oldStore = PostgresV2ContentReviewStore(database: resources.database(.psql), makeUUID: { oldToken })
            let oldLease = try #require(try await oldStore.claimPending(now: now, leaseDuration: 10, limit: 1).first)
            #expect(oldLease.input.messageID == accepted.messageID)
            #expect(try await oldStore.validateAndRenew(oldLease, now: now.addingTimeInterval(1), leaseDuration: 9) == .current)

            let renewedStore = PostgresV2ContentReviewStore(database: resources.database(.psql), makeUUID: { newToken })
            let renewedLease = try #require(try await renewedStore.claimPending(now: now.addingTimeInterval(11), leaseDuration: 10, limit: 1).first)
            #expect(renewedLease.claimToken == newToken)
            #expect(renewedLease.claimToken != oldLease.claimToken)

            // An old worker may resume after its lease expires, but it must
            // never release or resolve the newer owner's claim.
            try await oldStore.scheduleRetry(oldLease, disposition: .retry(at: now.addingTimeInterval(20)), now: now.addingTimeInterval(12))
            #expect(try await oldStore.resolve(oldLease, verdict: .clear, now: now.addingTimeInterval(12)) == false)
            let fenced = try #require(try await sql.raw("""
                SELECT state, claim_token = \(bind: newToken) AS has_new_token, decision
                FROM im_v2.content_review_jobs WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewLeaseFenceAssertionRow.self))
            #expect(fenced.state == "claimed")
            #expect(fenced.hasNewToken)
            #expect(fenced.decision == nil)

            #expect(try await renewedStore.resolve(
                renewedLease,
                verdict: .reviewRequired(try .init(category: "manual_review", severity: 2, confidence: 0.75)),
                now: now.addingTimeInterval(12)
            ))
            let completed = try #require(try await sql.raw("""
                SELECT state, decision, claim_token IS NULL AS released
                FROM im_v2.content_review_jobs WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewCompletionAssertionRow.self))
            #expect(completed.state == "completed")
            #expect(completed.decision == "review_required")
            #expect(completed.released == true)
            #expect(try await count("im_v2.content_review_decisions", on: sql) == 1)
            #expect(try await count("im_v2.content_review_findings", on: sql) == 1)
            #expect(try await count("im_v2.content_review_cases", on: sql) == 1)

            // A late worker must never close or redact a newer edit. The
            // edit path rewrites the expected revision in its own transaction;
            // this assertion exercises the review store's final fence.
            guard case .accepted(let editedLater) = try await sender.send(.init(
                roomID: roomID,
                actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-000000000d03"),
                text: "will be edited before review"
            )) else {
                Issue.record("expected second accepted message")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let editedLaterUUID = try #require(UUID(uuidString: editedLater.messageID.rawValue))
            let staleStore = PostgresV2ContentReviewStore(
                database: resources.database(.psql),
                makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000d04")! }
            )
            let staleLease = try #require(try await staleStore.claimPending(now: now.addingTimeInterval(20), leaseDuration: 10, limit: 1).first)
            #expect(staleLease.input.messageID == editedLater.messageID)
            try await sql.raw("UPDATE im_v2.messages SET content_revision = 2 WHERE message_id = \(bind: editedLaterUUID)").run()
            #expect(try await staleStore.validateAndRenew(staleLease, now: now.addingTimeInterval(21), leaseDuration: 10) == .superseded)
            let superseded = try #require(try await sql.raw("""
                SELECT state, decision FROM im_v2.content_review_jobs WHERE message_id = \(bind: editedLaterUUID)
                """).first(decoding: ContentReviewCompletionAssertionRow.self))
            #expect(superseded.state == "superseded")
            #expect(superseded.decision == nil)

            // A slow provider may return after its original deadline. If no
            // other worker has replaced the token, validation renews the same
            // claim instead of permanently superseding valid content.
            guard case .accepted(let slowReview) = try await sender.send(.init(
                roomID: roomID,
                actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-000000000d05"),
                text: "slow review"
            )) else {
                Issue.record("expected third accepted message")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let slowStore = PostgresV2ContentReviewStore(
                database: resources.database(.psql),
                makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000d06")! }
            )
            let slowLease = try #require(try await slowStore.claimPending(now: now.addingTimeInterval(30), leaseDuration: 1, limit: 1).first)
            #expect(slowLease.input.messageID == slowReview.messageID)
            #expect(try await slowStore.validateAndRenew(slowLease, now: now.addingTimeInterval(32), leaseDuration: 10) == .current)

            let retryAt = now.addingTimeInterval(50)
            try await slowStore.scheduleRetry(slowLease, disposition: .retry(at: retryAt), now: now.addingTimeInterval(33))
            #expect(try await slowStore.claimPending(now: now.addingTimeInterval(49), leaseDuration: 10, limit: 1).isEmpty)
            let retryLease = try #require(try await slowStore.claimPending(now: retryAt, leaseDuration: 10, limit: 1).first)
            #expect(retryLease.attempt == slowLease.attempt + 1)
            try await slowStore.scheduleRetry(retryLease, disposition: .pause, now: now.addingTimeInterval(51))
            let paused = try #require(try await sql.raw("""
                SELECT state, next_attempt_at, paused_at
                FROM im_v2.content_review_jobs
                WHERE message_id = \(bind: UUID(uuidString: slowReview.messageID.rawValue)!)
                """).first(decoding: ContentReviewRetryAssertionRow.self))
            #expect(paused.state == "paused")
            #expect(paused.nextAttemptAt == nil)
            #expect(paused.pausedAt == now.addingTimeInterval(51))
            let reviewMetrics = PostgresV2DurableWorkMetricsSource(database: resources.database(.psql))
            #expect((await reviewMetrics.durableWorkMetricsSnapshot()).pausedContentReviews == 1)

            let replay = V2DurableWorkOperatorReplayService(
                store: PostgresV2DurableWorkReplayStore(database: resources.database(.psql)),
                operatorPrincipal: "content-safety-oncall",
                now: { now.addingTimeInterval(52) }
            )
            let replayResult = try await replay.replay(.init(
                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000d07")!,
                target: try .init(kind: .contentReview, sourceEventID: .init(slowReview.messageID.rawValue)),
                reason: .dependencyRecovered
            ))
            #expect(replayResult.outcome == .requeued)
            let replayedMetrics = await reviewMetrics.durableWorkMetricsSnapshot()
            #expect(replayedMetrics.pausedContentReviews == 0)
            #expect(replayedMetrics.readyContentReviews == 1)
            let replayedLease = try #require(try await slowStore.claimPending(now: now.addingTimeInterval(52), leaseDuration: 10, limit: 1).first)
            #expect(replayedLease.input.messageID == slowReview.messageID)
            #expect(replayedLease.attempt == 1)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("a content-review escalation keeps the message visible and opens exactly one review case")
    func contentReviewEscalationDoesNotRedactTheMessage() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10,
                  retryAfterSeconds: 3
            ))
            let sender = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: resources.database(.psql)),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            guard case .accepted(let accepted) = try await sender.send(.init(
                roomID: roomID,
                actorUserID: senderID,
                clientMessageID: clientMessageID,
                text: "needs manual review"
            )) else {
                Issue.record("expected accepted message")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }

            let reviewStore = PostgresV2ContentReviewStore(
                database: resources.database(.psql),
                makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000d10")! }
            )
            let moderation = V2TrustedSafetyModerationService(
                store: PostgresV2ModerationStore(database: resources.database(.psql)),
                safetyActorUserID: try .init("00000000-0000-0000-0000-000000000d12"),
                capacityProfile: profile,
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000d13")! }),
                now: { now.addingTimeInterval(1) }
            )
            let worker = try V2ContentReviewWorker(
                store: reviewStore,
                reviewer: V2ConfiguredContentReviewer(reviewTerms: ["manual"]),
                moderation: moderation,
                now: { now.addingTimeInterval(1) }
            )

            #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, resolvedCount: 1, redactedCount: 0, releasedCount: 0))
            let messageUUID = try #require(UUID(uuidString: accepted.messageID.rawValue))
            let message = try #require(try await sql.raw("""
                SELECT withdrawn_at IS NOT NULL AS withdrawn, content_revision
                FROM im_v2.messages WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewRedactionAssertionRow.self))
            let job = try #require(try await sql.raw("""
                SELECT state, decision FROM im_v2.content_review_jobs WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewCompletionAssertionRow.self))
            #expect(!message.withdrawn)
            #expect(message.revision == 1)
            #expect(job.state == "completed")
            #expect(job.decision == "review_required")
            #expect(try await count("im_v2.content_review_decisions", on: sql) == 1)
            #expect(try await count("im_v2.content_review_findings", on: sql) == 1)
            #expect(try await count("im_v2.content_review_cases", on: sql) == 1)
            #expect(try await count("im_v2.moderation_operations", on: sql) == 0)
            #expect(try await count("im_v2.moderation_audit_entries", on: sql) == 0)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("a content policy violation resumes its staged finding after a crash following authoritative redaction")
    func contentReviewViolationUsesAuthoritativeRedaction() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10,
                  retryAfterSeconds: 3
            ))
            let sender = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: resources.database(.psql)),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            guard case .accepted(let accepted) = try await sender.send(.init(
                roomID: roomID,
                actorUserID: senderID,
                clientMessageID: clientMessageID,
                text: "blocked policy text"
            )) else {
                Issue.record("expected accepted message")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let reviewStore = PostgresV2ContentReviewStore(
                database: resources.database(.psql),
                makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000d11")! }
            )
            let moderation = V2TrustedSafetyModerationService(
                store: PostgresV2ModerationStore(database: resources.database(.psql)),
                safetyActorUserID: try .init("00000000-0000-0000-0000-000000000d12"),
                capacityProfile: profile,
                identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000d13")! }),
                now: { now.addingTimeInterval(1) }
            )
            let crashedLease = try #require(try await reviewStore.claimPending(
                now: now.addingTimeInterval(1), leaseDuration: 1, limit: 1
            ).first)
            let finding = try V2ContentReviewFinding(category: "configured_policy", severity: 4, confidence: 1)
            #expect(try await reviewStore.stageViolation(crashedLease, finding: finding))
            let redaction = try V2TrustedSafetyModeration(
                roomID: crashedLease.input.roomID,
                operationID: .init(crashedLease.input.messageID.rawValue),
                action: .redactMessage,
                messageID: crashedLease.input.messageID,
                expectedMessageRevision: crashedLease.input.contentRevision,
                reasonCode: .init("content_policy_violation")
            )
            guard case .applied = try await moderation.apply(redaction) else {
                Issue.record("expected the authoritative redaction to commit before the simulated crash")
                throw V2RoomWriteStoreError.corruptPersistenceState
            }

            // Simulate process loss before resolve(). The replacement lease
            // must reuse the staged finding, recognize its stable moderation
            // operation, and never call the provider again.
            let recoveringStore = PostgresV2ContentReviewStore(
                database: resources.database(.psql),
                makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000d14")! }
            )
            let recoveringWorker = try V2ContentReviewWorker(
                store: recoveringStore,
                reviewer: UnexpectedContentReviewer(),
                moderation: moderation,
                now: { now.addingTimeInterval(3) }
            )
            #expect(try await recoveringWorker.runOnce(limit: 1) == .init(
                claimedCount: 1, resolvedCount: 1, redactedCount: 1, releasedCount: 0
            ))
            let messageUUID = try #require(UUID(uuidString: accepted.messageID.rawValue))
            let redacted = try #require(try await sql.raw("""
                SELECT withdrawn_at IS NOT NULL AS withdrawn, content_revision
                FROM im_v2.messages WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewRedactionAssertionRow.self))
            let job = try #require(try await sql.raw("""
                SELECT state, decision FROM im_v2.content_review_jobs WHERE message_id = \(bind: messageUUID)
                """).first(decoding: ContentReviewCompletionAssertionRow.self))
            #expect(redacted.withdrawn)
            #expect(redacted.revision == 2)
            #expect(job.state == "completed")
            #expect(job.decision == "violation")
            #expect(try await count("im_v2.content_review_decisions", on: sql) == 1)
            #expect(try await count("im_v2.content_review_findings", on: sql) == 1)
            #expect(try await count("im_v2.moderation_operations", on: sql) == 1)
            #expect(try await count("im_v2.moderation_audit_entries", on: sql) == 1)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("forward routes co-located pairs to their real database and explicitly rejects cross-owner copies")
    func forwardUsesPhysicalOwnerDatabases() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              let secondaryURL = Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        let secondary = DatabaseID(string: "forward-owner-b")
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            resources.databases.use(try .postgres(url: secondaryURL, maxConnectionsPerEventLoop: 1), as: secondary)
            let primarySQL = try #require(resources.database(.psql) as? any SQLDatabase)
            let secondarySQL = try #require(resources.database(secondary) as? any SQLDatabase)
            for sql in [primarySQL, secondarySQL] {
                guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
                try await installSchema(on: sql)
            }
            let roomB = UUID()
            let roomBID = RoomID(uuid: roomB)
            try await seedRoom(on: primarySQL)
            try await seedRoom(roomID: roomB, shardID: "room-b", on: secondarySQL)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            // seedRoom already installs the local room-a route. Add only the
            // remote room-b route to this test's control directory.
            try await primarySQL.raw("""
                INSERT INTO im_v2.room_owner_routes (room_id, room_shard_id, route_epoch, created_at, updated_at)
                VALUES (\(bind: roomB), 'room-b', 0, \(bind: now), \(bind: now))
                """).run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10,
                  retryAfterSeconds: 3
            ))
            let limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let writeA = PostgresV2RoomWriteStore(database: resources.database(.psql))
            let writeB = PostgresV2RoomWriteStore(database: resources.database(secondary))
            let sendA = V2SendMessageService(store: writeA, capacityProfile: profile, limits: limits, now: { now })
            let sendB = V2SendMessageService(store: writeB, capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let sourceA) = try await sendA.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "source in primary")),
                  case .accepted(let sourceB) = try await sendB.send(.init(roomID: roomBID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "source only in owner B"))
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let router = V2PostgresRoomShardRouter(database: resources.database(.psql))
            let service = try V2RoutedForwardMessagesService(router: router, owners: [
                "room-a": V2ForwardMessagesService(database: resources.database(.psql), writeStore: writeA, capacityProfile: profile, limits: limits, now: { now }),
                "room-b": V2ForwardMessagesService(database: resources.database(secondary), writeStore: writeB, capacityProfile: profile, limits: limits, now: { now })
            ])
            let chunkID = try V2ForwardChunkIdentity.operationID(planID: .init("00000000-0000-0000-0000-00000000f001"), chunkIndex: 0)
            #expect(chunkID.uuidValue == UUID(uuidString: "59993946-8967-8ccb-9846-764840d87627"))
            let command = try V2ForwardMessagesCommand(operationID: chunkID, sources: [
                .init(roomID: roomID, messageID: sourceA.messageID, revision: .init(1)),
                .init(roomID: roomBID, messageID: sourceB.messageID, revision: .init(1))
            ], targetRoomIDs: [roomID, roomBID])
            let results = try await service.forward(actorUserID: senderID, command: command)
            #expect(results.map(\.errorCode) == [nil, "CROSS_OWNER_FORWARD_UNAVAILABLE", "CROSS_OWNER_FORWARD_UNAVAILABLE", nil])
            for sql in [primarySQL, secondarySQL] {
                #expect(try await count("im_v2.messages", on: sql) == 2)
                #expect(try await count("im_v2.message_forward_operations", on: sql) == 1)
                #expect(try await count("im_v2.message_send_completions", on: sql) == 2)
            }
            #expect(try await primarySQL.raw("SELECT count(*) AS value FROM im_v2.messages WHERE room_id = \(bind: roomB)").first(decoding: CountRow.self)?.value == 0)
            #expect(try await secondarySQL.raw("SELECT count(*) AS value FROM im_v2.messages WHERE room_id = \(bind: roomUUID)").first(decoding: CountRow.self)?.value == 0)
            let withdrawal = V2MessageWithdrawalService(store: PostgresV2MessageWithdrawalStore(database: resources.database(secondary)), capacityProfile: profile, now: { now.addingTimeInterval(1) })
            _ = try await withdrawal.withdraw(.init(roomID: roomBID, actorUserID: senderID, operationID: .init(uuid: UUID()), messageID: sourceB.messageID, expectedMessageRevision: 1))
            #expect(try await service.forward(actorUserID: senderID, command: command) == results)
            for sql in [primarySQL, secondarySQL] { try await sql.raw("DROP SCHEMA im_v2 CASCADE").run() }
            try await resources.shutdown()
        } catch {
            for database in [resources.database(.psql), resources.database(secondary)] {
                if let sql = database as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("source exports are immutable, bounded, concurrent-retry safe and pin exact media", arguments: [V2GroupCapacityClass.standard, .large])
    func forwardExportCommitAndReplay(capacityClass: V2GroupCapacityClass) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let database = resources.database(.psql)
            let sql = try #require(database as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(capacityClass: capacityClass, on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            // Seed a nonzero owner epoch in the current schema.
            try await sql.raw("""
                INSERT INTO im_v2.room_owner_routes (room_id, room_shard_id, route_epoch, created_at, updated_at)
                VALUES (\(bind: roomUUID), 'room-a', 7, \(bind: now), \(bind: now)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id = EXCLUDED.room_shard_id, route_epoch = EXCLUDED.route_epoch, updated_at = EXCLUDED.updated_at
                """).run()
            try await sql.raw("UPDATE im_v2.rooms SET owner_epoch = 7 WHERE room_id = \(bind: roomUUID)").run()
            try await V2SchemaReadiness.verify(database: database)
            try await assertSQLSchemaGate(true, on: sql)
            let mediaIDs = [UUID(uuidString: "00000000-0000-0000-0000-00000000e202")!, UUID(uuidString: "00000000-0000-0000-0000-00000000e201")!]
            let orphanID = UUID()
            for asset in mediaIDs + [orphanID] {
                try await sql.raw("""
                    INSERT INTO im_v2.media_objects (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at)
                    VALUES (\(bind: asset), \(bind: senderUUID), 'image/png', 42, 'available', \(bind: UUID()), \(bind: now.addingTimeInterval(600)), \(bind: now), \(bind: now))
                    """).run()
            }
            let limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10,
                  retryAfterSeconds: 3
            ))
            let write = PostgresV2RoomWriteStore(database: database)
            let send = V2SendMessageService(store: write, capacityProfile: profile, limits: limits, now: { now })
            let entity = try V2MessageEntity(offsetUTF16: 0, lengthUTF16: 8, kind: .bold)
            guard case .accepted(let source) = try await send.send(.init(
                roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "original caption",
                media: mediaIDs.map { V2MediaReference(mediaID: .init(uuid: $0)) }, entities: [entity]
            )) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let reference = try V2ForwardMessageReference(roomID: roomID, messageID: source.messageID, revision: .init(1))
            let operation = MessageForwardOperationID(uuid: UUID())
            let target = RoomID(uuid: UUID()) // Deliberately absent from this source database.
            let route = try V2RoomShardRoute(shardID: "room-a", epoch: 7)
            let targetRoute = try V2RoomShardRoute(shardID: "room-b", epoch: 12)
            let exports = PostgresV2ForwardExportStore(database: database, maximumExportsPerRoom: 1)
            for badRoute in [try V2RoomShardRoute(shardID: "room-a", epoch: 6), try V2RoomShardRoute(shardID: "wrong-owner", epoch: 7)] {
                await #expect(throws: V2ForwardExportError.ownerChanged) {
                    try await exports.prepare(actorUserID: senderID, operationID: operation, source: reference,
                                              sourceRoute: badRoute, targetRoomID: target, targetRoute: targetRoute, now: now)
                }
            }
            // A failing media check leaves no export, client identity or pin.
            try await sql.raw("UPDATE im_v2.media_objects SET state = 'failed' WHERE media_id = \(bind: mediaIDs[1])").run()
            await #expect(throws: V2ForwardExportError.mediaUnavailable) {
                try await exports.prepare(actorUserID: senderID, operationID: operation, source: reference,
                                          sourceRoute: route, targetRoomID: target, targetRoute: targetRoute, now: now)
            }
            #expect(try await count("im_v2.message_forward_exports", on: sql) == 0)
            try await sql.raw("UPDATE im_v2.media_objects SET state = 'available' WHERE media_id = \(bind: mediaIDs[1])").run()
            let competing = try await withThrowingTaskGroup(of: V2ForwardExport.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        try await PostgresV2ForwardExportStore(database: database, maximumExportsPerRoom: 1)
                            .prepare(actorUserID: senderID, operationID: operation, source: reference,
                                     sourceRoute: route, targetRoomID: target, targetRoute: targetRoute, now: now)
                    }
                }
                var results: [V2ForwardExport] = []
                for try await result in group { results.append(result) }
                return results
            }
            let original = try #require(competing.first)
            #expect(competing.count == 16 && competing.allSatisfy { $0 == original })
            #expect(original.intent.text == "original caption")
            #expect(original.intent.entities == [entity])
            #expect(original.intent.media.map(\.mediaID) == mediaIDs)
            #expect(original.intent.media.allSatisfy { $0.contentType == "image/png" && $0.byteCount == 42 })
            #expect(original.intent.sourceEpoch == 7 && original.intent.targetEpoch == 12)
            #expect(try await count("im_v2.message_forward_exports", on: sql) == 1)
            // Export commit is not target success and emits no target message.
            #expect(try await count("im_v2.messages", on: sql) == 1)
            #expect(try await count("im_v2.message_send_completions", on: sql) == 1)
            for statement in ["UPDATE im_v2.message_forward_exports SET source_content_revision = 2", "UPDATE im_v2.message_forward_exports SET payload = 'x'::bytea", "DELETE FROM im_v2.message_forward_exports"] {
                await #expect(throws: (any Error).self) { try await sql.raw("\(unsafeRaw: statement)").run() }
            }
            var damaged = original.payload; damaged[0] ^= 1
            #expect(throws: V2ForwardExportError.corruptPersistenceState) { try V2ForwardExport(payload: damaged, digest: original.digest) }
            await #expect(throws: V2ForwardExportError.capacityExceeded) {
                try await exports.prepare(actorUserID: senderID, operationID: .init(uuid: UUID()), source: reference,
                                          sourceRoute: route, targetRoomID: target, targetRoute: targetRoute, now: now)
            }
            let edit = V2MessageEditService(store: PostgresV2MessageEditStore(database: database), capacityProfile: profile, maximumTextUTF8Bytes: 64, now: { now.addingTimeInterval(1) })
            guard case .edited = try await edit.edit(.init(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), messageID: source.messageID, expectedMessageRevision: 1, text: "changed later")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            await #expect(throws: V2ForwardExportError.sourceChanged) {
                try await exports.prepare(actorUserID: senderID, operationID: .init(uuid: UUID()), source: reference,
                                          sourceRoute: route, targetRoomID: target, targetRoute: targetRoute, now: now)
            }
            await #expect(throws: V2ForwardExportError.idempotencyConflict) {
                try await exports.prepare(actorUserID: senderID, operationID: operation,
                                          source: .init(roomID: roomID, messageID: source.messageID, revision: .init(2)),
                                          sourceRoute: route, targetRoomID: target, targetRoute: targetRoute, now: now)
            }
            await #expect(throws: V2ForwardExportError.idempotencyConflict) {
                try await exports.prepare(actorUserID: senderID, operationID: operation,
                                          source: .init(roomID: target, messageID: source.messageID, revision: .init(1)),
                                          sourceRoute: route, targetRoomID: target, targetRoute: targetRoute, now: now)
            }
            let withdrawal = V2MessageWithdrawalService(store: PostgresV2MessageWithdrawalStore(database: database), capacityProfile: profile, now: { now.addingTimeInterval(2) })
            guard case .withdrawn = try await withdrawal.withdraw(.init(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), messageID: source.messageID, expectedMessageRevision: 2)) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            await #expect(throws: V2ForwardExportError.sourceUnavailable) {
                try await exports.prepare(actorUserID: senderID, operationID: .init(uuid: UUID()), source: reference,
                                          sourceRoute: route, targetRoomID: target, targetRoute: targetRoute, now: now)
            }
            // Later leave/withdrawal/epoch changes cannot reauthorize or rewrite
            // the already-committed copy. A new connection pool reads its bytes.
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = 1 WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: senderUUID)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1, owner_epoch = 8 WHERE room_id = \(bind: roomUUID)").run()
            let later = now.addingTimeInterval(3_600)
            let retention = PostgresV2MediaRetentionStore(database: database)
            #expect(try await retention.expireEligibleMedia(now: later, withdrawnRetention: 60, limit: 10) == 1)
            #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.media_objects WHERE state = 'available'").first(decoding: CountRow.self)?.value == 2)
            #expect(try await count("im_v2.media_purge_outbox", on: sql) == 1)
            let secondResources = makeV2DatabaseTestResources()
            do {
                secondResources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
                let replay = try await PostgresV2ForwardExportStore(database: secondResources.database(.psql)).prepare(
                    actorUserID: senderID, operationID: operation, source: reference,
                    sourceRoute: .init(shardID: "room-a", epoch: 8), targetRoomID: target,
                    targetRoute: .init(shardID: "room-c", epoch: 13), now: later)
                #expect(replay == original)
                try await secondResources.shutdown()
            } catch { try? await secondResources.shutdown(); throw error }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("export and withdrawal serialize at the source commit in both orders", arguments: [true, false])
    func forwardExportWithdrawalCommitOrder(exportWins: Bool) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let database = resources.database(.psql)
            let sql = try #require(database as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10,
                  retryAfterSeconds: 3
            ))
            let send = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: profile,
                                            limits: .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let source) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "commit boundary")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let reference = try V2ForwardMessageReference(roomID: roomID, messageID: source.messageID, revision: .init(1))
            let operation = MessageForwardOperationID(uuid: UUID())
            let target = RoomID(uuid: UUID())
            let sourceRoute = try V2RoomShardRoute(shardID: "room-a", epoch: 0)
            let targetRoute = try V2RoomShardRoute(shardID: "room-b", epoch: 0)
            let exports = PostgresV2ForwardExportStore(database: database)
            let withdrawal = V2MessageWithdrawalService(store: PostgresV2MessageWithdrawalStore(database: database), capacityProfile: profile, now: { now.addingTimeInterval(1) })
            let withdrawalCommand = V2AuthenticatedMessageWithdrawal(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), messageID: source.messageID, expectedMessageRevision: 1)
            // Pause the winner inside its real write transaction, after the
            // source room lock. The loser must wait for that transaction ID.
            try await sql.raw("""
                CREATE FUNCTION im_v2.zz_test_forward_commit_gate() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    PERFORM pg_advisory_xact_lock(7316204993);
                    RETURN NEW;
                END;
                $$
                """).run()
            let trigger = exportWins
                ? "CREATE TRIGGER zz_test_forward_commit_gate BEFORE INSERT ON im_v2.message_forward_exports FOR EACH ROW EXECUTE FUNCTION im_v2.zz_test_forward_commit_gate()"
                : "CREATE TRIGGER zz_test_forward_commit_gate BEFORE UPDATE OF withdrawn_at ON im_v2.messages FOR EACH ROW WHEN (NEW.withdrawn_at IS NOT NULL) EXECUTE FUNCTION im_v2.zz_test_forward_commit_gate()"
            try await sql.raw("\(unsafeRaw: trigger)").run()
            let gate = PostgreSQLTransactionGate()
            let blocker = Task {
                try await database.transaction { transaction in
                    let connection = try #require(transaction as? any SQLDatabase)
                    try await connection.raw("SELECT pg_advisory_xact_lock(7316204993)").run()
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()
            var exporting: Task<V2ForwardExport, Error>?
            var withdrawing: Task<V2MessageWithdrawalOutcome, Error>?
            do {
                if exportWins {
                    exporting = Task { try await exports.prepare(actorUserID: senderID, operationID: operation, source: reference, sourceRoute: sourceRoute, targetRoomID: target, targetRoute: targetRoute, now: now) }
                    try await waitForAdvisoryWaiters(1, on: sql)
                    withdrawing = Task { try await withdrawal.withdraw(withdrawalCommand) }
                } else {
                    withdrawing = Task { try await withdrawal.withdraw(withdrawalCommand) }
                    try await waitForAdvisoryWaiters(1, on: sql)
                    exporting = Task { try await exports.prepare(actorUserID: senderID, operationID: operation, source: reference, sourceRoute: sourceRoute, targetRoomID: target, targetRoute: targetRoute, now: now) }
                }
                try await waitForPostgreSQLLockWaiters(1, lockType: "transactionid", on: sql)
            } catch {
                await gate.releaseTransaction()
                _ = try? await blocker.value
                _ = try? await exporting?.value
                _ = try? await withdrawing?.value
                throw error
            }
            await gate.releaseTransaction()
            try await blocker.value
            let exportTask = try #require(exporting)
            let withdrawTask = try #require(withdrawing)
            let exportResult = await exportTask.result
            let withdrawalResult = await withdrawTask.result
            if exportWins {
                let copy = try exportResult.get()
                #expect(copy.intent.text == "commit boundary")
                #expect(try await exports.prepare(actorUserID: senderID, operationID: operation, source: reference, sourceRoute: sourceRoute, targetRoomID: target, targetRoute: targetRoute, now: now) == copy)
            } else {
                #expect(throws: V2ForwardExportError.sourceUnavailable) { try exportResult.get() }
            }
            guard case .withdrawn = try withdrawalResult.get() else { throw V2RoomWriteStoreError.corruptPersistenceState }
            #expect(try await count("im_v2.message_forward_exports", on: sql) == (exportWins ? 1 : 0))
            #expect(try await count("im_v2.messages", on: sql) == 1)
            #expect(try await count("im_v2.message_send_completions", on: sql) == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("physical target inbox atomically accepts exports and recovers post-commit failure", arguments: [V2GroupCapacityClass.standard, .large])
    func forwardInboxAcceptanceAndRecovery(mode: V2GroupCapacityClass) async throws {
        try await withForwardOwnerDatabases(mode: mode) { sourceDB, targetDB, sourceSQL, targetSQL, target in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let actor = UserID(uuid: memberTwoUUID)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: sourceDB), capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let source) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "source owner only")) else { throw V2ForwardInboxError.corruptPersistenceState }
            let exporter = PostgresV2ForwardExportStore(database: sourceDB)
            let sourceRoute = try V2RoomShardRoute(shardID: "room-a", epoch: 0)
            let targetRoute = try V2RoomShardRoute(shardID: "room-b", epoch: 0)
            let reference = try V2ForwardMessageReference(roomID: roomID, messageID: source.messageID, revision: .init(1))
            let first = try await exporter.prepare(actorUserID: actor, operationID: .init(uuid: UUID()), source: reference, sourceRoute: sourceRoute, targetRoomID: target, targetRoute: targetRoute, now: now)
            let second = try await exporter.prepare(actorUserID: actor, operationID: .init(uuid: UUID()), source: reference, sourceRoute: sourceRoute, targetRoomID: target, targetRoute: targetRoute, now: now)
            let sourceWithdrawal = V2MessageWithdrawalService(store: PostgresV2MessageWithdrawalStore(database: sourceDB), capacityProfile: profile, now: { now.addingTimeInterval(1) })
            guard case .withdrawn = try await sourceWithdrawal.withdraw(.init(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), messageID: source.messageID, expectedMessageRevision: 1)) else { throw V2ForwardInboxError.corruptPersistenceState }
            let inbox = PostgresV2ForwardInboxStore(database: targetDB)
            try await inbox.receive(first, now: now)
            #expect(try await inbox.status(exportID: first.intent.exportID) == .pending(.admission))
            #expect(try await count("im_v2.messages", on: targetSQL) == 0)
            // Abort the inbox acceptance update after the message write.
            // A shared transaction must roll back both facts and all credits.
            try await targetSQL.raw("""
                CREATE FUNCTION im_v2.zz_test_abort_inbox_acceptance() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN RAISE EXCEPTION 'test rollback before target commit'; END; $$
                """).run()
            try await targetSQL.raw("""
                CREATE TRIGGER zz_test_abort_inbox_acceptance BEFORE UPDATE OF state ON im_v2.message_forward_inbox
                FOR EACH ROW WHEN (NEW.state = 'accepted') EXECUTE FUNCTION im_v2.zz_test_abort_inbox_acceptance()
                """).run()
            await #expect(throws: (any Error).self) {
                try await PostgresV2RoomWriteStore(database: targetDB).usingControlDatabase(sourceDB, authorizationResolutionDatabase: sourceDB).importForwardExport(first, capacityProfile: profile, limits: limits, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
            }
            #expect(try await inbox.status(exportID: first.intent.exportID) == .pending(.admission))
            #expect(try await count("im_v2.messages", on: targetSQL) == 0)
            #expect(try await count("im_v2.message_send_completions", on: targetSQL) == 0)
            #expect(try await count("im_v2.room_events", on: targetSQL) == 0)
            try await targetSQL.raw("DROP TRIGGER zz_test_abort_inbox_acceptance ON im_v2.message_forward_inbox").run()
            try await targetSQL.raw("DROP FUNCTION im_v2.zz_test_abort_inbox_acceptance()").run()
            let copies = try await withThrowingTaskGroup(of: V2ForwardImportOutcome.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        try await PostgresV2RoomWriteStore(database: targetDB).usingControlDatabase(sourceDB, authorizationResolutionDatabase: sourceDB).importForwardExport(first, capacityProfile: profile, limits: limits, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
                    }
                }
                var results: [V2ForwardImportOutcome] = []
                for try await result in group { results.append(result) }
                return results
            }
            let result = try #require(copies.first)
            guard case .accepted(let firstMessageID, let firstSequence) = result else { throw V2ForwardInboxError.corruptPersistenceState }
            #expect(copies.count == 16 && copies.allSatisfy { $0 == result })
            #expect(firstSequence == 1)
            #expect(try await count("im_v2.messages", on: targetSQL) == 1)
            #expect(try await count("im_v2.message_send_completions", on: targetSQL) == 1)
            #expect(try await targetSQL.raw("""
                SELECT count(*) AS value FROM im_v2.messages WHERE message_id = \(bind: firstMessageID.uuidValue!)
                  AND text_body = 'source owner only' AND sender_user_id = \(bind: memberTwoUUID)
                  AND forwarded_from_message_id = \(bind: source.messageID.uuidValue!) AND forwarded_from_user_id = \(bind: senderUUID)
                """).first(decoding: CountRow.self)?.value == 1)
            #expect(try await targetSQL.raw("SELECT count(*) AS value FROM im_v2.messages WHERE room_id = \(bind: roomUUID)").first(decoding: CountRow.self)?.value == 0)
            // Even a checksum-valid envelope cannot alter a received ID or
            // replace the export identity of an already-bound source/target pair.
            for field in ["text", "exportID"] {
                var object = try #require(JSONSerialization.jsonObject(with: first.payload) as? [String: Any])
                object[field] = field == "text" ? "changed after receive" : UUID().uuidString
                if field == "exportID" { object["targetClientMessageID"] = UUID().uuidString }
                let alteredIntent = try JSONDecoder().decode(V2ForwardExportIntent.self, from: JSONSerialization.data(withJSONObject: object))
                let altered = try V2ForwardExport(intent: alteredIntent)
                await #expect(throws: V2ForwardInboxError.idempotencyConflict) { try await inbox.receive(altered, now: now) }
            }
            #expect(try await count("im_v2.message_forward_inbox", on: targetSQL) == 1)
            // Attribution does not gain the trusted inbox capability.
            let forged = try V2SendMessageCommand(roomID: target, senderUserID: actor, clientMessageID: .init(uuid: UUID()), text: first.intent.text,
                forwardedFrom: .init(messageID: source.messageID, senderUserID: senderID, sourceRevision: .init(1)), limits: limits)
            let targetWrite = PostgresV2RoomWriteStore(database: targetDB).usingControlDatabase(sourceDB, authorizationResolutionDatabase: sourceDB)
            await #expect(throws: V2RoomWriteStoreError.actorNotEligible) {
                try await targetWrite.accept(command: forged, capacityProfile: profile, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
            }
            // Fail only the post-finalization marker. The target message and
            // inbox accepted receipt must commit together and survive failure.
            try await targetSQL.raw("""
                CREATE FUNCTION im_v2.zz_test_fail_inbox_completion() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN RAISE EXCEPTION 'test failure after target commit'; END; $$
                """).run()
            try await targetSQL.raw("""
                CREATE TRIGGER zz_test_fail_inbox_completion BEFORE UPDATE OF state ON im_v2.message_forward_inbox
                FOR EACH ROW WHEN (NEW.state = 'completed') EXECUTE FUNCTION im_v2.zz_test_fail_inbox_completion()
                """).run()
            await #expect(throws: (any Error).self) {
                try await targetWrite.importForwardExport(second, capacityProfile: profile, limits: limits, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
            }
            #expect(try await inbox.status(exportID: second.intent.exportID) == .pending(.finalization))
            #expect(try await count("im_v2.messages", on: targetSQL) == 2)
            #expect(try await count("im_v2.message_send_completions", on: targetSQL) == 2)
            #expect(try await inbox.terminalReceipt(exportID: second.intent.exportID) == nil)
            try await targetSQL.raw("DROP TRIGGER zz_test_fail_inbox_completion ON im_v2.message_forward_inbox").run()
            try await targetSQL.raw("DROP FUNCTION im_v2.zz_test_fail_inbox_completion()").run()
            let secondRow = try #require(try await targetSQL.raw("SELECT result_message_id AS value FROM im_v2.message_forward_inbox WHERE export_id = \(bind: second.intent.exportID)").first(decoding: ForwardInboxUUIDAssertion.self))
            let targetWithdrawal = V2MessageWithdrawalService(store: PostgresV2MessageWithdrawalStore(database: targetDB), capacityProfile: profile, now: { now.addingTimeInterval(2) })
            guard case .withdrawn = try await targetWithdrawal.withdraw(.init(roomID: target, actorUserID: actor, operationID: .init(uuid: UUID()), messageID: .init(uuid: secondRow.value), expectedMessageRevision: 1)) else { throw V2ForwardInboxError.corruptPersistenceState }
            try await targetSQL.raw("UPDATE im_v2.room_memberships SET left_revision = 1 WHERE room_id = \(bind: target.uuidValue!) AND user_id = \(bind: memberTwoUUID)").run()
            try await targetSQL.raw("UPDATE im_v2.rooms SET membership_revision = 1, owner_epoch = 1 WHERE room_id = \(bind: target.uuidValue!)").run()
            let restarted = PostgresV2RoomWriteStore(database: targetDB).usingControlDatabase(sourceDB, authorizationResolutionDatabase: sourceDB)
            await #expect(throws: V2ForwardInboxError.ownerChanged) {
                try await restarted.importForwardExport(second, capacityProfile: profile, limits: .init(maxUTF8Bytes: 1), identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
            }
            #expect(try await inbox.status(exportID: second.intent.exportID) == .pending(.finalization))
            #expect(try await inbox.terminalReceipt(exportID: second.intent.exportID) == nil)
            // Completed receipts are immutable evidence even after a cutover.
            #expect(try await restarted.importForwardExport(first, capacityProfile: profile, limits: .init(maxUTF8Bytes: 1), identifiers: V2AcceptanceIDFactory().make(at: now), now: now) == result)
            // Restore only this disposable fixture's epoch. Membership loss,
            // tombstone and smaller current limits must still allow recovery.
            try await targetSQL.raw("UPDATE im_v2.rooms SET owner_epoch=0 WHERE room_id=\(bind: target.uuidValue!)").run()
            let recovered = try await restarted.importForwardExport(second, capacityProfile: profile, limits: .init(maxUTF8Bytes: 1), identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
            #expect(recovered == .accepted(messageID: .init(uuid: secondRow.value), roomSequence: 2))
            #expect(try await inbox.status(exportID: second.intent.exportID) == recovered)
            #expect(try await restarted.importForwardExport(first, capacityProfile: profile, limits: .init(maxUTF8Bytes: 1), identifiers: try V2AcceptanceIDFactory().make(at: now), now: now) == result)
            #expect(try await count("im_v2.messages", on: targetSQL) == 2)
            #expect(try await count("im_v2.message_send_completions", on: targetSQL) == 2)
            for statement in ["UPDATE im_v2.message_forward_inbox SET payload = 'x'::bytea", "UPDATE im_v2.message_forward_inbox SET result_room_sequence = 999", "DELETE FROM im_v2.message_forward_inbox"] {
                await #expect(throws: (any Error).self) { try await targetSQL.raw("\(unsafeRaw: statement)").run() }
            }
            #expect(try await count("im_v2.messages", on: sourceSQL) == 1)
        }
    }


    @Test("target inbox enforces current permission, owner epoch, admission and media readiness", arguments: ["removed", "muted", "frozen", "permission", "inactive", "epoch", "admission", "media"], [V2GroupCapacityClass.standard, .large])
    func forwardInboxTargetBoundaries(scenario: String, capacityClass: V2GroupCapacityClass) async throws {
        try await withForwardOwnerDatabases(mode: capacityClass) { sourceDB, targetDB, sourceSQL, targetSQL, target in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let actor = UserID(uuid: memberTwoUUID)
            var media: [V2MediaReference] = []
            if scenario == "media" {
                let asset = UUID()
                try await sourceSQL.raw("""
                    INSERT INTO im_v2.media_objects (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at)
                    VALUES (\(bind: asset), \(bind: senderUUID), 'image/png', 42, 'available', \(bind: UUID()), \(bind: now.addingTimeInterval(600)), \(bind: now), \(bind: now))
                    """).run()
                media = [.init(mediaID: .init(uuid: asset))]
            }
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: sourceDB), capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let source) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "authorize at target", media: media)) else { throw V2ForwardInboxError.corruptPersistenceState }
            let export = try await PostgresV2ForwardExportStore(database: sourceDB).prepare(actorUserID: actor, operationID: .init(uuid: UUID()),
                source: .init(roomID: roomID, messageID: source.messageID, revision: .init(1)), sourceRoute: .init(shardID: "room-a", epoch: 0),
                targetRoomID: target, targetRoute: .init(shardID: "room-b", epoch: 0), now: now)
            let inbox = PostgresV2ForwardInboxStore(database: targetDB)
            try await inbox.receive(export, now: now)
            let write = PostgresV2RoomWriteStore(database: targetDB).usingControlDatabase(sourceDB, authorizationResolutionDatabase: sourceDB)
            var completed: (V2ForwardExport, V2ForwardImportOutcome)?
            if ["removed", "muted", "frozen", "permission", "inactive"].contains(scenario) {
                let earlier = try await PostgresV2ForwardExportStore(database: sourceDB).prepare(actorUserID: actor,
                    operationID: .init(uuid: UUID()), source: .init(roomID: roomID, messageID: source.messageID, revision: .init(1)),
                    sourceRoute: .init(shardID: "room-a", epoch: 0), targetRoomID: target,
                    targetRoute: .init(shardID: "room-b", epoch: 0), now: now)
                try await inbox.receive(earlier, now: now)
                let accepted = try await write.importForwardExport(earlier, capacityProfile: profile, limits: limits,
                    identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
                guard case .accepted = accepted else { throw V2ForwardInboxError.corruptPersistenceState }
                completed = (earlier, accepted)
            }
            switch scenario {
            case "removed":
                try await targetSQL.raw("UPDATE im_v2.room_memberships SET left_revision = 1 WHERE room_id = \(bind: target.uuidValue!) AND user_id = \(bind: memberTwoUUID)").run()
                try await targetSQL.raw("UPDATE im_v2.rooms SET membership_revision = 1 WHERE room_id = \(bind: target.uuidValue!)").run()
            case "muted":
                try await targetSQL.raw("INSERT INTO im_v2.room_member_mutes (room_id, user_id, mute_until, actor_user_id, operation_id, created_at) VALUES (\(bind: target.uuidValue!), \(bind: memberTwoUUID), \(bind: now.addingTimeInterval(300)), \(bind: senderUUID), \(bind: UUID()), \(bind: now))").run()
            case "frozen":
                try await targetSQL.raw("UPDATE im_v2.rooms SET frozen_at = \(bind: now), frozen_by_user_id = \(bind: senderUUID) WHERE room_id = \(bind: target.uuidValue!)").run()
            case "permission":
                try await targetSQL.raw("INSERT INTO im_v2.group_role_permissions (room_id, role, permission) VALUES (\(bind: target.uuidValue!), 'member', 'invite_members')").run()
            case "inactive":
                try await targetSQL.raw("UPDATE im_v2.public_user_profiles SET state = 'suspended' WHERE user_id = \(bind: memberTwoUUID)").run()
            case "epoch":
                try await targetSQL.raw("UPDATE im_v2.rooms SET owner_epoch = 1 WHERE room_id = \(bind: target.uuidValue!)").run()
            case "admission":
                try await targetSQL.raw("UPDATE im_v2.room_admission SET command_window_used = command_window_limit WHERE room_id = \(bind: target.uuidValue!)").run()
            default: break
            }
            func admissionSnapshot() async throws -> [String] {
                var values: [String] = []
                for table in ["room_admission", "shard_admission_pools", "rooms"] {
                    values.append(try #require(try await targetSQL.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self)).value)
                }
                return values
            }
            let before = try await admissionSnapshot()
            if let (earlier, accepted) = completed {
                #expect(try await write.importForwardExport(earlier, capacityProfile: profile, limits: limits,
                    identifiers: try V2AcceptanceIDFactory().make(at: now), now: now) == accepted)
                #expect(try await inbox.status(exportID: earlier.intent.exportID) == accepted)
            }
            if scenario == "epoch" {
                await #expect(throws: V2ForwardInboxError.ownerChanged) {
                    try await write.importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
                }
                #expect(try await inbox.status(exportID: export.intent.exportID) == .pending(.admission))
            } else {
                let result = try await write.importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
                let expected: V2ForwardImportOutcome = switch scenario {
                case "removed", "permission", "inactive": .rejected(code: "FORBIDDEN")
                case "muted": .rejected(code: "ACTOR_MUTED")
                case "frozen": .rejected(code: "ROOM_FROZEN")
                case "admission": .pending(.admission)
                default: .pending(.media)
                }
                #expect(result == expected)
                #expect(try await inbox.status(exportID: export.intent.exportID) == expected)
                #expect(try await write.importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now) == expected)
            }
            #expect(try await admissionSnapshot() == before)
            #expect(try await count("im_v2.messages", on: targetSQL) == (completed == nil ? 0 : 1))
            #expect(try await count("im_v2.message_send_completions", on: targetSQL) == (completed == nil ? 0 : 1))
            #expect(try await count("im_v2.message_forward_inbox", on: targetSQL) == (completed == nil ? 1 : 2))
            if scenario == "media" {
                #expect(try await count("im_v2.message_forward_inbox_media", on: targetSQL) == 1)
                #expect(try await count("im_v2.media_objects", on: targetSQL) == 0)
                await #expect(throws: (any Error).self) { try await targetSQL.raw("UPDATE im_v2.message_forward_inbox_media SET state = 'ready'").run() }
            }
            if scenario == "admission" {
                try await targetSQL.raw("UPDATE im_v2.room_admission SET command_window_used = 0 WHERE room_id = \(bind: target.uuidValue!)").run()
                let resumed = try await write.importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
                guard case .accepted = resumed else { throw V2ForwardInboxError.corruptPersistenceState }
                #expect(try await count("im_v2.messages", on: targetSQL) == 1)
            }
        }
    }

    @Test("direct imports recover a failed completion transaction without duplicating personal events", arguments: [false, true])
    func forwardInboxDirectFinalization(changesOwner: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { sourceDB, targetDB, _, targetSQL, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let actor = UserID(uuid: memberTwoUUID)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: sourceDB), capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let source) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "copied into direct")) else { throw V2ForwardInboxError.corruptPersistenceState }
            let direct = try V2DirectMessagingService(store: PostgresV2DirectMessagingStore(database: targetDB), capacityProfile: profile, roomShardID: "room-b", now: { now })
            guard case .opened(let target) = try await direct.open(actorUserID: actor, operationID: .init(uuid: UUID()), targetUserID: senderID) else { throw V2ForwardInboxError.corruptPersistenceState }
            let export = try await PostgresV2ForwardExportStore(database: sourceDB).prepare(actorUserID: actor, operationID: .init(uuid: UUID()),
                source: .init(roomID: roomID, messageID: source.messageID, revision: .init(1)), sourceRoute: .init(shardID: "room-a", epoch: 0),
                targetRoomID: target.roomID, targetRoute: .init(shardID: "room-b", epoch: 0), now: now)
            try await targetSQL.raw("""
                CREATE FUNCTION im_v2.test_reject_forward_completion() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF NEW.state = 'completed' THEN
                        RAISE EXCEPTION 'injected forward completion failure';
                    END IF;
                    RETURN NEW;
                END $$
                """).run()
            try await targetSQL.raw("""
                CREATE TRIGGER test_reject_forward_completion BEFORE UPDATE ON im_v2.message_forward_inbox
                FOR EACH ROW EXECUTE FUNCTION im_v2.test_reject_forward_completion()
                """).run()
            let write = try PostgresV2RoomWriteStore(database: targetDB,
                strangerMessagePolicy: .init(maximumMessagesPerWindow: 10, window: 86_400),
                contentReviewMode: .disabled).usingWorkloadDatabase(targetDB)
            await #expect(throws: (any Error).self) {
                try await write.importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
            }
            let inbox = PostgresV2ForwardInboxStore(database: targetDB)
            #expect(try await inbox.status(exportID: export.intent.exportID) == .pending(.finalization))
            #expect(try await count("im_v2.messages", on: targetSQL) == 1)
            #expect(try await count("im_v2.message_send_completions", on: targetSQL) == 1)
            let projectionsBefore = try await count("im_v2.user_state_event_outbox", on: targetSQL)
            try await targetSQL.raw("DROP TRIGGER test_reject_forward_completion ON im_v2.message_forward_inbox").run()
            try await targetSQL.raw("DROP FUNCTION im_v2.test_reject_forward_completion()").run()
            if changesOwner {
                try await targetSQL.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: target.roomID.uuidValue!)").run()
                await #expect(throws: V2ForwardInboxError.ownerChanged) {
                    try await write.importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
                }
                #expect(try await inbox.status(exportID: export.intent.exportID) == .pending(.finalization))
                #expect(try await inbox.terminalReceipt(exportID: export.intent.exportID) == nil)
                #expect(try await count("im_v2.messages", on: targetSQL) == 1)
                try await targetSQL.raw("UPDATE im_v2.rooms SET owner_epoch=0 WHERE room_id=\(bind: target.roomID.uuidValue!)").run()
            }
            let result = try await write.importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
            guard case .accepted = result else { throw V2ForwardInboxError.corruptPersistenceState }
            #expect(try await inbox.status(exportID: export.intent.exportID) == result)
            #expect(try await count("im_v2.messages", on: targetSQL) == 1)
            #expect(try await count("im_v2.user_state_event_outbox", on: targetSQL) == projectionsBefore)
            #expect(try await write.importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now) == result)
            #expect(try await count("im_v2.user_state_event_outbox", on: targetSQL) == projectionsBefore)
        }
    }

    @Test("forward attachments copy verified bytes into stable target objects before acceptance", arguments: ["success", "large", "scan-retry", "copy-ack-loss", "lease-expiry", "concurrent", "cancel-scan", "owner-fence", "two-files", "eicar", "size", "collision", "short-source", "clock-retry", "compact-success", "compact-rejected", "purge-before-copy", "purge-after-copy", "runtime-ack-loss-compacted"])
    func forwardMediaImportBytesAndRecovery(scenario: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { sourceDB, targetDB, sourceSQL, targetSQL, targetRoom in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let root = FileManager.default.temporaryDirectory.appending(path: "im-forward-files-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let sourceProvider = try V2LocalFilesystemMediaProvider(rootDirectory: root.appending(path: "source"), targetBaseURL: URL(string: "https://source.invalid")!, signingKey: Data(repeating: 1, count: 32), now: { now })
            let targetProvider = try V2LocalFilesystemMediaProvider(rootDirectory: root.appending(path: "target"), targetBaseURL: URL(string: "https://target.invalid")!, signingKey: Data(repeating: 2, count: 32), now: { now })
            try await sourceProvider.prepare(); try await targetProvider.prepare()
            let bytes: Data
            if scenario == "eicar" {
                bytes = Data("X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*".utf8)
            } else if scenario == "large" { bytes = Data(repeating: 97, count: 8 * 1_024 * 1_024 + 11) }
            else { bytes = Data("forwarded attachment bytes\n".utf8) }
            let sourceMediaID = MediaID(uuid: UUID())
            let actualSourceBytes = scenario == "short-source" ? Data(bytes.dropLast()) : bytes
            let sourceUpload = try await sourceProvider.issueUploadTarget(mediaID: sourceMediaID, contentType: "application/octet-stream", byteCount: Int64(actualSourceBytes.count), expiresAt: now.addingTimeInterval(600))
            try await sourceProvider.storeUploadedObject(mediaID: sourceMediaID, targetURL: sourceUpload.url, contentType: "application/octet-stream", bytes: actualSourceBytes)
            try await sourceSQL.raw("""
                INSERT INTO im_v2.media_objects (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at)
                VALUES (\(bind: sourceMediaID.uuidValue!), \(bind: senderUUID), 'application/octet-stream', \(bind: Int64(bytes.count)), 'available', \(bind: UUID()), \(bind: now.addingTimeInterval(600)), \(bind: now), \(bind: now))
                """).run()
            var references = [V2MediaReference(mediaID: sourceMediaID)]
            let secondBytes = Data("second independent attachment".utf8)
            if scenario == "two-files" {
                let secondID = MediaID(uuid: UUID())
                let upload = try await sourceProvider.issueUploadTarget(mediaID: secondID, contentType: "application/octet-stream", byteCount: Int64(secondBytes.count), expiresAt: now.addingTimeInterval(600))
                try await sourceProvider.storeUploadedObject(mediaID: secondID, targetURL: upload.url, contentType: "application/octet-stream", bytes: secondBytes)
                try await sourceSQL.raw("""
                    INSERT INTO im_v2.media_objects (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at)
                    VALUES (\(bind: secondID.uuidValue!), \(bind: senderUUID), 'application/octet-stream', \(bind: Int64(secondBytes.count)), 'available', \(bind: UUID()), \(bind: now.addingTimeInterval(600)), \(bind: now), \(bind: now))
                    """).run()
                references.append(.init(mediaID: secondID))
            }
            let profile = try forwardImportTestProfile(), limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: sourceDB), capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let sourceMessage) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "attachment caption", media: references)) else { throw V2ForwardInboxError.corruptPersistenceState }
            let actor = UserID(uuid: memberTwoUUID)
            let export = try await PostgresV2ForwardExportStore(database: sourceDB).prepare(actorUserID: actor, operationID: .init(uuid: UUID()),
                source: .init(roomID: roomID, messageID: sourceMessage.messageID, revision: .init(1)), sourceRoute: .init(shardID: "room-a", epoch: 0), targetRoomID: targetRoom, targetRoute: .init(shardID: "room-b", epoch: 0), now: now)
            let inbox = PostgresV2ForwardInboxStore(database: targetDB)
            try await inbox.receive(export, now: now)
            let importer = try PostgresV2ForwardMediaImportStore(database: targetDB, temporaryLifetime: 2)
            let copier = try V2LocalFilesystemForwardMediaCopier(sources: ["room-a": sourceProvider], target: targetProvider, maximumBytes: scenario == "size" ? Int64(bytes.count - 1) : 64 * 1_024 * 1_024, now: { now })
            let scanner = V2LocalEICARMediaScanner(provider: targetProvider)
            let write = PostgresV2RoomWriteStore(database: targetDB)
            #expect(try await write.importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now) == .pending(.media))
            if scenario == "runtime-ack-loss-compacted" {
                let clock = TestSequenceClock([now])
                let jobs = PostgresV2ForwardDeliveryStore(database: sourceDB)
                let receipts = PostgresV2ForwardReceiptStore(database: sourceDB)
                let media = try V2ForwardMediaImportWorker(store: importer, copier: copier, scanner: scanner, now: { clock.now() })
                let firstEndpoint = V2ForwardImportEndpoint(inbox: inbox, write: write, media: media,
                    capacityProfile: profile, limits: limits, now: { clock.now() })
                let replayEndpoint = V2ForwardImportEndpoint(inbox: inbox, write: write,
                    capacityProfile: profile, limits: limits, now: { clock.now() })
                @Sendable func runUntil(target: any V2ForwardExportDelivering, state: String, attempts: Int64) async throws {
                    let worker = try V2ForwardDeliveryWorker(store: jobs, receipts: receipts, target: target,
                        sourceCommand: forwardSourceCommand(database: sourceDB, now: { clock.now() }),
                        deadline: { .now + .seconds(10) },
                        retryPolicy: .init(initialDelay: 1, maximumDelay: 1, maximumAttempts: 100, jitterFraction: 0), now: { clock.now() })
                    let runtime = try V2ForwardDeliveryRuntime(workers: ["room-a": worker], minimumPollMilliseconds: 10)
                    let task = Task { await runtime.run() }
                    do {
                        var reached = false
                        for _ in 0..<1_000 {
                            reached = try await sourceSQL.raw("""
                                SELECT state = \(bind: state) AND retry_count = \(bind: attempts) AS exists
                                FROM im_v2.message_forward_delivery_jobs WHERE export_id = \(bind: export.intent.exportID)
                                """).first(decoding: ExistsRow.self)?.exists == true
                            if reached { break }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        task.cancel(); await task.value
                        try #require(reached)
                    } catch { task.cancel(); await task.value; throw error }
                }
                try await runUntil(target: ForwardReceiptLosingDelivery(target: firstEndpoint), state: "pending", attempts: 1)
                let original = try #require(try await inbox.terminalReceipt(exportID: export.intent.exportID))
                guard case .accepted = original.outcome else { throw V2ForwardInboxError.corruptPersistenceState }
                #expect(try await receipts.status(exportID: export.intent.exportID) == nil)
                #expect(try await count("im_v2.messages", on: targetSQL) == 1)
                let targetID = MediaID(uuid: try #require(try await targetSQL.raw("SELECT target_media_id AS value FROM im_v2.message_forward_media_imports").first(decoding: ForwardInboxUUIDAssertion.self)).value)
                let compactAt = now.addingTimeInterval(PostgresV2ForwardInboxCompactor.retentionSeconds + 1)
                #expect(try await PostgresV2ForwardInboxCompactor(database: targetDB).runOnce(now: compactAt, limit: 1) == 1)
                #expect(try await PostgresV2ForwardExportCompactor(database: sourceDB).runOnce(now: compactAt, limit: 1) == 0)
                // A missing configured route represents temporary target unavailability.
                // It cannot manufacture a rejection or permit source cleanup.
                clock.set([compactAt.addingTimeInterval(2)])
                let unavailable = try V2ConfiguredForwardExportDelivery(targets: ["unavailable-room-b": replayEndpoint])
                try await runUntil(target: unavailable, state: "pending", attempts: 2)
                #expect(try await receipts.status(exportID: export.intent.exportID) == nil)
                #expect(try await PostgresV2ForwardExportCompactor(database: sourceDB).runOnce(now: clock.now(), limit: 1) == 0)
                // Remove source bytes to prove replay uses the already committed
                // target result. This is injected provider loss, not retention GC.
                try await sourceProvider.purge(mediaID: sourceMediaID)
                clock.set([compactAt.addingTimeInterval(4)])
                try await runUntil(target: replayEndpoint, state: "completed", attempts: 3)
                #expect(try await receipts.status(exportID: export.intent.exportID) == original.outcome)
                #expect(try await replayEndpoint.deliver(export)?.outcome == original.outcome)
                #expect(try await count("im_v2.messages", on: targetSQL) == 1)
                #expect(try await count("im_v2.media_objects", on: targetSQL) == 1)
                let download = try await targetProvider.issueDownloadTarget(mediaID: targetID, expiresAt: now.addingTimeInterval(600))
                #expect(try await targetProvider.readDownloadedObject(mediaID: targetID, targetURL: download.url) == bytes)
                #expect(try await targetSQL.raw("SELECT payload IS NULL AS exists FROM im_v2.message_forward_inbox").first(decoding: ExistsRow.self)?.exists == true)
                let finalAt = clock.now().addingTimeInterval(PostgresV2ForwardExportCompactor.retentionSeconds + 1)
                #expect(try await PostgresV2ForwardExportCompactor(database: sourceDB).runOnce(now: finalAt, limit: 1) == 1)
                #expect(try await sourceSQL.raw("SELECT payload IS NULL AS exists FROM im_v2.message_forward_exports").first(decoding: ExistsRow.self)?.exists == true)
                #expect(try await replayEndpoint.deliver(export)?.outcome == original.outcome)
                return
            }
            if scenario == "purge-before-copy" || scenario == "purge-after-copy" {
                let callbackAt = now.addingTimeInterval(4)
                let clock = TestSequenceClock([now])
                let interrupted = ForwardMediaCheckpointCopier(base: copier, beforeCopy: scenario == "purge-before-copy") { lease in
                    let cleanupAt = now.addingTimeInterval(3)
                    #expect(lease.expiresAt > callbackAt)
                    let retention = try V2MediaRetentionWorker(store: PostgresV2MediaRetentionStore(database: targetDB), now: { cleanupAt })
                    // The temporary object is overdue, but the pending inbox pins it.
                    #expect(try await retention.runOnce(limit: 1) == 0)
                    try await targetSQL.raw("UPDATE im_v2.rooms SET frozen_at = \(bind: cleanupAt), frozen_by_user_id = \(bind: senderUUID) WHERE room_id = \(bind: targetRoom.uuidValue!)").run()
                    #expect(try await importer.claim(exportID: export.intent.exportID, now: cleanupAt, leaseDuration: 300) == nil)
                    #expect(try await inbox.status(exportID: export.intent.exportID) == .rejected(code: "ROOM_FROZEN"))
                    #expect(try await retention.runOnce(limit: 1) == 1)
                    let purger = try V2MediaPurgeWorker(store: PostgresV2MediaPurgeStore(database: targetDB), provider: targetProvider, now: { cleanupAt })
                    let report = try await purger.runOnce(limit: 1)
                    #expect(report.claimedCount == 1 && report.completedCount == 1)
                    #expect(try await purger.runOnce(limit: 1).claimedCount == 0)
                    await #expect(throws: V2LocalFilesystemMediaProviderError.objectUnavailable) {
                        try await targetProvider.issueDownloadTarget(mediaID: lease.targetMediaID, expiresAt: now.addingTimeInterval(600))
                    }
                    clock.set([callbackAt])
                }
                let worker = try V2ForwardMediaImportWorker(store: importer, copier: interrupted, scanner: scanner,
                    leaseDuration: 300, now: { clock.now() })
                // In one case the real copier attempts its installation after purge;
                // in the other its successful receipt arrives after purge. Both lose
                // while the original lease is still within its time window.
                #expect(try await worker.runOnce(exportID: export.intent.exportID) == .superseded)
                #expect(try await worker.runOnce(exportID: export.intent.exportID) == .idle)
                #expect(try await count("im_v2.messages", on: targetSQL) == 0)
                #expect(try await targetSQL.raw("SELECT state = 'expired' AS exists FROM im_v2.media_objects").first(decoding: ExistsRow.self)?.exists == true)
                #expect(try await targetSQL.raw("SELECT copied_digest IS NULL AS exists FROM im_v2.message_forward_media_imports").first(decoding: ExistsRow.self)?.exists == true)
                #expect(try await count("im_v2.media_purge_outbox WHERE state = 'completed'", on: targetSQL) == 1)
                let targetID = MediaID(uuid: try #require(try await targetSQL.raw("SELECT target_media_id AS value FROM im_v2.message_forward_media_imports").first(decoding: ForwardInboxUUIDAssertion.self)).value)
                await #expect(throws: V2LocalFilesystemMediaProviderError.objectUnavailable) {
                    try await targetProvider.issueDownloadTarget(mediaID: targetID, expiresAt: now.addingTimeInterval(600))
                }
                let compactAt = now.addingTimeInterval(PostgresV2ForwardInboxCompactor.retentionSeconds + 4)
                #expect(try await PostgresV2ForwardInboxCompactor(database: targetDB).runOnce(now: compactAt, limit: 1) == 1)
                let endpoint = V2ForwardImportEndpoint(inbox: inbox, write: write, capacityProfile: profile, limits: limits, now: { compactAt })
                let receipt = try #require(try await endpoint.deliver(export))
                #expect(receipt.outcome == .rejected(code: "ROOM_FROZEN"))
                #expect(try await targetSQL.raw("SELECT payload IS NULL AS exists FROM im_v2.message_forward_inbox").first(decoding: ExistsRow.self)?.exists == true)
                #expect(try await count("im_v2.messages", on: targetSQL) == 0)
                return
            }
            if scenario == "compact-success" || scenario == "compact-rejected" {
                let sourceJobs = PostgresV2ForwardDeliveryStore(database: sourceDB)
                let deliveryLease = try #require(try await sourceJobs.claim(sourceShardID: "room-a", now: now, leaseDuration: 300, limit: 1).first)
                let mediaLease = try #require(try await importer.claim(exportID: export.intent.exportID, now: now, leaseDuration: 300))
                let copied = try await copier.copy(mediaLease)
                #expect(try await importer.recordCopied(mediaLease, receipt: copied, now: now))
                let targetCompactor = PostgresV2ForwardInboxCompactor(database: targetDB)
                let sourceCompactor = PostgresV2ForwardExportCompactor(database: sourceDB)
                let compactAt = now.addingTimeInterval(PostgresV2ForwardInboxCompactor.retentionSeconds + 1)
                #expect(try await targetCompactor.runOnce(now: compactAt, limit: 1) == 0)
                #expect(try await sourceCompactor.runOnce(now: compactAt, limit: 1) == 0)
                if scenario == "compact-success" {
                    #expect(try await scanner.scan(mediaID: mediaLease.targetMediaID) == .passed)
                    #expect(try await importer.complete(mediaLease, receipt: copied, result: .passed, now: now))
                    guard case .accepted = try await write.importForwardExport(export, capacityProfile: profile,
                        limits: limits, identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
                    else { throw V2ForwardInboxError.corruptPersistenceState }
                } else {
                    // Reject while the original media lease is still current.
                    try await targetSQL.raw("UPDATE im_v2.rooms SET frozen_at = \(bind: now), frozen_by_user_id = \(bind: senderUUID) WHERE room_id = \(bind: targetRoom.uuidValue!)").run()
                    #expect(try await importer.claim(exportID: export.intent.exportID, now: now, leaseDuration: 300) == nil)
                    #expect(try await inbox.status(exportID: export.intent.exportID) == .rejected(code: "ROOM_FROZEN"))
                }
                let receipt = try #require(try await inbox.terminalReceipt(exportID: export.intent.exportID))
                // Target compaction must not depend on the source ACK/receipt.
                #expect(try await targetCompactor.runOnce(now: compactAt, limit: 1) == 1)
                #expect(try await sourceCompactor.runOnce(now: compactAt, limit: 1) == 0)
                let endpoint = V2ForwardImportEndpoint(inbox: inbox, write: write, capacityProfile: profile,
                    limits: limits, now: { now.addingTimeInterval(1) })
                #expect(try await endpoint.deliver(export)?.outcome == receipt.outcome)
                let receipts = PostgresV2ForwardReceiptStore(database: sourceDB)
                try await receipts.record(receipt, now: now)
                #expect(try await sourceCompactor.runOnce(now: compactAt, limit: 1) == 0)
                #expect(try await sourceJobs.complete(deliveryLease, now: now.addingTimeInterval(1)))
                #expect(try await sourceCompactor.runOnce(now: compactAt, limit: 1) == 1)
                #expect(try await targetSQL.raw("SELECT payload IS NULL AS exists FROM im_v2.message_forward_inbox WHERE export_id = \(bind: export.intent.exportID)").first(decoding: ExistsRow.self)?.exists == true)
                #expect(try await sourceSQL.raw("SELECT payload IS NULL AS exists FROM im_v2.message_forward_exports WHERE export_id = \(bind: export.intent.exportID)").first(decoding: ExistsRow.self)?.exists == true)
                func targetState() async throws -> String {
                    try #require(try await targetSQL.raw("""
                        SELECT jsonb_build_object(
                            'objects', (SELECT jsonb_agg(to_jsonb(r) ORDER BY media_id) FROM im_v2.media_objects r),
                            'imports', (SELECT jsonb_agg(to_jsonb(r) ORDER BY ordinal) FROM im_v2.message_forward_media_imports r),
                            'mapping', (SELECT jsonb_agg(to_jsonb(r) ORDER BY ordinal) FROM im_v2.message_forward_inbox_media r),
                            'messages', (SELECT jsonb_agg(to_jsonb(r) ORDER BY message_id) FROM im_v2.messages r)
                        )::text AS value
                        """).first(decoding: StringValueRow.self)).value
                }
                let before = try await targetState()
                // Logical callback time remains inside the original lease. It
                // must lose to terminal state, not merely to lease expiration.
                let callbackAt = now.addingTimeInterval(1)
                #expect(try await importer.recordCopied(mediaLease, receipt: copied, now: callbackAt) == false)
                #expect(try await importer.complete(mediaLease, receipt: copied, result: .passed, now: callbackAt) == false)
                #expect(try await importer.reject(mediaLease, now: callbackAt) == false)
                #expect(try await importer.retry(mediaLease, disposition: .pause, now: callbackAt) == false)
                #expect(try await importer.claim(exportID: export.intent.exportID, now: callbackAt, leaseDuration: 300) == nil)
                let operatorResult = try await PostgresV2ForwardWorkReplayStore(database: targetDB).replay(
                    .init(operationID: UUID(), shardID: "room-b", kind: .media, exportID: export.intent.exportID,
                          ordinal: 0, reason: .dependencyRecovered), operatorPrincipal: "compaction-test", now: callbackAt)
                #expect(operatorResult.outcome == .notPaused)
                try await sourceProvider.purge(mediaID: sourceMediaID)
                #expect(try await endpoint.deliver(export)?.outcome == receipt.outcome)
                let sourceService = try V2CrossOwnerForwardService(sources: ["room-a": .init(
                    exports: .init(database: sourceDB), receipts: receipts, jobs: sourceJobs)], now: { callbackAt })
                let result = try await sourceService.forward(actor: actor, operation: .init(uuid: export.intent.operationID),
                    source: .init(roomID: roomID, messageID: sourceMessage.messageID, revision: .init(1)),
                    sourceRoute: .init(shardID: "room-a", epoch: 0), target: targetRoom, targetRoute: .init(shardID: "room-b", epoch: 0))
                guard case .completed(let terminal) = result else { throw V2ForwardInboxError.corruptPersistenceState }
                if case .accepted(let message, let sequence) = receipt.outcome {
                    #expect(terminal.messageID == message && terminal.roomSequence == sequence)
                } else { #expect(terminal.errorCode == "ROOM_FROZEN") }
                let download = try await targetProvider.issueDownloadTarget(mediaID: mediaLease.targetMediaID, expiresAt: now.addingTimeInterval(600))
                #expect(try await targetProvider.readDownloadedObject(mediaID: mediaLease.targetMediaID, targetURL: download.url) == bytes)
                #expect(try await targetState() == before)
                #expect(try await count("im_v2.media_objects", on: targetSQL) == 1)
                #expect(try await count("im_v2.messages", on: targetSQL) == (scenario == "compact-success" ? 1 : 0))
                return
            }
            if scenario == "clock-retry" {
                let clock = TestSequenceClock([now])
                let worker = try V2ForwardMediaImportWorker(store: importer, copier: copier, scanner: scanner, leaseDuration: 30, retryPolicy: .init(initialDelay: 2, maximumDelay: 2, maximumAttempts: 100, jitterFraction: 0), now: { clock.now() })
                let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
                var identity: UUID?
                for (index, invalid) in badDates.enumerated() {
                    let claimTime = now.addingTimeInterval(Double(index) * 40)
                    clock.set([claimTime, invalid])
                    await #expect(throws: V2ForwardInboxError.corruptPersistenceState) { try await worker.runOnce(exportID: export.intent.exportID) }
                    let id = try #require(try await targetSQL.raw("SELECT target_media_id AS value FROM im_v2.message_forward_media_imports").first(decoding: ForwardInboxUUIDAssertion.self)).value
                    if let identity { #expect(id == identity) } else { identity = id }
                    #expect(try await targetSQL.raw("SELECT state = 'claimed' AND copied_digest IS NULL AND retry_count = \(bind: Int64(index + 1)) AND lease_expires_at = \(bind: claimTime.addingTimeInterval(30)) AS exists FROM im_v2.message_forward_media_imports").first(decoding: ExistsRow.self)?.exists == true)
                    #expect(try await inbox.status(exportID: export.intent.exportID) == .pending(.media))
                    #expect(try await count("im_v2.messages", on: targetSQL) == 0)
                }
                clock.set([now.addingTimeInterval(320)])
                #expect(try await worker.runOnce(exportID: export.intent.exportID) == .ready)
                let targetID = MediaID(uuid: try #require(identity))
                let download = try await targetProvider.issueDownloadTarget(mediaID: targetID, expiresAt: now.addingTimeInterval(600))
                #expect(try await targetProvider.readDownloadedObject(mediaID: targetID, targetURL: download.url) == bytes)
                #expect(try await targetSQL.raw("SELECT state = 'ready' AND claim_token IS NULL AND copied_digest IS NOT NULL AND completed_at = \(bind: now.addingTimeInterval(320)) AS exists FROM im_v2.message_forward_media_imports").first(decoding: ExistsRow.self)?.exists == true)
                return
            }
            if scenario == "owner-fence" {
                let lease = try #require(try await importer.claim(exportID: export.intent.exportID, now: now, leaseDuration: 300))
                let copied = try await copier.copy(lease)
                try await targetSQL.raw("UPDATE im_v2.rooms SET owner_epoch = 1 WHERE room_id = \(bind: targetRoom.uuidValue!)").run()
                await #expect(throws: V2ForwardInboxError.ownerChanged) { try await importer.recordCopied(lease, receipt: copied, now: now) }
                await #expect(throws: V2ForwardInboxError.ownerChanged) { try await importer.complete(lease, receipt: copied, result: .passed, now: now) }
                #expect(try await inbox.status(exportID: export.intent.exportID) == .pending(.media))
                #expect(try await targetSQL.raw("SELECT count(*) AS value FROM im_v2.message_forward_media_imports WHERE copied_digest IS NOT NULL").first(decoding: CountRow.self)?.value == 0)
                #expect(try await count("im_v2.messages", on: targetSQL) == 0)
                return
            }
            var readyAt = now
            if ["copy-ack-loss", "lease-expiry", "concurrent", "collision"].contains(scenario) {
                let old = try #require(try await importer.claim(exportID: export.intent.exportID, now: now, leaseDuration: 5))
                if scenario == "collision" {
                    let wrong = Data(repeating: 120, count: bytes.count)
                    let upload = try await targetProvider.issueUploadTarget(mediaID: old.targetMediaID, contentType: "application/octet-stream", byteCount: Int64(wrong.count), expiresAt: now.addingTimeInterval(600))
                    try await targetProvider.storeUploadedObject(mediaID: old.targetMediaID, targetURL: upload.url, contentType: "application/octet-stream", bytes: wrong)
                    #expect(try await importer.retry(old, disposition: .retry(at: now), now: now))
                } else {
                    let copied = try await copier.copy(old)
                    if scenario == "lease-expiry" { #expect(try await importer.recordCopied(old, receipt: copied, now: now)) }
                    // Expired metadata is protected by the pending import job.
                    #expect(try await PostgresV2MediaRetentionStore(database: targetDB).expireEligibleMedia(now: now.addingTimeInterval(6), withdrawnRetention: 1, limit: 10) == 0)
                    let recovered = try #require(try await importer.claim(exportID: export.intent.exportID, now: now.addingTimeInterval(6), leaseDuration: 300))
                    #expect(recovered.targetMediaID == old.targetMediaID && recovered.targetUploadSessionID == old.targetUploadSessionID)
                    #expect(recovered.claimToken != old.claimToken && recovered.attempt == 2)
                    #expect(try await importer.complete(old, receipt: copied, result: .passed, now: now.addingTimeInterval(7)) == false)
                    #expect(try await importer.reject(old, now: now.addingTimeInterval(7)) == false)
                    #expect(try await importer.retry(old, disposition: .retry(at: now), now: now.addingTimeInterval(7)) == false)
                    if scenario == "lease-expiry" { try await sourceProvider.purge(mediaID: sourceMediaID) }
                    if scenario == "concurrent" {
                        // Simulate losing the unacknowledged install, then race
                        // old and new leases to atomically reconstruct it.
                        let lostTarget = try await targetProvider.issueDownloadTarget(mediaID: old.targetMediaID, expiresAt: now.addingTimeInterval(600))
                        let lostObject = try await targetProvider.downloadedObject(mediaID: old.targetMediaID, targetURL: lostTarget.url)
                        try FileManager.default.removeItem(at: lostObject.fileURL)
                        let collisions = try await withThrowingTaskGroup(of: V2ForwardMediaCopyReceipt.self) { group in
                            for index in 0..<4 {
                                let candidate = index.isMultiple(of: 2) ? old : recovered
                                group.addTask { try await copier.copy(candidate) }
                            }
                            var results: [V2ForwardMediaCopyReceipt] = []
                            for try await result in group { results.append(result) }
                            return results
                        }
                        #expect(collisions.count == 4 && collisions.allSatisfy { $0 == copied })
                    }
                    let replayCopy = try await copier.copy(recovered)
                    #expect(replayCopy == copied)
                    readyAt = now.addingTimeInterval(7)
                    #expect(try await importer.recordCopied(recovered, receipt: replayCopy, now: readyAt))
                    #expect(try await scanner.scan(mediaID: recovered.targetMediaID) == .passed)
                    #expect(try await importer.complete(recovered, receipt: replayCopy, result: .passed, now: readyAt))
                }
            }
            if scenario == "cancel-scan" {
                let blocking = ForwardMediaBlockingScanner()
                let worker = try V2ForwardMediaImportWorker(store: importer, copier: copier, scanner: blocking, now: { now })
                let task = Task { try await worker.runOnce(exportID: export.intent.exportID) }
                do {
                    for _ in 0..<500 {
                        if await blocking.started { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    try #require(await blocking.started)
                    task.cancel()
                    await #expect(throws: CancellationError.self) { try await task.value }
                } catch {
                    task.cancel(); _ = try? await task.value; throw error
                }
                #expect(try await inbox.status(exportID: export.intent.exportID) == .pending(.media))
                #expect(try await count("im_v2.messages", on: targetSQL) == 0)
                try await sourceProvider.purge(mediaID: sourceMediaID)
                readyAt = now.addingTimeInterval(1)
                let resumed = try V2ForwardMediaImportWorker(store: importer, copier: copier, scanner: scanner, now: { now.addingTimeInterval(1) })
                #expect(try await resumed.runOnce(exportID: export.intent.exportID) == .ready)
            } else if scenario == "scan-retry" {
                let failingScanner = ForwardMediaFailOnceScanner(scanner: scanner)
                let firstWorker = try V2ForwardMediaImportWorker(store: importer, copier: copier, scanner: failingScanner,
                    retryPolicy: .init(initialDelay: 1, maximumDelay: 1, maximumAttempts: 3, jitterFraction: 0), now: { now })
                #expect(try await firstWorker.runOnce(exportID: export.intent.exportID) == .retryScheduled)
                #expect(try await count("im_v2.messages", on: targetSQL) == 0)
                #expect(try await inbox.status(exportID: export.intent.exportID) == .pending(.media))
                try await sourceProvider.purge(mediaID: sourceMediaID)
                readyAt = now.addingTimeInterval(2)
                let secondWorker = try V2ForwardMediaImportWorker(store: importer, copier: copier, scanner: failingScanner, now: { now.addingTimeInterval(2) })
                #expect(try await secondWorker.runOnce(exportID: export.intent.exportID) == .ready)
            } else if !["copy-ack-loss", "lease-expiry", "concurrent"].contains(scenario) {
                let worker = try V2ForwardMediaImportWorker(store: importer, copier: copier, scanner: scanner, now: { now })
                let rejected = ["eicar", "size", "collision", "short-source"].contains(scenario)
                #expect(try await worker.runOnce(exportID: export.intent.exportID) == (rejected ? .rejected : .ready))
                if scenario == "two-files" {
                    #expect(try await write.importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now) == .pending(.media))
                    #expect(try await count("im_v2.messages", on: targetSQL) == 0)
                    #expect(try await worker.runOnce(exportID: export.intent.exportID) == .ready)
                }
                #expect(try await worker.runOnce(exportID: export.intent.exportID) == .idle)
            }
            let expectedMediaCount: Int64 = scenario == "two-files" ? 2 : 1
            #expect(try await count("im_v2.media_objects", on: targetSQL) == expectedMediaCount)
            #expect(try await count("im_v2.message_forward_media_imports", on: targetSQL) == expectedMediaCount)
            if ["eicar", "size", "collision", "short-source"].contains(scenario) {
                #expect(try await inbox.status(exportID: export.intent.exportID) == .rejected(code: "MEDIA_UNAVAILABLE"))
                #expect(try await write.importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now) == .rejected(code: "MEDIA_UNAVAILABLE"))
                #expect(try await count("im_v2.messages", on: targetSQL) == 0)
                #expect(try await count("im_v2.message_media_references", on: targetSQL) == 0)
                #expect(try await PostgresV2MediaRetentionStore(database: targetDB).expireEligibleMedia(now: now.addingTimeInterval(1), withdrawnRetention: 1, limit: 10) == 1)
                if scenario == "collision" {
                    let media = try #require(try await targetSQL.raw("SELECT target_media_id AS value FROM im_v2.message_forward_media_imports").first(decoding: ForwardInboxUUIDAssertion.self))
                    let targetID = MediaID(uuid: media.value)
                    let download = try await targetProvider.issueDownloadTarget(mediaID: targetID, expiresAt: now.addingTimeInterval(60))
                    #expect(try await targetProvider.readDownloadedObject(mediaID: targetID, targetURL: download.url) == Data(repeating: 120, count: bytes.count))
                }
                return
            }
            // A ready mapping alone is still not message success.
            #expect(try await count("im_v2.messages", on: targetSQL) == 0)
            let accepted = try await write.importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: V2AcceptanceIDFactory().make(at: readyAt), now: readyAt)
            guard case .accepted = accepted else { throw V2ForwardInboxError.corruptPersistenceState }
            let mapped = try #require(try await targetSQL.raw("SELECT target_media_id AS value FROM im_v2.message_forward_inbox_media WHERE ordinal = 0").first(decoding: ForwardInboxUUIDAssertion.self))
            let targetID = MediaID(uuid: mapped.value)
            #expect(targetID != sourceMediaID)
            let download = try await targetProvider.issueDownloadTarget(mediaID: targetID, expiresAt: now.addingTimeInterval(600))
            #expect(try await targetProvider.readDownloadedObject(mediaID: targetID, targetURL: download.url) == bytes)
            #expect(try await count("im_v2.messages", on: targetSQL) == 1)
            #expect(try await count("im_v2.message_media_references", on: targetSQL) == expectedMediaCount)
            #expect(try await targetSQL.raw("SELECT count(*) AS value FROM im_v2.media_objects WHERE owner_user_id = \(bind: memberTwoUUID) AND state = 'available'").first(decoding: CountRow.self)?.value == expectedMediaCount)
            let expectedDigest = scenario == "large" ? "639997266bfc8ec827c7dad9a63b929ab7945231ef50f6f27f3a8f3fceb66f2f" : "46d13734a672a1685d23835a855b942ee3955f7a19d80b280ff1e9f1cbc2912a"
            #expect(try await targetSQL.raw("SELECT encode(copied_digest, 'hex') AS value FROM im_v2.message_forward_media_imports WHERE ordinal = 0").first(decoding: ForwardImportDigestAssertion.self)?.value == expectedDigest)
            if scenario == "two-files" {
                let second = try #require(try await targetSQL.raw("SELECT target_media_id AS value FROM im_v2.message_forward_inbox_media WHERE ordinal = 1").first(decoding: ForwardInboxUUIDAssertion.self))
                let secondID = MediaID(uuid: second.value)
                let url = try await targetProvider.issueDownloadTarget(mediaID: secondID, expiresAt: now.addingTimeInterval(600))
                #expect(try await targetProvider.readDownloadedObject(mediaID: secondID, targetURL: url.url) == secondBytes)
                let ordered = try await targetSQL.raw("SELECT media_id AS value FROM im_v2.message_media_references ORDER BY ordinal").all(decoding: ForwardInboxUUIDAssertion.self)
                #expect(ordered.map(\.value) == [targetID.uuidValue!, second.value])
            }
            await #expect(throws: (any Error).self) { try await targetSQL.raw("UPDATE im_v2.message_forward_media_imports SET copied_digest = decode(repeat('00', 32), 'hex')").run() }
            #expect(try await write.importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: V2AcceptanceIDFactory().make(at: readyAt), now: readyAt) == accepted)
            #expect(try await count("im_v2.media_objects", on: targetSQL) == expectedMediaCount)
            if scenario == "success" || scenario == "two-files" {
                let secondExport = try await PostgresV2ForwardExportStore(database: sourceDB).prepare(actorUserID: actor, operationID: .init(uuid: UUID()),
                    source: .init(roomID: roomID, messageID: sourceMessage.messageID, revision: .init(1)), sourceRoute: .init(shardID: "room-a", epoch: 0), targetRoomID: targetRoom, targetRoute: .init(shardID: "room-b", epoch: 0), now: now)
                let withdrawal = V2MessageWithdrawalService(store: PostgresV2MessageWithdrawalStore(database: sourceDB), capacityProfile: profile, now: { now.addingTimeInterval(1) })
                guard case .withdrawn = try await withdrawal.withdraw(.init(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), messageID: sourceMessage.messageID, expectedMessageRevision: 1)) else { throw V2ForwardInboxError.corruptPersistenceState }
                let sourceRetention = PostgresV2MediaRetentionStore(database: sourceDB)
                let retentionAt = now.addingTimeInterval(1_000)
                #expect(try await sourceRetention.expireEligibleMedia(now: retentionAt, withdrawnRetention: 1, limit: 10) == 0)
                let sourceReceipts = PostgresV2ForwardReceiptStore(database: sourceDB)
                let completedReceipt = try #require(try await inbox.terminalReceipt(exportID: export.intent.exportID))
                try await sourceReceipts.record(completedReceipt, now: retentionAt)
                #expect(try await sourceRetention.expireEligibleMedia(now: retentionAt, withdrawnRetention: 1, limit: 10) == 0)
                // Rejection before copying is a durable terminal result too.
                try await inbox.receive(secondExport, now: now)
                try await targetSQL.raw("UPDATE im_v2.rooms SET frozen_at = \(bind: now), frozen_by_user_id = \(bind: senderUUID) WHERE room_id = \(bind: targetRoom.uuidValue!)").run()
                #expect(try await importer.claim(exportID: secondExport.intent.exportID, now: now, leaseDuration: 300) == nil)
                let rejectedReceipt = try #require(try await inbox.terminalReceipt(exportID: secondExport.intent.exportID))
                #expect(rejectedReceipt.outcome == .rejected(code: "ROOM_FROZEN"))
                try await sourceReceipts.record(rejectedReceipt, now: retentionAt)
                #expect(try await sourceRetention.expireEligibleMedia(now: retentionAt, withdrawnRetention: 1, limit: 10) == expectedMediaCount)
                #expect(try await sourceRetention.expireEligibleMedia(now: retentionAt, withdrawnRetention: 1, limit: 10) == 0)
                #expect(try await count("im_v2.media_purge_outbox", on: sourceSQL) == expectedMediaCount)
                let purge = try V2MediaPurgeWorker(store: PostgresV2MediaPurgeStore(database: sourceDB), provider: sourceProvider, now: { retentionAt })
                let purged = try await purge.runOnce(limit: 10)
                #expect(purged.completedCount == Int(expectedMediaCount))
                #expect(purged.releasedCount == 0 && purged.pausedCount == 0)
                for reference in references {
                    await #expect(throws: V2LocalFilesystemMediaProviderError.objectUnavailable) {
                        try await sourceProvider.issueDownloadTarget(mediaID: reference.mediaID, expiresAt: now.addingTimeInterval(600))
                    }
                }
                #expect(try await purge.runOnce(limit: 10).claimedCount == 0)
                #expect(try await targetProvider.readDownloadedObject(mediaID: targetID, targetURL: download.url) == bytes)
                #expect(try await PostgresV2MediaRetentionStore(database: targetDB).expireEligibleMedia(now: retentionAt, withdrawnRetention: 1, limit: 10) == 0)
                try await sourceReceipts.record(completedReceipt, now: retentionAt)
                #expect(try await inbox.terminalReceipt(exportID: export.intent.exportID) == completedReceipt)
            }
            let staging = root.appending(path: "target/.upload-staging")
            #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        }
    }

    internal func forwardImportTestProfile() throws -> V2CapacityProfile {
        try .init(id: "standard", limits: .init(
            maxEligibleMembers: 10, maxCommandsPerWindow: 10,
              retryAfterSeconds: 3
        ))
    }

    @Test("source terminal receipts release capacity only after durable target completion", arguments: ["completed", "rejected", "source-epoch", "rollback"])
    func forwardTerminalReceiptRecovery(scenario: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { sourceDB, targetDB, sourceSQL, targetSQL, target in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile(), limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let actor = UserID(uuid: memberTwoUUID)
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: sourceDB), capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "receipt source")) else { throw V2ForwardInboxError.corruptPersistenceState }
            let exporter = PostgresV2ForwardExportStore(database: sourceDB, maximumExportsPerRoom: 1)
            let operation = MessageForwardOperationID(uuid: UUID())
            let reference = try V2ForwardMessageReference(roomID: roomID, messageID: message.messageID, revision: .init(1))
            let sourceRoute = try V2RoomShardRoute(shardID: "room-a", epoch: 0), targetRoute = try V2RoomShardRoute(shardID: "room-b", epoch: 0)
            let export = try await exporter.prepare(actorUserID: actor, operationID: operation, source: reference, sourceRoute: sourceRoute, targetRoomID: target, targetRoute: targetRoute, now: now)
            let inbox = PostgresV2ForwardInboxStore(database: targetDB)
            let receipts = PostgresV2ForwardReceiptStore(database: sourceDB)
            #expect(try await inbox.terminalReceipt(exportID: export.intent.exportID) == nil)
            try await inbox.receive(export, now: now)
            #expect(try await inbox.terminalReceipt(exportID: export.intent.exportID) == nil)
            await #expect(throws: V2ForwardExportError.capacityExceeded) {
                try await exporter.prepare(actorUserID: actor, operationID: .init(uuid: UUID()), source: reference, sourceRoute: sourceRoute, targetRoomID: target, targetRoute: targetRoute, now: now)
            }
            #expect(throws: V2ForwardInboxError.corruptPersistenceState) {
                try V2ForwardTerminalReceipt(export: export, outcome: .pending(.finalization))
            }
            if scenario == "rejected" {
                try await targetSQL.raw("UPDATE im_v2.rooms SET frozen_at = \(bind: now), frozen_by_user_id = \(bind: senderUUID) WHERE room_id = \(bind: target.uuidValue!)").run()
            }
            let outcome = try await PostgresV2RoomWriteStore(database: targetDB).importForwardExport(export, capacityProfile: profile, limits: limits, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
            if scenario == "rejected" { #expect(outcome == .rejected(code: "ROOM_FROZEN")) }
            else { guard case .accepted = outcome else { throw V2ForwardInboxError.corruptPersistenceState } }
            let receipt = try #require(try await inbox.terminalReceipt(exportID: export.intent.exportID))
            #expect(receipt.outcome == outcome)
            #expect(try await receipts.status(exportID: export.intent.exportID) == nil)
            // Target success with the source ACK lost still consumes a slot.
            await #expect(throws: V2ForwardExportError.capacityExceeded) {
                try await exporter.prepare(actorUserID: actor, operationID: .init(uuid: UUID()), source: reference, sourceRoute: sourceRoute, targetRoomID: target, targetRoute: targetRoute, now: now)
            }
            if scenario == "source-epoch" {
                try await sourceSQL.raw("UPDATE im_v2.rooms SET owner_epoch = 1 WHERE room_id = \(bind: roomUUID)").run()
                await #expect(throws: V2ForwardExportError.ownerChanged) { try await receipts.record(receipt, now: now) }
                #expect(try await receipts.status(exportID: export.intent.exportID) == nil)
                #expect(try await count("im_v2.message_forward_export_receipts", on: sourceSQL) == 0)
                return
            }
            if scenario == "rollback" {
                try await sourceSQL.raw("CREATE FUNCTION im_v2.zz_abort_receipt() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'receipt rollback'; END; $$").run()
                try await sourceSQL.raw("CREATE TRIGGER zz_abort_receipt AFTER INSERT ON im_v2.message_forward_export_receipts FOR EACH ROW EXECUTE FUNCTION im_v2.zz_abort_receipt()").run()
                await #expect(throws: (any Error).self) { try await receipts.record(receipt, now: now) }
                #expect(try await receipts.status(exportID: export.intent.exportID) == nil)
                await #expect(throws: V2ForwardExportError.capacityExceeded) {
                    try await exporter.prepare(actorUserID: actor, operationID: .init(uuid: UUID()), source: reference, sourceRoute: sourceRoute, targetRoomID: target, targetRoute: targetRoute, now: now)
                }
                try await sourceSQL.raw("DROP TRIGGER zz_abort_receipt ON im_v2.message_forward_export_receipts").run()
                try await sourceSQL.raw("DROP FUNCTION im_v2.zz_abort_receipt()").run()
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<16 {
                    group.addTask { try await PostgresV2ForwardReceiptStore(database: sourceDB).record(receipt, now: now) }
                }
                try await group.waitForAll()
            }
            #expect(try await receipts.status(exportID: export.intent.exportID) == outcome)
            #expect(try await count("im_v2.message_forward_export_receipts", on: sourceSQL) == 1)
            // Replaying an old export cannot consume another slot or repin it.
            #expect(try await exporter.prepare(actorUserID: actor, operationID: operation, source: reference, sourceRoute: sourceRoute, targetRoomID: target, targetRoute: targetRoute, now: now) == export)
            let next = try await exporter.prepare(actorUserID: actor, operationID: .init(uuid: UUID()), source: reference, sourceRoute: sourceRoute, targetRoomID: target, targetRoute: targetRoute, now: now)
            #expect(next.intent.exportID != export.intent.exportID)
            await #expect(throws: V2ForwardExportError.capacityExceeded) {
                try await exporter.prepare(actorUserID: actor, operationID: .init(uuid: UUID()), source: reference, sourceRoute: sourceRoute, targetRoomID: target, targetRoute: targetRoute, now: now)
            }
            let conflict = try V2ForwardTerminalReceipt(export: export, outcome: .rejected(code: "DIFFERENT_RESULT"))
            await #expect(throws: V2ForwardExportError.idempotencyConflict) { try await receipts.record(conflict, now: now) }
            var changed = try #require(JSONSerialization.jsonObject(with: export.payload) as? [String: Any])
            changed["text"] = "changed authorized content"
            let changedIntent = try JSONDecoder().decode(V2ForwardExportIntent.self, from: JSONSerialization.data(withJSONObject: changed))
            let changedExport = try V2ForwardExport(intent: changedIntent)
            let changedReceipt = try V2ForwardTerminalReceipt(export: changedExport, outcome: outcome)
            await #expect(throws: V2ForwardExportError.idempotencyConflict) { try await receipts.record(changedReceipt, now: now) }
            await #expect(throws: (any Error).self) { try await sourceSQL.raw("UPDATE im_v2.message_forward_export_receipts SET recorded_at = recorded_at + interval '1 second'").run() }
            await #expect(throws: (any Error).self) { try await sourceSQL.raw("DELETE FROM im_v2.message_forward_export_receipts").run() }
            // Durable receipt recovery is independent of current memberships,
            // epochs and mutable source/target message projections.
            try await sourceSQL.raw("UPDATE im_v2.rooms SET owner_epoch = 1 WHERE room_id = \(bind: roomUUID)").run()
            try await targetSQL.raw("UPDATE im_v2.rooms SET owner_epoch = 1 WHERE room_id = \(bind: target.uuidValue!)").run()
            let reread = try #require(try await PostgresV2ForwardInboxStore(database: targetDB).terminalReceipt(exportID: export.intent.exportID))
            try await PostgresV2ForwardReceiptStore(database: sourceDB).record(reread, now: now.addingTimeInterval(5))
            #expect(try await receipts.status(exportID: export.intent.exportID) == outcome)
        }
    }

    @Test("source delivery leases stop at owner epoch change")
    func forwardDeliveryOwnerFence() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { sourceDB, targetDB, sourceSQL, _, targetRoom in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile(), limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let sender = V2SendMessageService(store: PostgresV2RoomWriteStore(database: sourceDB), capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "delivery owner")) else { throw V2ForwardExportError.corruptPersistenceState }
            let exports = PostgresV2ForwardExportStore(database: sourceDB)
            for _ in 0..<4 {
                _ = try await exports.prepare(actorUserID: .init(uuid: memberTwoUUID), operationID: .init(uuid: UUID()),
                    source: .init(roomID: roomID, messageID: message.messageID, revision: .init(1)),
                    sourceRoute: .init(shardID: "room-a", epoch: 0), targetRoomID: targetRoom,
                    targetRoute: .init(shardID: "room-b", epoch: 0), now: now)
            }
            let jobs = PostgresV2ForwardDeliveryStore(database: sourceDB)
            let receipts = PostgresV2ForwardReceiptStore(database: sourceDB)
            let leases = try await jobs.claim(sourceShardID: "room-a", now: now, leaseDuration: 60, limit: 3)
            try #require(leases.count == 3)
            #expect(try await jobs.isCurrent(leases[0], now: now))
            let inbox = PostgresV2ForwardInboxStore(database: targetDB)
            let writer = PostgresV2RoomWriteStore(database: targetDB)
            var targetReceipts: [V2ForwardTerminalReceipt] = []
            for lease in leases.prefix(2) {
                try await inbox.receive(lease.export, now: now)
                _ = try await writer.importForwardExport(lease.export, capacityProfile: profile, limits: limits,
                    identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
                targetReceipts.append(try #require(try await inbox.terminalReceipt(exportID: lease.export.intent.exportID)))
            }
            try await receipts.record(targetReceipts[0], now: now)
            // A room being exclusively locked cannot yield even the fourth,
            // pending job; claim must skip it without waiting for the holder.
            let barrier = InviteImportTestBarrier()
            let holder = Task {
                do {
                    try await sourceDB.transaction { transaction in
                        let sql = try #require(transaction as? any SQLDatabase)
                        try await sql.raw("SELECT room_id FROM im_v2.rooms WHERE room_id = \(bind: roomUUID) FOR UPDATE").run()
                        await barrier.hold()
                    }
                } catch {
                    // Release the observer even if lock acquisition fails.
                    await barrier.release()
                    await barrier.hold()
                    throw error
                }
            }
            await barrier.waitUntilHeld()
            do {
                #expect(try await jobs.claim(sourceShardID: "room-a", now: now, leaseDuration: 60, limit: 10).isEmpty)
                await barrier.release(); try await holder.value
            } catch {
                await barrier.release(); _ = try? await holder.value; throw error
            }
                try await sourceSQL.raw("UPDATE im_v2.rooms SET owner_epoch = 1 WHERE room_id = \(bind: roomUUID)").run()

            func snapshot() async throws -> [String] {
                var values: [String] = []
                for table in ["rooms", "message_forward_exports", "message_forward_delivery_jobs", "message_forward_export_receipts"] {
                    values.append(try #require(try await sourceSQL.raw("SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), '[]'::jsonb)::text AS value FROM im_v2.\(ident: table) t").first(decoding: StringValueRow.self)).value)
                }
                return values
            }
            let before = try await snapshot()
            for lease in leases { #expect(try await !jobs.isCurrent(lease, now: now)) }
            #expect(try await !jobs.complete(leases[0], now: now))
            #expect(try await !jobs.reschedule(leases[2], disposition: .retry(at: now.addingTimeInterval(2)), resetAttempts: true, now: now))
            #expect(try await !jobs.reschedule(leases[2], disposition: .pause, now: now))
            await #expect(throws: V2ForwardExportError.ownerChanged) { try await receipts.record(targetReceipts[1], now: now) }
            try await receipts.record(targetReceipts[0], now: now)
            for time in [now, now.addingTimeInterval(61)] {
                #expect(try await jobs.claim(sourceShardID: "room-a", now: time, leaseDuration: 60, limit: 10).isEmpty)
            }
            #expect(try await snapshot() == before)
        }
    }

}

private struct ContentReviewJobAssertionRow: Decodable {
    let state: String
    let revision: Int64
    let decision: String?
    enum CodingKeys: String, CodingKey {
        case state, decision
        case revision = "expected_content_revision"
    }
}
private struct ContentReviewLeaseFenceAssertionRow: Decodable {
    let state: String
    let hasNewToken: Bool
    let decision: String?
    enum CodingKeys: String, CodingKey {
        case state, decision
        case hasNewToken = "has_new_token"
    }
}
private struct ContentReviewCompletionAssertionRow: Decodable {
    let state: String
    let decision: String?
    let released: Bool?
}
private struct ContentReviewRetryAssertionRow: Decodable {
    let state: String
    let nextAttemptAt: Date?
    let pausedAt: Date?
    enum CodingKeys: String, CodingKey {
        case state
        case nextAttemptAt = "next_attempt_at"
        case pausedAt = "paused_at"
    }
}
private struct ContentReviewRedactionAssertionRow: Decodable {
    let withdrawn: Bool
    let revision: Int64
    enum CodingKeys: String, CodingKey {
        case withdrawn
        case revision = "content_revision"
    }
}
private struct UnexpectedContentReviewer: V2ContentReviewing {
    func review(_: V2ContentReviewInput) async throws -> V2ContentReviewVerdict {
        throw V2ContentReviewWorkerError.dispositionNotApplied
    }
}
private actor ForwardMediaBlockingScanner: V2MediaScanProvider {
    private(set) var started = false
    func scan(mediaID: MediaID) async throws -> V2MediaScanResult {
        started = true
        try await Task.sleep(for: .seconds(3_600))
        return .passed
    }
}
