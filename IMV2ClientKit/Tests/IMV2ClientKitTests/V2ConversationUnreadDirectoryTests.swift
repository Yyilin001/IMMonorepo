import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("V2 conversation unread directory")
struct V2ConversationUnreadDirectoryTests {
    @Test("rotation walks bounded pages and persists the cursor between runs")
    func rotationWalksAndResumes() async throws {
        let (store, directory) = try makeUnreadStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try RoomID("00000000-0000-0000-0000-000000000370")
        let second = try RoomID("00000000-0000-0000-0000-000000000371")
        let third = try RoomID("00000000-0000-0000-0000-000000000372")
        let base = Date(timeIntervalSince1970: 1_750_008_000)
        let transport = PagedUnreadTransport(pages: [
            unreadPage([(first, 10, 4), (second, 6, 1)], at: base, next: "cursor-1"),
            unreadPage([(third, 3, 3)], at: base.addingTimeInterval(-60), next: nil),
        ])
        let reader = V2ClientConversationUnreadDirectory(
            transport: transport, store: store, watermarks: store,
            now: { Date(timeIntervalSince1970: 1_750_008_500) }
        )

        let firstPass = try await reader.refresh(pageBudget: 1)

        #expect(firstPass.pagesFetched == 1)
        #expect(firstPass.roomsRecorded == 2)
        #expect(firstPass.rotation == .init(cursor: "cursor-1", cycle: 0))
        #expect(!firstPass.completedCycle)

        // 新实例模拟进程重启：轮转必须从持久化游标继续，而不是从头再来。
        let resumed = V2ClientConversationUnreadDirectory(
            transport: transport, store: store, watermarks: store,
            now: { Date(timeIntervalSince1970: 1_750_008_600) }
        )
        let secondPass = try await resumed.refresh(pageBudget: 1)

        #expect(secondPass.pagesFetched == 1)
        #expect(secondPass.roomsRecorded == 1)
        #expect(secondPass.rotation == .init(cursor: nil, cycle: 1))
        #expect(secondPass.completedCycle)
        #expect(await transport.requestedCursors() == [nil, "cursor-1"])

        let rows = try await resumed.snapshot(roomIDs: [first, second, third])
        #expect(rows[first]?.serverUnreadCount == 4)
        #expect(rows[second]?.serverUnreadCount == 1)
        #expect(rows[third]?.serverUnreadCount == 3)
    }

    @Test("one refresh costs exactly the page budget it is given")
    func boundsWorkPerRefresh() async throws {
        let (store, directory) = try makeUnreadStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = Date(timeIntervalSince1970: 1_750_009_000)
        let transport = PagedUnreadTransport(pages: [
            unreadPage([(try RoomID("00000000-0000-0000-0000-000000000373"), 1, 1)], at: base, next: "c1"),
            unreadPage([(try RoomID("00000000-0000-0000-0000-000000000374"), 1, 1)], at: base, next: "c2"),
            unreadPage([(try RoomID("00000000-0000-0000-0000-000000000375"), 1, 1)], at: base, next: nil),
        ])
        let reader = V2ClientConversationUnreadDirectory(transport: transport, store: store, watermarks: store)

        let report = try await reader.refresh(pageBudget: 2)

        #expect(report.pagesFetched == 2)
        #expect(report.rotation == .init(cursor: "c2", cycle: 0))
        #expect(await transport.requestedCursors() == [nil, "c1"])
    }

    @Test("a completed cycle drops rooms that no longer appear")
    func completedCyclePrunesStaleRooms() async throws {
        let (store, directory) = try makeUnreadStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = try RoomID("00000000-0000-0000-0000-000000000376")
        let left = try RoomID("00000000-0000-0000-0000-000000000377")
        let base = Date(timeIntervalSince1970: 1_750_010_000)
        let transport = PagedUnreadTransport(pages: [
            unreadPage([(kept, 2, 2), (left, 5, 5)], at: base, next: nil),
            unreadPage([(kept, 2, 0)], at: base, next: nil),
        ])
        let reader = V2ClientConversationUnreadDirectory(transport: transport, store: store, watermarks: store)

        _ = try await reader.refresh(pageBudget: 1)
        #expect(try await store.unreadEntries(roomIDs: [kept, left]).count == 2)

        let second = try await reader.refresh(pageBudget: 1)

        #expect(second.completedCycle)
        #expect(try await store.unreadEntries(roomIDs: [kept, left]).keys.sorted() == [kept])
    }

    @Test("snapshot applies the local read line and omits rooms it has never seen")
    func snapshotUsesLocalReadLine() async throws {
        let (store, directory) = try makeUnreadStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let read = try RoomID("00000000-0000-0000-0000-000000000378")
        let unseen = try RoomID("00000000-0000-0000-0000-000000000379")
        let base = Date(timeIntervalSince1970: 1_750_011_000)
        let transport = PagedUnreadTransport(pages: [unreadPage([(read, 10, 5)], at: base, next: nil)])
        let reader = V2ClientConversationUnreadDirectory(transport: transport, store: store, watermarks: store)
        _ = try await reader.refresh(pageBudget: 1)

        // 进入房间：本地回执入队即可，未读立即归零，无需等待服务端。
        try await store.enqueue(V2PendingReadReceipt(
            roomID: read,
            operationID: .init(uuid: UUID()),
            readThroughRoomSequence: 10,
            state: .pending,
            attemptCount: 0,
            nextAttemptAt: base,
            resultingRoomSequence: nil,
            terminalCode: nil
        ))

        let rows = try await reader.snapshot(roomIDs: [read, unseen])

        #expect(rows[read]?.displayedUnread == 0)
        #expect(rows[read]?.serverUnreadCount == 5)
        #expect(rows[read]?.localReadWatermark == 10)
        // 还没被轮转覆盖到的房间不出现：界面据此不显示角标，而不是显示本地推算值。
        #expect(rows[unseen] == nil)
    }
}

private func unreadPage(
    _ rooms: [(RoomID, UInt64, UInt64)],
    at date: Date,
    next: String?
) -> V2ClientRoomSummaryPage {
    .init(
        rooms: rooms.map {
            .init(roomID: $0.0, roomKind: .group, head: $0.1, lastEventAt: date, unreadCount: $0.2, latestMessage: nil)
        },
        nextCursor: next
    )
}

/// 按顺序回答摘要页的传输替身；记录每次请求的游标，用于验证轮转确实按游标推进。
private actor PagedUnreadTransport: V2ClientRoomSummaryTransport {
    private var queued: [V2ClientRoomSummaryPage]
    private var cursors: [String?] = []

    init(pages: [V2ClientRoomSummaryPage]) {
        queued = pages
    }

    func roomSummaries(cursor: String?, pageSize _: Int) async throws -> V2ClientRoomSummaryPage {
        cursors.append(cursor)
        guard !queued.isEmpty else { throw V2RealtimeTransportError.unexpectedResponse }
        return queued.removeFirst()
    }

    func requestedCursors() -> [String?] { cursors }
}

private func makeUnreadStore() throws -> (GRDBV2LocalSyncStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "im-v2-unread-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try GRDBV2LocalSyncStore(
        databaseURL: directory.appending(path: "state.sqlite"),
        installationBinding: .init(value: UUID(uuidString: "00000000-0000-0000-0000-000000000980")!)
    )
    return (store, directory)
}
