import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 snapshot V3 service contract")
struct V2SyncServiceSnapshotTests {
    @Test("manifest and page requests preserve the V3 generation and root fence")
    func forwardsManifestAndPageFence() async throws {
        let store = RecordingSnapshotV3Store()
        let service = V2SyncService(store: store, now: { Date(timeIntervalSince1970: 1_750_000_000) })
        let userID = try UserID("00000000-0000-0000-0000-000000000801")
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000802")
        let snapshotID = try SnapshotID("00000000-0000-0000-0000-000000000803")

        let manifest = try await service.fetchSnapshotManifest(
            userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: 7
        )
        let page = try await service.fetchSnapshotPage(
            userID: userID, deviceID: deviceID, snapshotID: snapshotID,
            generation: 7, rootDigest: manifest.rootDigest, index: 0
        )

        #expect(manifest.schemaVersion == V2SnapshotProjectionV3Codec.schemaVersion)
        #expect(page.rootDigest == manifest.rootDigest)
        #expect(page.firstKey == page.lastKey)
        #expect(await store.requestedRootDigest() == manifest.rootDigest)
    }

    @Test("snapshot acknowledgement forwards the exact base and receipt fence")
    func forwardsAcknowledgementFence() async throws {
        let store = RecordingSnapshotV3Store()
        let service = V2SyncService(store: store, now: { Date(timeIntervalSince1970: 1_750_000_000) })
        try await service.acknowledgeSnapshot(
            userID: .init("00000000-0000-0000-0000-000000000801"),
            deviceID: .init("00000000-0000-0000-0000-000000000802"),
            snapshotID: .init("00000000-0000-0000-0000-000000000803"),
            generation: 7, baseSequence: 42, receipt: .init("snapshot-receipt")
        )
        #expect(await store.acknowledgedFence() == .init(generation: 7, base: 42, receipt: "snapshot-receipt"))
    }
}

private actor RecordingSnapshotV3Store: V2SyncStore {
    struct Ack: Equatable { let generation: UInt64; let base: UInt64; let receipt: String }
    private var root: String?
    private var ack: Ack?

    func pull(userID _: UserID, deviceID _: DeviceID, syncToken _: V2SyncToken?, maxRecords _: Int, now _: Date) throws -> V2SyncPullResult { throw V2SyncStoreError.invalidOrExpiredSyncToken }
    func acknowledge(userID _: UserID, deviceID _: DeviceID, generation _: UInt64, highestContiguousSequence _: UInt64, receipt _: V2SyncReceipt, now _: Date) {}
    func fetchSnapshotManifest(userID _: UserID, deviceID _: DeviceID, snapshotID: SnapshotID, generation: UInt64, now _: Date) throws -> V2SnapshotManifest {
        let digest = V2SnapshotV3Digest.initial(baseSequence: 42, capabilityProfile: "base")
        return .init(snapshotID: snapshotID, generation: generation, baseSequence: 42, rootDigest: digest, schemaVersion: V2SnapshotProjectionV3Codec.schemaVersion, capabilityProfile: "base", pageCount: 1, totalItems: 1, totalBytes: 10, nextSyncToken: try .init("snapshot-token"), receipt: try .init("snapshot-receipt"), expiresAt: .distantFuture)
    }
    func fetchSnapshotPage(userID _: UserID, deviceID _: DeviceID, snapshotID: SnapshotID, generation: UInt64, rootDigest: String, index: UInt32, now _: Date) throws -> V2SnapshotPage {
        self.root = rootDigest
        let key = try V2SnapshotProjectionKey(projectionKind: "relationship", entityKey: "00000000-0000-0000-0000-000000000804")
        return .init(snapshotID: snapshotID, generation: generation, rootDigest: rootDigest, index: index, firstKey: key, lastKey: key, itemCount: 1, digest: String(repeating: "a", count: 64), payload: Data("page".utf8))
    }
    func acknowledgeSnapshot(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation: UInt64, baseSequence: UInt64, receipt: V2SyncReceipt, now _: Date) { ack = .init(generation: generation, base: baseSequence, receipt: receipt.rawValue) }
    func requestedRootDigest() -> String? { root }
    func acknowledgedFence() -> Ack? { ack }
}
