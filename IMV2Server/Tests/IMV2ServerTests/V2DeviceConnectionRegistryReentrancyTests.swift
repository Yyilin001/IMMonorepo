import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 device connection registry reentrancy")
struct V2DeviceConnectionRegistryReentrancyTests {
    @Test("unregister during presence refresh removes the late database lease")
    func compensatesLatePresenceRefresh() async throws {
        let registry = V2DeviceConnectionRegistry()
        let leases = SuspendedPresenceLeases()
        await registry.configureLivePresenceLeases(leases)
        let identity = try identityFixture()
        let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000d03")!
        let stream = try streamFixture()

        let registration = Task {
            await registry.register(stream, connectionID: connectionID, identity: identity)
        }
        await leases.waitUntilRefreshStarts()
        await registry.unregister(connectionID: connectionID)
        await leases.resumeRefresh()
        _ = await registration.value

        #expect(await registry.connectionMetricsSnapshot().activeConnections == 0)
        #expect(await leases.activeConnectionIDs().isEmpty)
    }

    @Test("unregister during the privacy lookup cannot complete a stale registration")
    func rejectsRegistrationAfterSuspendedPrivacyLookup() async throws {
        let registry = V2DeviceConnectionRegistry()
        let leases = SuspendedPreferencePresenceLeases()
        await registry.configureLivePresenceLeases(leases)
        let identity = try identityFixture()
        let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000d07")!
        let stream = try streamFixture()

        let registration = Task {
            await registry.register(
                stream,
                connectionID: connectionID,
                identity: identity
            )
        }
        await leases.waitUntilPreferenceLookupStarts()
        await registry.unregister(connectionID: connectionID)
        await leases.resumePreferenceLookup()

        #expect(await !registration.value)
        #expect(await registry.connectionMetricsSnapshot().activeConnections == 0)
        #expect(await leases.activeConnectionIDs().isEmpty)
    }

    @Test("unregister while broker activation is suspended leaves no phantom subscription")
    func compensatesLateSubscriptionActivation() async throws {
        let registry = V2DeviceConnectionRegistry()
        let broker = SuspendedLiveActivityBroker()
        await registry.configureLiveActivityBroker(broker)
        let identity = try identityFixture()
        let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000d04")!
        let roomID = try RoomID("00000000-0000-0000-0000-000000000d05")
        let target = try UserID("00000000-0000-0000-0000-000000000d06")
        let stream = try streamFixture()
        await registry.register(stream, connectionID: connectionID, identity: identity)

        let subscription = Task {
            await registry.subscribePresence(
                stream,
                connectionID: connectionID,
                roomID: roomID,
                targetUserID: target
            )
        }
        await broker.waitUntilPresenceActivationStarts()
        await registry.unregister(connectionID: connectionID)
        await broker.resumePresenceActivation()
        await subscription.value

        #expect(await registry.connectionMetricsSnapshot().activeConnections == 0)
        #expect(await broker.activePresenceTargets().isEmpty)
        #expect(await registry.transientMutationTokenCount() == 0)
    }

    @Test("connection churn does not retain transient mutation generations")
    func connectionChurnClearsMutationTokens() async throws {
        let registry = V2DeviceConnectionRegistry()
        let identity = try identityFixture()
        let stream = try streamFixture()

        for index in 0..<256 {
            let connectionID = UUID(
                uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index / 256), UInt8(index % 256))
            )
            await registry.register(stream, connectionID: connectionID, identity: identity)
            await registry.unregister(connectionID: connectionID)
        }

        #expect(await registry.connectionMetricsSnapshot().activeConnections == 0)
        #expect(await registry.transientMutationTokenCount() == 0)
    }

    private func identityFixture() throws -> V2AuthenticatedConnection {
        .init(
            userID: try .init("00000000-0000-0000-0000-000000000d01"),
            deviceID: try .init("00000000-0000-0000-0000-000000000d02"),
            capabilityProfile: "base"
        )
    }

    private func streamFixture() throws -> V2GatewayByteStream {
        V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, 1]),
            session: .init(
                limits: try .init(maximumInFlightRequests: 1),
                authenticator: RegistryReentrancyAuthenticator(),
                capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()
            ),
            handler: RegistryReentrancyCommandHandler(),
            registry: V2DeviceConnectionRegistry()
        )
    }
}

private actor SuspendedPresenceLeases: V2LivePresenceLeaseManaging {
    private var active: Set<UUID> = []
    private var refreshStarted: CheckedContinuation<Void, Never>?
    private var refreshResume: CheckedContinuation<Void, Never>?
    private var didStartRefresh = false

    func admitConnection(
        identity _: V2AuthenticatedConnection,
        connectionID: UUID,
        policy _: V2AuthenticatedConnectionAdmissionPolicy,
        now: Date
    ) async throws -> V2AuthenticatedConnectionLeaseOutcome {
        active.insert(connectionID)
        didStartRefresh = true
        refreshStarted?.resume()
        refreshStarted = nil
        await withCheckedContinuation { refreshResume = $0 }
        return .accepted(expiresAt: now.addingTimeInterval(30))
    }

    func renewConnection(
        identity _: V2AuthenticatedConnection,
        connectionID: UUID,
        now: Date
    ) -> V2AuthenticatedConnectionLeaseOutcome {
        guard active.contains(connectionID) else { return .rejected }
        return .accepted(expiresAt: now.addingTimeInterval(30))
    }

    func removePresence(
        identity _: V2AuthenticatedConnection,
        connectionID: UUID,
        now _: Date
    ) -> Bool {
        active.remove(connectionID)
        return !active.isEmpty
    }

    func allowsOnlinePresence(userID _: UserID) -> Bool { true }

    func waitUntilRefreshStarts() async {
        if didStartRefresh { return }
        await withCheckedContinuation { refreshStarted = $0 }
    }
    func resumeRefresh() { refreshResume?.resume(); refreshResume = nil }
    func activeConnectionIDs() -> Set<UUID> { active }
}

private actor SuspendedPreferencePresenceLeases: V2LivePresenceLeaseManaging {
    private var active: Set<UUID> = []
    private var lookupStarted: CheckedContinuation<Void, Never>?
    private var lookupResume: CheckedContinuation<Void, Never>?
    private var didStartLookup = false

    func admitConnection(
        identity _: V2AuthenticatedConnection,
        connectionID: UUID,
        policy _: V2AuthenticatedConnectionAdmissionPolicy,
        now: Date
    ) -> V2AuthenticatedConnectionLeaseOutcome {
        active.insert(connectionID)
        return .accepted(expiresAt: now.addingTimeInterval(30))
    }

    func renewConnection(
        identity _: V2AuthenticatedConnection,
        connectionID: UUID,
        now: Date
    ) -> V2AuthenticatedConnectionLeaseOutcome {
        guard active.contains(connectionID) else { return .rejected }
        return .accepted(expiresAt: now.addingTimeInterval(30))
    }

    func removePresence(
        identity _: V2AuthenticatedConnection,
        connectionID: UUID,
        now _: Date
    ) -> Bool {
        active.remove(connectionID)
        return !active.isEmpty
    }

    func allowsOnlinePresence(userID _: UserID) async -> Bool {
        didStartLookup = true
        lookupStarted?.resume()
        lookupStarted = nil
        await withCheckedContinuation { lookupResume = $0 }
        return false
    }

    func waitUntilPreferenceLookupStarts() async {
        if didStartLookup { return }
        await withCheckedContinuation { lookupStarted = $0 }
    }

    func resumePreferenceLookup() {
        lookupResume?.resume()
        lookupResume = nil
    }

    func activeConnectionIDs() -> Set<UUID> { active }
}

private actor SuspendedLiveActivityBroker: V2LiveActivityInterestManaging, V2LiveActivityPublishing {
    private var presenceTargets: Set<UserID> = []
    private var activationStarted: CheckedContinuation<Void, Never>?
    private var activationResume: CheckedContinuation<Void, Never>?
    private var didStartActivation = false

    func activatePresence(targetUserID: UserID) async throws {
        didStartActivation = true
        activationStarted?.resume()
        activationStarted = nil
        await withCheckedContinuation { activationResume = $0 }
        presenceTargets.insert(targetUserID)
    }
    func deactivatePresence(targetUserID: UserID) { presenceTargets.remove(targetUserID) }
    func activateTyping(roomID _: RoomID) async throws {}
    func deactivateTyping(roomID _: RoomID) {}
    func publishPresence(targetUserID _: UserID, isOnline _: Bool, expiresAt _: Date) {}
    func publishTyping(_ state: V2TypingState) {}

    func waitUntilPresenceActivationStarts() async {
        if didStartActivation { return }
        await withCheckedContinuation { activationStarted = $0 }
    }
    func resumePresenceActivation() { activationResume?.resume(); activationResume = nil }
    func activePresenceTargets() -> Set<UserID> { presenceTargets }
}

private struct RegistryReentrancyAuthenticator: V2GatewayAuthenticator {
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) async throws -> V2GatewayAuthentication {
        try .init(userID: .init("00000000-0000-0000-0000-000000000d01"), expiresAt: nil)
    }
}

private struct RegistryReentrancyCommandHandler: V2GatewayCommandHandler {
    func handle(envelope _: IMV2Envelope, identity _: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        .init()
    }
}
