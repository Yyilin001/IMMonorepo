@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

struct V2SyncResponseBoundsTests {
    @Test(arguments: [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func recordConstruction(value: UInt64) throws {
        func construct() throws -> V2SyncRecord {
            try .init(sequence: value, sourceEventID: .init("event"), projectionKind: "message", payloadJSON: "{}")
        }
        if value == 0 || value > UInt64(Int64.max) {
            #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try construct() }
        } else {
            #expect(try construct().sequence == value)
        }
    }

    @Test(arguments: ["readyGeneration", "record", "preparingGeneration", "resetGeneration", "resetBase"], [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func returnedBounds(field: String, value: UInt64) async throws {
        if field == "record" && (value == 0 || value > UInt64(Int64.max)) {
            #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                try V2SyncRecord(sequence: value, sourceEventID: .init("event"), projectionKind: "message", payloadJSON: "{}")
            }
            return
        }
        let expected: V2SyncPullResult
        switch field {
        case "readyGeneration", "record":
            expected = try .ready(generation: field == "readyGeneration" ? value : 1,
                records: [.init(sequence: field == "record" ? value : 1, sourceEventID: .init("event"), projectionKind: "message", payloadJSON: "{}")],
                nextSyncToken: .init("token"), receipt: .init("receipt"), hasMore: false)
        case "preparingGeneration": expected = try .resetPreparing(snapshotID: .init("snapshot"), generation: value, retryAfter: 1)
        default: expected = try .resetRequired(snapshotID: .init("snapshot"), generation: field == "resetGeneration" ? value : 1, baseSequence: field == "resetBase" ? value : 0, expiresAt: Date(timeIntervalSince1970: 1000))
        }
        let service = V2SyncService(store: SyncResponseBoundsStore(result: expected))
        let user = try UserID("user"), device = try DeviceID("device")
        if value > UInt64(Int64.max) || (value == 0 && field != "resetBase") {
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                try await service.pull(userID: user, deviceID: device, syncToken: nil, requestedMaxRecords: 1)
            }
        } else {
            #expect(try await service.pull(userID: user, deviceID: device, syncToken: nil, requestedMaxRecords: 1) == expected)
        }
    }
}

private struct SyncResponseBoundsStore: V2SyncStore {
    let result: V2SyncPullResult
    func pull(userID: UserID, deviceID: DeviceID, syncToken: V2SyncToken?, maxRecords: Int, requireSnapshot: Bool, now: Date) async throws -> V2SyncPullResult { result }
    func acknowledge(userID: UserID, deviceID: DeviceID, generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws { throw V2SyncServiceError.invalidRequest }
    func fetchSnapshotManifest(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, now: Date) async throws -> V2SnapshotManifest { throw V2SyncServiceError.invalidRequest }
    func fetchSnapshotPage(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, rootDigest: String, index: UInt32, now: Date) async throws -> V2SnapshotPage { throw V2SyncServiceError.invalidRequest }
    func acknowledgeSnapshot(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws { throw V2SyncServiceError.invalidRequest }
}
