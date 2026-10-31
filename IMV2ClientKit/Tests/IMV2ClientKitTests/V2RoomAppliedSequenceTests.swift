import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

private let appliedSequenceInstallationBinding = V2LocalInstallationBinding(
    value: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
)

/// "本地已应用到的房间序号"是"进入房间即已读"要推进到的位置（合同 §5.4）。
///
/// 只按最后一条可见消息上报会让房间尾部是非消息事件时未读永久停在 1，因此这里固定
/// 该访问器确实覆盖**非消息事件**。
struct V2RoomAppliedSequenceTests {
    @Test("an edit-only tail still advances the applied sequence")
    func editOnlyTailAdvances() async throws {
        let (store, directory) = try makeAppliedSequenceStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let room = try RoomID("00000000-0000-0000-0000-0000000004a0")

        // 编辑既不改消息行的房间序号，也不落进任何"按事件序号保存"的投影表：
        // 只有可靠房间日志的游标与事件表能证明它已经被应用。
        _ = try await store.applyGroupEventPage(try roomPage(
            room: room,
            events: [
                try .init(
                    sourceEventID: .init("00000000-0000-0000-0000-0000000004a1"),
                    roomSequence: 7,
                    projectionKind: "message",
                    payload: appliedSequenceMessagePayload(room: room, roomSequence: 7)
                ),
                try .init(
                    sourceEventID: .init("00000000-0000-0000-0000-0000000004a2"),
                    roomSequence: 8,
                    projectionKind: "message",
                    payload: appliedSequenceEditPayload(room: room, roomSequence: 8)
                )
            ],
            nextRoomSequence: 8
        ))

        #expect(try await store.roomAppliedRoomSequence(roomID: room) == 8)
        #expect(try await store.groupEventCursor(roomID: room) == 8)
    }

    @Test("a reaction-only room-log tail advances the applied room sequence")
    func reactionOnTheRoomLogAdvances() async throws {
        let (store, directory) = try makeAppliedSequenceStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let room = try RoomID("00000000-0000-0000-0000-0000000004b0")
        let messageID = try MessageID("00000000-0000-0000-0000-0000000004b1")

        // Reactions share the room log with messages, including standard groups.
        _ = try await store.applyGroupEventPage(roomPage(
            room: room,
            events: [
                try V2ClientGroupEvent(
                    sourceEventID: .init("00000000-0000-0000-0000-0000000004b2"),
                    roomSequence: 4,
                    projectionKind: "message",
                    payload: appliedSequenceMessagePayload(room: room, roomSequence: 4)
                ),
                try V2ClientGroupEvent(
                    sourceEventID: .init("00000000-0000-0000-0000-0000000004b3"),
                    roomSequence: 5,
                    projectionKind: "message_reaction",
                    payload: try JSONSerialization.data(withJSONObject: [
                        "event_type": "message.reaction_changed",
                        "room_id": room.rawValue,
                        "message_id": messageID.rawValue,
                        "actor_user_id": "00000000-0000-0000-0000-0000000004b4",
                        "reaction": "👍",
                        "action": "add",
                        "room_sequence": 5
                    ])
                )
            ],
            nextRoomSequence: 5
        ))

        #expect(try await store.roomAppliedRoomSequence(roomID: room) == 5)
        #expect(try await store.groupEventCursor(roomID: room) == 5)
        #expect(try await store.cursor() == nil)
    }

    @Test("a room with no local evidence has no applied sequence")
    func roomWithoutEvidenceStaysAtZero() async throws {
        let (store, directory) = try makeAppliedSequenceStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 零表示"本地没有任何该房间事件的证据"，界面据此不推进已读线。
        #expect(try await store.roomAppliedRoomSequence(roomID: .init("00000000-0000-0000-0000-0000000004c0")) == 0)
    }
}

private func makeAppliedSequenceStore() throws -> (GRDBV2LocalSyncStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "im-v2-applied-sequence-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try GRDBV2LocalSyncStore(
        databaseURL: directory.appending(path: "state.sqlite"),
        installationBinding: appliedSequenceInstallationBinding
    )
    return (store, directory)
}

private func roomPage(
    room: RoomID,
    events: [V2ClientGroupEvent],
    nextRoomSequence: UInt64
) throws -> V2ClientGroupEventPage {
    try .init(roomID: room, events: events, nextRoomSequence: nextRoomSequence, hasMore: false)
}

private func appliedSequenceMessagePayload(room: RoomID, roomSequence: UInt64) -> Data {
    appliedSequencePayload([
        "event_type": "message.accepted",
        "room_id": room.rawValue,
        "room_sequence": roomSequence,
        "message_id": String(format: "00000000-0000-0000-0000-%012llu", roomSequence),
        "message_revision": 1,
        "sender_user_id": "00000000-0000-0000-0000-0000000004ff",
        "text": "消息 \(roomSequence)",
        "server_created_at_ms": 1_750_000_000_000
    ])
}

private func appliedSequenceEditPayload(room: RoomID, roomSequence: UInt64) -> Data {
    appliedSequencePayload([
        "event_type": "message.edited",
        "room_id": room.rawValue,
        "room_sequence": roomSequence,
        "message_id": "00000000-0000-0000-0000-000000000007",
        "message_revision": 2,
        "text": "编辑后的文本"
    ])
}

private func appliedSequencePayload(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}
