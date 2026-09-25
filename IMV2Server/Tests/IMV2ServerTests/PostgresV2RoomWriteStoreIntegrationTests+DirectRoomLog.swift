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
import SQLKit
import Synchronization
import Testing
import Vapor
import VaporTesting


extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("password fallback failure limits persist across account-service instances")
    func persistsPasswordLoginFailureLimit() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else {
            return
        }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2PasswordLoginRateLimitError.unavailable
            }
            let schemaExists = try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self)
            guard schemaExists?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let admissionPolicy = try V2PasswordLoginRateLimitPolicy(maximumFailures: 3, window: 60, lockout: 60)
            let admitted = try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<20 {
                    group.addTask {
                        let replica = V2PostgresPasswordLoginAttemptLimiter(database: resources.database(.psql), policy: admissionPolicy)
                        return try await replica.consumeAttempt(accountHandle: "concurrent-budget") == nil
                    }
                }
                var count = 0
                for try await allowed in group { if allowed { count += 1 } }
                return count
            }
            #expect(admitted == 3)

            let policy = try V2PasswordLoginRateLimitPolicy(maximumFailures: 2, window: 60, lockout: 60)
            let firstInstance = V2PostgresPasswordLoginAttemptLimiter(database: resources.database(.psql), policy: policy)
            let secondInstance = V2PostgresPasswordLoginAttemptLimiter(database: resources.database(.psql), policy: policy)
            let userID = try UserID("00000000-0000-0000-0000-000000000901")
            let deviceID = try DeviceID("00000000-0000-0000-0000-000000000902")
            #expect(try await firstInstance.blockedRetryAfterSeconds(accountHandle: "limit-test") == nil)
            try await firstInstance.recordRejectedAttempt(accountHandle: "limit-test", userID: userID, deviceID: deviceID)
            #expect(try await secondInstance.blockedRetryAfterSeconds(accountHandle: "limit-test") == nil)
            try await secondInstance.recordRejectedAttempt(accountHandle: "limit-test", userID: userID, deviceID: deviceID)
            let retryAfter = try #require(try await firstInstance.blockedRetryAfterSeconds(accountHandle: "limit-test"))
            #expect((1 ... 60).contains(retryAfter))
            try await secondInstance.recordSuccessfulAttempt(accountHandle: "limit-test", userID: userID, deviceID: deviceID)
            #expect(try await firstInstance.blockedRetryAfterSeconds(accountHandle: "limit-test") == nil)
            try await firstInstance.recordRejectedAttempt(accountHandle: "unknown-audit", userID: nil, deviceID: deviceID)

            let audits = try await sql.raw("""
                SELECT outcome, user_id, device_id, occurred_at
                FROM im_v2.account_password_authentication_audit
                ORDER BY occurred_at, event_id
                """).all(decoding: PasswordAuthenticationAuditRow.self)
            #expect(audits.map(\.outcome) == ["assertion_rejected", "assertion_rejected", "assertion_succeeded", "assertion_rejected"])
            #expect(audits.dropLast().allSatisfy { $0.userID == UUID(uuidString: userID.rawValue) && $0.deviceID == UUID(uuidString: deviceID.rawValue) })
            #expect(audits.last?.userID == nil)
            #expect(audits.last?.deviceID == UUID(uuidString: deviceID.rawValue))

            // Hold the canonical handle lock, queue a rejection first, then a
            // success. Without the same advisory lock on the success path,
            // DELETE observes an empty table and the later rejected attempt
            // leaves a stale failure window after a successful login.
            let raceHandle = "success-rejection-race"
            let gate = PostgreSQLTransactionGate()
            let blocker = Task {
                try await resources.database(.psql).transaction { transaction in
                    guard let transactionSQL = transaction as? any SQLDatabase else {
                        throw V2PasswordLoginRateLimitError.unavailable
                    }
                    let lockKey = "v2-password-login-rate:" + raceHandle
                    try await transactionSQL.raw(
                        "SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))"
                    ).run()
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()
            var rejected: Task<Void, Error>?
            var succeeded: Task<Void, Error>?
            do {
                rejected = Task {
                    try await firstInstance.recordRejectedAttempt(
                        accountHandle: raceHandle,
                        userID: userID,
                        deviceID: deviceID
                    )
                }
                try await waitForAdvisoryWaiters(1, on: sql)
                succeeded = Task {
                    try await secondInstance.recordSuccessfulAttempt(
                        accountHandle: raceHandle,
                        userID: userID,
                        deviceID: deviceID
                    )
                }
                try await waitForAdvisoryWaiters(2, on: sql)
            } catch {
                rejected?.cancel()
                succeeded?.cancel()
                await gate.releaseTransaction()
                _ = try? await blocker.value
                _ = try? await rejected?.value
                _ = try? await succeeded?.value
                throw error
            }
            await gate.releaseTransaction()
            try await blocker.value
            try await rejected?.value
            try await succeeded?.value
            #expect(try await firstInstance.blockedRetryAfterSeconds(accountHandle: raceHandle) == nil)
            #expect(try await sql.raw("SELECT 1 FROM im_v2.account_password_login_rate_limits WHERE account_handle = \(bind: raceHandle)").first() == nil)

            // A persisted counter may already be at the SQL ceiling when a
            // lockout expires before its window. Renew denial atomically;
            // never overflow the column and roll back the audit with it.
            let ceilingLimiter = V2PostgresPasswordLoginAttemptLimiter(
                database: resources.database(.psql),
                policy: try .init(maximumFailures: Int(Int32.max), window: 60, lockout: 60)
            )
            for count in [Int(Int32.max) - 1, Int(Int32.max)] {
                let handle = "counter-boundary-\(count)"
                let auditDevice = DeviceID(uuid: UUID())
                try await sql.raw("""
                    INSERT INTO im_v2.account_password_login_rate_limits
                        (account_handle, window_started_at, failure_count, blocked_until, updated_at)
                    VALUES (\(bind: handle), CURRENT_TIMESTAMP, \(bind: count),
                            CURRENT_TIMESTAMP - interval '1 second', CURRENT_TIMESTAMP)
                    """).run()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<4 {
                        group.addTask {
                            try await ceilingLimiter.recordRejectedAttempt(
                                accountHandle: handle, userID: userID, deviceID: auditDevice)
                        }
                    }
                    try await group.waitForAll()
                }
                struct CounterState: Decodable {
                    let count: Int; let blocked: Bool; let audits: Int
                }
                let counter = try #require(try await sql.raw("""
                    SELECT failure_count AS count, blocked_until > CURRENT_TIMESTAMP AS blocked,
                           (SELECT count(*) FROM im_v2.account_password_authentication_audit
                            WHERE device_id = \(bind: UUID(uuidString: auditDevice.rawValue)!)) AS audits
                    FROM im_v2.account_password_login_rate_limits WHERE account_handle = \(bind: handle)
                    """).first(decoding: CounterState.self))
                #expect(counter.count == Int(Int32.max))
                #expect(counter.blocked)
                #expect(counter.audits == 1)
            }

            // Invalid clock values must fail before a Date reaches the
            // nonthrowing PostgreSQL encoder, with no charged budget row.
            for (seconds, window) in [
                (Double.nan, 60.0), (Double.infinity, 60.0), (Double.greatestFiniteMagnitude, 60.0),
                (946_684_800.0 - 9_000_000_000_000, 1_000_000_000_000.0)
            ] {
                let invalidNow: @Sendable () -> Date = { Date(timeIntervalSince1970: seconds) }
                let edge = V2PostgresAccountEdgeClientRateLimiter(database: resources.database(.psql),
                    policy: try .init(maximumRequests: 1, window: window),
                    key: try .init(base64Encoded: Data(repeating: 1, count: 32).base64EncodedString()), now: invalidNow)
                await #expect(throws: V2AccountEdgeClientRateLimitError.unavailable) {
                    try await edge.consume(address: .init("127.0.0.1"))
                }
                await #expect(throws: V2AccountEdgeClientRateLimitError.unavailable) {
                    try await edge.purgeExpired(limit: 10)
                }
                let directory = V2PostgresPublicIdentityDirectory(database: resources.database(.psql),
                    policy: try .init(maximumQueries: 1, window: window), now: invalidNow)
                await #expect(throws: V2PublicIdentityDirectoryError.unavailable) {
                    try await directory.resolve(handle: .init("boundary_account"), actorUserID: userID)
                }
            }
            #expect(try await sql.raw("SELECT 1 FROM im_v2.account_edge_client_rate_limits").first() == nil)
            #expect(try await sql.raw("SELECT 1 FROM im_v2.public_identity_lookup_rate_limits").first() == nil)

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

    @Test("password registration writes a privacy-minimized audit fact atomically")
    func recordsPasswordRegistrationAudit() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2PasswordAccountStoreError.unavailable
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let deviceID = try DeviceID("00000000-0000-0000-0000-000000000903")
            let userID = try await V2PostgresPasswordAccountStore(
                database: resources.database(.psql),
                now: { Date(timeIntervalSince1970: 1_750_001_001) }
            ).register(
                accountHandle: "audit-registration",
                passwordHash: V2PasswordHashPolicy.dummyDigest,
                publicHandle: "audit_registration",
                displayName: "审计注册",
                deviceID: deviceID
            )

            let audit = try #require(try await sql.raw("""
                SELECT outcome, user_id, device_id, occurred_at
                FROM im_v2.account_password_authentication_audit
                """).first(decoding: PasswordAuthenticationAuditRow.self))
            #expect(audit.outcome == "registration_succeeded")
            #expect(audit.userID == UUID(uuidString: userID.rawValue))
            #expect(audit.deviceID == UUID(uuidString: deviceID.rawValue))
            #expect(audit.occurredAt == Date(timeIntervalSince1970: 1_750_001_001))

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

    @Test("schema readiness fails before serving without password failure state")
    func schemaReadinessRequiresPasswordLoginRateLimitTable() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2SchemaReadinessError.unsupportedDatabase
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            // The canonical schema must satisfy the complete startup contract
            // before this test removes one required table. This catches a
            // schema migration whose renamed functions or triggers were not
            // reflected in the binary readiness gate.
            try await V2SchemaReadiness.verify(database: resources.database(.psql))
            try await sql.raw("DROP TABLE im_v2.account_password_login_rate_limits").run()

            await #expect(throws: V2SchemaReadinessError.unavailableTable("im_v2.account_password_login_rate_limits")) {
                try await V2SchemaReadiness.verify(database: resources.database(.psql))
            }

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

    @Test("capacity-profile readiness rejects a reused identifier with changed durable limits")
    func capacityProfileReadinessRejectsPersistedLimitDrift() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1),
                as: .psql,
                isDefault: true
            )
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2CapacityProfileReadinessError.unsupportedDatabase
            }
            guard (try await sql.raw(
                "SELECT to_regnamespace('im_v2') IS NOT NULL AS exists"
            ).first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await sql.raw("CREATE SCHEMA im_v2").run()
            try await sql.raw("""
                CREATE TABLE im_v2.shard_admission_pools (
                    room_shard_id text NOT NULL,
                    capacity_profile_id text NOT NULL,
                    command_window_limit bigint NOT NULL,

                    PRIMARY KEY (room_shard_id, capacity_profile_id)
                )
                """).run()
            let profile = try V2CapacityProfile(id: "loadtest-v17", limits: .init(
                maxEligibleMembers: 10,
                maxCommandsPerWindow: 500_000,

                retryAfterSeconds: 3
            ))

            // A new profile may start before its control plane issues a pool.
            try await V2CapacityProfileReadiness.verify(
                database: resources.database(.psql), profile: profile
            )
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, command_window_limit)
                VALUES ('rooms-load-00', 'loadtest-v17', 500000)
                """).run()
            try await V2CapacityProfileReadiness.verify(
                database: resources.database(.psql), profile: profile
            )

            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools
                SET command_window_limit = 100000
                WHERE capacity_profile_id = 'loadtest-v17'
                """).run()
            await #expect(throws: V2CapacityProfileReadinessError.persistedLimitsMismatch(
                profileID: "loadtest-v17"
            )) {
                try await V2CapacityProfileReadiness.verify(
                    database: resources.database(.psql), profile: profile
                )
            }

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

    @Test("schema readiness rejects a legacy cursor index without the current sequence invariant")
    func schemaReadinessRejectsLegacyDirectEventCursorContract() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2SchemaReadinessError.unsupportedDatabase
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            // An old index cannot substitute for the current sequence invariant.
            try await V2SchemaReadiness.verify(database: resources.database(.psql))
            try await sql.raw("ALTER TABLE im_v2.messages DROP CONSTRAINT messages_message_row_sequences_match").run()
            try await sql.raw("CREATE INDEX messages_direct_event_cursor_idx ON im_v2.messages (room_id, room_sequence) WHERE accepted_event_storage = 'message_row'").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable("im_v2.messages[direct-event-source]")) {
                try await V2SchemaReadiness.verify(database: resources.database(.psql))
            }

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

    @Test("edge client request budget is shared across replicas and stores no clear-text address")
    func enforcesPseudonymousEdgeClientRateLimit() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2AccountEdgeClientRateLimitError.unavailable
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let key = try V2AccountEdgeClientRateLimitKey(base64Encoded: Data(repeating: 8, count: 32).base64EncodedString())
            let policy = try V2AccountEdgeClientRateLimitPolicy(maximumRequests: 2, window: 60)
            let address = try V2AccountEdgeClientAddress("198.51.100.8")
            let firstReplica = V2PostgresAccountEdgeClientRateLimiter(
                database: resources.database(.psql), policy: policy, key: key,
                now: { Date(timeIntervalSince1970: 1_750_002_000) }
            )

            #expect(try await firstReplica.consume(address: address) == .allowed)
            #expect(try await firstReplica.consume(address: address) == .allowed)
            #expect(try await firstReplica.consume(address: address) == .rateLimited(retryAfterSeconds: 60))
            #expect(try await firstReplica.consume(address: try V2AccountEdgeClientAddress("203.0.113.9")) == .allowed)

            let concurrentPolicy = try V2AccountEdgeClientRateLimitPolicy(
                maximumRequests: 1,
                window: 60
            )
            let concurrentAddress = try V2AccountEdgeClientAddress("192.0.2.44")
            let concurrentFirst = V2PostgresAccountEdgeClientRateLimiter(
                database: resources.database(.psql), policy: concurrentPolicy, key: key,
                now: { Date(timeIntervalSince1970: 1_750_002_000) }
            )
            let concurrentSecond = V2PostgresAccountEdgeClientRateLimiter(
                database: resources.database(.psql), policy: concurrentPolicy, key: key,
                now: { Date(timeIntervalSince1970: 1_750_002_000) }
            )
            async let concurrentFirstResult = concurrentFirst.consume(address: concurrentAddress)
            async let concurrentSecondResult = concurrentSecond.consume(address: concurrentAddress)
            let concurrentResults = try await [concurrentFirstResult, concurrentSecondResult]
            #expect(concurrentResults.filter { $0 == .allowed }.count == 1)
            #expect(concurrentResults.filter {
                $0 == .rateLimited(retryAfterSeconds: 60)
            }.count == 1)

            let secondReplica = V2PostgresAccountEdgeClientRateLimiter(
                database: resources.database(.psql), policy: policy, key: key,
                now: { Date(timeIntervalSince1970: 1_750_002_061) }
            )
            #expect(try await secondReplica.consume(address: address) == .allowed)
            #expect(try await secondReplica.consume(address: try V2AccountEdgeClientAddress("2001:db8::8")) == .allowed)

            let persistedKeys = try await sql.raw("SELECT client_key FROM im_v2.account_edge_client_rate_limits ORDER BY client_key").all(decoding: EdgeClientRateLimitKeyRow.self)
            #expect(persistedKeys.count == 4)
            #expect(persistedKeys.allSatisfy { $0.clientKey != "198.51.100.8" && $0.clientKey != "2001:db8::8" })
            #expect(persistedKeys.allSatisfy { $0.clientKey.count == 64 })
            #expect(try await secondReplica.purgeExpired(limit: 100) == 2)
            #expect(try await count("im_v2.account_edge_client_rate_limits", on: sql) == 2)

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

    @Test("display-name updates propagate to direct peers in bounded, idempotent pages")
    func propagatesDisplayNameToExistingDirectPeers() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2DirectRoomProfilePropagationError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let now = Date(timeIntervalSince1970: 1_750_001_000)
            let sourceUUID = UUID(uuidString: "00000000-0000-0000-0000-00000000a001")!
            let firstPeerUUID = UUID(uuidString: "00000000-0000-0000-0000-00000000a002")!
            let secondPeerUUID = UUID(uuidString: "00000000-0000-0000-0000-00000000a003")!
            let sourceUserID = try UserID(sourceUUID.uuidString)
            let capacityProfile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10,
                  retryAfterSeconds: 3
            ))
            let leaseID = UUID(uuidString: "00000000-0000-0000-0000-00000000a010")!
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
                VALUES ('rooms-primary', 'standard', \(bind: leaseID), 1, \(bind: now.addingTimeInterval(600)), 10)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, created_at, updated_at)
                VALUES (\(bind: sourceUUID), 'source_a001', '旧名称', 1, \(bind: now), \(bind: now)),
                       (\(bind: firstPeerUUID), 'peer_a002', '同伴一', 1, \(bind: now), \(bind: now)),
                       (\(bind: secondPeerUUID), 'peer_a003', '同伴二', 1, \(bind: now), \(bind: now))
                """).run()

            let directService = try V2DirectMessagingService(
                store: PostgresV2DirectMessagingStore(database: resources.database(.psql)),
                capacityProfile: capacityProfile, roomShardID: "rooms-primary", now: { now }
            )
            var directRoomIDs: [RoomID] = []
            for peer in [firstPeerUUID, secondPeerUUID] {
                guard case .opened(let room) = try await directService.open(
                    actorUserID: sourceUserID, operationID: try .init(UUID().uuidString),
                    targetUserID: try .init(peer.uuidString)
                ) else {
                    Issue.record("expected direct room")
                    return
                }
                directRoomIDs.append(room.roomID)
            }
            // A direct peer becomes visible only once the first eligible
            // message commits. Seed that state here so this test exercises
            // display-name propagation for real conversations, rather than
            // leaking an unopened stranger-initiated room.
            let directMessages = V2SendMessageService(
                store: PostgresV2RoomWriteStore(
                    database: resources.database(.psql),
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 3, window: 86_400)
                ),
                capacityProfile: capacityProfile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            for roomID in directRoomIDs {
                guard case .accepted = try await directMessages.send(.init(
                    roomID: roomID,
                    actorUserID: sourceUserID,
                    clientMessageID: try .init(UUID().uuidString),
                    text: "已建立会话"
                )) else {
                    Issue.record("expected accepted first direct message")
                    return
                }
            }

            let personalWorker = V2UserStateEventWorker(
                outbox: try PostgresV2UserStateEventOutbox(database: resources.database(.psql)),
                projector: try PostgresV2UserStateEventProjector(database: resources.database(.psql)), now: { now })
            #expect(try await personalWorker.runOnce(limit: 100) == 6)
            #expect(try await personalWorker.runOnce(limit: 100) == 0)

            let profileEventID = UUID(uuidString: "00000000-0000-0000-0000-00000000a020")!
            let directory = V2PostgresPublicIdentityDirectory(
                database: resources.database(.psql), policy: try .init(maximumQueries: 10, window: 60),
                makeUUID: { profileEventID }, now: { now.addingTimeInterval(1) }
            )
            let updated = try await directory.updateDisplayName(for: sourceUserID, displayName: "新名称")
            #expect(updated.displayName == "新名称")

            let router = V2PostgresUserShardRouter(database: resources.database(.psql))
            try await configureDefaultUserShardRoute(
                .init(bucket: "users-primary", observedRouterEpoch: 1),
                now: now,
                on: sql
            )
            let registry = try V2StaticUserShardStorageRegistry(locations: [
                try .init(bucket: "users-primary", database: resources.database(.psql), schema: "im_v2"),
            ])
            let shadow = V2PostgresUserShardProjectionDelivery(
                registry: registry,
                routeFence: router,
                coLocatedControlBuckets: ["users-primary"]
            )
            // Simulate a process loss after the control-plane sync record was
            // committed but before it reached the current user shard. The
            // expired lease must retry that exact source event rather than
            // append a second control record or skip the first recipient.
            let interruptedWorker = V2DirectRoomProfilePropagationWorker(
                database: resources.database(.psql), projectionDelivery: ProfilePropagationFailingProjectionDelivery(),
                now: { now.addingTimeInterval(2) }
            )
            await #expect(throws: ProfilePropagationShadowFailure.interrupted) {
                try await interruptedWorker.runOnce(limit: 1)
            }
            let interruptedControlCount = try #require(try await sql.raw("""
                SELECT COUNT(*)::bigint AS value FROM im_v2.user_sync_log
                WHERE source_event_id = \(bind: profileEventID) AND projection_kind = 'direct_room_profile'
                """).first(decoding: CountRow.self))
            #expect(interruptedControlCount.value == 1)
            let interruptedInvalidationCount = try #require(try await sql.raw("""
                SELECT COUNT(*)::bigint AS value FROM im_v2.user_sync_log
                WHERE source_event_id = \(bind: profileEventID) AND projection_kind = 'profile_invalidation'
                """).first(decoding: CountRow.self))
            #expect(interruptedInvalidationCount.value == 1)
            let interruptedOutbox = try #require(try await sql.raw("""
                SELECT state, enumeration_checkpoint IS NOT NULL AS checkpointed
                FROM im_v2.public_profile_update_outbox WHERE source_event_id = \(bind: profileEventID)
                """).first(decoding: ProfilePropagationOutboxRow.self))
            #expect(interruptedOutbox.state == "claimed")
            #expect(!interruptedOutbox.checkpointed)
            try await sql.raw("""
                UPDATE im_v2.public_profile_update_outbox
                SET lease_expires_at = CURRENT_TIMESTAMP - INTERVAL '1 second'
                WHERE source_event_id = \(bind: profileEventID)
                """).run()
            let recoveryNow = Date()
            let worker = V2DirectRoomProfilePropagationWorker(
                database: resources.database(.psql), projectionDelivery: shadow, now: { recoveryNow }
            )
            let firstPage = try await worker.runOnce(limit: 1)
            #expect(firstPage.projectedRecipientCount == 1)
            #expect(firstPage.completedUpdateCount == 0)
            let pending = try #require(try await sql.raw("""
                SELECT state, enumeration_checkpoint IS NOT NULL AS checkpointed
                FROM im_v2.public_profile_update_outbox WHERE source_event_id = \(bind: profileEventID)
                """).first(decoding: ProfilePropagationOutboxRow.self))
            #expect(pending.state == "pending")
            #expect(pending.checkpointed)

            let secondPage = try await worker.runOnce(limit: 1)
            #expect(secondPage.projectedRecipientCount == 1)
            #expect(secondPage.completedUpdateCount == 1)
            let completed = try #require(try await sql.raw("""
                SELECT state, completed_at IS NOT NULL AS completed
                FROM im_v2.public_profile_update_outbox WHERE source_event_id = \(bind: profileEventID)
                """).first(decoding: ProfilePropagationCompletedRow.self))
            #expect(completed.state == "completed")
            #expect(completed.completed)
            let projections = try await sql.raw("""
                SELECT user_id, payload->>'room_id' AS room_id, payload->>'display_name' AS display_name,
                       (payload->>'revision')::bigint AS revision
                FROM im_v2.user_sync_log
                WHERE source_event_id = \(bind: profileEventID) AND projection_kind = 'direct_room_profile'
                ORDER BY user_id
                """).all(decoding: ProfilePropagationProjectionRow.self)
            #expect(projections.map(\.userID) == [firstPeerUUID, secondPeerUUID])
            #expect(projections.allSatisfy { $0.displayName == "新名称" && $0.revision == 2 })
            #expect(projections.allSatisfy { UUID(uuidString: $0.roomID)?.uuidString == $0.roomID })
            let invalidations = try await sql.raw("""
                SELECT user_id, payload->>'user_id' AS user_id_payload,
                       (payload->>'minimum_profile_revision')::bigint AS minimum_profile_revision
                FROM im_v2.user_sync_log
                WHERE source_event_id = \(bind: profileEventID) AND projection_kind = 'profile_invalidation'
                ORDER BY user_id
                """).all(decoding: ProfileInvalidationAssertionRow.self)
            #expect(invalidations.map(\.recipientUserID) == [firstPeerUUID, secondPeerUUID])
            #expect(invalidations.allSatisfy {
                $0.invalidatedUserID == sourceUUID && $0.minimumProfileRevision == 2
            })

            // A completed source event is never reprojected on a later poll.
            let replay = try await worker.runOnce(limit: 8)
            #expect(replay.projectedRecipientCount == 0)
            #expect(try await scopedCount("im_v2", "user_sync_log", user: firstPeerUUID, on: sql) == 3)
            #expect(try await scopedCount("im_v2", "user_sync_log", user: secondPeerUUID, on: sql) == 3)

            let disableOperationID = UUID(uuidString: "00000000-0000-0000-0000-00000000a021")!
            let disableService = try V2PostgresAccountDisableService(
                database: resources.database(.psql),
                operatorPrincipal: "account-safety-primary",
                now: { now.addingTimeInterval(10) }
            )
            #expect(try await disableService.disable(.init(
                userID: sourceUserID,
                operationID: disableOperationID,
                reason: .policyEnforcement
            )) == .disabled(disabledAt: now.addingTimeInterval(10)))
            let suspensionReport = try await worker.runOnce(limit: 8)
            let suspensionProfiles = try await sql.raw("SELECT user_id FROM im_v2.user_sync_log WHERE source_event_id = \(bind: disableOperationID) AND projection_kind = 'direct_room_profile'").all(decoding: ProjectionRecipientAssertionRow.self)
            let suspensionInvalidations = try await sql.raw("SELECT user_id, payload->>'profile_state' AS profile_state, (payload->>'minimum_profile_revision')::bigint AS minimum_profile_revision FROM im_v2.user_sync_log WHERE source_event_id = \(bind: disableOperationID) AND projection_kind = 'profile_invalidation' ORDER BY user_id").all(decoding: ProfileSuspensionInvalidationAssertionRow.self)
            #expect(suspensionReport == .init(claimedUpdateCount: 1, projectedRecipientCount: 2, completedUpdateCount: 1))
            #expect(suspensionProfiles.isEmpty)
            #expect(suspensionInvalidations.map(\.recipientUserID) == [firstPeerUUID, secondPeerUUID])
            #expect(suspensionInvalidations.allSatisfy { $0.profileState == "suspended" && $0.minimumProfileRevision == 3 })

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

    @Test("mention authorization preserves bilateral block checks without scanning a whole room")
    func mentionAuthorizationRejectsBlockedUserTargets() async throws {
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
            try await sql.raw("""
                INSERT INTO im_v2.user_blocks (blocker_user_id, blocked_user_id, created_at)
                VALUES (\(bind: memberTwoUUID), \(bind: senderUUID), \(bind: now))
                """).run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3))
            let service = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: resources.database(.psql)),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )

            await #expect(throws: V2MentionValidationError.notAuthorized) {
                try await service.send(.init(
                    roomID: roomID,
                    actorUserID: senderID,
                    clientMessageID: clientMessageID,
                    text: "@受限成员",
                    mentions: [.user(try .init(memberTwoUUID.uuidString))]
                ))
            }
            #expect(try await count("im_v2.messages", on: sql) == 0)
            #expect(try await count("im_v2.room_events", on: sql) == 0)

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("direct room-log messages persist once and recover only through revision-fenced room cursors", arguments: [false, true])
    func persistsDirectRoomLogWithoutPerUserFanoutArtifacts(_ actorScoped: Bool) async throws {
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

            let now = Date(timeIntervalSince1970: 1_750_200_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 100,

                 retryAfterSeconds: 3
            ))
            let lease = UUID(uuidString: "00000000-0000-0000-0000-00000000c001")!
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
                VALUES ('rooms-primary', 'standard', \(bind: lease), 1, \(bind: now.addingTimeInterval(600)), 100)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, created_at, updated_at)
                VALUES
                    (\(bind: senderUUID), 'sender012', '发送者', 1, \(bind: now), \(bind: now)),
                    (\(bind: memberTwoUUID), 'member015', '成员二', 1, \(bind: now), \(bind: now)),
                    (\(bind: memberThreeUUID), 'member016', '成员三', 1, \(bind: now), \(bind: now))
                """).run()
            let direct = try V2DirectMessagingService(
                store: PostgresV2DirectMessagingStore(database: resources.database(.psql)),
                capacityProfile: profile,
                roomShardID: "rooms-primary",
                now: { now }
            )
            let recipient = try UserID(memberTwoUUID.uuidString)
            guard case .opened(let room) = try await direct.open(
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-00000000c002"),
                targetUserID: recipient
            ) else {
                Issue.record("expected direct room")
                return
            }
            guard case .opened(let secondRoom) = try await direct.open(
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-00000000c005"),
                targetUserID: try .init(memberThreeUUID.uuidString)
            ) else {
                Issue.record("expected second direct room")
                return
            }
            let activationScope: V2RoomActivationWriteScope?
            if actorScoped {
                let activations = PostgresV2RoomActivationStore(database: resources.database(.psql))
                let owner = try V2RoomDataOwner(shardID: "rooms-primary", epoch: 0)
                let host = V2ActorHostIdentity(
                    hostID: try .init("direct-log-test"), incarnationID: UUID()
                )
                var tokens: [V2RoomActivationToken] = []
                for roomID in [room.roomID, secondRoom.roomID] {
                    guard case .acquired(let lease) = try await activations.acquire(
                        roomID: roomID, owner: owner, host: host, duration: .init(30_000)
                    ) else { throw V2RoomActivationLeaseError.activationChanged }
                    tokens.append(lease.token)
                }
                activationScope = try .init(tokens: tokens)
            } else {
                activationScope = nil
            }
            func selected(_ local: PostgresV2RoomWriteStore) throws -> any V2AtomicRoomWriteBatchStore {
                if let activationScope { return local.usingActivationScope(activationScope) }
                return local
            }
            let shardCredits = V2ShardAdmissionCommandCreditPool(
                database: resources.database(.psql), batchSize: 2
            )
            let roomCredits = V2RoomAdmissionCommandCreditPool(
                database: resources.database(.psql), batchSize: 2
            )
            let fastAppendCache = V2DirectRoomLogFastAppendCache()
            let isolatingWriterLocal = PostgresV2RoomWriteStore(
                database: resources.database(.psql),
                strangerMessagePolicy: try .init(
                    maximumMessagesPerWindow: 10, window: 86_400
                ),
                contentReviewMode: .disabled,
                shardAdmissionCommandCreditPool: shardCredits
            )
            let isolatingWriter = try selected(isolatingWriterLocal)
            let legacyProfile = try V2CapacityProfile(
                id: "legacy-test",
                limits: profile.limits
            )
            let profileIsolationRequests: [V2RoomWriteRequest] = [
                .init(
                    command: try .init(
                        roomID: room.roomID, senderUserID: senderID,
                        clientMessageID: try .init(
                            "00000000-0000-0000-0000-00000000c050"
                        ),
                        text: "有效配置输入",
                        limits: try .init(maxUTF8Bytes: 64)
                    ),
                    capacityProfile: profile,
                    identifiers: try .init(
                        messageID: .init("00000000-0000-0000-0000-00000000c051"),
                        eventID: .init("00000000-0000-0000-0000-00000000c052")
                    ),
                    now: now
                ),
                .init(
                    command: try .init(
                        roomID: secondRoom.roomID, senderUserID: senderID,
                        clientMessageID: try .init(
                            "00000000-0000-0000-0000-00000000c054"
                        ),
                        text: "旧配置输入",
                        limits: try .init(maxUTF8Bytes: 64)
                    ),
                    capacityProfile: legacyProfile,
                    identifiers: try .init(
                        messageID: .init("00000000-0000-0000-0000-00000000c055"),
                        eventID: .init("00000000-0000-0000-0000-00000000c056")
                    ),
                    now: now
                ),
            ]
            // Cold direct batches cannot bypass per-room admission; the
            // batcher retries each request through the scalar path.
            await #expect(throws: V2AtomicRoomWriteBatchError(
                reason: .incompatibleConfiguration
            )) {
                try await isolatingWriter.acceptAtomically(
                    requests: profileIsolationRequests
                )
            }
            let isolatedProfileWrites = try await sql.raw("""
                SELECT COUNT(*)::bigint AS value
                FROM im_v2.messages
                WHERE message_id IN (
                    '00000000-0000-0000-0000-00000000c051'::uuid,
                    '00000000-0000-0000-0000-00000000c055'::uuid
                )
                """).first(decoding: CountRow.self)
            #expect(isolatedProfileWrites?.value == 0)
            let writerLocal = PostgresV2RoomWriteStore(
                database: resources.database(.psql),
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
                contentReviewMode: .disabled,
                directRoomLogFastAppendCache: fastAppendCache,
                shardAdmissionCommandCreditPool: shardCredits,
                roomAdmissionCommandCreditPool: roomCredits
            )
            let writer = try selected(writerLocal)
            let messages = V2SendMessageService(
                store: writer, capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64), now: { now }
            )
            // Per-room admission keeps cold commands on its
            // scalar transaction. It may have unused precharged room credits,
            // so a cold set must not overwrite that durable counter from an
            // older preflight snapshot.
            let coldRequests: [V2RoomWriteRequest] = [
                .init(
                    command: try .init(
                        roomID: room.roomID, senderUserID: senderID,
                        clientMessageID: try .init("00000000-0000-0000-0000-00000000c030"),
                        text: "第一条冷批量消息", limits: try .init(maxUTF8Bytes: 64)
                    ),
                    capacityProfile: profile,
                    identifiers: try .init(
                        messageID: .init("00000000-0000-0000-0000-00000000c031"),
                        eventID: .init("00000000-0000-0000-0000-00000000c032")
                    ),
                    now: now
                ),
                .init(
                    command: try .init(
                        roomID: secondRoom.roomID, senderUserID: senderID,
                        clientMessageID: try .init("00000000-0000-0000-0000-00000000c034"),
                        text: "第二条冷批量消息", limits: try .init(maxUTF8Bytes: 64)
                    ),
                    capacityProfile: profile,
                    identifiers: try .init(
                        messageID: .init("00000000-0000-0000-0000-00000000c035"),
                        eventID: .init("00000000-0000-0000-0000-00000000c036")
                    ),
                    now: now
                ),
            ]
            #expect(await writer.atomicBatchEligibility(requests: coldRequests) == [false, false])
            await #expect(throws: V2AtomicRoomWriteBatchError(
                reason: .incompatibleConfiguration
            )) {
                try await writer.acceptAtomically(requests: coldRequests)
            }
            var coldBatched: [V2SendMessageOutcome] = []
            for request in coldRequests {
                coldBatched.append(try await writer.accept(
                    command: request.command,
                    capacityProfile: request.capacityProfile,
                    identifiers: request.identifiers,
                    now: request.now
                ))
            }
            #expect(coldBatched.allSatisfy {
                if case .accepted(let message) = $0 { return message.roomSequence > 0 && message.sourceEventID != nil }
                return false
            })
            #expect(try await count("im_v2.stranger_message_windows", on: sql) == 2)
            let coldSources = Set(["00000000-0000-0000-0000-00000000C032", "00000000-0000-0000-0000-00000000C036"])
            let coldOutbox = try PostgresV2UserStateEventOutbox(database: resources.database(.psql))
            let coldProjector = try PostgresV2UserStateEventProjector(database: resources.database(.psql))
            let deliveryTime = now.addingTimeInterval(60)
            let coldLeases = try await coldOutbox.claim(now: deliveryTime, leaseDuration: 30, limit: 1024)
                .filter { coldSources.contains($0.event.sourceEventID.rawValue) }
            #expect(coldLeases.count == 4)
            for lease in coldLeases {
                let sequence = try await coldProjector.project(lease.event)
                #expect(try await coldProjector.project(lease.event) == sequence)
                #expect(try await coldOutbox.acknowledge(lease, sequence: sequence, now: deliveryTime))
            }
            let coldProjectionRows = try await sql.raw("""
                SELECT user_id, user_sync_sequence, source_event_id, projection_kind
                FROM im_v2.user_sync_log
                WHERE source_event_id IN
                    ('00000000-0000-0000-0000-00000000c032'::uuid,
                     '00000000-0000-0000-0000-00000000c036'::uuid)
                ORDER BY user_id, user_sync_sequence
                """).all(decoding: DirectBatchProjectionSyncAssertionRow.self)
            #expect(coldProjectionRows.count == 4)
            #expect(coldProjectionRows.filter {
                $0.userID == senderUUID
                    && $0.projectionKind == "direct_sending_capability"
            }.count == 2)
            #expect(coldProjectionRows.filter {
                $0.projectionKind == "direct_room_profile"
            }.count == 2)
            let senderCapabilitySequences = coldProjectionRows
                .filter { $0.userID == senderUUID }
                .map(\.userSyncSequence)
            #expect(senderCapabilitySequences.count == 2)
            if senderCapabilitySequences.count == 2 {
                #expect(senderCapabilitySequences[1] == senderCapabilitySequences[0] + 1)
            }
            let coldPairStates = try await sql.raw("""
                SELECT lower_profile_visible_to_higher,
                       higher_profile_visible_to_lower,
                       lower_can_send, higher_can_send
                FROM im_v2.direct_room_pairs
                WHERE room_id IN
                    (\(bind: UUID(uuidString: room.roomID.rawValue)! ),
                     \(bind: UUID(uuidString: secondRoom.roomID.rawValue)! ))
                """).all(decoding: DirectPairProjectionStateAssertionRow.self)
            #expect(coldPairStates.count == 2)
            #expect(coldPairStates.allSatisfy {
                $0.lowerProfileVisibleToHigher || $0.higherProfileVisibleToLower
            })
            #expect(coldPairStates.allSatisfy {
                $0.lowerCanSend == true || $0.higherCanSend == true
            })
            let coldCreditSnapshot = await shardCredits.snapshot()
            #expect(coldCreditSnapshot.databaseCreditsReserved == 0)
            #expect(coldCreditSnapshot.committedCredits == 0)
            let clientID = try ClientMessageID("00000000-0000-0000-0000-00000000c003")
            guard case .accepted(let accepted) = try await messages.send(.init(
                roomID: room.roomID, actorUserID: senderID, clientMessageID: clientID,
                text: "只写一次的私聊"
            )) else {
                Issue.record("expected room-log acceptance")
                return
            }

            let replay = try await messages.send(.init(
                roomID: room.roomID, actorUserID: senderID, clientMessageID: clientID,
                text: "只写一次的私聊"
            ))
            guard case .idempotent(let replayed) = replay else {
                Issue.record("expected idempotent replay")
                return
            }
            #expect(replayed == accepted.receipt)

            // A later policy mutation must still be fenced by the durable
            // user policy revision inside the write transaction; a stale
            // cache entry must never authorize this send.
            guard case .accepted = try await messages.send(.init(
                roomID: room.roomID, actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-00000000c004"),
                text: "缓存回填后的第二条消息"
            )) else {
                Issue.record("expected second room-log acceptance")
                return
            }

            // Friend relationships make the two established conversations
            // eligible without changing their room-event history.  The test
            // removes them immediately after the append so the stale-policy
            // assertion below retains its original stranger semantics.
            try await sql.raw("""
                INSERT INTO im_v2.user_relationships
                    (lower_user_id, higher_user_id, state, requested_by_user_id, updated_at)
                VALUES
                    (\(bind: senderUUID), \(bind: memberTwoUUID), 'accepted', \(bind: senderUUID), \(bind: now)),
                    (\(bind: senderUUID), \(bind: memberThreeUUID), 'accepted', \(bind: senderUUID), \(bind: now))
                """).run()
            try await sql.raw("""
                UPDATE im_v2.direct_room_pairs
                SET direct_policy_revision = direct_policy_revision + 1
                WHERE room_id IN (\(bind: UUID(uuidString: room.roomID.rawValue)! ),
                                  \(bind: UUID(uuidString: secondRoom.roomID.rawValue)! ))
                """).run()
            // The direct-policy revisions above intentionally invalidate the
            // old cache entries. Warm only the first room, then mix that cache
            // hit with a second-room miss. The optimistic fast-path probe may
            // acquire a shard credit for the first input before discovering
            // the later miss; every speculative token must be returned before
            // the established complete path handles the whole batch.
            guard case .accepted = try await messages.send(.init(
                roomID: room.roomID, actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-00000000c021"),
                text: "关系变更后的缓存回填"
            )) else {
                Issue.record("expected first post-revision cache warm acceptance")
                return
            }
            let creditsBeforeMixedFastMiss = await shardCredits.snapshot()
            let mixedFastCacheRequests: [V2RoomWriteRequest] = [
                .init(
                    command: try .init(
                        roomID: room.roomID,
                        senderUserID: senderID,
                        clientMessageID: try .init("00000000-0000-0000-0000-00000000c040"),
                        text: "缓存命中输入",
                        limits: try .init(maxUTF8Bytes: 64)
                    ),
                    capacityProfile: profile,
                    identifiers: try .init(
                        messageID: .init("00000000-0000-0000-0000-00000000c041"),
                        eventID: .init("00000000-0000-0000-0000-00000000c042")
                    ),
                    now: now
                ),
                .init(
                    command: try .init(
                        roomID: secondRoom.roomID,
                        senderUserID: senderID,
                        clientMessageID: try .init("00000000-0000-0000-0000-00000000c044"),
                        text: "缓存未命中输入",
                        limits: try .init(maxUTF8Bytes: 64)
                    ),
                    capacityProfile: profile,
                    identifiers: try .init(
                        messageID: .init("00000000-0000-0000-0000-00000000c045"),
                        eventID: .init("00000000-0000-0000-0000-00000000c046")
                    ),
                    now: now
                ),
            ]
            await #expect(throws: V2AtomicRoomWriteBatchError(
                reason: .incompatibleConfiguration
            )) {
                try await writer.acceptAtomically(requests: mixedFastCacheRequests)
            }
            var mixedFastCacheBatch: [V2SendMessageOutcome] = []
            for request in mixedFastCacheRequests {
                mixedFastCacheBatch.append(try await writer.accept(
                    command: request.command,
                    capacityProfile: request.capacityProfile,
                    identifiers: request.identifiers,
                    now: request.now
                ))
            }
            #expect(mixedFastCacheBatch.allSatisfy {
                if case .accepted(let message) = $0 { return message.roomSequence > 0 && message.sourceEventID != nil }
                return false
            })
            let creditsAfterMixedFastMiss = await shardCredits.snapshot()
            #expect(
                creditsAfterMixedFastMiss.inFlightCredits
                    == creditsBeforeMixedFastMiss.inFlightCredits
            )
            #expect(
                creditsAfterMixedFastMiss.returnedCredits
                    == creditsBeforeMixedFastMiss.returnedCredits + 2
            )
            let projectionRecordsBeforeSteadyStateBatch = try await sql.raw("""
                SELECT COUNT(*)::bigint AS value
                FROM im_v2.user_sync_log
                WHERE projection_kind IN ('direct_sending_capability', 'direct_room_profile')
                """).first(decoding: CountRow.self)
            if actorScoped {
                let beforeMessages = try await count("im_v2.messages", on: sql)
                let beforeCredits = await shardCredits.snapshot()
                let beforeFast = await fastAppendCache.snapshot()
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: secondRoom.roomID.uuidValue!)").run()
                await #expect(throws: V2RoomActivationLeaseError.ownerChanged) { _ = try await writer.acceptAtomically(requests: coldRequests) }
                #expect(try await count("im_v2.messages", on: sql) == beforeMessages)
                let afterCredits = await shardCredits.snapshot()
                let afterFast = await fastAppendCache.snapshot()
                #expect(afterCredits.inFlightCredits == beforeCredits.inFlightCredits)
                #expect(afterFast.attemptedAppends == beforeFast.attemptedAppends + 2)
                #expect(afterFast.committedAppends == beforeFast.committedAppends)
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=0 WHERE room_id=\(bind: secondRoom.roomID.uuidValue!)").run()
            }
            let fastAppendBeforeSteadyStateBatch = await fastAppendCache.snapshot()
            let batched = try await writer.acceptAtomically(requests: [
                .init(
                    command: try .init(
                        roomID: room.roomID,
                        senderUserID: senderID,
                        clientMessageID: try .init("00000000-0000-0000-0000-00000000c007"),
                        text: "第一条批量消息",
                        limits: try .init(maxUTF8Bytes: 64)
                    ),
                    capacityProfile: profile,
                    identifiers: try .init(
                        messageID: .init("00000000-0000-0000-0000-00000000c008"),
                        eventID: .init("00000000-0000-0000-0000-00000000c009")
                    ),
                    now: now
                ),
                .init(
                    command: try .init(
                        roomID: secondRoom.roomID,
                        senderUserID: senderID,
                        clientMessageID: try .init("00000000-0000-0000-0000-00000000c011"),
                        text: "第二条批量消息",
                        limits: try .init(maxUTF8Bytes: 64)
                    ),
                    capacityProfile: profile,
                    identifiers: try .init(
                        messageID: .init("00000000-0000-0000-0000-00000000c012"),
                        eventID: .init("00000000-0000-0000-0000-00000000c013")
                    ),
                    now: now
                ),
            ])
            #expect(batched.allSatisfy {
                if case .accepted(let message) = $0 { return message.roomSequence > 0 && message.sourceEventID != nil }
                return false
            })
            let projectionRecordsAfterSteadyStateBatch = try await sql.raw("""
                SELECT COUNT(*)::bigint AS value
                FROM im_v2.user_sync_log
                WHERE projection_kind IN ('direct_sending_capability', 'direct_room_profile')
                """).first(decoding: CountRow.self)
            #expect(
                projectionRecordsAfterSteadyStateBatch?.value
                    == projectionRecordsBeforeSteadyStateBatch?.value
            )
            let fastAppendAfterSteadyStateBatch = await fastAppendCache.snapshot()
            #expect(
                fastAppendAfterSteadyStateBatch.committedAppends
                    == fastAppendBeforeSteadyStateBatch.committedAppends + 2
            )
            #expect(
                fastAppendAfterSteadyStateBatch.fallbackAppends
                    == fastAppendBeforeSteadyStateBatch.fallbackAppends
            )
            // A same-room set cannot use the conditional batch statement,
            // because it advances one cursor per room. The batcher must fall
            // back to the ordered one-command fast path; both credit
            // reservations occur before their respective transactions.
            let sameRoomRequests: [V2RoomWriteRequest] = [
                .init(
                    command: try .init(
                        roomID: room.roomID, senderUserID: senderID,
                        clientMessageID: try .init("00000000-0000-0000-0000-00000000c015"),
                        text: "热点会话的第一条原子批消息",
                        limits: try .init(maxUTF8Bytes: 64)
                    ),
                    capacityProfile: profile,
                    identifiers: try .init(
                        messageID: .init("00000000-0000-0000-0000-00000000c016"),
                        eventID: .init("00000000-0000-0000-0000-00000000c017")
                    ),
                    now: now
                ),
                .init(
                    command: try .init(
                        roomID: room.roomID, senderUserID: senderID,
                        clientMessageID: try .init("00000000-0000-0000-0000-00000000c019"),
                        text: "热点会话的第二条原子批消息",
                        limits: try .init(maxUTF8Bytes: 64)
                    ),
                    capacityProfile: profile,
                    identifiers: try .init(
                        messageID: .init("00000000-0000-0000-0000-00000000c01a"),
                        eventID: .init("00000000-0000-0000-0000-00000000c01b")
                    ),
                    now: now
                ),
            ]
            await #expect(throws: V2AtomicRoomWriteBatchError(
                reason: .incompatibleConfiguration
            )) {
                try await writer.acceptAtomically(requests: sameRoomRequests)
            }
            var sameRoomBatch: [V2SendMessageOutcome] = []
            for request in sameRoomRequests {
                sameRoomBatch.append(try await writer.accept(
                    command: request.command,
                    capacityProfile: request.capacityProfile,
                    identifiers: request.identifiers,
                    now: request.now
                ))
            }
            guard case .accepted(let firstSameRoomMessage) = sameRoomBatch[0],
                  case .accepted(let secondSameRoomMessage) = sameRoomBatch[1],

                  secondSameRoomMessage.roomSequence == firstSameRoomMessage.roomSequence + 1
            else {
                Issue.record("expected ordered hot direct fallback acceptance")
                return
            }
            let hotRoomCredits = await roomCredits.snapshot()
            #expect(hotRoomCredits.inFlightCredits == 0)
            #expect(hotRoomCredits.batchReservations > 0)
            #expect(hotRoomCredits.committedCredits > 0)
            let hotRoomAdmission = try #require(try await sql.raw("""
                SELECT command_window_used
                FROM im_v2.room_admission
                WHERE room_id = \(bind: UUID(uuidString: room.roomID.rawValue)!)
                """).first(decoding: CapacityRow.self))
            #expect(hotRoomAdmission.commandWindowUsed == 9)

            try await sql.raw("""
                DELETE FROM im_v2.user_relationships
                WHERE lower_user_id = \(bind: senderUUID)
                  AND higher_user_id IN (\(bind: memberTwoUUID), \(bind: memberThreeUUID))
                """).run()

            // Rich messages retain the existing CTE: the plain-message fast
            // path must never silently skip a required moderation record.
            let reviewingMessages = V2SendMessageService(
                store: try selected(PostgresV2RoomWriteStore(
                    database: resources.database(.psql),
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
                    contentReviewMode: .enabled,
                    shardAdmissionCommandCreditPool: shardCredits
                )),
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            guard case .accepted = try await reviewingMessages.send(.init(
                roomID: room.roomID, actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-00000000c00a"),
                text: "审核路径仍保留完整持久化"
            )) else {
                Issue.record("expected reviewed room-log acceptance")
                return
            }
            #expect(try await count("im_v2.content_review_jobs", on: sql) == 1)

            _ = try await direct.setStrangerMessagePermission(
                actorUserID: recipient,
                operationID: try .init("00000000-0000-0000-0000-00000000c005"),
                permission: .deny
            )
            let fastAppendBeforeStalePolicy = await fastAppendCache.snapshot()
            let stalePolicyAttempt = try await messages.send(.init(
                roomID: room.roomID, actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-00000000c006"),
                text: "策略变更后必须被拒绝"
            ))
            guard case .denied(let stalePolicyDenial) = stalePolicyAttempt else {
                Issue.record("stale direct-send cache bypassed a policy change")
                return
            }
            #expect(stalePolicyDenial.reason == .generic)
            let fastAppendAfterStalePolicy = await fastAppendCache.snapshot()
            #expect(
                fastAppendAfterStalePolicy.fallbackAppends
                    == fastAppendBeforeStalePolicy.fallbackAppends + 1
            )

            let roomLog = V2GroupEventLogService(store: PostgresV2GroupEventLogStore(database: resources.database(.psql)))
            let senderPage = try await roomLog.pull(roomID: room.roomID, actorUserID: senderID, afterRoomSequence: accepted.roomSequence - 1, pageSize: 10)
            let recipientPage = try await roomLog.pull(roomID: room.roomID, actorUserID: recipient, afterRoomSequence: accepted.roomSequence - 1, pageSize: 10)
            #expect(senderPage.events.map(\.roomSequence) == [
                accepted.roomSequence,
                accepted.roomSequence + 1,
                accepted.roomSequence + 2,
                accepted.roomSequence + 3,
                accepted.roomSequence + 4,
                accepted.roomSequence + 5,
                accepted.roomSequence + 6,
                accepted.roomSequence + 7
            ])
            #expect(recipientPage.events == senderPage.events)
            #expect(String(data: try #require(senderPage.events.first?.payload), encoding: .utf8)?.contains("只写一次的私聊") == true)
            let acceptedEventID = try #require(UUID(uuidString: senderPage.events.first?.sourceEventID.rawValue ?? ""))
            let directMessageEvent = try #require(try await sql.raw("""
                SELECT accepted_event_id, accepted_event_storage,
                       accepted_membership_revision
                FROM im_v2.messages
                WHERE message_id = \(bind: UUID(uuidString: accepted.messageID.rawValue)!)
                """).first(decoding: DirectMessageRowEventRow.self))
            #expect(directMessageEvent.acceptedEventID == acceptedEventID)
            #expect(directMessageEvent.acceptedEventStorage == "message_row")
            #expect(accepted.sourceEventID?.rawValue == acceptedEventID.uuidString)
            // Direct-room creation commits its initial membership revision
            // before the first accepted message. The row-source event must
            // retain that exact historical fence rather than assuming zero.
            #expect(directMessageEvent.acceptedMembershipRevision == 1)
            #expect(accepted.acceptedMembershipRevision == 1)
            #expect(try await count(
                "im_v2.room_events WHERE event_id = '\(acceptedEventID.uuidString)'",
                on: sql
            ) == 0)

            // The accepted event must continue to expose its original body
            // after a later message revision changes the mutable row.
            await #expect(throws: (any Error).self) {
                try await sql.raw("""
                    UPDATE im_v2.messages
                    SET text_body = '没有 revision 的非法修改'
                    WHERE message_id = \(bind: UUID(uuidString: accepted.messageID.rawValue)!)
                    """).run()
            }
            try await sql.raw("""
                UPDATE im_v2.messages
                SET text_body = '已编辑的当前内容', rich_entities = '[]'::jsonb,
                    content_revision = 2
                WHERE message_id = \(bind: UUID(uuidString: accepted.messageID.rawValue)!)
                """).run()
            let recoveredAfterRevision = try await roomLog.pull(
                roomID: room.roomID, actorUserID: senderID,
                afterRoomSequence: accepted.roomSequence - 1, pageSize: 10
            )
            let originalPayload = String(
                data: try #require(recoveredAfterRevision.events.first?.payload),
                encoding: .utf8
            )
            #expect(originalPayload?.contains("只写一次的私聊") == true)
            #expect(originalPayload?.contains("已编辑的当前内容") == false)
            #expect(try await count("im_v2.message_content_versions", on: sql) == 1)
            await #expect(throws: V2GroupEventLogError.actorNotMember) {
                try await roomLog.pull(roomID: room.roomID, actorUserID: try .init(memberThreeUUID.uuidString), afterRoomSequence: 0, pageSize: 10)
            }

            #expect(try await count("im_v2.messages", on: sql) == 12)
            // Eleven ordinary direct messages are materialized from the
            // message row itself. The reviewed message intentionally retains
            // the complete room-event write graph.
            #expect(try await count("im_v2.room_events WHERE event_type = 'message.accepted'", on: sql) == 1)
            #expect(try await count("im_v2.message_projection_states", on: sql) == 0)
            #expect(try await count("im_v2.user_sync_log WHERE projection_kind = 'message'", on: sql) == 0)
            // Normal room admission remains authoritative. Complete-path
            // commands increment it in their own transaction; warm commands
            // may consume a previously durable room-credit batch.
            let roomAdmission = try #require(try await sql.raw("""
                SELECT command_window_used
                FROM im_v2.room_admission
                WHERE room_id = \(bind: UUID(uuidString: room.roomID.rawValue)!)
                """).first(decoding: CapacityRow.self))
            #expect(roomAdmission.commandWindowUsed == 10)
            let creditedAdmission = try #require(try await sql.raw("""
                SELECT command_window_used
                FROM im_v2.shard_admission_pools
                WHERE room_shard_id = 'rooms-primary' AND capacity_profile_id = 'standard'
                """).first(decoding: CapacityRow.self))
            // Seven complete-path commands reserve exactly one shard unit in
            // their source transaction. Five warm commands consume three
            // two-unit durable credit batches, leaving one safely precharged
            // unit for a later warm append.
            #expect(creditedAdmission.commandWindowUsed == 13)
            let creditSnapshot = await shardCredits.snapshot()
            #expect(creditSnapshot.batchReservations == 3)
            #expect(creditSnapshot.databaseCreditsReserved == 6)
            #expect(creditSnapshot.committedCredits == 5)

            // Warm the actual cached append, then corrupt membership without
            // changing its revision. A cache revision match must not authorize
            // a third participant, and the conditional failure must roll back.
            for _ in 0..<2 {
                guard case .accepted = try await messages.send(.init(
                    roomID: secondRoom.roomID, actorUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "membership fence warmup"
                )) else {
                    Issue.record("expected membership-fence warmup acceptance")
                    return
                }
            }
            let beforeCorruptFast = await fastAppendCache.snapshot()
            let secondRoomUUID = try #require(secondRoom.roomID.uuidValue)
            try await sql.raw("""
                INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision)
                VALUES (\(bind: secondRoomUUID), \(bind: memberTwoUUID), 1)
                """).run()
            let beforeCorruptArtifacts = try await directWriteArtifactCounts(sql: sql)
            let beforeCorruptSequence = try #require(try await sql.raw("""
                SELECT room_sequence AS value FROM im_v2.rooms
                WHERE room_id = \(bind: secondRoomUUID)
                """).first(decoding: CountRow.self)).value
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                try await messages.send(.init(
                    roomID: secondRoom.roomID, actorUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "must reject third member"
                ))
            }
            let afterCorruptFast = await fastAppendCache.snapshot()
            #expect(afterCorruptFast.attemptedAppends == beforeCorruptFast.attemptedAppends + 1)
            #expect(afterCorruptFast.fallbackAppends == beforeCorruptFast.fallbackAppends + 1)
            #expect(afterCorruptFast.committedAppends == beforeCorruptFast.committedAppends)
            #expect(try await directWriteArtifactCounts(sql: sql) == beforeCorruptArtifacts)
            #expect(try await sql.raw("""
                SELECT room_sequence AS value FROM im_v2.rooms
                WHERE room_id = \(bind: secondRoomUUID)
                """).first(decoding: CountRow.self)?.value == beforeCorruptSequence)

            let roomUUID = try #require(UUID(uuidString: room.roomID.rawValue))
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1 WHERE room_id = \(bind: roomUUID)").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = 1 WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: memberTwoUUID)").run()
            await #expect(throws: V2GroupEventLogError.actorNotMember) {
                try await roomLog.pull(roomID: room.roomID, actorUserID: recipient, afterRoomSequence: 0, pageSize: 10)
            }

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

    @Test("direct room-log command credits are durable, bounded, and cannot oversell a shard window")
    func directRoomLogCommandCreditsPreserveShardCapacity() async throws {
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

            let now = Date(timeIntervalSince1970: 1_750_201_000)
            let leaseID = UUID(uuidString: "00000000-0000-0000-0000-00000000c101")!
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
                VALUES ('rooms-credit-test', 'credit-test', \(bind: leaseID), 1, \(bind: now.addingTimeInterval(600)), 2)
                """).run()
            let state = try ShardAdmissionState(
                lease: .init(
                    id: try .init(leaseID.uuidString), generation: 1,
                    validUntil: now.addingTimeInterval(600),
                    commandWindow: try .init(limit: 2)))
            let credits = V2ShardAdmissionCommandCreditPool(
                database: resources.database(.psql), batchSize: 2
            )

            for expectedEffectiveUsed in 0 ... 1 {
                let acquisition = try await credits.acquire(
                    roomShardID: "rooms-credit-test", capacityProfileID: "credit-test",
                    shardState: state, now: now
                )
                guard case .granted(let token, let effective) = acquisition,
                      let effectiveLease = effective.lease
                else {
                    Issue.record("expected a durable command credit")
                    return
                }
                #expect(effectiveLease.commandWindow.used == expectedEffectiveUsed)
                await credits.commit(token)
            }
            let exhausted = try await credits.acquire(
                roomShardID: "rooms-credit-test", capacityProfileID: "credit-test",
                shardState: state, now: now
            )
            guard case .rateLimited = exhausted else {
                Issue.record("the credit pool oversold the command window")
                return
            }
            let persisted = try #require(try await sql.raw("""
                SELECT command_window_used
                FROM im_v2.shard_admission_pools
                WHERE room_shard_id = 'rooms-credit-test'
                  AND capacity_profile_id = 'credit-test'
                """).first(decoding: CapacityRow.self))
            #expect(persisted.commandWindowUsed == 2)
            #expect(await credits.snapshot() == .init(
                activeCredits: 0, inFlightCredits: 0,
                batchReservations: 1, databaseCreditsReserved: 2,
                committedCredits: 2, returnedCredits: 0,
                expiredCreditsDiscarded: 0, capacityRejections: 1
            ))

            // A micro-batch crosses the credit actor once but preserves the
            // exact per-request result order. Returning the granted prefix is
            // process-local only; the durable row remains conservatively
            // charged and can never be oversold.
            let batchLeaseID = UUID(
                uuidString: "00000000-0000-0000-0000-00000000c102"
            )!
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
                VALUES ('rooms-credit-batch-test', 'credit-batch-test', \(bind: batchLeaseID), 1, \(bind: now.addingTimeInterval(600)), 2)
                """).run()
            let batchState = try ShardAdmissionState(
                lease: .init(
                    id: try .init(batchLeaseID.uuidString), generation: 1,
                    validUntil: now.addingTimeInterval(600),
                    commandWindow: try .init(limit: 2)))
            let batchCredits = V2ShardAdmissionCommandCreditPool(
                database: resources.database(.psql), batchSize: 2
            )
            let batchRequest = V2ShardAdmissionCommandCreditPool.BatchRequest(
                roomShardID: "rooms-credit-batch-test",
                capacityProfileID: "credit-batch-test",
                shardState: batchState,
                now: now
            )
            let firstBatch = try await batchCredits.acquire(
                [batchRequest, batchRequest, batchRequest]
            )
            #expect(firstBatch.count == 3)
            let grantedPrefix: [V2ShardAdmissionCommandCreditPool.Token] =
                firstBatch.compactMap { acquisition in
                guard case .granted(let token, _) = acquisition else { return nil }
                return token
            }
            #expect(grantedPrefix.count == 2)
            guard case .rateLimited = firstBatch[2] else {
                Issue.record("the batched credit pool oversold the shard window")
                return
            }
            await batchCredits.release(grantedPrefix, now: now)

            let reusedBatch = try await batchCredits.acquire([batchRequest, batchRequest])
            let reusedTokens: [V2ShardAdmissionCommandCreditPool.Token] =
                reusedBatch.compactMap { acquisition in
                guard case .granted(let token, _) = acquisition else { return nil }
                return token
            }
            #expect(reusedTokens.count == 2)
            await batchCredits.commit(reusedTokens)
            guard case .rateLimited = try await batchCredits.acquire(
                roomShardID: "rooms-credit-batch-test",
                capacityProfileID: "credit-batch-test",
                shardState: batchState,
                now: now
            ) else {
                Issue.record("returned batch credits were durably oversold")
                return
            }
            #expect(await batchCredits.snapshot() == .init(
                activeCredits: 0, inFlightCredits: 0,
                batchReservations: 1, databaseCreditsReserved: 2,
                committedCredits: 2, returnedCredits: 2,
                expiredCreditsDiscarded: 0, capacityRejections: 2
            ))

            // Concurrent waiters may all observe one completed reservation.
            // Retiring that shared task before returning the grant prevents
            // an exhausted waiter from synchronously re-reading the same
            // completed task forever and monopolizing the credit-pool actor.
            let concurrentLeaseID = UUID(
                uuidString: "00000000-0000-0000-0000-00000000c103"
            )!
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
                VALUES ('rooms-credit-concurrent-test', 'credit-concurrent-test', \(bind: concurrentLeaseID), 1, \(bind: now.addingTimeInterval(600)), 64)
                """).run()
            let concurrentState = try ShardAdmissionState(
                lease: .init(
                    id: try .init(concurrentLeaseID.uuidString), generation: 1,
                    validUntil: now.addingTimeInterval(600),
                    commandWindow: try .init(limit: 64)))
            let concurrentCredits = V2ShardAdmissionCommandCreditPool(
                database: resources.database(.psql), batchSize: 1
            )
            let concurrentTokens = try await withThrowingTaskGroup(
                of: V2ShardAdmissionCommandCreditPool.Token.self,
                returning: [V2ShardAdmissionCommandCreditPool.Token].self
            ) { group in
                for _ in 0..<64 {
                    group.addTask {
                        let acquisition = try await concurrentCredits.acquire(
                            roomShardID: "rooms-credit-concurrent-test",
                            capacityProfileID: "credit-concurrent-test",
                            shardState: concurrentState,
                            now: now
                        )
                        guard case .granted(let token, _) = acquisition else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        return token
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            #expect(concurrentTokens.count == 64)
            await concurrentCredits.commit(concurrentTokens)
            let concurrentSnapshot = await concurrentCredits.snapshot()
            #expect(concurrentSnapshot.batchReservations == 64)
            #expect(concurrentSnapshot.databaseCreditsReserved == 64)
            #expect(concurrentSnapshot.committedCredits == 64)

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

}

private struct EdgeClientRateLimitKeyRow: Decodable {
    let clientKey: String
    enum CodingKeys: String, CodingKey { case clientKey = "client_key" }
}
private struct DirectBatchProjectionSyncAssertionRow: Decodable {
    let userID: UUID
    let userSyncSequence: Int64
    let sourceEventID: UUID
    let projectionKind: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case userSyncSequence = "user_sync_sequence"
        case sourceEventID = "source_event_id"
        case projectionKind = "projection_kind"
    }
}
private struct PasswordAuthenticationAuditRow: Decodable {
    let outcome: String
    let userID: UUID?
    let deviceID: UUID
    let occurredAt: Date

    enum CodingKeys: String, CodingKey {
        case outcome
        case userID = "user_id"
        case deviceID = "device_id"
        case occurredAt = "occurred_at"
    }
}
private struct ProfilePropagationOutboxRow: Decodable {
    let state: String
    let checkpointed: Bool
}
private struct ProfilePropagationCompletedRow: Decodable {
    let state: String
    let completed: Bool
}
private struct ProfileInvalidationAssertionRow: Decodable {
    let recipientUserID: UUID
    let invalidatedUserID: UUID
    let minimumProfileRevision: Int64

    enum CodingKeys: String, CodingKey {
        case recipientUserID = "user_id"
        case invalidatedUserID = "user_id_payload"
        case minimumProfileRevision = "minimum_profile_revision"
    }
}
private struct ProjectionRecipientAssertionRow: Decodable {
    let userID: UUID
    enum CodingKeys: String, CodingKey { case userID = "user_id" }
}
private struct ProfileSuspensionInvalidationAssertionRow: Decodable {
    let recipientUserID: UUID
    let profileState: String
    let minimumProfileRevision: Int64
    enum CodingKeys: String, CodingKey {
        case recipientUserID = "user_id"
        case profileState = "profile_state"
        case minimumProfileRevision = "minimum_profile_revision"
    }
}
private struct ProfilePropagationFailingProjectionDelivery: V2UserShardProjectionDelivering {
    func deliverToCurrentShard(
        userID _: UserID,
        sourceEventID _: EventID,
        projectionKinds _: Set<String>
    ) async throws -> UInt64? {
        throw ProfilePropagationShadowFailure.interrupted
    }
}
private struct DirectMessageRowEventRow: Decodable {
    let acceptedEventID: UUID
    let acceptedEventStorage: String
    let acceptedMembershipRevision: Int64
    enum CodingKeys: String, CodingKey {
        case acceptedEventID = "accepted_event_id"
        case acceptedEventStorage = "accepted_event_storage"
        case acceptedMembershipRevision = "accepted_membership_revision"
    }
}
