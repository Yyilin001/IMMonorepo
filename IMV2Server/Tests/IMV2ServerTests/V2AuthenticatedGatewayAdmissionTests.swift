import Foundation
import IMV2Core
@testable import IMV2Server
import Synchronization
import Testing

@Suite("V2 authenticated gateway admission")
struct V2AuthenticatedGatewayAdmissionTests {
    @Test("wall clock jumps neither refill command buckets early nor stall their normal refill",
          arguments: [-1_000_000_000.0, -3_600, 3_600, 1_000_000_000])
    func monotonicRefillAcrossWallClockJumps(jump: Double) async throws {
        let clock = AdmissionMonotonicTestClock()
        let limiter = V2AuthenticatedGatewayCommandRateLimiter(policy: .init(
            deviceCommandsPerSecond: 1, deviceBurst: 1,
            userCommandsPerSecond: 1, userBurst: 1,
            maximumTrackedIdentities: 8
        ), monotonicNow: { clock.now() })
        let first = try identity(user: 1, device: 1)
        let second = try identity(user: 1, device: 2)
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let jumped = start.addingTimeInterval(jump)
        #expect(await limiter.admit(identity: first, now: start))
        #expect(await !limiter.admit(identity: first, now: jumped))
        clock.advance(by: .milliseconds(500))
        #expect(await !limiter.admit(identity: first, now: jumped))
        clock.advance(by: .milliseconds(500))
        #expect(await limiter.admit(identity: first, now: jumped))
        // Both devices share the same user's budget even across the jump.
        #expect(await !limiter.admit(identity: second, now: jumped))
        clock.advance(by: .seconds(1))
        #expect(await limiter.admit(identity: second, now: start))
        #expect(await !limiter.admit(identity: first, now: start))
        #expect(await limiter.trackedIdentityCount() == 3)
    }

    @Test("invalid server clocks preserve existing quotas and allow normal refill after recovery",
          arguments: [false, true], [Double.nan, .infinity, -.infinity,
              .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
              Double(Int64.max) / 1_000, -Double(Int64.max) / 500])
    func invalidClockPreservesQuota(seeded: Bool, seconds: Double) async throws {
        let clock = AdmissionMonotonicTestClock()
        let limiter = V2AuthenticatedGatewayCommandRateLimiter(policy: .init(
            deviceCommandsPerSecond: 1,
            deviceBurst: 2,
            userCommandsPerSecond: 1,
            userBurst: 2,
            maximumTrackedIdentities: 4
        ), monotonicNow: { clock.now() })
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let first = try identity(user: 1, device: 1)
        let second = try identity(user: 2, device: 2)
        let newcomer = try identity(user: 3, device: 3)
        if seeded {
            #expect(await limiter.admit(identity: first, now: start))
            #expect(await limiter.admit(identity: second, cost: 2, now: start))
        }

        let invalid = Date(timeIntervalSince1970: seconds)
        #expect(await !limiter.admit(identity: first, now: invalid))
        #expect(await !limiter.admit(identity: newcomer, now: invalid))
        // Zero-cost liveness does not consult or mutate token buckets.
        #expect(await limiter.admit(identity: newcomer, cost: 0, now: invalid))
        #expect(await limiter.trackedIdentityCount() == (seeded ? 4 : 0))

        #expect(await limiter.admit(identity: first, cost: seeded ? 1 : 2, now: start))
        #expect(await !limiter.admit(identity: first, now: start))
        if seeded {
            // Invalid accesses must not evict an unrelated exhausted bucket.
            #expect(await !limiter.admit(identity: second, now: start))
            clock.advance(by: .seconds(1))
            #expect(await limiter.admit(identity: second, now: start.addingTimeInterval(1)))
        } else {
            clock.advance(by: .seconds(1))
        }
        #expect(await limiter.admit(identity: first, now: start.addingTimeInterval(1)))
        #expect(await !limiter.admit(identity: first, now: start.addingTimeInterval(1)))
    }

    @Test("accepted integer rate boundaries preserve charging and clock-based refill across shards",
          arguments: [1, 9_007_199_254_740_993, Int.max - 1, Int.max], [8, 2_051])
    func integerRateBoundaries(rate: Int, capacity: Int) async throws {
        for highDeviceRate in [false, true] {
            let clock = AdmissionMonotonicTestClock()
            let limiter = V2AuthenticatedGatewayCommandRateLimiter(policy: .init(
                deviceCommandsPerSecond: highDeviceRate ? rate : 1,
                deviceBurst: 2,
                userCommandsPerSecond: highDeviceRate ? 1 : rate,
                userBurst: 3,
                maximumTrackedIdentities: capacity
            ), shardCount: 3, monotonicNow: { clock.now() })
            let start = Date(timeIntervalSince1970: 1_750_000_000)
            let first = try identity(user: 1, device: 1)
            let second = try identity(user: 1, device: 2)

            #expect(await limiter.admit(identity: first, cost: 2, now: start))
            #expect(await !limiter.admit(identity: first, now: start))
            #expect(await limiter.admit(identity: second, now: start))
            #expect(await !limiter.admit(identity: second, now: start))
            // A clock rollback cannot replenish either exhausted bucket.
            #expect(await !limiter.admit(identity: first, now: start.addingTimeInterval(-1)))
            #expect(await limiter.admit(identity: first, cost: 0, now: start))
            clock.advance(by: .seconds(1))
            #expect(await limiter.admit(identity: first, now: start.addingTimeInterval(1)))
            #expect(await !limiter.admit(identity: first, now: start.addingTimeInterval(1)))
            #expect(await limiter.trackedIdentityCount() == 3)
        }
    }

    @Test("uneven shard budgets retain the process-wide identity ceiling", arguments: [2_051, 4_099])
    func boundsIdentitiesAcrossShards(capacity: Int) async throws {
        let clock = AdmissionMonotonicTestClock()
        let limiter = V2AuthenticatedGatewayCommandRateLimiter(policy: .init(
            deviceCommandsPerSecond: Int.max,
            deviceBurst: 1,
            userCommandsPerSecond: Int.max,
            userBurst: 1,
            maximumTrackedIdentities: capacity
        ), shardCount: 3, monotonicNow: { clock.now() })
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        for value in 1...(capacity + 10) {
            #expect(await limiter.admit(identity: try identity(user: value, device: value), now: now))
        }
        let count = await limiter.trackedIdentityCount()
        #expect(count <= capacity)
        // Each shard may leave one slot unused when admitting a user/device pair.
        #expect(count >= capacity - 3)
        #expect(await !limiter.admit(
            identity: try identity(user: capacity + 10, device: capacity + 10), now: now
        ))
    }

    @Test("device and user command buckets are charged atomically and refill")
    func rateLimitsDeviceAndUser() async throws {
        let clock = AdmissionMonotonicTestClock()
        let limiter = V2AuthenticatedGatewayCommandRateLimiter(policy: .init(
            deviceCommandsPerSecond: 1,
            deviceBurst: 2,
            userCommandsPerSecond: 3,
            userBurst: 3,
            maximumTrackedIdentities: 8
        ), monotonicNow: { clock.now() })
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let first = try identity(user: 1, device: 1)
        let second = try identity(user: 1, device: 2)

        #expect(await limiter.admit(identity: first, now: now))
        #expect(await limiter.admit(identity: first, now: now))
        #expect(await !limiter.admit(identity: first, now: now))
        #expect(await limiter.admit(identity: second, now: now))
        #expect(await !limiter.admit(identity: second, now: now))
        clock.advance(by: .seconds(1))
        #expect(await limiter.admit(identity: first, now: now.addingTimeInterval(1)))
    }

    @Test("weighted commands consume their full cost while zero-cost liveness remains available")
    func chargesWeightedCommands() async throws {
        let clock = AdmissionMonotonicTestClock()
        let limiter = V2AuthenticatedGatewayCommandRateLimiter(policy: .init(
            deviceCommandsPerSecond: 1,
            deviceBurst: 10,
            userCommandsPerSecond: 1,
            userBurst: 10,
            maximumTrackedIdentities: 8
        ), monotonicNow: { clock.now() })
        let identity = try identity(user: 1, device: 1)
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        #expect(await limiter.admit(identity: identity, cost: 8, now: now))
        #expect(await !limiter.admit(identity: identity, cost: 3, now: now))
        #expect(await limiter.admit(identity: identity, cost: 0, now: now))
        #expect(await limiter.admit(identity: identity, cost: 2, now: now))
        #expect(await !limiter.admit(identity: identity, cost: 1, now: now))
    }

    @Test("rate-limit identity churn remains hard bounded")
    func boundsTrackedIdentities() async throws {
        let clock = AdmissionMonotonicTestClock()
        let limiter = V2AuthenticatedGatewayCommandRateLimiter(policy: .init(
            deviceCommandsPerSecond: 1,
            deviceBurst: 1,
            userCommandsPerSecond: 1,
            userBurst: 1,
            maximumTrackedIdentities: 4
        ), monotonicNow: { clock.now() })
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        for value in 1...20 {
            _ = await limiter.admit(identity: try identity(user: value, device: value), now: now)
        }
        #expect(await limiter.trackedIdentityCount() == 4)
    }

    @Test("first capacity eviction preserves the most recently used quota state")
    func preservesRecentQuotaWhenLazyRecencyTrackingStarts() async throws {
        let clock = AdmissionMonotonicTestClock()
        let limiter = V2AuthenticatedGatewayCommandRateLimiter(policy: .init(
            deviceCommandsPerSecond: 1,
            deviceBurst: 1,
            userCommandsPerSecond: 1,
            userBurst: 1,
            maximumTrackedIdentities: 4
        ), monotonicNow: { clock.now() })
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let first = try identity(user: 1, device: 1)
        let second = try identity(user: 2, device: 2)
        let newcomer = try identity(user: 3, device: 3)

        #expect(await limiter.admit(identity: first, now: start))
        #expect(await limiter.admit(identity: second, now: start))
        clock.advance(by: .seconds(1))
        #expect(await limiter.admit(identity: first, now: start.addingTimeInterval(1)))

        // Adding two newcomer identities forces the first eviction and the
        // lazy LRU rebuild. The older second user/device pair must be evicted,
        // while the first pair retains its just-consumed token buckets.
        #expect(await limiter.admit(identity: newcomer, now: start.addingTimeInterval(1)))
        #expect(await !limiter.admit(identity: first, now: start.addingTimeInterval(1)))
        #expect(await limiter.trackedIdentityCount() == 4)
    }

    @Test("registry enforces exact local device and user connection ceilings")
    func boundsAuthenticatedConnections() async throws {
        let registry = V2DeviceConnectionRegistry(connectionAdmissionPolicy: .init(
            maximumConnectionsPerDevice: 1,
            maximumConnectionsPerUser: 2
        ))
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let first = try identity(user: 1, device: 1)
        let second = try identity(user: 1, device: 2)
        let third = try identity(user: 1, device: 3)

        #expect(try await registry.register(try stream(), connectionID: firstID, identity: first))
        #expect(try await !registry.register(try stream(), connectionID: UUID(), identity: first))
        #expect(try await registry.register(try stream(), connectionID: secondID, identity: second))
        #expect(try await !registry.register(try stream(), connectionID: thirdID, identity: third))
        await registry.unregister(connectionID: firstID)
        #expect(try await registry.register(try stream(), connectionID: thirdID, identity: third))
        #expect(await registry.connectionMetricsSnapshot().activeConnections == 2)
    }

    @Test("a connection identifier cannot be shared by two stream lifecycles")
    func rejectsDuplicateConnectionIdentifier() async throws {
        let registry = V2DeviceConnectionRegistry()
        let connectionID = UUID()
        let first = try identity(user: 1, device: 1)
        let second = try identity(user: 2, device: 2)

        #expect(try await registry.register(
            try stream(), connectionID: connectionID, identity: first
        ))
        #expect(try await !registry.register(
            try stream(), connectionID: connectionID, identity: second
        ))
        #expect(await registry.connectionMetricsSnapshot().activeConnections == 1)
    }

    @Test("presence privacy never removes the cross-replica admission lease")
    func hiddenPresenceKeepsAdmissionLease() async throws {
        let registry = V2DeviceConnectionRegistry(connectionAdmissionPolicy: .init(
            maximumConnectionsPerDevice: 1,
            maximumConnectionsPerUser: 1
        ))
        let leases = HiddenPresenceAdmissionLeases()
        await registry.configureLivePresenceLeases(leases)
        let connectionID = UUID()

        #expect(try await registry.register(
            try stream(),
            connectionID: connectionID,
            identity: try identity(user: 1, device: 1)
        ))
        #expect(await leases.activeConnectionIDs() == [connectionID])

        await registry.applyLiveActivityPreferences(
            connectionID: connectionID,
            allowsOnlinePresence: false
        )
        #expect(await leases.activeConnectionIDs() == [connectionID])

        await registry.unregister(connectionID: connectionID)
        #expect(await leases.activeConnectionIDs().isEmpty)
    }

    @Test("presence admission storage failures are not disguised as quota rejections")
    func propagatesPresenceAdmissionFailure() async throws {
        let registry = V2DeviceConnectionRegistry()
        await registry.configureLivePresenceLeases(FailingPresenceAdmissionLeases())

        await #expect(throws: PresenceAdmissionFixtureError.unavailable) {
            try await registry.register(
                try stream(),
                connectionID: UUID(),
                identity: try identity(user: 1, device: 1)
            )
        }
        #expect(await registry.connectionMetricsSnapshot().activeConnections == 0)
    }

    private func identity(user: Int, device: Int) throws -> V2AuthenticatedConnection {
        .init(
            userID: try .init(String(format: "00000000-0000-0000-0000-%012d", user)),
            deviceID: try .init(String(format: "10000000-0000-0000-0000-%012d", device)),
            capabilityProfile: "base"
        )
    }

    private func stream() throws -> V2GatewayByteStream {
        .init(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, 1]),
            session: .init(
                limits: try .init(maximumInFlightRequests: 1),
                authenticator: Authenticator(),
                capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()
            ),
            handler: Handler(),
            registry: V2DeviceConnectionRegistry()
        )
    }
}

private final class AdmissionMonotonicTestClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)

    func now() -> ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(by duration: Duration) { instant.withLock { $0 += duration } }
}

private enum PresenceAdmissionFixtureError: Error { case unavailable }

private actor FailingPresenceAdmissionLeases: V2LivePresenceLeaseManaging {
    func admitConnection(
        identity _: V2AuthenticatedConnection,
        connectionID _: UUID,
        policy _: V2AuthenticatedConnectionAdmissionPolicy,
        now _: Date
    ) throws -> V2AuthenticatedConnectionLeaseOutcome {
        throw PresenceAdmissionFixtureError.unavailable
    }

    func renewConnection(
        identity _: V2AuthenticatedConnection,
        connectionID _: UUID,
        now _: Date
    ) -> V2AuthenticatedConnectionLeaseOutcome { .rejected }

    func removePresence(
        identity _: V2AuthenticatedConnection,
        connectionID _: UUID,
        now _: Date
    ) -> Bool { false }

    func allowsOnlinePresence(userID _: UserID) -> Bool { true }
}

private actor HiddenPresenceAdmissionLeases: V2LivePresenceLeaseManaging {
    private var connectionIDs: Set<UUID> = []

    func admitConnection(
        identity _: V2AuthenticatedConnection,
        connectionID: UUID,
        policy _: V2AuthenticatedConnectionAdmissionPolicy,
        now: Date
    ) -> V2AuthenticatedConnectionLeaseOutcome {
        connectionIDs.insert(connectionID)
        return .accepted(expiresAt: now.addingTimeInterval(90))
    }

    func renewConnection(
        identity _: V2AuthenticatedConnection,
        connectionID: UUID,
        now: Date
    ) -> V2AuthenticatedConnectionLeaseOutcome {
        guard connectionIDs.contains(connectionID) else { return .rejected }
        return .accepted(expiresAt: now.addingTimeInterval(90))
    }

    func removePresence(
        identity _: V2AuthenticatedConnection,
        connectionID: UUID,
        now _: Date
    ) -> Bool {
        connectionIDs.remove(connectionID)
        return !connectionIDs.isEmpty
    }

    func allowsOnlinePresence(userID _: UserID) -> Bool { false }
    func activeConnectionIDs() -> Set<UUID> { connectionIDs }
}

private struct Authenticator: V2GatewayAuthenticator {
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) async throws -> V2GatewayAuthentication {
        try .init(userID: .init("00000000-0000-0000-0000-000000000001"), expiresAt: nil)
    }
}

private struct Handler: V2GatewayCommandHandler {
    func handle(
        envelope _: IMV2Envelope,
        identity _: V2AuthenticatedConnection
    ) async throws -> IMV2Envelope { .init() }
}
