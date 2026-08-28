import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 authenticated gateway admission")
struct V2AuthenticatedGatewayAdmissionTests {
    @Test("device and user command buckets are charged atomically and refill")
    func rateLimitsDeviceAndUser() async throws {
        let limiter = V2AuthenticatedGatewayCommandRateLimiter(policy: .init(
            deviceCommandsPerSecond: 1,
            deviceBurst: 2,
            userCommandsPerSecond: 3,
            userBurst: 3,
            maximumTrackedIdentities: 8
        ))
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let first = try identity(user: 1, device: 1)
        let second = try identity(user: 1, device: 2)

        #expect(await limiter.admit(identity: first, now: now))
        #expect(await limiter.admit(identity: first, now: now))
        #expect(await !limiter.admit(identity: first, now: now))
        #expect(await limiter.admit(identity: second, now: now))
        #expect(await !limiter.admit(identity: second, now: now))
        #expect(await limiter.admit(identity: first, now: now.addingTimeInterval(1)))
    }

    @Test("rate-limit identity churn remains hard bounded")
    func boundsTrackedIdentities() async throws {
        let limiter = V2AuthenticatedGatewayCommandRateLimiter(policy: .init(
            deviceCommandsPerSecond: 1,
            deviceBurst: 1,
            userCommandsPerSecond: 1,
            userBurst: 1,
            maximumTrackedIdentities: 4
        ))
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        for value in 1...20 {
            _ = await limiter.admit(identity: try identity(user: value, device: value), now: now)
        }
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
