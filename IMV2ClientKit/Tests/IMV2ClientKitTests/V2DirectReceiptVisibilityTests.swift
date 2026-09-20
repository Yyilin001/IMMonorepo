import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Direct receipt visibility versions")
struct V2DirectReceiptVisibilityTests {
    @Test("late preference updates cannot restore an older privacy setting")
    func preferenceRevisionOrdering() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-preference-order-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        func apply(_ sequence: UInt64, revision: Int, allowed: Bool, to target: GRDBV2LocalSyncStore) async throws {
            let record = try V2ClientSyncRecord(sequence: sequence, sourceEventID: .init(uuid: UUID()),
                projectionKind: "read_receipt_preferences", payload: JSONSerialization.data(withJSONObject: [
                    "preference_revision": revision, "allows_direct_read_receipts": allowed,
                    "allows_group_read_receipts": true, "updated_at_ms": 1750000000000,
                ]))
            _ = try await target.apply(.init(generation: 1, records: [record],
                nextSyncToken: .init("pref-\(sequence)"), receipt: .init("pref-\(sequence)"),
                hasMore: false, capabilityProfile: "base"))
        }
        try await apply(1, revision: 2, allowed: false, to: store)
        try await apply(2, revision: 1, allowed: true, to: store)
        try await apply(3, revision: 2, allowed: false, to: store)
        #expect(try await store.readReceiptPreference()?.allowsDirectReadReceipts == false)
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await apply(4, revision: 3, allowed: true, to: reopened)
        #expect(try await reopened.readReceiptPreference()?.allowsDirectReadReceipts == true)
        await #expect(throws: V2ClientSocialProjectionError.invalidPayload) {
            try await apply(5, revision: 3, allowed: false, to: reopened)
        }
        #expect(try await reopened.readReceiptPreference()?.allowsDirectReadReceipts == true)
    }


    @Test("hidden versions survive restart and snapshot activation", arguments: [false, true], [Int64(-1), Int64(1750000000000)])
    func lateVisibleReceiptCannotRestoreDisclosure(snapshot: Bool, milliseconds: Int64) async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-receipt-visibility-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let room = RoomID(uuid: UUID()), reader = UserID(uuid: UUID())
        func event(_ sequence: UInt64, _ readerRevision: UInt64, _ viewerRevision: UInt64, visible: Bool, read: UInt64) throws -> V2ClientSyncRecord {
            try .init(sequence: sequence, sourceEventID: .init(uuid: UUID()), projectionKind: "direct_read_receipt",
                payload: JSONSerialization.data(withJSONObject: [
                    "room_id": room.rawValue, "reader_user_id": reader.rawValue,
                    "reader_preference_revision": readerRevision, "viewer_preference_revision": viewerRevision,
                    "is_visible": visible, "read_through_room_sequence": read, "recorded_at_ms": milliseconds,
                ]))
        }
        func apply(_ record: V2ClientSyncRecord, to target: GRDBV2LocalSyncStore, generation: UInt64) async throws {
            _ = try await target.apply(.init(generation: generation, records: [record],
                nextSyncToken: .init("receipt-\(record.sequence)"), receipt: .init("receipt-\(record.sequence)"),
                hasMore: false, capabilityProfile: "base"))
        }
        try await apply(event(1, 0, 0, visible: true, read: 3), to: store, generation: 1)
        #expect(try await store.directReadReceipt(roomID: room)?.readThroughRoomSequence == 3)
        let hidden = try event(2, 1, 0, visible: false, read: 0)
        try await apply(hidden, to: store, generation: 1)
        #expect(try await store.directReadReceipt(roomID: room) == nil)
        let generation: UInt64 = snapshot ? 2 : 1
        if snapshot {
            let reset = try V2ClientResetRequired(snapshotID: .init("receipt-snapshot"), generation: 2, baseSequence: 2, expiresAt: .distantFuture)
            let page = try V2SnapshotProjectionV3Page(items: [.init(
                key: .init(projectionKind: hidden.projectionKind, entityKey: room.rawValue),
                sourceEventID: hidden.sourceEventID, sequence: hidden.sequence, payload: hidden.payload)])
            let bytes = try V2SnapshotProjectionV3Codec.encode(page)
            let digest = V2SnapshotV3Digest.page(bytes)
            let initial = V2SnapshotV3Digest.initial(baseSequence: 2, capabilityProfile: "base")
            let root = V2SnapshotV3Digest.next(previous: initial, pageIndex: 0, pageDigest: digest,
                firstKey: page.firstKey, lastKey: page.lastKey, itemCount: 1)
            let manifest = try V2ClientSnapshotManifest(reset: reset, rootDigest: root, pageCount: 1,
                totalItems: 1, totalBytes: UInt64(bytes.count), nextSyncToken: .init("receipt-snapshot-next"),
                receipt: .init("receipt-snapshot-receipt"), capabilityProfile: "base")
            try await store.beginReset(reset)
            try await store.beginSnapshotImport(manifest, initialDigest: initial)
            try await store.applySnapshotPage(.init(index: 0, digest: digest, firstKey: page.firstKey,
                lastKey: page.lastKey, itemCount: 1, payload: bytes), for: manifest)
            try await store.prepareSnapshotActivation(manifest)
            try await store.activateAcknowledgedSnapshot(manifest)
        }
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await apply(event(3, 0, 0, visible: true, read: 100), to: reopened, generation: generation)
        #expect(try await reopened.directReadReceipt(roomID: room) == nil)
        try await apply(event(4, 2, 0, visible: true, read: 101), to: reopened, generation: generation)
        #expect(try await reopened.directReadReceipt(roomID: room)?.readThroughRoomSequence == 101)
        try await apply(event(5, 1, 0, visible: false, read: 0), to: reopened, generation: generation)
        #expect(try await reopened.directReadReceipt(roomID: room)?.readThroughRoomSequence == 101)
        try await apply(event(6, 2, 1, visible: false, read: 0), to: reopened, generation: generation)
        #expect(try await reopened.directReadReceipt(roomID: room) == nil)
        await #expect(throws: V2ClientSocialProjectionError.invalidPayload) {
            try await apply(event(7, 1, 2, visible: true, read: 102), to: reopened, generation: generation)
        }
        await #expect(throws: V2ClientSocialProjectionError.invalidPayload) {
            try await apply(event(7, 2, 1, visible: true, read: 102), to: reopened, generation: generation)
        }
        #expect(try await reopened.directReadReceipt(roomID: room) == nil)
        // A delayed policy refresh after reenable carries no read progress.
        try await apply(event(7, 3, 1, visible: true, read: 0), to: reopened, generation: generation)
        #expect(try await reopened.directReadReceipt(roomID: room) == nil)
        let policyRestored = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await apply(event(8, 3, 1, visible: true, read: 102), to: policyRestored, generation: generation)
        #expect(try await policyRestored.directReadReceipt(roomID: room)?.readThroughRoomSequence == 102)
        try await apply(event(9, 3, 1, visible: true, read: 0), to: policyRestored, generation: generation)
        try await apply(event(10, 2, 1, visible: false, read: 0), to: policyRestored, generation: generation)
        #expect(try await policyRestored.directReadReceipt(roomID: room)?.readThroughRoomSequence == 102)
    }
}
