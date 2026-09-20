import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

private let watermarkTestInstallationBinding = V2LocalInstallationBinding(
    value: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
)

struct V2RoomReadWatermarkTests {
    @Test("an own-read-watermark projection advances the local read line", arguments: [Int64(-1), Int64(1750000000000)])
    func ownReadWatermarkAdvancesLocalState(milliseconds: Int64) async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let room = RoomID(uuid: UUID())

        _ = try await store.apply(batch([
            try watermarkRecord(sequence: 1, room: room, watermark: 42, recordedAtMilliseconds: milliseconds)
        ]))

        #expect(try await store.roomReadWatermark(roomID: room) == 42)
    }

    @Test("a stale or out-of-order watermark never moves the local read line backwards")
    func staleWatermarkIsIgnored() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let room = RoomID(uuid: UUID())

        // The second record is an older reading that arrives later. The local
        // line must keep the highest value because unread counts are derived
        // from it and a regression would resurrect already-read messages.
        _ = try await store.apply(batch([
            try watermarkRecord(sequence: 1, room: room, watermark: 42, recordedAtMilliseconds: 1_750_000_000_000),
            try watermarkRecord(sequence: 2, room: room, watermark: 7, recordedAtMilliseconds: 1_750_000_000_500)
        ]))
        #expect(try await store.roomReadWatermark(roomID: room) == 42)

        _ = try await store.apply(batch([
            try watermarkRecord(sequence: 3, room: room, watermark: 100, recordedAtMilliseconds: 1_750_000_001_000)
        ]))
        #expect(try await store.roomReadWatermark(roomID: room) == 100)
    }

    @Test("a malformed watermark payload is rejected instead of being applied")
    func malformedWatermarkIsRejected() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let room = RoomID(uuid: UUID())

        await #expect(throws: V2ClientSocialProjectionError.self) {
            _ = try await store.apply(batch([
                try V2ClientSyncRecord(
                    sequence: 1,
                    sourceEventID: .init(uuid: UUID()),
                    projectionKind: "own_read_watermark",
                    payload: try JSONSerialization.data(withJSONObject: [
                        "room_id": room.rawValue,
                        "read_through_room_sequence": 0,
                        "recorded_at_ms": 1_750_000_000_000
                    ])
                )
            ]))
        }
        #expect(try await store.roomReadWatermark(roomID: room) == nil)
    }

    @Test("a locally queued receipt advances the read line without a round trip")
    func queuedReceiptAdvancesLocalState() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let room = RoomID(uuid: UUID())
        // 传输永远失败：回执留在待发送状态，但进入房间的本地效果必须立刻生效，
        // 否则离线打开房间后未读会一直挂着，直到下次联网才归零。
        let outbox = V2ReadReceiptOutboxEngine(store: store, transport: WatermarkFailingReceiptTransport())
        let pending = try await outbox.enqueueReceipt(roomID: room, readThroughRoomSequence: 9)
        _ = try await outbox.flushOnce()

        #expect(try await store.pendingReadReceipts().first?.state == .pending)
        #expect(try await store.roomReadWatermark(roomID: room) == 9)
        #expect(try await store.roomReadWatermarks(roomIDs: [room]) == [room: 9])

        // 被拒绝的回执不得计入：一次越界上报不能让未读被永久压低。
        try await store.rejectReadReceipt(operationID: pending.operationID, code: "INVALID_ARGUMENT")
        #expect(try await store.roomReadWatermark(roomID: room) == nil)
    }
}

private struct WatermarkFailingReceiptTransport: V2ClientReadReceiptTransport {
    func recordReadReceipt(roomID _: RoomID, operationID _: ReadReceiptOperationID, readThroughRoomSequence _: UInt64) async throws -> V2ClientReadReceipt {
        throw V2RealtimeTransportError.unexpectedResponse
    }

    func setReadReceiptPreferences(operationID _: ReadReceiptPreferenceOperationID, allowsDirectReadReceipts _: Bool, allowsGroupReadReceipts _: Bool) async throws -> V2ReadReceiptPreferences {
        throw V2RealtimeTransportError.unexpectedResponse
    }

    func listReadReceiptReaders(roomID _: RoomID, messageID _: MessageID, cursor _: String?, pageSize _: Int) async throws -> V2ReadReceiptReadersPage {
        throw V2RealtimeTransportError.unexpectedResponse
    }
}

private func makeStore() throws -> (GRDBV2LocalSyncStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "im-v2-watermark-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try GRDBV2LocalSyncStore(
        databaseURL: directory.appending(path: "state.sqlite"),
        installationBinding: watermarkTestInstallationBinding
    )
    return (store, directory)
}

private func batch(_ records: [V2ClientSyncRecord]) throws -> V2ClientSyncBatch {
    try .init(
        generation: 1,
        records: records,
        nextSyncToken: .init("watermark-token"),
        receipt: .init("watermark-receipt"),
        hasMore: false,
        capabilityProfile: "base"
    )
}

private func watermarkRecord(
    sequence: UInt64,
    room: RoomID,
    watermark: UInt64,
    recordedAtMilliseconds: Int64
) throws -> V2ClientSyncRecord {
    try .init(
        sequence: sequence,
        sourceEventID: .init(uuid: UUID()),
        projectionKind: "own_read_watermark",
        payload: try JSONSerialization.data(withJSONObject: [
            "room_id": room.rawValue,
            "read_through_room_sequence": watermark,
            "recorded_at_ms": recordedAtMilliseconds
        ])
    )
}
