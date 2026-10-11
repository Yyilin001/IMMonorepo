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
    @Test("password fallback failure limits persist across account-service instances")
    func persistsPasswordLoginFailureLimit() async throws {
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
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
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
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
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
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
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
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
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
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
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
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
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            // The owner transaction retains its only connection while reading
            // control identity. A separate same-database pool prevents self-wait.
            let identityDatabaseID = DatabaseID(string: "direct-profile-identity")
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: identityDatabaseID)
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

            let directService = try V2DirectRoomOperationTestFixture(
                store: PostgresV2DirectMessagingStore(database: resources.database(.psql), identityReader: PostgresV2DirectRoomIdentityReader(database: resources.database(identityDatabaseID)), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: capacityProfile, roomShardID: "rooms-primary", now: { now }
            )
            var directRoomIDs: [RoomID] = []
            for peer in [firstPeerUUID, secondPeerUUID] {
                let room = try await directService.openedIdentity(
                    actorUserID: sourceUserID, operationID: try .init(UUID().uuidString),
                    targetUserID: try .init(peer.uuidString)
                , firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
                directRoomIDs.append(room.roomID)
            }
            // A direct peer becomes visible only once the first eligible
            // message commits. Seed that state here so this test exercises
            // display-name propagation for real conversations, rather than
            // leaking an unopened stranger-initiated room.
            let directMessages = V2SendMessageService(
                store: V2PolicyAuthorizedTestWriteStore(database: resources.database(.psql),
                    controlDatabase: resources.database(identityDatabaseID),
                    store: PostgresV2RoomWriteStore(database: resources.database(.psql),
                        strangerMessagePolicy: try .init(maximumMessagesPerWindow: 3, window: 86_400)),
                    shardID: "rooms-primary", epoch: 0),
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

            // Direct creation samples elapsed owner time, so its opening events
            // can become eligible after the fixed first-message fixture clock.
            struct ProjectionEligibility: Decodable { let value: Date }
            let eligibleAt = try #require(try await sql.raw("SELECT MAX(next_attempt_at) AS value FROM im_v2.user_state_event_outbox").first(decoding: ProjectionEligibility.self)).value
            let personalWorker = V2UserStateEventWorker(
                outbox: try PostgresV2UserStateEventOutbox(database: resources.database(.psql)),
                projector: try PostgresV2UserStateEventProjector(database: resources.database(.psql)), now: { eligibleAt })
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
            let disabled = try await withFixturePolicyOwners(database: resources.database(.psql),
                projectionDelivery: SuccessfulProjectionDelivery()) { owners in
                let service = try V2PostgresAccountDisableService(operatorPrincipal: "account-safety-primary", policyOwners: owners)
                return try await service.disable(.init(userID: sourceUserID,
                    operationID: disableOperationID, reason: .policyEnforcement))
            }
            guard case .disabled(let disabledAt) = disabled else {
                throw V2AccountDisableError.unavailable
            }
            let persistedDisable = try #require(try await sql.raw("""
                SELECT disabled_at AS value FROM im_v2.account_disables
                WHERE user_id = \(bind: sourceUUID) AND operation_id = \(bind: disableOperationID)
                """).first(decoding: ProjectionEligibility.self)).value
            #expect(disabledAt == persistedDisable)
            let suspensionWorker = V2DirectRoomProfilePropagationWorker(
                database: resources.database(.psql), projectionDelivery: shadow, now: Date.init)
            let suspensionReport = try await suspensionWorker.runOnce(limit: 8)
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
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
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
                store: V2PolicyAuthorizedTestWriteStore(database: resources.database(.psql),
                    controlDatabase: resources.database(.psql),
                    store: PostgresV2RoomWriteStore(database: resources.database(.psql)),
                    shardID: "room-a", epoch: 0),
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
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
        else { return }

        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            // The owner transaction retains its only connection while reading
            // control identity. A separate same-database pool prevents self-wait.
            let identityDatabaseID = DatabaseID(string: "direct-log-identity")
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: identityDatabaseID)
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)

            let now = Date()
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
            let direct = try V2DirectRoomOperationTestFixture(
                store: PostgresV2DirectMessagingStore(database: resources.database(.psql), identityReader: PostgresV2DirectRoomIdentityReader(database: resources.database(identityDatabaseID)), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: profile,
                roomShardID: "rooms-primary",
                now: { now }
            )
            let policyOwners = PostgresV2PolicyOwnerDirectory(journal: .init(database: resources.database(identityDatabaseID)),
                dispatcher: .init(database: resources.database(identityDatabaseID), projectionDelivery: SuccessfulProjectionDelivery()))
            do {
            let recipient = try UserID(memberTwoUUID.uuidString)
            let room = try await direct.openedIdentity(
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-00000000c002"),
                targetUserID: recipient
            , firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let secondRoom = try await direct.openedIdentity(
                actorUserID: senderID,
                operationID: try .init("00000000-0000-0000-0000-00000000c005"),
                targetUserID: try .init(memberThreeUUID.uuidString)
            , firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
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
            func selected(_ local: PostgresV2RoomWriteStore) -> V2PolicyAuthorizedTestWriteStore {
                .init(database: resources.database(.psql), controlDatabase: resources.database(identityDatabaseID),
                    store: local, shardID: "rooms-primary", epoch: 0, activationScope: activationScope)
            }
            let isolatingWriterLocal = PostgresV2RoomWriteStore(
                database: resources.database(.psql),
                strangerMessagePolicy: try .init(
                    maximumMessagesPerWindow: 10, window: 86_400
                ),
                contentReviewMode: .disabled)
            let isolatingWriter = selected(isolatingWriterLocal)
            let legacyProfile = try V2CapacityProfile(
                id: "legacy-test",
                limits: profile.limits
            )
            let invalidProfileRequest = V2RoomWriteRequest(
                command: try .init(roomID: secondRoom.roomID, senderUserID: senderID,
                    clientMessageID: .init("00000000-0000-0000-0000-00000000c054"),
                    text: "错误配置输入", limits: .init(maxUTF8Bytes: 64)),
                capacityProfile: legacyProfile,
                identifiers: try .init(messageID: .init("00000000-0000-0000-0000-00000000c055"),
                    eventID: .init("00000000-0000-0000-0000-00000000c056")), now: now)
            await #expect(throws: V2RoomWriteStoreError.capacityProfileMismatch) {
                try await isolatingWriter.accept(command: invalidProfileRequest.command,
                    capacityProfile: invalidProfileRequest.capacityProfile,
                    identifiers: invalidProfileRequest.identifiers, now: invalidProfileRequest.now)
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
                contentReviewMode: .disabled)
            let writer = selected(writerLocal)
            let messages = V2SendMessageService(
                store: writer, capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64), now: { now }
            )
            // Each room initializes its actual policy state before its independent write.
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
            var coldBatched: [V2SendMessageOutcome] = []
            for request in coldRequests {
                coldBatched.append(try await writer.accept(command: request.command,
                    capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: request.now))
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
            let coldLeases = try await deliverUserStateEvents(coldOutbox, projector: coldProjector, now: deliveryTime, leaseDuration: 30, limit: 1024)
                .filter { coldSources.contains($0.event.sourceEventID.rawValue) }
            #expect(coldLeases.count == 4)
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
            let clientID = try ClientMessageID("00000000-0000-0000-0000-00000000c003")
            guard case .accepted(let accepted) = try await messages.send(.init(
                roomID: room.roomID, actorUserID: senderID, clientMessageID: clientID,
                text: "只写一次的私聊"
            )) else {
                Issue.record("expected room-log acceptance")
                throw CancellationError()
            }

            let replay = try await messages.send(.init(
                roomID: room.roomID, actorUserID: senderID, clientMessageID: clientID,
                text: "只写一次的私聊"
            ))
            guard case .idempotent(let replayed) = replay else {
                Issue.record("expected idempotent replay")
                throw CancellationError()
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
                throw CancellationError()
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
            // hit with a second-room miss, exercising the complete-path fallback.
            guard case .accepted = try await messages.send(.init(
                roomID: room.roomID, actorUserID: senderID,
                clientMessageID: try .init("00000000-0000-0000-0000-00000000c021"),
                text: "关系变更后的缓存回填"
            )) else {
                Issue.record("expected first post-revision cache warm acceptance")
                throw CancellationError()
            }
            let mixedPolicyRequests: [V2RoomWriteRequest] = [
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
            var mixedPolicyBatch: [V2SendMessageOutcome] = []
            for request in mixedPolicyRequests {
                mixedPolicyBatch.append(try await writer.accept(command: request.command,
                    capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: request.now))
            }
            #expect(mixedPolicyBatch.allSatisfy {
                if case .accepted(let message) = $0 { return message.roomSequence > 0 && message.sourceEventID != nil }
                return false
            })
            let projectionRecordsBeforeSteadyStateBatch = try await sql.raw("""
                SELECT COUNT(*)::bigint AS value
                FROM im_v2.user_sync_log
                WHERE projection_kind IN ('direct_sending_capability', 'direct_room_profile')
                """).first(decoding: CountRow.self)
            if actorScoped {
                let beforeMessages = try await count("im_v2.messages", on: sql)
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: secondRoom.roomID.uuidValue!)").run()
                await #expect(throws: V2RoomActivationLeaseError.ownerChanged) {
                    let request = coldRequests[1]
                    _ = try await writer.accept(command: request.command, capacityProfile: request.capacityProfile,
                        identifiers: request.identifiers, now: request.now)
                }
                #expect(try await count("im_v2.messages", on: sql) == beforeMessages)
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=0 WHERE room_id=\(bind: secondRoom.roomID.uuidValue!)").run()
            }
            let steadyRequests: [V2RoomWriteRequest] = [
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
            ]
            var batched: [V2SendMessageOutcome] = []
            for request in steadyRequests {
                batched.append(try await writer.accept(command: request.command,
                    capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: request.now))
            }
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
            // Sequential room turns preserve consecutive committed room sequences.
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
            var sameRoomBatch: [V2SendMessageOutcome] = []
            for request in sameRoomRequests {
                sameRoomBatch.append(try await writer.accept(command: request.command,
                    capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: request.now))
            }
            guard case .accepted(let firstSameRoomMessage) = sameRoomBatch[0],
                  case .accepted(let secondSameRoomMessage) = sameRoomBatch[1],

                  secondSameRoomMessage.roomSequence == firstSameRoomMessage.roomSequence + 1
            else {
                Issue.record("expected ordered hot direct fallback acceptance")
                throw CancellationError()
            }
            let hotRoomAdmission = try #require(try await sql.raw("""
                SELECT command_window_used
                FROM im_v2.room_admission
                WHERE room_id = \(bind: UUID(uuidString: room.roomID.rawValue)!)
                """).first(decoding: CapacityRow.self))
            #expect(hotRoomAdmission.commandWindowUsed == 0)

            try await sql.raw("""
                DELETE FROM im_v2.user_relationships
                WHERE lower_user_id = \(bind: senderUUID)
                  AND higher_user_id IN (\(bind: memberTwoUUID), \(bind: memberThreeUUID))
                """).run()

            // Rich messages retain the existing CTE: the plain-message fast
            // path must never silently skip a required moderation record.
            let reviewingMessages = V2SendMessageService(
                store: selected(PostgresV2RoomWriteStore(
                    database: resources.database(.psql),
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
                    contentReviewMode: .enabled)),
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
                throw CancellationError()
            }
            #expect(try await count("im_v2.content_review_jobs", on: sql) == 1)

            _ = try await PostgresV2AccountPreferenceOperationStore(database: resources.database(.psql), projectionDelivery: SuccessfulProjectionDelivery(), policyOwners: policyOwners).executePreferenceFixture(owner: recipient, operation: .strangerMessagePreference(try .init("00000000-0000-0000-0000-00000000c005")), value: .strangerMessage(.deny), now: now)
            await #expect(throws: V2SendOperationResponseError.directPolicyDenied) {
                _ = try await messages.send(.init(
                    roomID: room.roomID, actorUserID: senderID,
                    clientMessageID: .init("00000000-0000-0000-0000-00000000c006"),
                    text: "策略变更后必须被拒绝"))
            }
            #expect(try await retiredDirectDenialTableIsAbsent(on: sql))

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
            let roomAdmission = try #require(try await sql.raw("""
                SELECT command_window_used
                FROM im_v2.room_admission
                WHERE room_id = \(bind: UUID(uuidString: room.roomID.rawValue)!)
                """).first(decoding: CapacityRow.self))
            #expect(roomAdmission.commandWindowUsed == 0)

            // Warm the actual cached append, then corrupt membership without
            // changing its revision. A cache revision match must not authorize
            // a third participant, and the conditional failure must roll back.
            for _ in 0..<2 {
                guard case .accepted = try await messages.send(.init(
                    roomID: secondRoom.roomID, actorUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "membership fence warmup"
                )) else {
                    Issue.record("expected membership-fence warmup acceptance")
                    throw CancellationError()
                }
            }
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
            await policyOwners.shutdown()
            } catch {
                await policyOwners.shutdown()
                throw error
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
