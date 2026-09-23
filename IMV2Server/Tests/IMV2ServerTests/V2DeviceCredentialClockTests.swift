import FluentPostgresDriver
import FluentKit
import Foundation
import IMV2Core
import NIOCore
import PostgresNIO
import SQLKit
import Synchronization
import Testing
@testable import IMV2Server

@Suite("Device service clock validation order")
struct V2DeviceCredentialClockTests {
    private static let invalidSeconds: [Double] = [
        .nan, .infinity, -.infinity, .greatestFiniteMagnitude,
        -.greatestFiniteMagnitude, 1e14, -1e14,
        -210_866_803_201, 9_224_318_016_000,
    ]

    @Test("Invalid entry clocks stop before generation or transaction; corrected clocks reach the database boundary",
          arguments: ["registration", "cancellable", "refresh"])
    func entryClock(operation: String) async throws {
        try await withClockDatabase { database in
            let state = DeviceClockState()
            let service = try makeService(database, state: state)
            let request = V2TrustedDeviceRegistration(userID: .init(uuid: UUID()),
                deviceID: .init(uuid: UUID()), operationID: UUID())
            let cancellable = try V2CancellableDeviceRegistration(registration: request, cancellation: .init(
                deviceID: request.deviceID, operationID: request.operationID,
                proof: .init(rawValue: "imv2-cancel-registration-v1." + String(repeating: "A", count: 43)),
                issueBeforeMilliseconds: 1_750_000_060_000))
            let refresh = try V2DeviceCredentialRefresh(userID: request.userID, deviceID: request.deviceID,
                refreshCredential: "clock-test-placeholder", revocationCredential: fixtureRevocationCredential,
                operationID: request.operationID)
            @Sendable func invoke() async throws {
                switch operation {
                case "registration": _ = try await service.register(request)
                case "cancellable": _ = try await service.register(cancellable)
                default: _ = try await service.refresh(refresh)
                }
            }

            for seconds in Self.invalidSeconds {
                state.clock.withLock { $0 = Date(timeIntervalSince1970: seconds) }
                await #expect(throws: V2DeviceCredentialServiceError.unavailable) { try await invoke() }
            }
            #expect(state.generated.withLock { $0 } == 0)
            #expect(database.transactions.withLock { $0 } == 0)

            state.clock.withLock { $0 = Date(timeIntervalSince1970: 1_750_000_000) }
            // The fixture aborts here without running a transaction body.
            await #expect(throws: ClockDatabaseStop.boundary) { try await invoke() }
            #expect(state.generated.withLock { $0 } == 2)
            #expect(database.transactions.withLock { $0 } == 1)
            #expect(database.dates.withLock { $0.isEmpty })
        }
    }

    @Test("Registration rechecks the clock after its locked device lookup")
    func clockChangesDuringLookup() async throws {
        try await withClockDatabase { database in
            let state = DeviceClockState()
            let service = try makeService(database, state: state)
            let request = V2TrustedDeviceRegistration(userID: .init(uuid: UUID()),
                deviceID: .init(uuid: UUID()), operationID: UUID())
            for seconds in Self.invalidSeconds {
                state.clock.withLock { $0 = Date(timeIntervalSince1970: 1_750_000_000) }
                database.afterDeviceLookup.withLock { callback in
                    callback = { state.clock.withLock { $0 = Date(timeIntervalSince1970: seconds) } }
                }
                await #expect(throws: V2DeviceCredentialServiceError.unavailable) {
                    try await service.register(request)
                }
            }
            #expect(database.dates.withLock { $0.isEmpty })

            // A valid post-lock observation, rather than the entry sample,
            // must supply the active-device query's timestamp.
            let observed = Date(timeIntervalSince1970: 1_750_000_010.25)
            state.clock.withLock { $0 = Date(timeIntervalSince1970: 1_750_000_000) }
            database.afterDeviceLookup.withLock { callback in
                callback = { state.clock.withLock { $0 = observed } }
            }
            await #expect(throws: ClockDatabaseStop.boundary) { try await service.register(request) }
            #expect(database.dates.withLock { $0 } == [observed])
        }
    }

    @Test("Registration validates all derived deadlines before its first write",
          arguments: ["session-overflow", "replay-overflow", "replay-disappears", "access-disappears", "refresh-disappears"])
    func derivedDeadlines(failure: String) async throws {
        try await withClockDatabase { database in
            let state = DeviceClockState()
            let observed = Date(timeIntervalSince1970: failure == "session-overflow"
                ? 9_224_318_015_970 : 1_750_000_000)
            state.clock.withLock { $0 = observed }
            database.afterDeviceLookup.withLock { $0 = {} }
            database.allowsTimestampReads.withLock { $0 = true }
            let service = try makeService(database, state: state,
                accessLifetime: failure == "access-disappears" ? 1e-12 : 30,
                refreshLifetime: failure == "refresh-disappears" ? 1e-12 : 30,
                replayWindow: failure == "replay-overflow" ? .greatestFiniteMagnitude
                    : failure == "replay-disappears" ? 1e-12 : 30,
                maximumSessionLifetime: 60)
            let request = V2TrustedDeviceRegistration(userID: .init(uuid: UUID()),
                deviceID: .init(uuid: UUID()), operationID: UUID())
            await #expect(throws: V2DeviceCredentialServiceError.unavailable) {
                try await service.register(request)
            }
            #expect(database.writes.withLock { $0 } == 0)

            // Corrected time/configuration may reach the intercepted INSERT.
            // The spy still prevents actual persistence or issuance.
            state.clock.withLock { $0 = Date(timeIntervalSince1970: 1_750_000_000) }
            let corrected = try makeService(database, state: state, maximumSessionLifetime: 60)
            await #expect(throws: ClockDatabaseStop.boundary) { try await corrected.register(request) }
            #expect(database.writes.withLock { $0 } == 1)
        }
    }


    @Test("Session generation is checked before mutation and its exact successor is bound",
          arguments: [Int64.min, -1, 0, 1, Int64.max - 1, Int64.max])
    func sessionGeneration(generation: Int64) async throws {
        try await withClockDatabase { database in
            let state = DeviceClockState()
            let user = UUID(), device = UUID()
            let expiry = Date(timeIntervalSince1970: 1_750_000_600)
            try prepareRefreshDatabase(database, user: user, expiry: expiry, generation: generation)
            let service = try makeService(database, state: state)
            let request = try V2DeviceCredentialRefresh(userID: .init(uuid: user), deviceID: .init(uuid: device),
                refreshCredential: "clock-test-placeholder", revocationCredential: fixtureRevocationCredential,
                operationID: UUID())
            if generation <= 0 {
                await #expect(throws: V2DeviceCredentialServiceError.malformedPersistence) { try await service.refresh(request) }
                #expect(database.writes.withLock { $0 } == 0)
            } else if generation == Int64.max {
                await #expect(throws: V2DeviceCredentialServiceError.unavailable) { try await service.refresh(request) }
                #expect(database.writes.withLock { $0 } == 0)
            } else {
                // Neither statement reaches a real driver. The empty history
                // response lets us inspect the next UPDATE's bound generation.
                await #expect(throws: ClockDatabaseStop.boundary) { try await service.refresh(request) }
                #expect(database.writes.withLock { $0 } == 2)
                #expect(database.generationUpdates.withLock { $0 } == [generation + 1])
            }
        }
    }
    @Test("Refresh observes the clock after account and device waits",
          arguments: ["account-lock", "device-lookup"], ["invalid", "expired", "advanced"])
    func refreshClockAfterWait(stage: String, scenario: String) async throws {
        try await withClockDatabase { database in
            let state = DeviceClockState()
            let user = UUID(), device = UUID()
            let expiry = Date(timeIntervalSince1970: 1_750_000_600)
            try prepareRefreshDatabase(database, user: user, expiry: expiry)
            let service = try makeService(database, state: state)
            let request = try V2DeviceCredentialRefresh(userID: .init(uuid: user), deviceID: .init(uuid: device),
                refreshCredential: "clock-test-placeholder", revocationCredential: fixtureRevocationCredential,
                operationID: UUID())
            let samples: [Double] = scenario == "invalid" ? Self.invalidSeconds
                : [scenario == "expired" ? expiry.timeIntervalSince1970 : 1_750_000_002.5]
            for seconds in samples {
                state.clock.withLock { $0 = Date(timeIntervalSince1970: 1_750_000_000) }
                let afterWait: @Sendable () -> Void = {
                    state.clock.withLock { $0 = Date(timeIntervalSince1970: seconds) }
                }
                if stage == "account-lock" {
                    database.afterAccountLock.withLock { $0 = afterWait }
                } else {
                    database.afterDeviceLookup.withLock { $0 = afterWait }
                }
                switch scenario {
                case "invalid":
                    await #expect(throws: V2DeviceCredentialServiceError.unavailable) { try await service.refresh(request) }
                    #expect(database.writes.withLock { $0 } == 0)
                case "expired":
                    #expect(try await service.refresh(request) == .terminalRejection)
                    #expect(database.writes.withLock { $0 } == 0)
                default:
                    await #expect(throws: ClockDatabaseStop.boundary) { try await service.refresh(request) }
                    #expect(database.dates.withLock { $0 } == [Date(timeIntervalSince1970: seconds), expiry])
                }
            }
        }
    }
}

@Suite("Password budget clock precision")
struct V2PasswordBudgetClockTests {
    @Test("Window accounting handles the full timestamp span and backward clocks", arguments: [false, true])
    func fullWindowSpan(backward: Bool) async throws {
        try await withClockDatabase { database in
            let early = try nativeClockTimestamp(-211_813_487_000_000_001)
            let late = try nativeClockTimestamp(9_223_371_330_199_999_999)
            let current = backward ? early : late, start = backward ? late : early
            database.rows.withLock { $0 = [
                "SELECT clock_timestamp() AS current": .init(timestamps: ["current": current]),
                "SELECT window_started_at, failure_count, blocked_until": .init(
                    columns: ["failure_count": Data("3".utf8)], timestamps: ["window_started_at": start]),
            ] }
            database.afterDeviceLookup.withLock { $0 = {} }
            database.allowsTimestampReads.withLock { $0 = true }
            let limiter = V2PostgresPasswordLoginAttemptLimiter(database: database,
                policy: try .init(maximumFailures: 10, window: 60.5, lockout: 60))
            await #expect(throws: ClockDatabaseStop.boundary) {
                try await limiter.recordRejectedAttempt(accountHandle: "precision-budget", userID: nil, deviceID: .init(uuid: UUID()))
            }
            #expect(database.budgetCounts.withLock { $0 } == [backward ? 4 : 1])
            #expect(database.timestampBindings.withLock { $0 } == [backward ? start.microseconds : current.microseconds, current.microseconds])
        }
    }

    @Test("Audit persistence retains native clock samples without a Date round trip",
          arguments: [Int64(-211_813_488_000_000_000), -1, 0, 803_315_200_125_001, 9_223_371_331_199_999_999])
    func auditTimestamp(microseconds: Int64) async throws {
        try await withClockDatabase { database in
            let observed = try nativeClockTimestamp(microseconds)
            await #expect(throws: ClockDatabaseStop.boundary) {
                try await recordPasswordAuthenticationAudit(outcome: .assertionRejected, userID: nil,
                    deviceID: .init(uuid: UUID()), occurredAt: observed, on: database)
            }
            #expect(database.timestampBindings.withLock { $0 } == [microseconds])
            #expect(database.writes.withLock { $0 } == 1)
        }
    }

    @Test("Date-based audit callers keep timestamp validation and encoding")
    func dateAuditTimestamp() async throws {
        try await withClockDatabase { database in
            let device = DeviceID(uuid: UUID())
            for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1e14, 1e14] {
                await #expect(throws: V2PasswordAuthenticationAuditError.invalidTimestamp) {
                    try await recordPasswordAuthenticationAudit(outcome: .registrationSucceeded, userID: nil,
                        deviceID: device, occurredAt: Date(timeIntervalSince1970: seconds), on: database)
                }
            }
            #expect(database.writes.withLock { $0 } == 0)
            let observed = Date(timeIntervalSince1970: 1_750_000_000.125)
            await #expect(throws: ClockDatabaseStop.boundary) {
                try await recordPasswordAuthenticationAudit(outcome: .registrationSucceeded, userID: nil,
                    deviceID: device, occurredAt: observed, on: database)
            }
            let encoded = try V2PostgresTimestamp(date: observed)
            #expect(database.timestampBindings.withLock { $0 } == [encoded.microseconds])
            #expect(database.writes.withLock { $0 } == 1)
        }
    }

    @Test("Budget windows use native cutoff boundaries and preserve their original start",
          arguments: [Int64(803_315_200_125_001), 101, -101, -211_813_487_000_000_001, 9_223_371_330_199_999_999],
          [Int64(-1), 0, 1])
    func windowBoundary(currentMicroseconds: Int64, adjustment: Int64) async throws {
        try await withClockDatabase { database in
            let current = try nativeClockTimestamp(currentMicroseconds)
            let start = try nativeClockTimestamp(currentMicroseconds - 60_500_000 + adjustment)
            database.rows.withLock { $0 = [
                "SELECT clock_timestamp() AS current": .init(timestamps: ["current": current]),
                "SELECT window_started_at, failure_count, blocked_until": .init(
                    columns: ["failure_count": Data("3".utf8)], timestamps: ["window_started_at": start]),
            ] }
            database.afterDeviceLookup.withLock { $0 = {} }
            database.allowsTimestampReads.withLock { $0 = true }
            let limiter = V2PostgresPasswordLoginAttemptLimiter(database: database,
                policy: try .init(maximumFailures: 10, window: 60.5, lockout: 60))
            await #expect(throws: ClockDatabaseStop.boundary) {
                try await limiter.recordRejectedAttempt(accountHandle: "precision-budget", userID: nil, deviceID: .init(uuid: UUID()))
            }
            #expect(database.budgetCounts.withLock { $0 } == [adjustment > 0 ? 4 : 1])
            #expect(database.timestampBindings.withLock { $0.first } == (adjustment > 0 ? start.microseconds : current.microseconds))
        }
    }

    @Test("A still-active native lockout remains a read-only decision",
          arguments: [Int64(803_315_200_125_001), -211_813_487_000_000_001, 9_223_371_330_199_999_999])
    func activeLockoutBoundary(currentMicroseconds: Int64) async throws {
        try await withClockDatabase { database in
            let current = try nativeClockTimestamp(currentMicroseconds)
            let start = try nativeClockTimestamp(currentMicroseconds - 1_000_000)
            let deadline = try nativeClockTimestamp(currentMicroseconds + 1)
            database.rows.withLock { $0 = [
                "SELECT clock_timestamp() AS current": .init(timestamps: ["current": current]),
                "SELECT window_started_at, failure_count, blocked_until": .init(columns: ["failure_count": Data("3".utf8)],
                    timestamps: ["window_started_at": start, "blocked_until": deadline]),
            ] }
            database.afterDeviceLookup.withLock { $0 = {} }
            database.allowsTimestampReads.withLock { $0 = true }
            let limiter = V2PostgresPasswordLoginAttemptLimiter(database: database,
                policy: try .init(maximumFailures: 10, window: 60.5, lockout: 60))
            try await limiter.recordRejectedAttempt(accountHandle: "precision-budget", userID: nil, deviceID: .init(uuid: UUID()))
            #expect(database.writes.withLock { $0 } == 0)
        }
    }

    @Test("Retry-After keeps native microseconds at whole-second boundaries",
          arguments: [Int64(803_315_200_125_001), -1, 0, -211_813_487_999_999_999, 9_223_371_330_199_999_999],
          [Int64(-1), 0, 1])
    func retryAfterPrecision(currentMicroseconds: Int64, adjustment: Int64) async throws {
        try await withClockDatabase { database in
            let current = try nativeClockTimestamp(currentMicroseconds)
            let deadline = try nativeClockTimestamp(currentMicroseconds + 1_000_000 + adjustment)
            database.rows.withLock { $0 = [
                "SELECT clock_timestamp() AS current": .init(timestamps: ["current": current]),
                "SELECT blocked_until FROM im_v2.account_password_login_rate_limits": .init(timestamps: ["blocked_until": deadline]),
            ] }
            let limiter = V2PostgresPasswordLoginAttemptLimiter(database: database,
                policy: try .init(maximumFailures: 1, window: 60, lockout: 60))
            #expect(try await limiter.blockedRetryAfterSeconds(accountHandle: "precision-budget") == (adjustment > 0 ? 2 : 1))
            #expect(database.writes.withLock { $0 } == 0)
        }
    }

    @Test("Retry-After handles full timestamp span and expired limits without overflow")
    func retryAfterFullRange() async throws {
        try await withClockDatabase { database in
            let samples: [(Int64, Int64, Int?)] = [
                (-211_813_488_000_000_000, 9_223_371_331_199_999_999, 9_435_184_819_200),
                (-1_000_001, 0, 2), (-999_999, 999_999, 2), (-1_000_001, 999_999, 2),
                (-1, 1, 1), (1, 1, nil), (1, 0, nil),
            ]
            let limiter = V2PostgresPasswordLoginAttemptLimiter(database: database,
                policy: try .init(maximumFailures: 1, window: 60, lockout: 60))
            for (start, end, expected) in samples {
                let current = try nativeClockTimestamp(start), deadline = try nativeClockTimestamp(end)
                database.rows.withLock { $0 = [
                    "SELECT clock_timestamp() AS current": .init(timestamps: ["current": current]),
                    "SELECT blocked_until FROM im_v2.account_password_login_rate_limits": .init(timestamps: ["blocked_until": deadline]),
                ] }
                #expect(try await limiter.blockedRetryAfterSeconds(accountHandle: "precision-budget") == expected)
            }
            #expect(database.writes.withLock { $0 } == 0)
        }
    }

    @Test("A lockout must remain strictly future after timestamp encoding",
          arguments: [1_750_000_000.125, 946_684_800.25, -210_866_802_200, 9_224_318_015_000],
          [1e-12, 0.0000001])
    func lockoutPrecision(seconds: Double, duration: Double) async throws {
        try await withClockDatabase { database in
            let current = Date(timeIntervalSince1970: seconds)
            let nativeCurrent = try V2PostgresTimestamp(date: current)
            let row = ClockSQLRow(timestamps: ["current": nativeCurrent])
            database.rows.withLock { $0 = ["SELECT clock_timestamp() AS current": row] }
            database.afterDeviceLookup.withLock { $0 = {} }
            database.allowsTimestampReads.withLock { $0 = true }
            let limiter = V2PostgresPasswordLoginAttemptLimiter(database: database,
                policy: try .init(maximumFailures: 1, window: 60, lockout: duration))
            let device = DeviceID(uuid: UUID())
            await #expect(throws: V2PasswordLoginRateLimitError.unavailable) {
                try await limiter.recordRejectedAttempt(accountHandle: "precision-budget", userID: nil, deviceID: device)
            }
            #expect(database.writes.withLock { $0 } == 0)
            #expect(database.dates.withLock { $0.isEmpty })

            // Subsecond lockouts remain supported when their encoded
            // deadline advances. The fixture intercepts the first INSERT.
            let valid = V2PostgresPasswordLoginAttemptLimiter(database: database,
                policy: try .init(maximumFailures: 1, window: 60, lockout: 0.5))
            await #expect(throws: ClockDatabaseStop.boundary) {
                try await valid.recordRejectedAttempt(accountHandle: "precision-budget", userID: nil, deviceID: device)
            }
            #expect(database.writes.withLock { $0 } == 1)
            let deadline = try V2PostgresTimestamp(date: nativeCurrent.date.addingTimeInterval(0.5))
            #expect(database.timestampBindings.withLock { $0 } == [nativeCurrent.microseconds, deadline.microseconds, nativeCurrent.microseconds])
        }
    }
}

@Suite("Live presence lease duration precision")
struct V2LivePresenceLeaseDurationTests {
    @Test("A positive lease duration must survive database precision before any write",
          arguments: [Double(-1.0005), -1_000_000_000.1255, -210_866_803_199.1255, 1_750_000_000.1255],
          ["admit", "renew", "batch"])
    func vanishedDuration(seconds: Double, path: String) async throws {
        try await withClockDatabase { database in
            let now = Date(timeIntervalSince1970: seconds)
            let duration = 1e-12
            #expect(now.addingTimeInterval(duration) == now)
            let identity = V2AuthenticatedConnection(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), capabilityProfile: "base")
            let connection = UUID()
            let policy = V2AuthenticatedConnectionAdmissionPolicy(maximumConnectionsPerDevice: 2, maximumConnectionsPerUser: 8)
            let request = V2LivePresenceLeaseRenewalRequest(identity: identity, connectionID: connection, now: now)
            let tiny = try PostgresV2LiveActivityStore(database: database, onlineLease: duration)
            if path == "batch" {
                let result = try await tiny.renewConnections([request])
                #expect(result[connection] == .init(outcome: .rejected, allowsOnlinePresence: false))
            } else {
                await #expect(throws: V2LiveActivityStoreError.corruptPersistenceState) {
                    if path == "admit" {
                        _ = try await tiny.admitConnection(identity: identity, connectionID: connection, policy: policy, now: now)
                    } else { _ = try await tiny.renewConnection(identity: identity, connectionID: connection, now: now) }
                }
            }
            #expect(database.transactions.withLock { $0 } == 0)
            #expect(database.writes.withLock { $0 } == 0)

            let valid = try PostgresV2LiveActivityStore(database: database, onlineLease: 0.5)
            await #expect(throws: ClockDatabaseStop.boundary) {
                if path == "admit" {
                    _ = try await valid.admitConnection(identity: identity, connectionID: connection, policy: policy, now: now)
                } else if path == "renew" {
                    _ = try await valid.renewConnection(identity: identity, connectionID: connection, now: now)
                } else { _ = try await valid.renewConnections([request]) }
            }
            #expect(database.transactions.withLock { $0 } == (path == "admit" ? 1 : 0))
            #expect(database.writes.withLock { $0 } == (path == "admit" ? 0 : 1))
        }
    }
}

@Suite("Room credit heat elapsed time")
struct V2RoomCreditHeatClockTests {
    @Test("Batched commits restart promotion after an idle window")
    func idleWindowRestartsPromotion() async throws {
        try await withClockDatabase { database in
            let clock = Mutex(ContinuousClock.now)
            let pool = V2RoomAdmissionCommandCreditPool(database: database, batchSize: 8,
                monotonicNow: { clock.withLock { $0 } })
            let first = UUID(), second = UUID(), wall = Date()
            await pool.recordNormalAdmissionCommits(
                Array(repeating: (first, wall), count: 4) + Array(repeating: (second, wall), count: 3))
            #expect(await pool.shouldUseCredits(roomIDs: [first, second], now: wall) == [true, false])

            clock.withLock { $0 = $0.advanced(by: .milliseconds(5_001)) }
            // A commit must reset an idle room even if no admission lookup
            // or metrics sweep has removed its old heat record yet.
            await pool.recordNormalAdmissionCommits([(second, wall)])
            #expect(await pool.shouldUseCredits(roomIDs: [first, second], now: wall) == [false, false])
            await pool.recordNormalAdmissionCommits(
                Array(repeating: (first, wall), count: 3) + Array(repeating: (second, wall), count: 3))
            #expect(await pool.shouldUseCredits(roomIDs: [first, second], now: wall) == [false, true])
            await pool.recordNormalAdmissionCommits([(first, wall)])
            #expect(await pool.shouldUseCredits(roomIDs: [first, second], now: wall) == [true, true])
            #expect(await pool.snapshot().promotedHotRooms == 2)
            #expect(database.transactions.withLock { $0 } == 0)
            #expect(database.writes.withLock { $0 } == 0)
        }
    }

    @Test("Room heat survives wall-clock corrections and expires after actual elapsed time",
          arguments: [false, true], [Double(-3_600), 3_600, -1_000_000_000, 1_000_000_000, 0])
    func wallClockCorrections(duringCommits: Bool, jump: Double) async throws {
        try await withClockDatabase { database in
            let clock = Mutex(ContinuousClock.now)
            let pool = V2RoomAdmissionCommandCreditPool(database: database, batchSize: 8,
                monotonicNow: { clock.withLock { $0 } })
            let room = UUID(), wall = Date()
            for index in 0..<4 {
                let observed = duringCommits && index >= 2 ? wall.addingTimeInterval(jump) : wall
                await pool.recordNormalAdmissionCommit(roomID: room, now: observed)
                if index < 3 { #expect(await pool.shouldUseCredits(roomID: room, now: observed) == false) }
            }
            let corrected = wall.addingTimeInterval(jump)
            #expect(await pool.shouldUseCredits(roomID: room, now: corrected))
            #expect(await pool.snapshot().promotedHotRooms == 1)
            clock.withLock { $0 = $0.advanced(by: .seconds(5)) }
            #expect(await pool.shouldUseCredits(roomID: room, now: corrected))
            #expect(await pool.snapshot().promotedHotRooms == 1)
            clock.withLock { $0 = $0.advanced(by: .milliseconds(1)) }
            // Metrics must expire heat even without a subsequent admission.
            #expect(await pool.snapshot().promotedHotRooms == 0)
            #expect(await pool.shouldUseCredits(roomID: room, now: corrected) == false)
            #expect(await pool.snapshot().promotedHotRooms == 0)
            #expect(database.transactions.withLock { $0 } == 0)
            #expect(database.writes.withLock { $0 } == 0)
        }
    }

    @Test("Invalid wall clocks neither promote rooms nor erase valid heat")
    func invalidWallClocks() async throws {
        try await withClockDatabase { database in
            let instant = ContinuousClock.now
            let pool = V2RoomAdmissionCommandCreditPool(database: database, batchSize: 8, monotonicNow: { instant })
            let room = UUID(), coldRoom = UUID(), wall = Date()
            for _ in 0..<4 { await pool.recordNormalAdmissionCommit(roomID: room, now: wall) }
            for seconds in [Double.nan, .infinity, -.infinity, 1e14, -1e14] {
                let invalid = Date(timeIntervalSince1970: seconds)
                for _ in 0..<4 { await pool.recordNormalAdmissionCommit(roomID: coldRoom, now: invalid) }
                #expect(await pool.shouldUseCredits(roomID: coldRoom, now: wall) == false)
                #expect(await pool.shouldUseCredits(roomID: room, now: invalid) == false)
                await pool.recordNormalAdmissionCommit(roomID: room, now: invalid)
                #expect(await pool.shouldUseCredits(roomID: room, now: wall))
                #expect(await pool.snapshot().promotedHotRooms == 1)
            }
            #expect(database.transactions.withLock { $0 } == 0)
        }
    }
}

private final class DeviceClockState: Sendable {
    let clock = Mutex(Date(timeIntervalSince1970: 1_750_000_000))
    let generated = Mutex(0)
}

private func makeService(_ database: ClockDatabase, state: DeviceClockState,
                         accessLifetime: TimeInterval = 900, refreshLifetime: TimeInterval = 2_592_000,
                         replayWindow: TimeInterval = 600, maximumSessionLifetime: TimeInterval = 2_592_000) throws -> V2PostgresDeviceCredentialService {
    try .init(database: database, tokenHMACKey: .init(rawBytes: Data(repeating: 7, count: 32)),
        replayEnvelopeKey: .init(rawBytes: Data(repeating: 9, count: 32)),
        tokenGenerator: .init(makeToken: {
            state.generated.withLock { $0 += 1 }
            return "clock-test-placeholder"
        }), accessTokenLifetime: accessLifetime, refreshCredentialLifetime: refreshLifetime,
        replayWindow: replayWindow, maximumSessionLifetime: maximumSessionLifetime,
        now: { state.clock.withLock { $0 } })
}

private func withClockDatabase(_ body: (ClockDatabase) async throws -> Void) async throws {
    let resources = makeV2DatabaseTestResources()
    do {
        // Only borrow the driver's context and SQL dialect. The spy never
        // connects to this address or forwards any database operation.
        resources.databases.use(try .postgres(url: "postgres://fixture:unused@127.0.0.1:1/fixture"), as: .psql)
        let database = resources.database(.psql)
        let sql = try #require(database as? any SQLDatabase)
        try await body(ClockDatabase(context: database.context, dialect: sql.dialect))
        try await resources.shutdown()
    } catch {
        try? await resources.shutdown()
        throw error
    }
}

private enum ClockDatabaseStop: Error { case boundary }

/// Supplies local fixture rows and intercepts writes. No query is sent to a
/// driver, and no credential is issued or persistent row is made.
private final class ClockDatabase: Database, SQLDatabase, Sendable {
    let context: DatabaseContext
    let dialect: any SQLDialect
    let transactions = Mutex(0)
    let dates = Mutex<[Date]>([])
    let writes = Mutex(0)
    let allowsTimestampReads = Mutex(false)
    let allowsHistoryWrite = Mutex(false)
    let rows = Mutex<[String: ClockSQLRow]>([:])
    let generationUpdates = Mutex<[Int64]>([])
    let timestampBindings = Mutex<[Int64]>([])
    let budgetCounts = Mutex<[Int]>([])
    let afterDeviceLookup = Mutex<(@Sendable () -> Void)?>(nil)
    let afterAccountLock = Mutex<(@Sendable () -> Void)?>(nil)
    var inTransaction: Bool { true }

    init(context: DatabaseContext, dialect: any SQLDialect) {
        self.context = context
        self.dialect = dialect
    }

    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        transactions.withLock { $0 += 1 }
        guard afterDeviceLookup.withLock({ $0 != nil }) else {
            return eventLoop.makeFailedFuture(ClockDatabaseStop.boundary)
        }
        return closure(self)
    }

    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        eventLoop.makeFailedFuture(ClockDatabaseStop.boundary)
    }

    func execute(sql query: any SQLExpression, _ onRow: @escaping @Sendable (any SQLRow) -> Void) -> EventLoopFuture<Void> {
        var serializer = SQLSerializer(database: self)
        query.serialize(to: &serializer)
        let bindings = serializer.binds.compactMap { $0 as? Date }
        let isRead = serializer.sql.hasPrefix("SELECT ")
        if !isRead { writes.withLock { $0 += 1 } }
        if !isRead {
            timestampBindings.withLock { values in
                values.append(contentsOf: serializer.binds.compactMap { binding in
                    if let timestamp = binding as? V2PostgresTimestamp { return timestamp.microseconds }
                    if let date = binding as? Date { return (try? V2PostgresTimestamp(date: date))?.microseconds }
                    return nil
                })
            }
        }
        if serializer.sql.hasPrefix("UPDATE im_v2.account_password_login_rate_limits") {
            budgetCounts.withLock { $0.append(contentsOf: serializer.binds.compactMap { $0 as? Int }) }
        }
        if serializer.sql.hasPrefix("INSERT INTO im_v2.device_refresh_token_history"),
           allowsHistoryWrite.withLock({ $0 }) {
            return eventLoop.makeSucceededVoidFuture()
        }
        if serializer.sql.hasPrefix("UPDATE im_v2.device_refresh_sessions") {
            generationUpdates.withLock { $0.append(contentsOf: serializer.binds.compactMap { $0 as? Int64 }) }
        }
        if !bindings.isEmpty {
            dates.withLock { $0.append(contentsOf: bindings) }
            if !allowsTimestampReads.withLock({ $0 }) || !isRead {
                return eventLoop.makeFailedFuture(ClockDatabaseStop.boundary)
            }
        }
        guard isRead else {
            return eventLoop.makeFailedFuture(ClockDatabaseStop.boundary)
        }
        if serializer.sql.hasPrefix("SELECT pg_advisory_xact_lock"),
           serializer.binds.contains(where: { ($0 as? String)?.hasPrefix("account-state:") == true }) {
            afterAccountLock.withLock { $0 }?()
        }
        if serializer.sql.contains("FROM im_v2.auth_devices") {
            afterDeviceLookup.withLock { $0 }?()
        }
        if let row = rows.withLock({ rows in rows.first { serializer.sql.contains($0.key) }?.value }) {
            onRow(row)
        }
        return eventLoop.makeSucceededVoidFuture()
    }

    func execute(query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> Void) -> EventLoopFuture<Void> {
        eventLoop.makeFailedFuture(ClockDatabaseStop.boundary)
    }
    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> {
        eventLoop.makeFailedFuture(ClockDatabaseStop.boundary)
    }
    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> {
        eventLoop.makeFailedFuture(ClockDatabaseStop.boundary)
    }
}

private struct ClockSQLRow: SQLRow {
    let columns: [String: Data]
    let timestamps: [String: V2PostgresTimestamp]
    init(columns: [String: Data] = [:], timestamps: [String: V2PostgresTimestamp] = [:]) {
        self.columns = columns
        self.timestamps = timestamps
    }
    var allColumns: [String] { Array(Set(columns.keys).union(timestamps.keys)) }
    func contains(column: String) -> Bool { columns[column] != nil || timestamps[column] != nil }
    func decodeNil(column: String) throws -> Bool { !contains(column: column) }
    func decode<D: Decodable>(column: String, as: D.Type) throws -> D {
        if let timestamp = timestamps[column] {
            if let value = timestamp as? D { return value }
            if let value = timestamp.date as? D { return value }
        }
        guard let data = columns[column] else { throw ClockDatabaseStop.boundary }
        return try JSONDecoder().decode(D.self, from: data)
    }
}

private func nativeClockTimestamp(_ microseconds: Int64) throws -> V2PostgresTimestamp {
    var buffer = ByteBuffer()
    buffer.writeInteger(microseconds)
    return try .init(from: &buffer, type: .timestamptz, format: .binary, context: .default)
}

private func prepareRefreshDatabase(_ database: ClockDatabase, user: UUID, expiry: Date, generation: Int64 = 1) throws {
    let encoder = JSONEncoder()
    let key = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 7, count: 32))
    let rows: [String: ClockSQLRow] = [
        "SELECT user_id, revoked_at, session_expires_at FROM im_v2.auth_devices": .init(columns: [
            "user_id": try encoder.encode(user), "session_expires_at": try encoder.encode(expiry),
        ]),
        "FROM im_v2.device_revocation_capabilities AS capability": .init(columns: [
            "expires_at": try encoder.encode(expiry),
        ]),
        "SELECT family_generation, refresh_hmac, expires_at, revoked_at FROM im_v2.device_refresh_sessions": .init(columns: [
            "family_generation": try encoder.encode(generation),
            "refresh_hmac": try encoder.encode(key.digest("clock-test-placeholder")),
            "expires_at": try encoder.encode(expiry),
        ]),
    ]
    database.rows.withLock { $0 = rows }
    database.afterDeviceLookup.withLock { $0 = {} }
    database.allowsTimestampReads.withLock { $0 = true }
    database.allowsHistoryWrite.withLock { $0 = true }
}
