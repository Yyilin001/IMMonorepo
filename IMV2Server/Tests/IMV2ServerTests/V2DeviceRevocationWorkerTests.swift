import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 device revocation worker")
struct V2DeviceRevocationWorkerTests {
    @Test("every event is acknowledged only after local revocation handling")
    func consumesEventsInOrderForItsNode() async throws {
        let device = try DeviceID("00000000-0000-0000-0000-000000000701")
        let firstUser = try UserID("00000000-0000-0000-0000-000000000702")
        let secondUser = try UserID("00000000-0000-0000-0000-000000000703")
        let secondDevice = try DeviceID("00000000-0000-0000-0000-000000000704")
        let store = InMemoryDeviceRevocationEventStore(events: [
            .init(eventID: 8, userID: firstUser, deviceID: device),
            .init(eventID: 9, userID: secondUser, deviceID: secondDevice),
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
                capabilityProfile: "base"
            ),
            handler: RevocationCommandFake(),
            registry: registry
        )
        let closeRecorder = RevocationCloseRecorder()
        await stream.setDeviceRevocationHandler {
            await closeRecorder.recordClose()
        }
        await registry.register(
            stream,
            connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000713")!,
            identity: .init(userID: user, deviceID: device, capabilityProfile: "base")
        )
        #expect(await registry.connectionCount(for: device) == 1)

        let store = InMemoryDeviceRevocationEventStore(
            events: [.init(eventID: 10, userID: user, deviceID: device)],
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
}

private actor InMemoryDeviceRevocationEventStore: V2DeviceRevocationEventStore {
    private let events: [V2DeviceRevocationEvent]
    private let didCloseBeforeMarking: (@Sendable () async -> Bool)?
    private var processed: [String: [Int64]] = [:]
    private var closeObservations: [String: [Bool]] = [:]

    init(
        events: [V2DeviceRevocationEvent],
        didCloseBeforeMarking: (@Sendable () async -> Bool)? = nil
    ) {
        self.events = events
        self.didCloseBeforeMarking = didCloseBeforeMarking
    }

    func events(afterCursorFor nodeID: String, limit: Int) -> [V2DeviceRevocationEvent] {
        let cursor = processed[nodeID]?.last ?? 0
        return Array(events.filter { $0.eventID > cursor }.prefix(limit))
    }

    func markProcessed(eventID: Int64, nodeID: String, now _: Date) async {
        if let didCloseBeforeMarking {
            closeObservations[nodeID, default: []].append(await didCloseBeforeMarking())
        }
        processed[nodeID, default: []].append(eventID)
    }

    func processedEventIDs(for nodeID: String) -> [Int64] { processed[nodeID] ?? [] }
    func closeObservationsWhenMarked(for nodeID: String) -> [Bool] { closeObservations[nodeID] ?? [] }
}

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
    func authenticate(accessToken _: String, deviceID _: DeviceID) async throws -> UserID {
        try .init("00000000-0000-0000-0000-000000000711")
    }
}

private struct RevocationCommandFake: V2GatewayCommandHandler {
    func handle(envelope _: IMV2Envelope, identity _: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        .init()
    }
}
