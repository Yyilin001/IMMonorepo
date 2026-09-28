import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 device revocation worker")
struct V2DeviceRevocationWorkerTests {
    @Test("invalid batch limits fail before reading events or running cleanup", arguments: [Int.min, -1, 0])
    func invalidBatchLimits(limit: Int) async throws {
        let store = InMemoryDeviceRevocationEventStore(events: [])
        let cleaner = FailOnceProjectionCleaner()
        let gateway = V2DeviceRevocationWorker(store: store, registry: V2DeviceConnectionRegistry(), nodeID: "gateway-limit-test")
        let cleanup = V2RevokedDeviceProjectionCleanupWorker(store: store, cleaner: cleaner)
        await #expect(throws: V2GatewayAuthenticationError.corruptPersistenceState) {
            try await gateway.runOnce(limit: limit)
        }
        await #expect(throws: V2GatewayAuthenticationError.corruptPersistenceState) {
            try await cleanup.runOnce(limit: limit)
        }
        #expect(await store.eventReadCount == 0)
        #expect(await cleaner.cleanedDevices().isEmpty)
    }

    @Test("every event is acknowledged only after local revocation handling")
    func consumesEventsInOrderForItsNode() async throws {
        let device = try DeviceID("00000000-0000-0000-0000-000000000701")
        let firstUser = try UserID("00000000-0000-0000-0000-000000000702")
        let secondUser = try UserID("00000000-0000-0000-0000-000000000703")
        let secondDevice = try DeviceID("00000000-0000-0000-0000-000000000704")
        let store = InMemoryDeviceRevocationEventStore(events: [
            .init(eventID: 8, userID: firstUser, deviceID: device, revokedAt: revocationFixtureDate),
            .init(eventID: 9, userID: secondUser, deviceID: secondDevice, revokedAt: revocationFixtureDate),
        ])
        let worker = V2DeviceRevocationWorker(
            store: store,
            registry: V2DeviceConnectionRegistry(),
            nodeID: "gateway-test",
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )

        #expect(try await worker.runOnce(limit: 1) == 1)
        #expect(await store.processedEventIDs(for: "gateway-test") == [8])
        #expect(try await worker.runOnce(limit: 8) == 1)
        #expect(await store.processedEventIDs(for: "gateway-test") == [8, 9])
    }

    @Test("a newly named gateway starts at the pre-listener revocation watermark")
    func initializesOnlyAnAbsentCursorAtCurrentWatermark() async throws {
        let firstUser = try UserID("00000000-0000-0000-0000-000000000721")
        let firstDevice = try DeviceID("00000000-0000-0000-0000-000000000722")
        let secondUser = try UserID("00000000-0000-0000-0000-000000000723")
        let secondDevice = try DeviceID("00000000-0000-0000-0000-000000000724")
        let store = InMemoryDeviceRevocationEventStore(events: [
            .init(eventID: 12, userID: firstUser, deviceID: firstDevice, revokedAt: revocationFixtureDate),
            .init(eventID: 13, userID: secondUser, deviceID: secondDevice, revokedAt: revocationFixtureDate),
        ])
        let worker = V2DeviceRevocationWorker(
            store: store,
            registry: V2DeviceConnectionRegistry(),
            nodeID: "new-gateway-test",
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )

        try await worker.initializeForStartup()
        #expect(try await worker.runOnce(limit: 8) == 0)

        await store.append(.init(
            eventID: 14,
            userID: firstUser,
            deviceID: firstDevice,
            revokedAt: revocationFixtureDate
        ))
        #expect(try await worker.runOnce(limit: 8) == 1)
        #expect(await store.processedEventIDs(for: "new-gateway-test") == [14])
        try await worker.initializeForStartup()
        #expect(await store.cursor(for: "new-gateway-test") == 14)
    }

    @Test("a revocation event closes its registered live stream before advancing the node cursor")
    func revokesRegisteredLiveStreamBeforeAcknowledgingEvent() async throws {
        let user = try UserID("00000000-0000-0000-0000-000000000711")
        let device = try DeviceID("00000000-0000-0000-0000-000000000712")
        let registry = V2DeviceConnectionRegistry()
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, 1]),
            session: .init(
                limits: try .init(maximumInFlightRequests: 1),
                authenticator: RevocationAuthFake(),
                capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()
            ),
            handler: RevocationCommandFake(),
            registry: registry
        )
        let closeRecorder = RevocationCloseRecorder()
        await stream.setDeviceRevocationHandler {
            await closeRecorder.recordClose()
        }
        try await registry.register(
            stream,
            connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000713")!,
            identity: .init(userID: user, deviceID: device, capabilityProfile: "base"),
            publicationSuppressed: true
        )
        #expect(await registry.connectionCount(for: device) == 1)

        let store = InMemoryDeviceRevocationEventStore(
            events: [.init(
                eventID: 10,
                userID: user,
                deviceID: device,
                revokedAt: revocationFixtureDate
            )],
            didCloseBeforeMarking: { await closeRecorder.didRecordClose() }
        )
        let worker = V2DeviceRevocationWorker(
            store: store,
            registry: registry,
            nodeID: "gateway-live-close-test",
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )

        #expect(try await worker.runOnce(limit: 1) == 1)
        #expect(await closeRecorder.waitForClose())
        #expect(await registry.connectionCount(for: device) == 0)
        #expect(await store.closeObservationsWhenMarked(for: "gateway-live-close-test") == [true])
        #expect(await store.processedEventIDs(for: "gateway-live-close-test") == [10])
    }

    @Test("cluster projection cleanup replays history and acknowledges only after success")
    func projectionCleanupIsDurableAndReplayable() async throws {
        let user = try UserID("00000000-0000-0000-0000-000000000731")
        let device = try DeviceID("00000000-0000-0000-0000-000000000732")
        let store = InMemoryDeviceRevocationEventStore(events: [
            .init(eventID: 21, userID: user, deviceID: device, revokedAt: revocationFixtureDate)
        ])
        let cleaner = FailOnceProjectionCleaner()
        let worker = V2RevokedDeviceProjectionCleanupWorker(
            store: store,
            cleaner: cleaner,
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )

        try await worker.initializeForStartup()
        await #expect(throws: ProjectionCleanupTestError.unavailable) {
            try await worker.runOnce(limit: 8)
        }
        #expect(await store.processedEventIDs(for: "cluster").isEmpty)

        #expect(try await worker.runOnce(limit: 8) == 1)
        #expect(await cleaner.cleanedDevices() == [device, device])
        #expect(await cleaner.revocationTimes() == [revocationFixtureDate, revocationFixtureDate])
        #expect(await store.processedEventIDs(for: "cluster") == [21])
    }
}

private actor InMemoryDeviceRevocationEventStore: V2DeviceRevocationEventStore {
    private let didCloseBeforeMarking: (@Sendable () async -> Bool)?
    private var events: [V2DeviceRevocationEvent]
    private var cursors: [String: Int64] = [:]
    private var processed: [String: [Int64]] = [:]
    private var closeObservations: [String: [Bool]] = [:]
    private(set) var eventReadCount = 0

    init(
        events: [V2DeviceRevocationEvent],
        didCloseBeforeMarking: (@Sendable () async -> Bool)? = nil
    ) {
        self.events = events
        self.didCloseBeforeMarking = didCloseBeforeMarking
    }

    func initializeCursorIfNeeded(nodeID: String, now _: Date) {
        guard cursors[nodeID] == nil else { return }
        cursors[nodeID] = events.map(\.eventID).max() ?? 0
    }

    func initializeCursorAtBeginningIfNeeded(nodeID: String, now _: Date) {
        guard cursors[nodeID] == nil else { return }
        cursors[nodeID] = 0
    }

    func events(afterCursorFor nodeID: String, limit: Int) -> [V2DeviceRevocationEvent] {
        eventReadCount += 1
        let cursor = cursors[nodeID] ?? 0
        return Array(events.filter { $0.eventID > cursor }.prefix(limit))
    }

    func markProcessed(eventID: Int64, nodeID: String, now _: Date) async {
        if let didCloseBeforeMarking {
            closeObservations[nodeID, default: []].append(await didCloseBeforeMarking())
        }
        processed[nodeID, default: []].append(eventID)
        cursors[nodeID] = max(cursors[nodeID] ?? 0, eventID)
    }

    func append(_ event: V2DeviceRevocationEvent) { events.append(event) }
    func cursor(for nodeID: String) -> Int64? { cursors[nodeID] }
    func processedEventIDs(for nodeID: String) -> [Int64] { processed[nodeID] ?? [] }
    func closeObservationsWhenMarked(for nodeID: String) -> [Bool] { closeObservations[nodeID] ?? [] }
}

private enum ProjectionCleanupTestError: Error, Equatable {
    case unavailable
}

private actor FailOnceProjectionCleaner: V2RevokedDeviceProjectionCleaning {
    private var devices: [DeviceID] = []
    private var revokedAtValues: [Date] = []
    private var shouldFail = true

    func clean(userID _: UserID, deviceID: DeviceID, revokedAt: Date) throws {
        devices.append(deviceID)
        revokedAtValues.append(revokedAt)
        if shouldFail {
            shouldFail = false
            throw ProjectionCleanupTestError.unavailable
        }
    }

    func cleanedDevices() -> [DeviceID] { devices }
    func revocationTimes() -> [Date] { revokedAtValues }
}

private let revocationFixtureDate = Date(timeIntervalSince1970: 1_749_999_900)

private actor RevocationCloseRecorder {
    private var closeCount = 0

    func recordClose() { closeCount += 1 }

    func didRecordClose() -> Bool { closeCount == 1 }

    func waitForClose() async -> Bool {
        for _ in 0 ..< 20 {
            if closeCount == 1 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private struct RevocationAuthFake: V2GatewayAuthenticator {
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) async throws -> V2GatewayAuthentication {
        try .init(userID: .init("00000000-0000-0000-0000-000000000711"), expiresAt: nil)
    }
}

private struct RevocationCommandFake: V2GatewayCommandHandler {
    func handle(envelope _: IMV2Envelope, identity _: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        .init()
    }
}
