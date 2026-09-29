@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

struct V2SnapshotResponseBoundsTests {
    @Test(arguments: ["empty", "one", "pagesWithoutItems", "pagesWithoutBytes", "itemsWithoutPages", "bytesWithoutPages", "tooFewItems", "tooManyItems", "tooFewBytes", "tooManyBytes"])
    func manifestConsistency(scenario: String) async throws {
        let counts: (UInt32, UInt64, UInt64) = switch scenario {
        case "empty": (0, 0, 0)
        case "one": (1, 1, 1)
        case "pagesWithoutItems": (1, 0, 1)
        case "pagesWithoutBytes": (1, 1, 0)
        case "itemsWithoutPages": (0, 1, 0)
        case "bytesWithoutPages": (0, 0, 1)
        case "tooFewItems": (2, 1, 2)
        case "tooManyItems": (1, 501, 1)
        case "tooManyBytes": (1, 1, UInt64(V2SnapshotProjectionV3Codec.maximumPageBytes) + 1)
        default: (2, 2, 1)
        }
        let service = V2SyncService(store: SnapshotResponseBoundsStore(field: "counts", value: 0, counts: counts))
        func fetch() async throws -> V2SnapshotManifest {
            try await service.fetchSnapshotManifest(userID: .init("user"), deviceID: .init("device"), snapshotID: .init("snapshot"), generation: 1)
        }
        if ["empty", "one"].contains(scenario) {
            let result = try await fetch()
            #expect(result.pageCount == counts.0 && result.totalItems == counts.1 && result.totalBytes == counts.2)
        } else {
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await fetch() }
        }
    }

    @Test(arguments: ["itemCount", "payloadBytes"])
    func pageCounts(field: String) async throws {
        let upper = UInt64(field == "itemCount" ? V2SnapshotProjectionV3Codec.maximumPageItems : V2SnapshotProjectionV3Codec.maximumPageBytes)
        let values = field == "itemCount" ? [UInt64(0), 1, upper, upper + 1, UInt64(UInt32.max)] : [UInt64(0), 1, upper, upper + 1]
        for value in values {
            let service = V2SyncService(store: SnapshotResponseBoundsStore(field: field, value: value))
            let user = try UserID("user"), device = try DeviceID("device"), snapshot = try SnapshotID("snapshot")
            if value == 0 || value > upper {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                    try await service.fetchSnapshotPage(userID: user, deviceID: device, snapshotID: snapshot, generation: 1, rootDigest: "root", index: 0)
                }
            } else {
                let page = try await service.fetchSnapshotPage(userID: user, deviceID: device, snapshotID: snapshot, generation: 1, rootDigest: "root", index: 0)
                #expect((field == "itemCount" ? UInt64(page.itemCount) : UInt64(page.payload.count)) == value)
            }
        }
    }

    @Test(arguments: ["pageCount", "totalItems", "totalBytes"])
    func manifestCounts(field: String) async throws {
        let upper: UInt64 = field == "pageCount" ? UInt64(V2SnapshotProjectionV3Codec.maximumPageCount) : field == "totalItems" ? V2SnapshotProjectionV3Codec.maximumTotalItems : min(V2SnapshotProjectionV3Codec.maximumTotalBytes, UInt64(V2SnapshotProjectionV3Codec.maximumPageCount) * UInt64(V2SnapshotProjectionV3Codec.maximumPageBytes))
        let maximum: UInt64 = field == "pageCount" ? UInt64(UInt32.max) : UInt64.max
        for value in [UInt64(0), 1, upper, upper + 1, maximum] {
            let service = V2SyncService(store: SnapshotResponseBoundsStore(field: field, value: value))
            let user = try UserID("user"), device = try DeviceID("device"), snapshot = try SnapshotID("snapshot")
            if value > upper {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                    try await service.fetchSnapshotManifest(userID: user, deviceID: device, snapshotID: snapshot, generation: 1)
                }
            } else {
                let manifest = try await service.fetchSnapshotManifest(userID: user, deviceID: device, snapshotID: snapshot, generation: 1)
                let actual = field == "pageCount" ? UInt64(manifest.pageCount) : field == "totalItems" ? manifest.totalItems : manifest.totalBytes
                #expect(actual == value)
            }
        }
    }

    @Test(arguments: ["manifestID", "manifestGenerationMismatch", "pageID", "pageGenerationMismatch", "pageRoot", "pageIndex"])
    func responseMatchesRequest(field: String) async throws {
        let service = V2SyncService(store: SnapshotResponseBoundsStore(field: field, value: 2))
        let user = try UserID("user"), device = try DeviceID("device"), snapshot = try SnapshotID("snapshot")
        await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
            if field.hasPrefix("manifest") {
                _ = try await service.fetchSnapshotManifest(userID: user, deviceID: device, snapshotID: snapshot, generation: 1)
            } else {
                _ = try await service.fetchSnapshotPage(userID: user, deviceID: device, snapshotID: snapshot, generation: 1, rootDigest: "root", index: 0)
            }
        }
    }

    @Test(arguments: ["manifestGeneration", "base", "pageGeneration"], [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func returnedBounds(field: String, value: UInt64) async throws {
        let service = V2SyncService(store: SnapshotResponseBoundsStore(field: field, value: value))
        let user = try UserID("user"), device = try DeviceID("device"), snapshot = try SnapshotID("snapshot")
        let requestedGeneration = field != "base" && value > 0 && value <= UInt64(Int64.max) ? value : 1
        func responseValue() async throws -> UInt64 {
            if field == "pageGeneration" {
                return try await service.fetchSnapshotPage(userID: user, deviceID: device, snapshotID: snapshot, generation: requestedGeneration, rootDigest: "root", index: 0).generation
            }
            let manifest = try await service.fetchSnapshotManifest(userID: user, deviceID: device, snapshotID: snapshot, generation: requestedGeneration)
            return field == "base" ? manifest.baseSequence : manifest.generation
        }
        if value > UInt64(Int64.max) || (value == 0 && field != "base") {
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await responseValue() }
        } else { #expect(try await responseValue() == value) }
    }
}

private struct SnapshotResponseBoundsStore: V2SyncStore {
    let field: String
    let value: UInt64
    var counts: (UInt32, UInt64, UInt64)? = nil
    func pull(userID: UserID, deviceID: DeviceID, syncToken: V2SyncToken?, maxRecords: Int, requireSnapshot: Bool, now: Date) async throws -> V2SyncPullResult { throw V2SyncServiceError.invalidRequest }
    func acknowledge(userID: UserID, deviceID: DeviceID, generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws { throw V2SyncServiceError.invalidRequest }
    func fetchSnapshotManifest(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, now: Date) async throws -> V2SnapshotManifest {
        let derived: (UInt32, UInt64, UInt64)
        switch field {
        case "pageCount": derived = (UInt32(value), value, value)
        case "totalItems":
            let pages = min(UInt64(V2SnapshotProjectionV3Codec.maximumPageCount), value / 500 + (value % 500 == 0 ? 0 : 1))
            derived = (UInt32(pages), value, pages)
        case "totalBytes":
            let maximumBytes = UInt64(V2SnapshotProjectionV3Codec.maximumPageBytes)
            let pages = min(UInt64(V2SnapshotProjectionV3Codec.maximumPageCount), value / maximumBytes + (value % maximumBytes == 0 ? 0 : 1))
            derived = (UInt32(pages), pages, value)
        default: derived = (0, 0, 0)
        }
        let totals = counts ?? derived
        return try .init(snapshotID: field == "manifestID" ? .init("other") : snapshotID, generation: field == "manifestGeneration" || field == "manifestGenerationMismatch" ? value : generation,
                  baseSequence: field == "base" ? value : 0, rootDigest: "root", schemaVersion: 31,
                  capabilityProfile: "test", pageCount: totals.0,
                  totalItems: totals.1, totalBytes: totals.2,
                  nextSyncToken: .init("token"), receipt: .init("receipt"), expiresAt: now.addingTimeInterval(60))
    }
    func fetchSnapshotPage(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, rootDigest: String, index: UInt32, now: Date) async throws -> V2SnapshotPage {
        let key = try V2SnapshotProjectionKey(projectionKind: "message", entityKey: "message")
        return try .init(snapshotID: field == "pageID" ? .init("other") : snapshotID,
                     generation: field == "pageGeneration" || field == "pageGenerationMismatch" ? value : generation,
                     rootDigest: field == "pageRoot" ? "other" : rootDigest, index: field == "pageIndex" ? 1 : index,
                     firstKey: key, lastKey: key, itemCount: field == "itemCount" ? UInt32(value) : 1, digest: "page",
                     payload: field == "payloadBytes" ? Data(repeating: 1, count: Int(value)) : Data([1]))
    }
    func acknowledgeSnapshot(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws { throw V2SyncServiceError.invalidRequest }
}
