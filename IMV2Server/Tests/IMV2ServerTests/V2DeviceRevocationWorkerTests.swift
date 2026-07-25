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
}

private actor InMemoryDeviceRevocationEventStore: V2DeviceRevocationEventStore {
    private let events: [V2DeviceRevocationEvent]
    private var processed: [String: [Int64]] = [:]

    init(events: [V2DeviceRevocationEvent]) { self.events = events }

    func events(afterCursorFor nodeID: String, limit: Int) -> [V2DeviceRevocationEvent] {
        let cursor = processed[nodeID]?.last ?? 0
        return Array(events.filter { $0.eventID > cursor }.prefix(limit))
    }

    func markProcessed(eventID: Int64, nodeID: String, now _: Date) {
        processed[nodeID, default: []].append(eventID)
    }

    func processedEventIDs(for nodeID: String) -> [Int64] { processed[nodeID] ?? [] }
}
