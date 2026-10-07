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
import IMV2ActorContracts
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
    @Test("overlapping warm multi-shard batches reserve capacity without deadlocks")
    func overlappingMultiShardBatchesUseDeterministicLockOrder() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4),
                as: .psql,
                isDefault: true
            )
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists")
                .first(decoding: ExistsRow.self))?.exists == false
            else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_300_000)
            let profile = try V2CapacityProfile(id: "deadlock-profile", limits: .init(
                maxEligibleMembers: 10,
                maxCommandsPerWindow: 10_000,

                retryAfterSeconds: 1
            ))
            let shardIDs = ["deadlock-shard-a", "deadlock-shard-b", "deadlock-shard-c"]
            for (index, shardID) in shardIDs.enumerated() {
                let leaseID = UUID(uuidString: String(
                    format: "00000000-0000-0000-0000-%012d",
                    900 + index
                ))!
                try await sql.raw("""
                    INSERT INTO im_v2.shard_admission_pools
                        (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
                    VALUES (\(bind: shardID), \(bind: profile.id), \(bind: leaseID), 1, \(bind: now.addingTimeInterval(600)), 10000)
                    """).run()
            }

            let users = (0 ..< 12).map { index in
                UUID(uuidString: String(
                    format: "00000000-0000-0000-0001-%012d",
                    index + 1
                ))!
            }
            for (index, user) in users.enumerated() {
                try await sql.raw("""
                    INSERT INTO im_v2.public_user_profiles
                        (user_id, public_handle, display_name, revision, created_at, updated_at)
                    VALUES (\(bind: user), \(bind: String(format: "deadlock%02d", index)),
                            \(bind: "并发用户\(index)"), 1, \(bind: now), \(bind: now))
                    """).run()
            }

            var roomActors: [(roomID: RoomID, actorUserID: UserID)] = []
            for shardIndex in shardIDs.indices {
                let direct = V2DirectRoomOperationTestFixture(database: resources.database(.psql),
                    capacityProfile: profile, roomShardID: shardIDs[shardIndex], now: { now })
                for pairIndex in 0 ..< 2 {
                    let userIndex = shardIndex * 4 + pairIndex * 2
                    let actor = try UserID(users[userIndex].uuidString)
                    let target = try UserID(users[userIndex + 1].uuidString)
                    let room = try await direct.openedIdentity(actorUserID: actor,
                        operationID: .init(uuid: UUID()), targetUserID: target,
                        firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                    roomActors.append((room.roomID, actor))
                }
            }
            // Each transaction overlaps two shard rows, while no room or user
            // row overlaps another transaction. Any wait cycle therefore
            // comes specifically from inconsistent shard-row lock ordering.
            let batches = [
                [roomActors[0], roomActors[2]],
                [roomActors[3], roomActors[4]],
                [roomActors[5], roomActors[1]],
            ]
            let sharedCache = V2DirectRoomLogFastAppendCache()
            let writers = try batches.map { _ in
                PostgresV2RoomWriteStore(
                    database: resources.database(.psql),
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10_000, window: 86_400),
                    contentReviewMode: .disabled,
                    directRoomLogFastAppendCache: sharedCache)
            }
            // Prime each direct room through the sole supported per-room path.
            // The shared revision cache then makes every measured batch a warm append.
            for target in roomActors {
                let command = try V2SendMessageCommand(
                    roomID: target.roomID, senderUserID: target.actorUserID,
                    clientMessageID: .init(UUID().uuidString), text: "预热房间",
                    limits: .init(maxUTF8Bytes: 128)
                )
                guard case .accepted = try await writers[0].accept(
                    command: command, capacityProfile: profile,
                    identifiers: .init(messageID: .init(UUID().uuidString), eventID: .init(UUID().uuidString)),
                    now: now
                ) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            }
            let deadlocksBefore = try #require(try await sql.raw("""
                SELECT deadlocks::bigint AS value
                FROM pg_stat_database
                WHERE datname = current_database()
                """).first(decoding: CountRow.self)).value
            let messagesBefore = try await count("im_v2.messages", on: sql)
            let shardUsageBefore = try #require(try await sql.raw("""
                SELECT SUM(command_window_used)::bigint AS value
                FROM im_v2.shard_admission_pools
                WHERE capacity_profile_id = \(bind: profile.id)
                """).first(decoding: CountRow.self)).value

            let rounds = 32
            for round in 0 ..< rounds {
                let gate = V2IntegrationAsyncBarrier(parties: batches.count)
                let acceptedCount = try await withThrowingTaskGroup(of: Int.self) { group in
                    for index in batches.indices {
                        let batch = batches[index]
                        let writer = writers[index]
                        group.addTask {
                            await gate.wait()
                            let requests = try batch.enumerated().map { itemIndex, target in
                                V2RoomWriteRequest(
                                    command: try .init(
                                        roomID: target.roomID,
                                        senderUserID: target.actorUserID,
                                        clientMessageID: .init(UUID().uuidString),
                                        text: "有序锁并发批次 \(round)-\(index)-\(itemIndex)",
                                        limits: .init(maxUTF8Bytes: 128)
                                    ),
                                    capacityProfile: profile,
                                    identifiers: try .init(
                                        messageID: .init(UUID().uuidString),
                                        eventID: .init(UUID().uuidString)
                                    ),
                                    now: now.addingTimeInterval(Double(round))
                                )
                            }
                            return try await writer.acceptAtomically(requests: requests).count
                        }
                    }
                    var total = 0
                    for try await count in group { total += count }
                    return total
                }
                #expect(acceptedCount == 6)
            }

            let deadlocksAfter = try #require(try await sql.raw("""
                SELECT deadlocks::bigint AS value
                FROM pg_stat_database
                WHERE datname = current_database()
                """).first(decoding: CountRow.self)).value
            #expect(deadlocksAfter == deadlocksBefore)
            #expect(try await count("im_v2.messages", on: sql) - messagesBefore == rounds * 6)
            let shardUsageAfter = try #require(try await sql.raw("""
                SELECT SUM(command_window_used)::bigint AS value
                FROM im_v2.shard_admission_pools
                WHERE capacity_profile_id = \(bind: profile.id)
                """).first(decoding: CountRow.self)).value
            #expect(shardUsageAfter - shardUsageBefore == Int64(rounds * 6))

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

    @Test("activation-scoped multi-room appends and receipts do not deadlock on room foreign keys", arguments: [false, true])
    func concurrentGroupAppendsAndReceiptsUseCompatibleRoomLocks(_ actorScoped: Bool) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4),
                as: .psql,
                isDefault: true
            )
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw(
                "SELECT to_regnamespace('im_v2') IS NOT NULL AS exists"
            ).first(decoding: ExistsRow.self))?.exists == false
            else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(capacityClass: .large, on: sql)

            let secondRoom = UUID(
                uuidString: "00000000-0000-0000-0000-000000000021"
            )!
            let now = Date(timeIntervalSince1970: 1_750_000_001)
            try await sql.raw("""
                INSERT INTO im_v2.rooms
                    (room_id, room_shard_id, capacity_profile_id, capacity_class)
                VALUES (\(bind: secondRoom), 'room-a', 'standard',
                        \(bind: V2GroupCapacityClass.large.rawValue))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.group_rooms
                    (room_id, owner_user_id, title, created_at)
                VALUES (\(bind: secondRoom), \(bind: senderUUID),
                        '并发回执群', \(bind: now))
                """).run()
            // Activation-scoped and local variants exercise the same rooms.
            // The activation store needs their control-side owner records.
            try await sql.raw("""
                INSERT INTO im_v2.room_owner_routes
                    (room_id, room_shard_id, route_epoch, created_at, updated_at)
                VALUES (\(bind: secondRoom), 'room-a', 0, \(bind: now), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_admission
                    (room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation)
                VALUES (\(bind: secondRoom), 3, 10000, \(bind: leaseUUID), 1)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_memberships
                    (room_id, user_id, joined_revision)
                VALUES
                    (\(bind: secondRoom), \(bind: senderUUID), 0),
                    (\(bind: secondRoom), \(bind: memberTwoUUID), 0),
                    (\(bind: secondRoom), \(bind: memberThreeUUID), 0)
                """).run()
            try await sql.raw("""
                UPDATE im_v2.room_admission
                SET command_window_limit = 10000
                WHERE room_id = \(bind: roomUUID)
                """).run()
            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools
                SET command_window_limit = 10000,
                    valid_until = \(bind: now.addingTimeInterval(600))
                WHERE room_shard_id = 'room-a'
                  AND capacity_profile_id = 'standard'
                """).run()

            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10,
                maxCommandsPerWindow: 10_000,

                retryAfterSeconds: 1
            ))
            let localWriter = PostgresV2RoomWriteStore(
                database: resources.database(.psql),
                strangerMessagePolicy: try .init(
                    maximumMessagesPerWindow: 10_000,
                    window: 86_400
                ),
                contentReviewMode: .disabled)
            let writer: any V2AtomicRoomWriteBatchStore
            if actorScoped {
                let leases = PostgresV2RoomActivationStore(database: resources.database(.psql))
                let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
                let host = V2ActorHostIdentity(
                    hostID: try .init("receipt-lock-test"), incarnationID: UUID()
                )
                var tokens: [V2RoomActivationToken] = []
                for room in [roomUUID, secondRoom] {
                    guard case .acquired(let lease) = try await leases.acquire(
                        roomID: .init(uuid: room), owner: owner, host: host,
                        duration: .init(30_000)
                    ) else { throw V2RoomActivationLeaseError.activationChanged }
                    tokens.append(lease.token)
                }
                writer = localWriter.usingActivationScope(try .init(tokens: tokens))
            } else {
                writer = localWriter
            }
            let receiptStore = PostgresV2ReadReceiptStore(database: resources.database(.psql))
            let rooms = [roomUUID, secondRoom]

            func appendRequests(round: Int) throws -> [V2RoomWriteRequest] {
                try rooms.enumerated().map { index, room in
                    V2RoomWriteRequest(
                        command: try .init(
                            roomID: .init(room.uuidString),
                            senderUserID: senderID,
                            clientMessageID: .init(UUID().uuidString),
                            text: "append/receipt lock regression \(round)-\(index)",
                            limits: .init(maxUTF8Bytes: 128)
                        ),
                        capacityProfile: profile,
                        identifiers: try .init(
                            messageID: .init(UUID().uuidString),
                            eventID: .init(UUID().uuidString)
                        ),
                        now: now.addingTimeInterval(Double(round))
                    )
                }
            }

            #expect(try await writer.acceptAtomically(
                requests: appendRequests(round: 0)
            ).count == 2)
            let deadlocksBefore = try #require(try await sql.raw("""
                SELECT deadlocks::bigint AS value
                FROM pg_stat_database
                WHERE datname = current_database()
                """).first(decoding: CountRow.self)).value
            let rounds = 32
            for round in 1 ... rounds {
                let gate = V2IntegrationAsyncBarrier(parties: 2)
                let completed = try await withThrowingTaskGroup(of: Int.self) { group in
                    group.addTask {
                        await gate.wait()
                        return try await writer.acceptAtomically(
                            requests: appendRequests(round: round)
                        ).count
                    }
                    group.addTask {
                        await gate.wait()
                        let requests = try rooms.reversed().map { room in
                            V2ReadReceiptRecordRequest(
                                command: try .init(
                                    roomID: try .init(room.uuidString),
                                    actorUserID: senderID,
                                    operationID: try .init(UUID().uuidString),
                                    readThroughRoomSequence: 1
                                ),
                                now: now.addingTimeInterval(Double(round))
                            )
                        }
                        let results: [V2GroupReadReceiptBatchResult]
                        if actorScoped {
                            let route = try V2RoomShardRoute(shardID: "room-a", epoch: 0)
                            results = try await receiptStore.recordGroupsOwnerValidated(requests.map { .init(request: $0, ownerRoute: route) })
                        } else { results = try await receiptStore.recordGroups(requests) }
                        guard results.allSatisfy({ result in
                            if case .success(.handled(.recorded)) = result { return true }
                            return false
                        }) else {
                            throw V2ReadReceiptStoreError.corruptPersistenceState
                        }
                        return results.count
                    }
                    var total = 0
                    for try await count in group { total += count }
                    return total
                }
                #expect(completed == 4)
            }

            let deadlocksAfter = try #require(try await sql.raw("""
                SELECT deadlocks::bigint AS value
                FROM pg_stat_database
                WHERE datname = current_database()
                """).first(decoding: CountRow.self)).value
            #expect(deadlocksAfter == deadlocksBefore)
            #expect(try await count("im_v2.messages", on: sql) == 2 + rounds * 2)
            #expect(try await count("im_v2.read_receipt_operations", on: sql) == rounds * 2)

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

    @Test("concurrent independent presence admissions must all materialize their leases")
    func concurrentIndependentPresenceAdmissionsMaterializeLeases() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 8),
                as: .psql,
                isDefault: true
            )
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists")
                .first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let admissionCount = 256
            let users = (0..<admissionCount).map {
                UUID(uuidString: String(format: "00000000-0000-0000-0001-%012x", $0))!
            }
            let devices = (0..<admissionCount).map {
                UUID(uuidString: String(format: "00000000-0000-0000-0002-%012x", $0))!
            }
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices
                    (user_id, device_id, created_at, last_active_at)
                SELECT input.user_id, input.device_id, \(bind: now), \(bind: now)
                FROM unnest(\(bind: users)::uuid[], \(bind: devices)::uuid[])
                     AS input(user_id, device_id)
                """).run()
            let identities = try zip(users, devices).map { user, device in
                try V2AuthenticatedConnection(
                    userID: .init(user.uuidString),
                    deviceID: .init(device.uuidString),
                    capabilityProfile: "base"
                )
            }
            let store = try PostgresV2LiveActivityStore(database: resources.database(.psql))
            let policy = V2AuthenticatedConnectionAdmissionPolicy(
                maximumConnectionsPerDevice: 2,
                maximumConnectionsPerUser: 8
            )
            let outcomes = try await withThrowingTaskGroup(
                of: V2AuthenticatedConnectionLeaseOutcome.self,
                returning: [V2AuthenticatedConnectionLeaseOutcome].self
            ) { group in
                for (index, identity) in identities.enumerated() {
                    group.addTask {
                        try await store.admitConnection(
                            identity: identity,
                            connectionID: UUID(
                                uuidString: String(
                                    format: "00000000-0000-0000-0003-%012x", index
                                )
                            )!,
                            publicationSuppressed: false,
                            policy: policy,
                            now: now
                        )
                    }
                }
                var result: [V2AuthenticatedConnectionLeaseOutcome] = []
                result.reserveCapacity(admissionCount)
                for try await outcome in group { result.append(outcome) }
                return result
            }
            #expect(outcomes.count == admissionCount)
            #expect(outcomes.allSatisfy { outcome in
                outcome == .accepted(expiresAt: now.addingTimeInterval(90))
            })
            #expect(
                try await count("im_v2.user_live_presence_leases", on: sql)
                    == admissionCount
            )

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

    @Test("an expired presence lease must reacquire the global connection budget")
    func expiredPresenceLeaseCannotResurrectPastTheConnectionLimit() async throws {
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
            let now = Date()
            let user = UUID(uuidString: "00000000-0000-0000-0000-0000000008c1")!
            let device = UUID(uuidString: "00000000-0000-0000-0000-0000000008c2")!
            let peerUser = UUID(uuidString: "00000000-0000-0000-0000-0000000008d1")!
            let peerDevice = UUID(uuidString: "00000000-0000-0000-0000-0000000008d2")!
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices
                    (user_id, device_id, created_at, last_active_at)
                VALUES (\(bind: user), \(bind: device), \(bind: now), \(bind: now)),
                       (\(bind: peerUser), \(bind: peerDevice), \(bind: now), \(bind: now))
                """).run()
            let identity = try V2AuthenticatedConnection(
                userID: .init(user.uuidString),
                deviceID: .init(device.uuidString),
                capabilityProfile: "base"
            )
            let peerIdentity = try V2AuthenticatedConnection(
                userID: .init(peerUser.uuidString),
                deviceID: .init(peerDevice.uuidString),
                capabilityProfile: "base"
            )
            let firstConnection = UUID(uuidString: "00000000-0000-0000-0000-0000000008c3")!
            let replacementConnection = UUID(uuidString: "00000000-0000-0000-0000-0000000008c4")!
            let peerConnection = UUID(uuidString: "00000000-0000-0000-0000-0000000008d3")!
            let policy = V2AuthenticatedConnectionAdmissionPolicy(
                maximumConnectionsPerDevice: 1,
                maximumConnectionsPerUser: 1
            )
            let store = try PostgresV2LiveActivityStore(database: resources.database(.psql), onlineLease: 10)

            guard case .accepted(let expiry1) = try await store.admitConnection(
                identity: identity,
                connectionID: firstConnection,
                publicationSuppressed: false,
                policy: policy,
                now: now
            ) else { throw CancellationError() }
            #expect(expiry1 >= now.addingTimeInterval(9))
            guard case .accepted(let expiry2) = try await store.admitConnection(
                identity: peerIdentity,
                connectionID: peerConnection,
                publicationSuppressed: false,
                policy: policy,
                now: now
            ) else { throw CancellationError() }
            #expect(expiry2 >= now.addingTimeInterval(9))
            guard case .accepted(let expiry3) = try await store.renewConnection(
                identity: identity,
                connectionID: firstConnection,
                now: now.addingTimeInterval(1)
            ) else { throw CancellationError() }
            #expect(expiry3 >= now.addingTimeInterval(9))
            try await sql.raw("""
                INSERT INTO im_v2.user_live_activity_preferences
                    (user_id, allows_online_presence, allows_typing_indicators, updated_at)
                VALUES (\(bind: user), FALSE, TRUE, \(bind: now.addingTimeInterval(1)))
                """).run()
            let batched = try await store.renewConnections([
                .init(
                    identity: identity,
                    connectionID: firstConnection,
                    now: now.addingTimeInterval(1.25)
                ),
                .init(
                    identity: identity,
                    connectionID: firstConnection,
                    now: now.addingTimeInterval(1.5)
                ),
                .init(
                    identity: peerIdentity,
                    connectionID: peerConnection,
                    now: now.addingTimeInterval(1.5)
                ),
            ])
            #expect(batched.count == 2)
            #expect(batched[firstConnection]?.allowsOnlinePresence == false)
            #expect(batched[peerConnection]?.allowsOnlinePresence == true)
            for value in batched.values {
                guard case .accepted(let expiry) = value.outcome else { throw CancellationError() }
                #expect(expiry >= now.addingTimeInterval(9))
                #expect((value.remainingLeaseSeconds ?? 0) > 9 && (value.remainingLeaseSeconds ?? 11) <= 10.001)
            }
            #expect(try await !store.removePresence(
                identity: peerIdentity,
                connectionID: peerConnection,
                now: now.addingTimeInterval(1.5)
            ))

            // Expire the actual row without sleeping or treating a future caller clock as authority.
            try await sql.raw("UPDATE im_v2.user_live_presence_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE connection_id=\(bind:firstConnection)").run()
            let afterExpiry = Date()
            #expect(try await store.renewConnection(
                identity: identity,
                connectionID: firstConnection,
                now: afterExpiry
            ) == .rejected)
            guard case .accepted(let expiry4) = try await store.admitConnection(
                identity: identity,
                connectionID: replacementConnection,
                publicationSuppressed: false,
                policy: policy,
                now: afterExpiry
            ) else { throw CancellationError() }
            #expect(expiry4 >= now.addingTimeInterval(9))
            #expect(try await store.admitConnection(
                identity: identity,
                connectionID: firstConnection,
                publicationSuppressed: false,
                policy: policy,
                now: afterExpiry
            ) == .rejected)
            #expect(try await store.removePresence(
                identity: identity,
                connectionID: firstConnection,
                now: afterExpiry
            ))
            #expect(try await count("im_v2.user_live_presence_leases", on: sql) == 1)
            #expect(try await sql.raw("""
                SELECT EXISTS (
                    SELECT 1 FROM im_v2.user_live_presence_leases
                    WHERE connection_id = \(bind: replacementConnection)
                ) AS exists
                """).first(decoding: ExistsRow.self)?.exists == true)

            #expect(try await !store.removePresence(
                identity: identity,
                connectionID: replacementConnection,
                now: afterExpiry
            ))
            #expect(try await count("im_v2.user_live_presence_leases", on: sql) == 0)

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

    @Test("bounded housekeeping expires capabilities, recovers stale reset fences, and keeps ACK position")
    func boundedHousekeepingRecoversExpiredSyncReset() async throws {
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
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let user = UUID(uuidString: "00000000-0000-0000-0000-0000000008a1")!
            let device = UUID(uuidString: "00000000-0000-0000-0000-0000000008a2")!
            let snapshot = UUID(uuidString: "00000000-0000-0000-0000-0000000008a3")!
            try await sql.raw("""
                INSERT INTO im_v2.device_sync_cursors
                    (user_id, device_id, state, reset_generation, acknowledged_sequence,
                     pending_snapshot_id, pending_base_sequence, pending_snapshot_expires_at)
                VALUES (\(bind: user), \(bind: device), 'reset_pending', 2, 7,
                        \(bind: snapshot), 9, \(bind: now.addingTimeInterval(-1)))
                """).run()
            let digest = String(repeating: "a", count: 64)
            try await sql.raw("""
                INSERT INTO im_v2.sync_snapshot_artifacts
                    (snapshot_id, user_id, base_user_sync_sequence, source_projected_sequence,
                     schema_version, capability_profile, state, next_page_index,
                     rolling_digest, root_digest, page_count, item_count, total_bytes,
                     expires_at, created_at, published_at)
                VALUES (\(bind: snapshot), \(bind: user), 9, 9, 30, 'test', 'published', 1,
                        \(bind: digest), \(bind: digest), 1, 1, 3,
                        \(bind: now.addingTimeInterval(-1)), \(bind: now.addingTimeInterval(-60)),
                        \(bind: now.addingTimeInterval(-30)))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.sync_snapshot_pages
                    (snapshot_id, page_index, first_projection_kind, first_entity_key,
                     last_projection_kind, last_entity_key, item_count, page_digest,
                     payload, byte_count)
                VALUES (\(bind: snapshot), 0, 'message', 'one', 'message', 'one', 1,
                        \(bind: digest), \(bind: Data([1, 2, 3])), 3)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.device_snapshot_resets
                    (user_id, device_id, reset_generation, snapshot_id, state,
                     next_sync_token, snapshot_receipt, expires_at, created_at)
                VALUES (\(bind: user), \(bind: device), 2, \(bind: snapshot), 'ready',
                        'snapshot-token', 'snapshot-receipt',
                        \(bind: now.addingTimeInterval(-1)), \(bind: now.addingTimeInterval(-60)))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.sync_tokens
                    (token, user_id, device_id, reset_generation, watermark, expires_at, created_at)
                VALUES
                    ('expired-token', \(bind: user), \(bind: device), 2, 7, \(bind: now.addingTimeInterval(-1)), \(bind: now.addingTimeInterval(-60))),
                    ('live-token', \(bind: user), \(bind: device), 2, 7, \(bind: now.addingTimeInterval(60)), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.sync_receipts
                    (receipt, user_id, device_id, reset_generation, first_sequence, last_sequence, expires_at, created_at)
                VALUES
                    ('expired-receipt', \(bind: user), \(bind: device), 2, 7, 7, \(bind: now.addingTimeInterval(-1)), \(bind: now.addingTimeInterval(-60))),
                    ('live-receipt', \(bind: user), \(bind: device), 2, 7, 7, \(bind: now.addingTimeInterval(60)), \(bind: now))
                """).run()
            let report = try await V2SyncHousekeepingWorker(
                store: PostgresV2SyncHousekeepingStore(database: resources.database(.psql)),
                now: { now }
            ).runOnce(limit: 8)
            #expect(report == .init(expiredTokenCount: 1, expiredReceiptCount: 1, recoveredResetCount: 1, purgedSnapshotCount: 1))
            let cursor = try #require(try await sql.raw("""
                SELECT state, acknowledged_sequence, pending_snapshot_id
                FROM im_v2.device_sync_cursors
                WHERE user_id = \(bind: user) AND device_id = \(bind: device)
                """).first(decoding: HousekeepingCursorAssertionRow.self))
            #expect(cursor.state == "ready")
            #expect(cursor.acknowledgedSequence == 7)
            #expect(cursor.pendingSnapshotID == nil)
            let recoveredGeneration = try #require(try await sql.raw("""
                SELECT reset_generation AS value FROM im_v2.device_sync_cursors
                WHERE user_id = \(bind: user) AND device_id = \(bind: device)
                """).first(decoding: CountRow.self))
            #expect(recoveredGeneration.value == 1)
            #expect(try await count("im_v2.sync_snapshot_artifacts", on: sql) == 0)
            #expect(try await count("im_v2.sync_snapshot_pages", on: sql) == 0)
            #expect(try await count("im_v2.device_snapshot_resets", on: sql) == 0)
            #expect(try await count("im_v2.sync_tokens", on: sql) == 1)
            #expect(try await count("im_v2.sync_receipts", on: sql) == 1)

            // Revoked devices can never authenticate again. Their live
            // capability rows must not pin compaction or make cursor storage
            // grow with account history.
            let revokedDevice = UUID(uuidString: "00000000-0000-0000-0000-0000000008a4")!
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices
                    (user_id, device_id, revoked_at, created_at, last_active_at)
                VALUES (\(bind: user), \(bind: revokedDevice), \(bind: now),
                        \(bind: now.addingTimeInterval(-60)), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.device_sync_cursors
                    (user_id, device_id, state, reset_generation, acknowledged_sequence)
                VALUES (\(bind: user), \(bind: revokedDevice), 'ready', 1, 3)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.sync_tokens
                    (token, user_id, device_id, reset_generation, watermark,
                     expires_at, created_at)
                VALUES ('revoked-live-token', \(bind: user), \(bind: revokedDevice),
                        1, 3, \(bind: now.addingTimeInterval(600)), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.sync_receipts
                    (receipt, user_id, device_id, reset_generation,
                     first_sequence, last_sequence, expires_at, created_at)
                VALUES ('revoked-live-receipt', \(bind: user), \(bind: revokedDevice),
                        1, 3, 3, \(bind: now.addingTimeInterval(600)), \(bind: now))
                """).run()
            try await V2PostgresRevokedDeviceProjectionStore(
                database: resources.database(.psql)
            ).clean(
                userID: .init(user.uuidString),
                deviceID: .init(revokedDevice.uuidString),
                revokedAt: now
            )
            #expect(try await sql.raw("""
                SELECT COUNT(*) AS value FROM im_v2.device_sync_cursors
                WHERE user_id = \(bind: user) AND device_id = \(bind: revokedDevice)
                """).first(decoding: CountRow.self)?.value == 0)
            #expect(try await sql.raw("""
                SELECT COUNT(*) AS value FROM im_v2.sync_tokens
                WHERE user_id = \(bind: user) AND device_id = \(bind: revokedDevice)
                """).first(decoding: CountRow.self)?.value == 0)
            #expect(try await sql.raw("""
                SELECT COUNT(*) AS value FROM im_v2.sync_receipts
                WHERE user_id = \(bind: user) AND device_id = \(bind: revokedDevice)
                """).first(decoding: CountRow.self)?.value == 0)
            #expect(try await sql.raw("""
                SELECT COUNT(*) AS value
                FROM im_v2.revoked_device_projection_tombstones
                WHERE user_id = \(bind: user) AND device_id = \(bind: revokedDevice)
                """).first(decoding: CountRow.self)?.value == 1)

            // Stable projection effects are compacted only after their
            // incremental log row is gone.
            let projectionEvent = UUID(uuidString: "00000000-0000-0000-0000-0000000008a5")!
            let projectionOld = now.addingTimeInterval(-40 * 86_400)
            try await sql.raw("""
                INSERT INTO im_v2.user_projection_checkpoints
                    (user_id, projected_sequence, updated_at)
                VALUES (\(bind: user), 1, \(bind: now))
                ON CONFLICT (user_id) DO UPDATE
                SET projected_sequence = 1, updated_at = EXCLUDED.updated_at
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.user_projection_versions
                    (user_id, projection_kind, entity_key, valid_from_sequence,
                     source_event_id, payload, created_at)
                VALUES (\(bind: user), 'conversation_state', 'housekeeping-room', 1,
                        \(bind: projectionEvent), '{}'::jsonb, \(bind: projectionOld))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.user_projection_effects
                    (user_id, source_event_id, projection_kind,
                     user_sync_sequence, payload, created_at)
                VALUES (\(bind: user), \(bind: projectionEvent), 'conversation_state',
                        1, '{}'::jsonb, \(bind: projectionOld))
                """).run()
            let effectReport = try await V2SyncHousekeepingWorker(
                store: PostgresV2SyncHousekeepingStore(database: resources.database(.psql)),
                now: { now }
            ).runOnce(limit: 8)
            #expect(effectReport.purgedProjectionEffectCount == 1)
            #expect(try await count("im_v2.user_projection_effects", on: sql) == 0)
            #expect(try await count("im_v2.user_projection_versions", on: sql) == 1)

            // One old terminal fan-out is dismantled leaf-first in the same
            // bounded pass while its authoritative room event is retained.
            try await seedRoom(on: sql)
            let event = UUID(uuidString: "00000000-0000-0000-0000-0000000008b1")!
            let plan = UUID(uuidString: "00000000-0000-0000-0000-0000000008b2")!
            let unit = UUID(uuidString: "00000000-0000-0000-0000-0000000008b3")!
            let old = now.addingTimeInterval(-8 * 86_400)
            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id,
                     payload, committed_membership_revision, created_at)
                VALUES (\(bind: event), \(bind: roomUUID), 1, 'housekeeping.test',
                        \(bind: senderUUID), '{}'::jsonb, 0, \(bind: old))
                """).run()
            let veryOld = now.addingTimeInterval(-40 * 86_400)
            let directOperation = UUID(uuidString: "00000000-0000-0000-0000-0000000008b4")!
            let directCommand = try V2DirectRoomOperationCommand(actorUserID: senderID,
                operationID: .init(uuid: directOperation), targetUserID: .init(uuid: memberTwoUUID),
                firstSubmissionDeadlineMilliseconds: UInt64(veryOld.timeIntervalSince1970 * 1000) + 600_000)
            let directRecovery = try V2DirectRoomOperationRecoveryRequest(identity: directCommand.identity,
                fingerprint: directCommand.fingerprint, action: .closeIfAbsent)
            let directStore = PostgresV2DirectMessagingStore(database: resources.database(.psql),
                identityReader: PostgresV2DirectRoomIdentityReader(database: resources.database(.psql)),
                projectionDelivery: SuccessfulProjectionDelivery())
            guard case .receipt(let originalDirectProof) = try await directStore.recoverDirectRoomOperation(directRecovery, now: veryOld),
                  case .closed = originalDirectProof.outcome else { throw V2DirectMessagingStoreError.corruptPersistenceState }
            let staleConnection = UUID(uuidString: "00000000-0000-0000-0000-0000000008b5")!
            try await sql.raw("""
                INSERT INTO im_v2.user_live_presence_leases
                    (connection_id, user_id, device_id, expires_at, updated_at)
                VALUES (\(bind: staleConnection), \(bind: user), \(bind: revokedDevice),
                        \(bind: now.addingTimeInterval(-1)), \(bind: veryOld))
                """).run()
            let credentialOperation = UUID(uuidString: "00000000-0000-0000-0000-0000000008b6")!
            try await sql.raw("""
                INSERT INTO im_v2.device_credential_operations
                    (device_id, operation_id, operation_kind, user_id,
                     resulting_access_token_hmac, encrypted_access_token,
                     encrypted_refresh_credential, encrypted_revocation_credential, revocation_credential_expires_at, access_token_expires_at,
                     replay_expires_at, created_at)
                VALUES (\(bind: revokedDevice), \(bind: credentialOperation), 'refresh',
                        \(bind: user), \(bind: String(repeating: "a", count: 64)),
                        'encrypted-access', 'encrypted-refresh', 'encrypted-revocation', \(bind: now.addingTimeInterval(600)),
                        \(bind: now.addingTimeInterval(-2)),
                        \(bind: now.addingTimeInterval(-1)), \(bind: veryOld))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.device_refresh_token_history
                    (user_id, device_id, family_generation, refresh_hmac,
                     consumed_at, expires_at)
                VALUES (
                    \(bind: user), \(bind: revokedDevice), 1,
                    \(bind: String(repeating: "b", count: 64)),
                    \(bind: veryOld), \(bind: now.addingTimeInterval(-1))
                )
                """).run()

            let controlReport = try await V2ControlPlaneHousekeepingWorker(
                store: PostgresV2ControlPlaneHousekeepingStore(database: resources.database(.psql)),
                now: { now }
            ).runOnce(limit: 256)
            #expect(controlReport.deletedRows == 3)
            #expect(controlReport.deletedRows <= 256)
            #expect(controlReport.purgedIdempotencyRows == 0)
            #expect(controlReport.purgedExpiredConnectionLeaseRows == 1)
            #expect(controlReport.purgedExpiredCredentialReplayRows == 1)
            #expect(controlReport.purgedExpiredRefreshHistoryRows == 1)
            // Minimal terminal proof remains permanent across both cleanup owners.
            #expect(try await count("im_v2.direct_room_owner_receipts", on: sql) == 1)
            let roomReport = try await purgeRoomBookkeeping(
                database: resources.database(.psql), roomID: roomUUID, now: now)
            #expect(roomReport.deletedOperationRows == 0 && roomReport.deletedReviewJobs == 0)
            #expect(try await count("im_v2.room_events", on: sql) == 1)
            #expect(try await count("im_v2.direct_room_owner_receipts", on: sql) == 1)
            #expect(try await directStore.recoverDirectRoomOperation(directRecovery, now: now) == .receipt(originalDirectProof))
            #expect(try await count("im_v2.user_live_presence_leases", on: sql) == 0)
            #expect(try await count("im_v2.device_credential_operations", on: sql) == 0)
            #expect(try await count("im_v2.device_refresh_token_history", on: sql) == 0)

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

    @Test("room state GC retains current revisions and young states without personal references")
    func roomStateGCWithoutPersonalReferences() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let old = now.addingTimeInterval(-120)
            let service = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database),
                capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { old })
            guard case .accepted(let message) = try await service.send(.init(roomID: roomID,
                actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "current revision")) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let repository = PostgresV2MessageProjectionStateRepository()
            let current = try await repository.loadCurrentOrMaterialize(messageID: message.messageID.uuidValue!, revision: 1, sql: sql)
            var orphanIDs: [UUID] = []
            for date in [old, now] {
                let orphan = try V2StoredMessageProjectionState(
                    state: .init(accepted: .init(messageID: .init(uuid: UUID()), roomID: roomID, roomSequence: 1,
                        senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "orphan", mediaPresentations: [], createdAt: date),
                        forwardedFromMessageID: nil, forwardedFromUserID: nil),
                    originEventID: UUID(), stateEventID: nil, createdAt: date)
                try await repository.persist(orphan, sql: sql)
                orphanIDs.append(orphan.stateID)
            }
            let gc = PostgresV2MessageProjectionStateGCWorker(database: database, retention: 60)
            #expect(try await gc.runOnce(now: now, limit: 1) == 1)
            #expect(try await gc.runOnce(now: now, limit: 1) == 0)
            #expect(try await sql.raw("SELECT 1 FROM im_v2.message_projection_states WHERE state_id = \(bind: orphanIDs[0])").first() == nil)
            for retained in [current.stateID, orphanIDs[1]] {
                #expect(try await sql.raw("SELECT 1 FROM im_v2.message_projection_states WHERE state_id = \(bind: retained)").first() != nil)
            }
        }
    }

    @Test("Missing message states retain the authoritative timestamp when materialized and read again",
          arguments: [V2GroupCapacityClass.standard, .large])
    func messageStateMaterializationTimestampPrecision(mode: V2GroupCapacityClass) async throws {
        try await withForwardOwnerDatabases(mode: mode) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let service = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database),
                capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { now })
            let repository = PostgresV2MessageProjectionStateRepository()
            let offsets: [Int64] = [-1, 1, 803_315_200_123_457, -211_813_487_999_999_999, 9_223_371_331_199_999_999]
            for offset in offsets {
                guard case .accepted(let message) = try await service.send(.init(roomID: roomID,
                    actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "materialize clock")),
                      let messageID = message.messageID.uuidValue else { throw V2RoomWriteStoreError.corruptPersistenceState }
                var buffer = ByteBuffer()
                buffer.writeInteger(offset)
                let timestamp = try V2PersistenceTimestamp(from: &buffer, type: .timestamptz, format: .binary, context: .default)
                try await sql.raw("DELETE FROM im_v2.message_projection_states WHERE message_id = \(bind: messageID)").run()
                try await sql.raw("UPDATE im_v2.messages SET created_at = \(bind: timestamp) WHERE message_id = \(bind: messageID)").run()
                for _ in 0..<2 {
                    let stored = try await repository.loadCurrentOrMaterialize(messageID: messageID, revision: 1, sql: sql)
                    #expect(try stored.state.text == "materialize clock")
                    #expect(try await sql.raw("""
                        SELECT COUNT(*) = 1 AND bool_and(state.created_at = message.created_at) AS exists
                        FROM im_v2.message_projection_states state
                        JOIN im_v2.messages message ON message.message_id = state.message_id
                        WHERE message.message_id = \(bind: messageID)
                        """).first(decoding: ExistsRow.self)?.exists == true)
                }
            }
        }
    }

    /// Historical domain migrations below assume a currently usable device.
    /// Model a recent device explicitly; age/expiry backfill has its own test.

    @Test("password lifecycle revokes sessions, rejects stale assertions and consumes recovery once")
    func passwordLifecycle() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        let worker = V2PasswordHashWorker()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            let exists = try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self)
            guard exists?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            let key = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 41, count: 32))
            let store = V2PostgresPasswordAccountStore(database: resources.database(.psql))
            let device = DeviceID(uuid: UUID())
            let firstPassword = "original-password"
            let user = try await store.register(accountHandle: "lifecycle-user", passwordHash: try await worker.hash(firstPassword),
                publicHandle: "lifecycle_user", displayName: "Lifecycle", deviceID: device)
            let lifecycle = V2PasswordLifecycleService(database: resources.database(.psql), passwords: worker,
                limiter: V2PostgresPasswordLoginAttemptLimiter(database: resources.database(.psql), policy: try .init(maximumFailures: 10, window: 60, lockout: 60)), recoveryKey: key)
            let issuer = try V2PostgresDeviceCredentialService(database: resources.database(.psql), tokenHMACKey: key,
                replayEnvelopeKey: .init(rawBytes: Data(repeating: 42, count: 32)))
            let initial = try await issuer.register(.init(userID: user, deviceID: device, operationID: UUID(), credentialRevision: 1))
            guard case .issued(let tokens) = initial else { Issue.record("Expected device credentials"); throw V2PasswordLifecycleError.unavailable }
            let auth = V2PostgresGatewayAuthenticator(database: resources.database(.psql), tokenKey: key)
            #expect(try await auth.authenticateSession(accessToken: tokens.accessToken, deviceID: device).userID == user)
            let code = String(repeating: "a1", count: 32)
            await #expect(throws: V2PasswordLifecycleError.rejected) {
                try await lifecycle.setRecoveryCode(accountHandle: "lifecycle-user", password: "incorrect-password", recoveryCode: code, deviceID: device)
            }
            try await lifecycle.setRecoveryCode(accountHandle: "lifecycle-user", password: firstPassword, recoveryCode: code, deviceID: device)
            struct RecoveryRow: Decodable { let digest: String?; let revision: Int64 }
            let saved = try #require(try await sql.raw("SELECT recovery_code_hmac AS digest, credential_revision AS revision FROM im_v2.account_password_credentials WHERE user_id = \(bind: user.uuidValue)").first(decoding: RecoveryRow.self))
            #expect(saved.digest != code)
            #expect(saved.digest?.count == 64)
            #expect(saved.revision == 1)
            try await lifecycle.changePassword(accountHandle: "lifecycle-user", currentPassword: firstPassword, newPassword: "replacement-password", deviceID: device)
            await #expect(throws: V2GatewayAuthenticationError.unauthenticated) {
                try await auth.authenticateSession(accessToken: tokens.accessToken, deviceID: device)
            }
            #expect(try await issuer.register(.init(userID: user, deviceID: .init(uuid: UUID()), operationID: UUID(), credentialRevision: 1)) == .deviceUnavailable)
            let changed = try #require(try await store.passwordCredential(for: "lifecycle-user"))
            #expect(changed.revision == 2)
            #expect(try await worker.verify("replacement-password", created: changed.passwordHash))
            #expect(try await worker.verify(firstPassword, created: changed.passwordHash) == false)
            await #expect(throws: V2PasswordLifecycleError.rejected) {
                try await lifecycle.resetPassword(accountHandle: "lifecycle-user", recoveryCode: code, newPassword: "recovered-password", deviceID: device)
            }
            try await lifecycle.setRecoveryCode(accountHandle: "lifecycle-user", password: "replacement-password", recoveryCode: code, deviceID: device)
            let winners = try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        do {
                            try await lifecycle.resetPassword(accountHandle: "lifecycle-user", recoveryCode: code, newPassword: "recovered-password", deviceID: device)
                            return true
                        } catch V2PasswordLifecycleError.rejected { return false }
                    }
                }
                var successes = 0
                for try await winner in group { if winner { successes += 1 } }
                return successes
            }
            #expect(winners == 1)
            let recovered = try #require(try await store.passwordCredential(for: "lifecycle-user"))
            #expect(recovered.revision == 3)
            #expect(try await worker.verify("recovered-password", created: recovered.passwordHash))
            await #expect(throws: V2PasswordLifecycleError.rejected) {
                try await lifecycle.resetPassword(accountHandle: "lifecycle-user", recoveryCode: code, newPassword: "another-password", deviceID: device)
            }
            #expect(try await issuer.register(.init(userID: user, deviceID: .init(uuid: UUID()), operationID: UUID(), credentialRevision: 2)) == .deviceUnavailable)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await worker.shutdown()
            try await resources.shutdown()
        } catch {
            try? await worker.shutdown()
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("housekeeping retains exact permanent invitation and member operation evidence", arguments: ["approved", "mismatched"])
    func invitationApprovalReceiptsSurviveHousekeeping(_ state: String) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let applicant = UUID()
            try await sql.raw("INSERT INTO im_v2.public_user_profiles (user_id, public_handle, display_name, created_at, updated_at) VALUES (\(bind: applicant), 'retained_applicant', 'Retained Applicant', \(bind: now), \(bind: now))").run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 3))
            // Control authorization has its own pool even when its schema is colocated.
            // Owner transactions must not wait for another connection from their own exhausted pool.
            let controlID = DatabaseID(string: "cleanup-invitation-control")
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: controlID)
            let operations = try await CleanupInvitationOperations.make(database: resources.database(.psql),
                controlDatabase: resources.database(controlID), roomID: roomID, profile: profile, now: now)
            let invite = try await operations.createLink(actor: senderID)
            let submission = try await operations.submission(actor: .init(uuid: applicant), inviteID: invite.inviteID, secret: invite.secret)
            let request = try await operations.requestID(submission)
            let decisionOperation = GroupJoinDecisionOperationID(uuid: UUID())
            let decision = try await operations.decision(actor: senderID, requestID: request, revision: 0, operation: decisionOperation)
            let first = try await operations.execute(decision)
            guard case .receipt(let approval) = first, case .applied(.requestDecided(_, .approve, 1)) = approval.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            let remove = try await operations.membership(actor: senderID, target: .init(uuid: applicant), action: .remove, revision: 1)
            guard case .receipt(let removal) = try await operations.executeMembership(remove), case .changed = removal.outcome else { throw V2MembershipOperationValidationError.invalidReceipt }
            // The same UUID under a different actor cannot replace the approval proof.
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: memberTwoUUID)").run()
            let other = try await operations.membership(actor: .init(uuid: memberTwoUUID), target: .init(uuid: memberThreeUUID), action: .remove, revision: 2, operation: .init(decisionOperation.rawValue))
            guard case .receipt(let unrelated) = try await operations.executeMembership(other), case .changed = unrelated.outcome else { throw V2MembershipOperationValidationError.invalidReceipt }
            if state == "mismatched" {
                try await sql.raw("UPDATE im_v2.group_join_requests SET applicant_user_id = \(bind: memberTwoUUID) WHERE request_id = \(bind: request.uuidValue!)").run()
            }
            let expectedReceipt = try #require(try await sql.raw("SELECT receipt::text AS value FROM im_v2.group_invitation_receipts WHERE actor_user_id = \(bind: senderUUID) AND operation_id = \(bind: decisionOperation.uuidValue!)").first(decoding: StringValueRow.self)).value
            let originalApprovalLedger = try #require(try await sql.raw("SELECT row_to_json(m)::text AS value FROM im_v2.room_membership_operations m WHERE actor_user_id = \(bind: senderUUID) AND operation_id = \(bind: decisionOperation.uuidValue!)").first(decoding: StringValueRow.self)).value
            let later = now.addingTimeInterval(V2IdempotencyPolicy.minimumServerRetention + 1)
            let worker = V2ControlPlaneHousekeepingWorker(store: PostgresV2ControlPlaneHousekeepingStore(database: resources.database(.psql)), now: { later })
            _ = try await worker.runOnce(limit: 65_536)
            _ = try await PostgresV2RoomBookkeepingStore(database: resources.database(.psql)).purge(token: operations.token, now: later, retention: 7 * 86_400, idempotencyRetention: V2IdempotencyPolicy.minimumServerRetention, rowLimit: 1_000)
            #expect(try await count("im_v2.group_invitation_receipts", on: sql) == 3)
            #expect(try await count("im_v2.membership_operation_receipts", on: sql) == 2)
            let retainedReceipt = try await sql.raw("SELECT receipt::text AS value FROM im_v2.group_invitation_receipts WHERE actor_user_id = \(bind: senderUUID) AND operation_id = \(bind: decisionOperation.uuidValue!)").first(decoding: StringValueRow.self)?.value
            #expect(retainedReceipt == expectedReceipt)
            #expect(try await sql.raw("SELECT row_to_json(m)::text AS value FROM im_v2.room_membership_operations m WHERE actor_user_id = \(bind: senderUUID) AND operation_id = \(bind: decisionOperation.uuidValue!)").first(decoding: StringValueRow.self)?.value == originalApprovalLedger)
            // Original immutable proof wins even after the applicant leaves or the mutable request is corrupted.
            #expect(try await operations.coordinator.recoverOperation(.init(intent: decision.command.intent, action: .query), deadline: operations.deadline) == first)
            #expect(try await count("im_v2.room_events", on: sql) == 3)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("approval rolls back every owner effect at each late failure and replays the committed decision", arguments: ["outbox", "invite", "decision"])
    func invitationApprovalIsOneTransaction(_ failure: String) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(capacityClass: failure == "invite" ? .large : .standard, on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 7, room_sequence = 11 WHERE room_id = \(bind: roomUUID)").run()
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let applicant = UUID()
            try await sql.raw("INSERT INTO im_v2.public_user_profiles (user_id, public_handle, display_name, created_at, updated_at) VALUES (\(bind: applicant), 'atomic_applicant', 'Atomic Applicant', \(bind: now), \(bind: now))").run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 3))
            // Control authorization has its own pool even when its schema is colocated.
            // Owner transactions must not wait for another connection from their own exhausted pool.
            let controlID = DatabaseID(string: "cleanup-invitation-control")
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: controlID)
            let operations = try await CleanupInvitationOperations.make(database: resources.database(.psql),
                controlDatabase: resources.database(controlID), roomID: roomID, profile: profile, now: now)
            let invite = try await operations.createLink(actor: senderID)
            let submission = try await operations.submission(actor: .init(uuid: applicant), inviteID: invite.inviteID, secret: invite.secret)
            let requestID = try await operations.requestID(submission)
            let decision = try await operations.decision(actor: senderID, requestID: requestID, revision: 7)
            func snapshot() async throws -> String {
                try #require(try await sql.raw("""
                    SELECT jsonb_build_object(
                        'room', (SELECT to_jsonb(r) FROM im_v2.rooms r WHERE room_id = \(bind: roomUUID)),
                        'admission', (SELECT to_jsonb(r) FROM im_v2.room_admission r WHERE room_id = \(bind: roomUUID)),
                        'shard', (SELECT to_jsonb(r) FROM im_v2.shard_admission_pools r WHERE room_shard_id = 'room-a'),
                        'members', (SELECT jsonb_agg(to_jsonb(m) ORDER BY user_id, joined_revision) FROM im_v2.room_memberships m),
                        'invite', (SELECT to_jsonb(i) FROM im_v2.group_invite_links i WHERE invite_id = \(bind: invite.inviteID.uuidValue!)),
                        'request', (SELECT to_jsonb(r) FROM im_v2.group_join_requests r WHERE request_id = \(bind: requestID.uuidValue!)),
                        'events', (SELECT count(*) FROM im_v2.room_events),
                        'outbox', (SELECT count(*) FROM im_v2.user_state_event_outbox),
                        'operations', (SELECT count(*) FROM im_v2.group_invitation_receipts),
                        'memberOperations', (SELECT count(*) FROM im_v2.room_membership_operations),
                        'quota', (SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY applicant_user_id, operation_id), '[]'::jsonb) FROM im_v2.group_join_quota_intents q)
                    )::text AS value
                    """).first(decoding: StringValueRow.self)).value
            }
            let before = try await snapshot()
            try await sql.raw("CREATE FUNCTION im_v2.test_fail_approval() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected approval failure'; END $$").run()
            let faultTable = failure == "outbox" ? "user_state_event_outbox" : failure == "invite" ? "group_invite_links" : "group_join_requests"
            let faultEvent = failure == "outbox" ? "INSERT" : "UPDATE"
            try await sql.raw("CREATE TRIGGER test_fail_approval AFTER \(unsafeRaw: faultEvent) ON im_v2.\(unsafeRaw: faultTable) FOR EACH ROW EXECUTE FUNCTION im_v2.test_fail_approval()").run()
            var injectedFailure = false
            do { _ = try await operations.execute(decision) } catch { injectedFailure = true }
            #expect(injectedFailure)
            #expect(try await snapshot() == before, "Late \(failure) failure must roll back membership, both admission pools, event, plan, targets, outbox, operation, usage and request")
            try await sql.raw("DROP TRIGGER test_fail_approval ON im_v2.\(unsafeRaw: faultTable)").run()
            let first = try await operations.execute(decision)
            guard case .receipt(let approved) = first, case .applied(.requestDecided(_, .approve, 8)) = approved.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            #expect(approved.resolvedAtMilliseconds == UInt64(now.timeIntervalSince1970 * 1_000))
            #expect(try await sql.raw("SELECT membership_revision = 8 AND room_sequence = 12 AS exists FROM im_v2.rooms WHERE room_id = \(bind: roomUUID)").first(decoding: ExistsRow.self)?.exists == true)
            #expect(try await sql.raw("SELECT approval_membership_revision = 7 AS exists FROM im_v2.group_join_requests WHERE request_id = \(bind: requestID.uuidValue!)").first(decoding: ExistsRow.self)?.exists == true)
            #expect(try await count("im_v2.group_invitation_receipts", on: sql) == 3)
            #expect(try await count("im_v2.room_events", on: sql) == 1)
            #expect(try await sql.raw("SELECT approved_use_count::bigint AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == 1)
            #expect(try await count("im_v2.user_state_event_outbox", on: sql) == 1)
            let committed = try await snapshot()
            try await withThrowingTaskGroup(of: V2GroupInvitationOperationRecoveryResult.self) { group in
                for _ in 0..<10 { group.addTask { try await operations.execute(decision) } }
                for try await result in group { #expect(result == first) }
            }
            #expect(try await snapshot() == committed, "Lost response replay must not debit admission or invite usage again")
            let changed = try operations.intent(actor: senderID, reference: decision.command.identity.operation,
                action: .decide(requestID: requestID, decision: .reject, expectedMembershipRevision: 7))
            #expect(try await operations.coordinator.recoverOperation(.init(intent: changed, action: .query), deadline: operations.deadline) == .fingerprintConflict)
            let wrongRequest = try operations.intent(actor: senderID, reference: decision.command.identity.operation,
                action: .decide(requestID: .init(uuid: UUID()), decision: .approve, expectedMembershipRevision: 7))
            #expect(try await operations.coordinator.recoverOperation(.init(intent: wrongRequest, action: .query), deadline: operations.deadline) == .fingerprintConflict)
            let remove = try await operations.membership(actor: senderID, target: .init(uuid: applicant), action: .remove, revision: 8)
            guard case .receipt(let removal) = try await operations.executeMembership(remove), case .changed = removal.outcome else { throw V2MembershipOperationValidationError.invalidReceipt }
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = 9 WHERE user_id = \(bind: senderUUID)").run()
            let afterLeave = try await snapshot()
            #expect(try await operations.execute(decision) == first)
            #expect(try await snapshot() == afterLeave)
            // The marker alone is insufficient: readiness checks the actual key.
            try await V2SchemaReadiness.verify(database: resources.database(.psql))
            try await sql.raw("ALTER TABLE im_v2.group_join_requests DROP CONSTRAINT group_join_requests_reviewer_decision_key").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable("im_v2.group_join_requests[decision-operation]")) {
                try await V2SchemaReadiness.verify(database: resources.database(.psql))
            }
            print("Atomic approval: failure=\(failure), rollback=complete, concurrent replay=10, leave replay=stable")
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("approval serializes the last invite slot with competing approvals and ordinary membership changes")
    func invitationApprovalSharesMembershipLockOrder() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let applicants = [UUID(), UUID()]
            for (index, applicant) in applicants.enumerated() {
                try await sql.raw("INSERT INTO im_v2.public_user_profiles (user_id, public_handle, display_name, created_at, updated_at) VALUES (\(bind: applicant), \(bind: "race_applicant_\(index)"), 'Race Applicant', \(bind: now), \(bind: now))").run()
            }
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 3))
            // Control authorization has its own pool even when its schema is colocated.
            // Owner transactions must not wait for another connection from their own exhausted pool.
            let controlID = DatabaseID(string: "cleanup-invitation-control")
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: controlID)
            let operations = try await CleanupInvitationOperations.make(database: resources.database(.psql),
                controlDatabase: resources.database(controlID), roomID: roomID, profile: profile, now: now)
            let invite = try await operations.createLink(actor: senderID, uses: 1)
            var requestIDs: [GroupJoinRequestID] = []
            for applicant in applicants {
                requestIDs.append(try await operations.requestID(operations.submission(actor: .init(uuid: applicant), inviteID: invite.inviteID, secret: invite.secret)))
            }
            let firstCommand = try await operations.decision(actor: senderID, requestID: requestIDs[0], revision: 0)
            let secondCommand = try await operations.decision(actor: senderID, requestID: requestIDs[1], revision: 0)
            let removalCommand = try await operations.membership(actor: senderID, target: .init(uuid: memberTwoUUID), action: .remove, revision: 0)
            try await sql.raw("CREATE FUNCTION im_v2.test_hold_approval() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_advisory_xact_lock(908260001::bigint); RETURN NEW; END $$").run()
            try await sql.raw("CREATE TRIGGER test_hold_approval BEFORE UPDATE ON im_v2.group_join_requests FOR EACH ROW WHEN (NEW.state = 'approved') EXECUTE FUNCTION im_v2.test_hold_approval()").run()
            let outcomes = try await resources.database(.psql).withConnection { connection in
                let control = try #require(connection as? any SQLDatabase)
                try await control.raw("SELECT pg_advisory_lock(908260001::bigint)").run()
                let first = Task { try await operations.execute(firstCommand) }
                do {
                    var firstWaiting = false
                    for _ in 0..<500 {
                        let waiting = try await control.raw("SELECT COUNT(*)::bigint AS value FROM pg_locks WHERE locktype = 'advisory' AND NOT granted AND database = (SELECT oid FROM pg_database WHERE datname = current_database())").first(decoding: CountRow.self)?.value ?? 0
                        if waiting >= 1 { firstWaiting = true; break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    #expect(firstWaiting, "The first approval must reach its final write while holding the room")
                } catch {
                    try? await control.raw("SELECT pg_advisory_unlock(908260001::bigint)").run()
                    _ = await first.result
                    throw error
                }
                let second = Task { try await operations.execute(secondCommand) }
                let removal = Task { try await operations.executeMembership(removalCommand) }
                do {
                    var allWaiting = false
                    for _ in 0..<500 {
                        let waiting = try await control.raw("SELECT COUNT(*)::bigint AS value FROM pg_locks WHERE NOT granted AND pid IN (SELECT pid FROM pg_stat_activity WHERE datname = current_database())").first(decoding: CountRow.self)?.value ?? 0
                        if waiting >= 3 { allWaiting = true; break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    #expect(allWaiting, "Approval, competing approval and removal must all reach the real lock barrier")
                    try await control.raw("SELECT pg_advisory_unlock(908260001::bigint)").run()
                    return try await (first.value, second.value, removal.value)
                } catch {
                    try? await control.raw("SELECT pg_advisory_unlock(908260001::bigint)").run()
                    _ = await first.result; _ = await second.result; _ = await removal.result
                    throw error
                }
            }
            guard case .receipt(let firstProof) = outcomes.0, case .applied(.requestDecided(_, .approve, 1)) = firstProof.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            guard case .receipt(let secondProof) = outcomes.1, case .rejected(.membershipChanged(currentRevision: 1)) = secondProof.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            guard case .receipt(let staleRemoval) = outcomes.2, case .rejected(.membershipChanged(currentRevision: 1)) = staleRemoval.outcome else { throw V2MembershipOperationValidationError.invalidReceipt }
            // Explicitly observe the new baseline; never rewrite the old frozen CAS.
            let exhausted = try await operations.decision(actor: senderID, requestID: requestIDs[1], revision: 1)
            guard case .receipt(let exhaustedProof) = try await operations.execute(exhausted), case .rejected(.memberLimitReached) = exhaustedProof.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            let remove = try await operations.membership(actor: senderID, target: .init(uuid: memberTwoUUID), action: .remove, revision: 1)
            guard case .receipt(let removed) = try await operations.executeMembership(remove), case .changed = removed.outcome else { throw V2MembershipOperationValidationError.invalidReceipt }
            #expect(try await count("im_v2.room_events", on: sql) == 2)
            #expect(try await count("im_v2.membership_operation_receipts", on: sql) == 2)
            #expect(try await sql.raw("SELECT approved_use_count::bigint AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == 1)
            try await sql.raw("UPDATE im_v2.group_invite_links SET maximum_approved_uses = 2 WHERE invite_id = \(bind: invite.inviteID.uuidValue!)").run()
            let independent = try await operations.membership(actor: senderID, target: .init(uuid: applicants[1]), action: .add, revision: 2)
            guard case .receipt(let added) = try await operations.executeMembership(independent), case .changed = added.outcome else { throw V2MembershipOperationValidationError.invalidReceipt }
            // Independent membership does not settle the invitation request or debit its usage.
            #expect(try await operations.execute(secondCommand) == outcomes.1)
            #expect(try await sql.raw("SELECT approved_use_count::bigint AS value FROM im_v2.group_invite_links").first(decoding: CountRow.self)?.value == 1)
            #expect(try await sql.raw("SELECT state = 'pending' AS exists FROM im_v2.group_join_requests WHERE request_id = \(bind: requestIDs[1].uuidValue!)").first(decoding: ExistsRow.self)?.exists == true)
            #expect(try await count("im_v2.room_events", on: sql) == 3)
            print("Atomic approval race: one slot, two approvals plus removal; independent membership does not settle usage")
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("same applicant cannot overbook the last local quota slot across different invites")
    func invitationApplicantQuotaIsAtomic() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let applicant = UUID()
            try await sql.raw("INSERT INTO im_v2.public_user_profiles (user_id, public_handle, display_name, created_at, updated_at) VALUES (\(bind: applicant), 'quota_applicant', 'Quota Applicant', \(bind: now), \(bind: now))").run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 100, retryAfterSeconds: 3))
            // Control authorization has its own pool even when its schema is colocated.
            // Owner transactions must not wait for another connection from their own exhausted pool.
            let controlID = DatabaseID(string: "cleanup-invitation-control")
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: controlID)
            let operations = try await CleanupInvitationOperations.make(database: resources.database(.psql),
                controlDatabase: resources.database(controlID), roomID: roomID, profile: profile, now: now)
            var links: [Int: (inviteID: GroupInviteID, secret: V2GroupInviteSecret)] = [:]
            for index in 1...19 {
                let link = try await operations.createLink(actor: senderID, uses: 100)
                links[index] = link
                _ = try await operations.requestID(operations.submission(actor: .init(uuid: applicant), inviteID: link.inviteID, secret: link.secret))
            }
            links[20] = try await operations.createLink(actor: senderID, uses: 100)
            let revoked = try #require(links[19])
            let revoke = try await operations.admitted(operations.intent(actor: senderID, reference: .groupInvite(.init(uuid: UUID())), action: .revoke(inviteID: revoked.inviteID, expectedMembershipRevision: 0)))
            guard case .receipt(let revokedProof) = try await operations.execute(revoke), case .applied(.inviteRevoked) = revokedProof.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            links[21] = try await operations.createLink(actor: senderID, uses: 100)
            let firstLink = try #require(links[20]), secondLink = try #require(links[21])
            let requests = try await [operations.submission(actor: .init(uuid: applicant), inviteID: firstLink.inviteID, secret: firstLink.secret, note: "quota-race"),
                                      operations.submission(actor: .init(uuid: applicant), inviteID: secondLink.inviteID, secret: secondLink.secret, note: "quota-race")]
            try await sql.raw("""
                CREATE FUNCTION im_v2.test_hold_join_insert() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF NEW.note = 'quota-race' THEN
                        PERFORM pg_advisory_xact_lock(908230001::bigint);
                    END IF;
                    RETURN NEW;
                END $$
                """).run()
            try await sql.raw("CREATE TRIGGER test_hold_join_insert BEFORE INSERT ON im_v2.group_join_requests FOR EACH ROW EXECUTE FUNCTION im_v2.test_hold_join_insert()").run()
            let outcomes = try await resources.database(.psql).withConnection { connection in
                let control = try #require(connection as? any SQLDatabase)
                try await control.raw("SELECT pg_advisory_lock(908230001::bigint)").run()
                let first = Task { try await operations.execute(requests[0]) }
                do {
                    var firstWaiting = false
                    for _ in 0..<500 {
                        let waiting = try await control.raw("SELECT COUNT(*)::bigint AS value FROM pg_locks WHERE locktype = 'advisory' AND NOT granted AND database = (SELECT oid FROM pg_database WHERE datname = current_database())").first(decoding: CountRow.self)?.value ?? 0
                        if waiting >= 1 { firstWaiting = true; break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    #expect(firstWaiting, "The admitted winner must reach its actual owner INSERT")
                    // Original-proof lookup takes the room activation lock before
                    // reserving control quota. A second full operation cannot finish
                    // while the winner holds that lock at its owner INSERT.
                    let second = Task { try await operations.execute(requests[1]) }
                    do {
                        try await control.raw("SELECT pg_advisory_unlock(908230001::bigint)").run()
                    } catch {
                        second.cancel()
                        try? await control.raw("SELECT pg_advisory_unlock(908230001::bigint)").run()
                        _ = await second.result
                        throw error
                    }
                    let firstResult = await first.result
                    let secondResult = await second.result
                    return try [firstResult.get(), secondResult.get()]
                } catch {
                    try? await control.raw("SELECT pg_advisory_unlock(908230001::bigint)").run()
                    _ = await first.result
                    throw error
                }
            }
            let pendingCount = try await sql.raw("SELECT COUNT(*)::bigint AS value FROM im_v2.group_join_requests WHERE applicant_user_id = \(bind: applicant) AND state = 'pending'").first(decoding: CountRow.self)?.value
            print("Applicant quota: committed outstanding=\(pendingCount ?? -1)")
            #expect(pendingCount == 20)
            let winnerIndices = outcomes.indices.filter {
                if case .receipt(let proof) = outcomes[$0], case .applied(.requestSubmitted) = proof.outcome { return true }; return false
            }
            #expect(winnerIndices.count == 1)
            #expect(outcomes.filter { if case .deferred(let hint) = $0 { return hint.reason == .rateLimited }; return false }.count == 1)
            let winnerIndex = try #require(winnerIndices.first)
            let retry = requests[winnerIndex]
            let original = outcomes[winnerIndex]
            guard case .receipt(let winnerProof) = original, case .applied(.requestSubmitted(let winnerID, _)) = winnerProof.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            try await withThrowingTaskGroup(of: V2GroupInvitationOperationRecoveryResult.self) { group in
                for _ in 0..<10 { group.addTask { try await operations.execute(retry) } }
                for try await outcome in group { #expect(outcome == original) }
            }
            let winnerLink = winnerIndex == 0 ? firstLink : secondLink
            let equivalent = try await operations.submission(actor: .init(uuid: applicant), inviteID: winnerLink.inviteID, secret: winnerLink.secret)
            guard case .receipt(let equivalentProof) = try await operations.execute(equivalent), case .alreadySatisfied(.requestSubmitted(let existingID, _)) = equivalentProof.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            #expect(existingID == winnerID)
            let changed = try operations.intent(actor: .init(uuid: applicant), reference: retry.command.identity.operation,
                action: .submit(inviteID: winnerLink.inviteID, tokenDigest: operations.issuer.digest(winnerLink.secret), note: "changed"))
            #expect(try await operations.coordinator.recoverOperation(.init(intent: changed, action: .query), deadline: operations.deadline) == .fingerprintConflict)
            let reject = try await operations.decision(actor: senderID, requestID: winnerID, revision: 0, action: .reject)
            guard case .receipt(let rejected) = try await operations.execute(reject), case .applied(.requestDecided(_, .reject, nil)) = rejected.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            guard case .receipt(let loser) = try await operations.execute(requests[1 - winnerIndex]), case .applied(.requestSubmitted) = loser.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            #expect(try await sql.raw("SELECT COUNT(*)::bigint AS value FROM im_v2.group_join_requests WHERE applicant_user_id = \(bind: applicant) AND state = 'pending'").first(decoding: CountRow.self)?.value == 20)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("pending request cursors survive review and deletion across PostgreSQL timestamp ranges",
          arguments: ["review", "delete"], ["2026-09-05T01:02:03.123456Z", "10000-01-01 00:00:00.123456+00", "4000-01-01 00:00:00.123456+00 BC", "1582-10-10 00:00:00.123456+00", "200000-01-01 00:00:00.123456+00"])
    func invitationCursorSurvivesAnchorChange(_ change: String, timestamp: String) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let store = PostgresV2GroupInvitationStore(database: resources.database(.psql))
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 100, retryAfterSeconds: 3))
            // Control authorization has its own pool even when its schema is colocated.
            // Owner transactions must not wait for another connection from their own exhausted pool.
            let controlID = DatabaseID(string: "cleanup-invitation-control")
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: controlID)
            let operations = try await CleanupInvitationOperations.make(database: resources.database(.psql),
                controlDatabase: resources.database(controlID), roomID: roomID, profile: profile, now: now)
            let invite = try await operations.createLink(actor: senderID, uses: 100)
            let ids = (801...803).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
            for (index, applicant) in [senderUUID, memberTwoUUID, memberThreeUUID].enumerated() {
                try await sql.raw("""
                    INSERT INTO im_v2.group_join_requests
                        (request_id, invite_id, room_id, applicant_user_id, submission_operation_id, created_at, updated_at)
                    VALUES (\(bind: ids[index]), \(bind: invite.inviteID.uuidValue!), \(bind: roomUUID), \(bind: applicant), \(bind: UUID()), \(bind: timestamp)::timestamptz + \(bind: index == 2 ? 1 : 0) * INTERVAL '1 microsecond', \(bind: timestamp)::timestamptz)
                    """).run()
            }
            let first = try await store.pendingRequests(roomID: roomID, reviewerUserID: senderID, cursor: nil, pageSize: 1, now: now)
            #expect(first.requests.map(\.requestID.uuidValue) == [ids[0]])
            let cursor = try #require(first.nextCursor)
            if change == "delete" {
                try await sql.raw("DELETE FROM im_v2.group_join_requests WHERE request_id = \(bind: ids[0])").run()
            } else {
                try await sql.raw("UPDATE im_v2.group_join_requests SET state = 'rejected', decision_operation_id = \(bind: UUID()), decided_by_user_id = \(bind: senderUUID), decided_at = \(bind: now) WHERE request_id = \(bind: ids[0])").run()
            }
            let second = try await store.pendingRequests(roomID: roomID, reviewerUserID: senderID, cursor: cursor, pageSize: 1, now: now)
            #expect(second.requests.map(\.requestID.uuidValue) == [ids[1]])
            let secondCursor = try #require(second.nextCursor)
            let third = try await store.pendingRequests(roomID: roomID, reviewerUserID: senderID, cursor: secondCursor, pageSize: 1, now: now)
            #expect(third.requests.map(\.requestID.uuidValue) == [ids[2]])
            #expect(third.nextCursor == nil)
            let cursorData = try #require(Data(base64Encoded: cursor))
            let originalPayload = try #require(JSONSerialization.jsonObject(with: cursorData) as? [String: Any])
            if timestamp == "2026-09-05T01:02:03.123456Z" {
                // Retired text cursors are rejected; only the precise current shape is accepted.
                var legacy = originalPayload
                legacy["version"] = 1
                legacy["createdAt"] = timestamp
                legacy.removeValue(forKey: "createdAtMicroseconds")
                let legacyCursor = try JSONSerialization.data(withJSONObject: legacy).base64EncodedString()
                await #expect(throws: V2GroupInvitationServiceError.invalidRequest) {
                    try await store.pendingRequests(roomID: roomID, reviewerUserID: senderID, cursor: legacyCursor, pageSize: 1, now: now)
                }
            }
            let timeField = "createdAtMicroseconds"
            for field in ["roomID", "filter", "version", timeField] {
                var payload = originalPayload
                if field == "version" { payload[field] = 99 } else { payload[field] = field == "roomID" ? UUID().uuidString : "invalid" }
                let invalid = try JSONSerialization.data(withJSONObject: payload).base64EncodedString()
                await #expect(throws: V2GroupInvitationServiceError.invalidRequest) {
                    try await store.pendingRequests(roomID: roomID, reviewerUserID: senderID, cursor: invalid, pageSize: 1, now: now)
                }
            }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("twenty exhausted invitation links no longer occupy creation quota")
    func exhaustedInvitationsReleaseCreationQuota() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role = 'owner' WHERE user_id = \(bind: senderUUID)").run()
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let store = PostgresV2GroupInvitationStore(database: resources.database(.psql))
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 100, retryAfterSeconds: 3))
            // Control authorization has its own pool even when its schema is colocated.
            // Owner transactions must not wait for another connection from their own exhausted pool.
            let controlID = DatabaseID(string: "cleanup-invitation-control")
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: controlID)
            let operations = try await CleanupInvitationOperations.make(database: resources.database(.psql),
                controlDatabase: resources.database(controlID), roomID: roomID, profile: profile, now: now)
            for _ in 1...20 { _ = try await operations.createLink(actor: senderID, uses: 1) }
            let pending = try await operations.admitted(operations.intent(actor: senderID, reference: .groupInvite(.init(uuid: UUID())), action: .create(lifetimeSeconds: 3_600, maximumApprovedUses: 1, expectedMembershipRevision: 0)))
            guard case .deferred(let floor) = try await operations.execute(pending) else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            #expect(floor.reason == .rateLimited)
            try await sql.raw("UPDATE im_v2.group_invite_links SET approved_use_count = maximum_approved_uses WHERE room_id = \(bind: roomUUID)").run()
            #expect(try await store.activeInvites(roomID: roomID, actorUserID: senderID, now: now).isEmpty)
            guard case .receipt(let proof) = try await operations.execute(pending), case .applied(.inviteCreated(let createdID, _, _, _)) = proof.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            let active = try await store.activeInvites(roomID: roomID, actorUserID: senderID, now: now)
            #expect(active.map(\.inviteID) == [createdID])
            #expect(try await count("im_v2.group_invite_links", on: sql) == 21)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("send completion retains original fingerprint and metadata after content mutation/deletion",
          arguments: ["standard", "hybrid", "hybrid-mention"])
    func sendCompletionIsIndependentOfMutableContent(_ mode: String) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            let hybrid = mode != "standard"
            try await seedRoom(capacityClass: hybrid ? .large : .standard, on: sql)
            let command = try V2SendMessageCommand(
                roomID: roomID, senderUserID: senderID, clientMessageID: .init(uuid: UUID()),
                text: "original accepted content",
                mentions: mode == "hybrid-mention" ? [.user(.init(uuid: memberTwoUUID))] : [],
                limits: .init(maxUTF8Bytes: 128)
            )
            let ids = V2AcceptanceIdentifiers(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID()))
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10,

                retryAfterSeconds: 1
            ))
            let now = Date(timeIntervalSince1970: 1_750_000_001)
            let store = PostgresV2RoomWriteStore(database: resources.database(.psql))
            let outcome = try await store.accept(command: command, capacityProfile: profile, identifiers: ids, now: now)
            guard case .accepted(let accepted) = outcome else { Issue.record("Expected acceptance"); throw V2RoomWriteStoreError.corruptPersistenceState }
            try await assertSendCompletion(command: command, accepted: accepted, eventID: ids.eventID, sql: sql)
            #expect(try await store.accept(
                command: command, capacityProfile: .init(id: "changed-runtime-profile", limits: profile.limits),
                identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())),
                now: now.addingTimeInterval(60)
            ) == .idempotent(accepted.receipt))
            await #expect(throws: (any Error).self) {
                try await sql.raw("UPDATE im_v2.message_send_completions SET room_sequence = room_sequence + 1").run()
            }
            try await sql.raw("""
                UPDATE im_v2.rooms SET membership_revision = membership_revision + 1
                WHERE room_id = \(bind: roomUUID)
                """).run()
            try await sql.raw("""
                UPDATE im_v2.messages SET text_body = 'edited', content_revision = 2
                WHERE message_id = \(bind: accepted.messageID.uuidValue!)
                """).run()
            try await assertSendCompletion(command: command, accepted: accepted, eventID: ids.eventID, sql: sql)
            #expect(try await store.accept(
                command: command, capacityProfile: .init(id: "changed-runtime-profile", limits: profile.limits),
                identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())),
                now: now.addingTimeInterval(60)
            ) == .idempotent(accepted.receipt))
            try await sql.raw("""
                UPDATE im_v2.messages SET text_body = '', rich_entities = '[]'::jsonb,
                    content_revision = 3, withdrawn_at = \(bind: now), withdrawn_by_user_id = \(bind: senderUUID)
                WHERE message_id = \(bind: accepted.messageID.uuidValue!)
                """).run()
            #expect(try await store.accept(command: command, capacityProfile: profile, identifiers: ids, now: now.addingTimeInterval(120)) == .idempotent(accepted.receipt))
            // Follow the existing FK order when simulating content retention;
            // the completion must survive removal of every content-dependent row.
            try await sql.raw("DELETE FROM im_v2.message_content_versions WHERE message_id = \(bind: accepted.messageID.uuidValue!)").run()
            try await sql.raw("DELETE FROM im_v2.message_mentions WHERE message_id = \(bind: accepted.messageID.uuidValue!)").run()
            try await sql.raw("""
                DELETE FROM im_v2.messages WHERE message_id = \(bind: accepted.messageID.uuidValue!)
                """).run()
            try await assertSendCompletion(command: command, accepted: accepted, eventID: ids.eventID, sql: sql)
            #expect(try await store.accept(
                command: command, capacityProfile: .init(id: "changed-runtime-profile", limits: profile.limits),
                identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())),
                now: now.addingTimeInterval(60)
            ) == .idempotent(accepted.receipt))
            // The 35-day policy is a minimum retention, not an admission fence.
            // A delayed send has no server-verifiable creation epoch, so current
            // housekeeping must preserve its receipt even beyond that minimum.
            let afterRetention = now.addingTimeInterval(V2IdempotencyPolicy.minimumServerRetention + 86_400)
            _ = try await V2ControlPlaneHousekeepingWorker(
                store: PostgresV2ControlPlaneHousekeepingStore(database: resources.database(.psql)),
                now: { afterRetention }
            ).runOnce(limit: 1_024)
            try await assertSendCompletion(command: command, accepted: accepted, eventID: ids.eventID, sql: sql)
            #expect(try await store.accept(command: command, capacityProfile: profile, identifiers: ids,
                now: afterRetention) == .idempotent(accepted.receipt))
            for field in 0..<6 {
                var text = command.text
                var media = command.media
                var mentions = command.mentions
                var entities = command.entities
                var reply = command.replyTo
                var forward = command.forwardedFrom
                switch field {
                case 0: text = "different content"
                case 1: media = [.init(mediaID: .init(uuid: UUID()))]
                case 2: mentions = command.mentions.isEmpty ? [.user(.init(uuid: memberTwoUUID))] : []
                case 3: entities = [try .init(offsetUTF16: 0, lengthUTF16: 1, kind: .bold)]
                case 4: reply = .init(messageID: .init(uuid: UUID()))
                default: forward = .init(messageID: .init(uuid: UUID()), senderUserID: .init(uuid: memberTwoUUID), sourceRevision: try .init(1))
                }
                let changed = try V2SendMessageCommand(roomID: roomID, senderUserID: senderID,
                    clientMessageID: command.clientMessageID, text: text, media: media,
                    mentions: mentions, entities: entities, replyTo: reply,
                    forwardedFrom: forward, limits: .init(maxUTF8Bytes: 128))
                #expect(try await store.accept(command: changed, capacityProfile: profile, identifiers: ids, now: afterRetention) == .idempotencyConflict)
            }
            #expect(try await count("im_v2.messages", on: sql) == 0)
            #expect(try await count("im_v2.message_send_completions", on: sql) == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("startup rejects incomplete completion and forward revision contracts", arguments: ["table", "schema", "forward-column", "forward-room-column", "forward-constraint", "forward-trigger", "content-index", "content-index-shape", "export-epoch", "export-completion-column", "export-compaction-column", "export-compaction-check", "export-compaction-index", "export-compaction-trigger", "export-payload", "export-trigger", "export-index", "inbox-column", "inbox-owner-shard", "inbox-owner-epoch", "inbox-owner-constraint", "inbox-compaction-column", "inbox-compaction-constraint", "inbox-compaction-index", "inbox-trigger", "inbox-constraint", "inbox-media-index", "inbox-source-fk", "media-import-column", "media-import-trigger", "media-import-shape", "receipt-column", "receipt-trigger", "receipt-shape", "receipt-fk", "delivery-column", "delivery-trigger", "delivery-shape", "delivery-index", "delivery-fk", "replay-column", "replay-trigger", "replay-shape", "replay-weak-shape", "replay-pk", "media-scope-column", "media-scope-shape", "media-scope-trigger", "media-scope-function", "media-scope-fk"])
    func sendCompletionSchemaReadinessRejectsIncompleteContract(scenario: String) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await V2SchemaReadiness.verify(database: resources.database(.psql))
            try await assertSQLSchemaGate(true, on: sql)
            if scenario == "schema" {
                try await sql.raw("ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check").run()
                try await sql.raw("ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-5'").run()
                try await sql.raw("UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-5'").run()
                try await sql.raw("ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-5')").run()
            } else if scenario == "content-index" || scenario == "content-index-shape" {
                try await sql.raw("DROP INDEX im_v2.room_events_message_edit_revision_idx").run()
                if scenario == "content-index-shape" {
                    try await sql.raw("CREATE UNIQUE INDEX room_events_message_edit_revision_idx ON im_v2.room_events (room_id, room_sequence, event_type)").run()
                }
            } else if scenario == "media-scope-column" {
                try await sql.raw("ALTER TABLE im_v2.media_download_grants DROP COLUMN owner_epoch CASCADE").run()
            } else if scenario == "media-scope-shape" {
                try await sql.raw("ALTER TABLE im_v2.media_download_grants DROP CONSTRAINT media_download_grants_scope_check, ADD CONSTRAINT media_download_grants_scope_check CHECK (true)").run()
            } else if scenario == "media-scope-trigger" {
                try await sql.raw("ALTER TABLE im_v2.media_download_grants DISABLE TRIGGER media_download_grants_identity").run()
            } else if scenario == "media-scope-function" {
                try await sql.raw("CREATE OR REPLACE FUNCTION im_v2.reject_media_download_grant_identity_mutation() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END; $$").run()
            } else if scenario == "media-scope-fk" {
                try await sql.raw("ALTER TABLE im_v2.media_download_grants ADD CONSTRAINT renamed_device_fk FOREIGN KEY (user_id, device_id) REFERENCES im_v2.auth_devices(user_id, device_id)").run()
            } else if scenario == "replay-column" {
                try await sql.raw("ALTER TABLE im_v2.forward_work_replay_audit ALTER COLUMN shard_id DROP NOT NULL").run()
            } else if scenario == "replay-trigger" {
                try await sql.raw("ALTER TABLE im_v2.forward_work_replay_audit DISABLE TRIGGER forward_work_replay_audit_immutable").run()
            } else if scenario == "replay-shape" || scenario == "replay-weak-shape" {
                try await sql.raw("ALTER TABLE im_v2.forward_work_replay_audit DROP CONSTRAINT forward_work_replay_audit_target_check").run()
                if scenario == "replay-weak-shape" {
                    try await sql.raw("ALTER TABLE im_v2.forward_work_replay_audit ADD CONSTRAINT forward_work_replay_audit_target_check CHECK (true)").run()
                }
            } else if scenario == "replay-pk" {
                try await sql.raw("ALTER TABLE im_v2.forward_work_replay_audit DROP CONSTRAINT forward_work_replay_audit_pkey").run()
            } else if scenario == "delivery-column" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_delivery_jobs ALTER COLUMN retry_count DROP NOT NULL").run()
            } else if scenario == "delivery-trigger" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_delivery_jobs DISABLE TRIGGER message_forward_delivery_jobs_immutable").run()
            } else if scenario == "delivery-shape" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_delivery_jobs DROP CONSTRAINT message_forward_delivery_jobs_shape_check").run()
            } else if scenario == "delivery-fk" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_delivery_jobs DROP CONSTRAINT message_forward_delivery_jobs_export_id_fkey").run()
            } else if scenario == "delivery-index" {
                try await sql.raw("DROP INDEX im_v2.message_forward_delivery_jobs_ready_idx").run()
            } else if scenario == "receipt-column" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_export_receipts ALTER COLUMN payload_digest DROP NOT NULL").run()
            } else if scenario == "receipt-trigger" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_export_receipts DISABLE TRIGGER message_forward_export_receipts_immutable").run()
            } else if scenario == "receipt-shape" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_export_receipts DROP CONSTRAINT message_forward_export_receipts_shape_check").run()
            } else if scenario == "receipt-fk" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_export_receipts DROP CONSTRAINT message_forward_export_receipts_export_id_fkey").run()
            } else if scenario == "media-import-column" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_media_imports DROP COLUMN copied_digest").run()
            } else if scenario == "media-import-trigger" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_media_imports DISABLE TRIGGER message_forward_media_imports_immutable").run()
            } else if scenario == "media-import-shape" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_media_imports DROP CONSTRAINT message_forward_media_imports_shape_check").run()
            } else if scenario == "inbox-source-fk" {
                try await sql.raw("ALTER TABLE im_v2.messages ADD CONSTRAINT test_legacy_attribution FOREIGN KEY (forwarded_from_message_id) REFERENCES im_v2.messages(message_id)").run()
            } else if scenario == "inbox-owner-shard" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_inbox ALTER COLUMN target_shard_id DROP NOT NULL").run()
            } else if scenario == "inbox-owner-epoch" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_inbox DROP COLUMN target_epoch CASCADE").run()
            } else if scenario == "inbox-owner-constraint" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_inbox DROP CONSTRAINT message_forward_inbox_owner_check").run()
            } else if scenario == "inbox-compaction-column" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_inbox DROP COLUMN payload_compacted_at CASCADE").run()
            } else if scenario == "inbox-compaction-constraint" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_inbox DROP CONSTRAINT message_forward_inbox_compaction_check").run()
            } else if scenario == "inbox-compaction-index" {
                try await sql.raw("DROP INDEX im_v2.message_forward_inbox_compaction_idx").run()
            } else if scenario == "inbox-column" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_inbox DROP COLUMN payload_digest").run()
            } else if scenario == "inbox-trigger" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_inbox DISABLE TRIGGER message_forward_inbox_immutable").run()
            } else if scenario == "inbox-constraint" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_inbox_media DROP CONSTRAINT message_forward_inbox_media_ready_check").run()
            } else if scenario == "inbox-media-index" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_inbox_media DROP CONSTRAINT message_forward_inbox_media_target_media_id_key").run()
            } else if scenario == "export-epoch" {
                try await sql.raw("ALTER TABLE im_v2.rooms DROP COLUMN owner_epoch").run()
            } else if scenario == "export-completion-column" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_exports DROP COLUMN delivery_completed_at CASCADE").run()
            } else if scenario == "export-compaction-column" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_exports DROP COLUMN payload_compacted_at CASCADE").run()
            } else if scenario == "export-compaction-check" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_exports DROP CONSTRAINT message_forward_exports_compaction_check").run()
            } else if scenario == "export-compaction-index" {
                try await sql.raw("DROP INDEX im_v2.message_forward_exports_compaction_idx").run()
            } else if scenario == "export-compaction-trigger" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_delivery_jobs DISABLE TRIGGER message_forward_delivery_compaction_ready").run()
            } else if scenario == "export-payload" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_exports DROP COLUMN payload_digest").run()
            } else if scenario == "export-trigger" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_exports DISABLE TRIGGER message_forward_exports_immutable").run()
            } else if scenario == "export-index" {
                try await sql.raw("DROP INDEX im_v2.message_forward_exports_media_idx").run()
                try await sql.raw("CREATE INDEX message_forward_exports_media_idx ON im_v2.message_forward_exports (created_at)").run()
            } else if scenario == "forward-column" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_operations DROP COLUMN source_content_revision").run()
            } else if scenario == "forward-room-column" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_operations DROP COLUMN source_room_id").run()
            } else if scenario == "forward-constraint" {
                try await sql.raw("ALTER TABLE im_v2.message_send_completions DROP CONSTRAINT message_send_completions_fingerprint_version_check, ADD CONSTRAINT message_send_completions_fingerprint_version_check CHECK (fingerprint_version = 1)").run()
            } else if scenario == "forward-trigger" {
                try await sql.raw("ALTER TABLE im_v2.message_forward_operations DISABLE TRIGGER message_forward_operations_identity_immutable").run()
            } else {
                try await sql.raw("DROP TABLE im_v2.message_send_completions").run()
            }
            await #expect(throws: V2SchemaReadinessError.self) {
                try await V2SchemaReadiness.verify(database: resources.database(.psql))
            }
            try await assertSQLSchemaGate(false, on: sql)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("room routing requires the canonical directory even when the physical room exists")
    func roomDirectoryIsRequired() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let router = V2PostgresRoomShardRouter(database: database)
            let route = try await router.route(for: roomID)
            #expect(route.shardID == "room-a" && route.epoch == 0)
            try await sql.raw("DELETE FROM im_v2.room_owner_routes WHERE room_id = \(bind: roomUUID)").run()
            #expect(try await count("im_v2.rooms", on: sql) > 0)
            await #expect(throws: V2RoomShardRouteError.roomNotFound) { _ = try await router.route(for: roomID) }
            await #expect(throws: V2RoomShardRouteError.roomNotFound) { _ = try await router.routes(for: [roomID]) }
        }
    }
}

private actor V2IntegrationAsyncBarrier {
    private let parties: Int
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(parties: Int) {
        precondition(parties > 0)
        self.parties = parties
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            guard continuations.count == parties else { return }
            let ready = continuations
            continuations.removeAll(keepingCapacity: false)
            for continuation in ready { continuation.resume() }
        }
    }
}

/// Uses the production control coordinator and fenced owner store; the fixture
/// only constructs frozen inputs and checks the proof before extracting IDs.
private struct CleanupInvitationOperations: Sendable {
    let database: any Database
    let controlDatabase: any Database
    let token: V2RoomActivationToken
    let coordinator: V2ActorInvitationCoordinator
    let issuer: V2GroupInviteSecretIssuer
    let profile: V2CapacityProfile
    let now: Date
    let roomID: RoomID

    static func make(database: any Database, controlDatabase: any Database, roomID: RoomID, profile: V2CapacityProfile, now: Date) async throws -> Self {
        let leases = PostgresV2RoomActivationStore(database: database)
        guard case .acquired(let grant) = try await leases.acquire(roomID: roomID,
            owner: .init(shardID: "room-a", epoch: 0),
            host: .init(hostID: .init("cleanup-invitation-fixture"), incarnationID: UUID()),
            duration: .init(30_000)) else { throw V2RoomActivationLeaseError.activationChanged }
        let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 8, count: 32))
        let identities = PostgresV2GroupInvitationIdentityReader(database: controlDatabase)
        let executor = try V2RoomInvitationDomainExecutor(database: database, token: grant.token,
            identities: identities, capacityProfile: profile, now: { now })
        @Sendable func owner(_ intent: V2GroupInvitationOperationIntent) throws -> PostgresV2GroupInvitationOperationStore {
            let invite: GroupInviteID?
            switch intent.action { case .submit(let id, _, _), .revoke(let id, _): invite = id; default: invite = nil }
            return try .init(database: database, activationToken: grant.token, identities: identities,
                issuer: issuer, policy: .standard, capacity: profile, inviteID: invite)
        }
        let reads = try PostgresV2GroupInvitationOperationStore(database: database, activationToken: grant.token,
            identities: identities, issuer: issuer, policy: .standard, capacity: profile)
        let operations = V2GroupInvitationOperationRoomPort(baseline: { query, _ in
            try await reads.baseline(roomID: query.roomID, actorUserID: query.actorUserID)
        }, admit: { intent, _ in try await owner(intent).admit(intent, now: now) },
           submit: { request, _ in try await owner(request.command.intent).submit(request, now: now) },
           recover: { request, _ in try await owner(request.intent).recover(request, now: now) })
        return .init(database: database, controlDatabase: controlDatabase, token: grant.token,
            coordinator: .init(controlDatabase: controlDatabase,
                room: .init(query: { query, _ in try await executor.execute(query) }),
                operations: operations, secretIssuer: issuer, now: { now }),
            issuer: issuer, profile: profile, now: now, roomID: roomID)
    }
    var deadline: ContinuousClock.Instant { ContinuousClock.now.advanced(by: .seconds(25)) }
    func intent(actor: UserID, reference: V2OperationReference, action: V2GroupInvitationOperationAction) throws -> V2GroupInvitationOperationIntent {
        try .init(identity: .init(accountID: actor, scope: .room(roomID), operation: reference), action: action,
            confirmedUntilMilliseconds: UInt64(now.timeIntervalSince1970 * 1_000) + 120_000)
    }
    func admitted(_ intent: V2GroupInvitationOperationIntent, secret: V2GroupInviteSecret? = nil) async throws -> V2GroupInvitationSubmission {
        let authorization = secret.map(V2GroupInvitationSecretAuthorization.init(secret:))
        guard case .admitted(let admission) = try await coordinator.admitOperation(.init(intent: intent, secretAuthorization: authorization), deadline: deadline) else {
            throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
        return try .init(command: .init(intent: intent, admission: admission), secretAuthorization: authorization)
    }
    func execute(_ submission: V2GroupInvitationSubmission) async throws -> V2GroupInvitationOperationRecoveryResult {
        let result = try await coordinator.submitOperation(submission, deadline: deadline)
        if case .receipt(let proof) = result { guard proof.validates(intent: submission.command.intent) else { throw V2GroupInviteDirectoryError.ownerResultMismatch } }
        return result
    }
    func createLink(actor: UserID, uses: Int = 2) async throws -> (inviteID: GroupInviteID, secret: V2GroupInviteSecret) {
        let baseline = try await coordinator.operationBaseline(roomID: roomID, actorUserID: actor, deadline: deadline)
        let value = try intent(actor: actor, reference: .groupInvite(.init(uuid: UUID())),
            action: .create(lifetimeSeconds: 3_600, maximumApprovedUses: uses, expectedMembershipRevision: baseline.membershipRevision))
        guard case .receipt(let proof) = try await execute(admitted(value)),
            case .applied(.inviteCreated(let id, _, _, _)) = proof.outcome else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
        return (id, try issuer.secret(actorUserID: actor, operationID: .init(value.identity.operation.rawOperationID)))
    }
    func submission(actor: UserID, inviteID: GroupInviteID, secret: V2GroupInviteSecret, note: String? = nil,
                    operation: GroupJoinRequestOperationID = .init(uuid: UUID())) async throws -> V2GroupInvitationSubmission {
        try await admitted(intent(actor: actor, reference: .groupJoinRequest(operation),
            action: .submit(inviteID: inviteID, tokenDigest: issuer.digest(secret), note: note)), secret: secret)
    }
    func requestID(_ submission: V2GroupInvitationSubmission) async throws -> GroupJoinRequestID {
        guard case .receipt(let proof) = try await execute(submission) else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
        switch proof.outcome {
        case .applied(.requestSubmitted(let id, _)), .alreadySatisfied(.requestSubmitted(let id, _)): return id
        default: throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
    }
    func decision(actor: UserID, requestID: GroupJoinRequestID, revision: UInt64,
                  operation: GroupJoinDecisionOperationID = .init(uuid: UUID()), action: V2GroupJoinDecision = .approve) async throws -> V2GroupInvitationSubmission {
        try await admitted(intent(actor: actor, reference: .groupJoinDecision(operation),
            action: .decide(requestID: requestID, decision: action, expectedMembershipRevision: revision)))
    }
    func membership(actor: UserID, target: UserID, action: V2RoomMembershipAction, revision: UInt64,
                    operation: MembershipOperationID = .init(uuid: UUID())) async throws -> V2MembershipOperationCommand {
        let store = PostgresV2MembershipOperationStore(database: database, clock: { now })
        let snapshot = try await V2PostgresMembershipIdentitySnapshotValidator(database: controlDatabase).snapshot(actorUserID: actor, targetUserID: target)
        let intent = try V2MembershipIntent(roomID: roomID, actorUserID: actor, operationID: operation, targetUserID: target,
            action: action, expectedMembershipRevision: revision, confirmedUntilMilliseconds: UInt64(now.timeIntervalSince1970 * 1_000) + 120_000)
        guard case .admitted(let admission) = try await store.admit(intent, identitySnapshot: snapshot, token: token) else { throw V2MembershipOperationValidationError.invalidAdmission }
        return try .init(intent: intent, admission: admission)
    }
    func executeMembership(_ command: V2MembershipOperationCommand) async throws -> V2MembershipRecoveryResult {
        let snapshot = try await V2PostgresMembershipIdentitySnapshotValidator(database: controlDatabase).snapshot(actorUserID: command.intent.actorUserID, targetUserID: command.intent.targetUserID)
        let result = try await PostgresV2MembershipOperationStore(database: database, clock: { now }).submit(command, token: token,
            capacityProfile: profile, eventID: .init(uuid: UUID()), identitySnapshot: snapshot)
        if case .receipt(let proof) = result { guard proof.validates(command: command) else { throw V2MembershipOperationValidationError.invalidReceipt } }
        return result
    }
}
