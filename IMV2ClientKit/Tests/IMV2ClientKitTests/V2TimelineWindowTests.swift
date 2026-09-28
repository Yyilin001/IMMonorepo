import Foundation
import GRDB
import GRDBSQLite
import Synchronization
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Direct timeline location", .timeLimit(.minutes(1)))
struct V2TimelineWindowTests {
    private let room = RoomID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000811")!)
    private let user = UserID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000812")!)

    @Test("first, middle and last messages use small windows at any history depth", arguments: [1_000, 100_000])
    func deepHistory(count: Int) async throws {
        let f = try fixture()
        try await seed(f.store, count: count)
        try await f.store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_group_pinned_messages (room_id, message_id, is_pinned, updated_at) SELECT room_id, message_id, 0, 0 FROM v2_message_projections")
        }
        // This fixture has one serial reader and no observation/background
        // tasks. Keep the callback owner alive until the pool is closed.
        let work = TimelineQueryWork()
        defer { withExtendedLifetime(work) {} }
        try await f.store.databasePool.read { db in
            sqlite3_progress_handler(db.sqliteConnection, 100, { context in
                guard let context else { return 0 }
                Unmanaged<TimelineQueryWork>.fromOpaque(context).takeUnretainedValue().record()
                return 0
            }, Unmanaged.passUnretained(work).toOpaque())
        }
        do {
            for target in [1, count / 2, count] {
                work.reset()
                let result = try await f.store.conversationTimelineWindow(in: room, for: user, around: messageID(target), before: 40, after: 39)
                let steps = work.value
                print("Timeline seek: history=\(count), target=\(target), SQLite VM steps≈\(steps)")
                #expect(steps > 0 && steps < 50_000, "Index seek and decorations must stay bounded independently of history and retained pin tombstones")
                guard case .found(let window) = result else { Issue.record("target not found"); continue }
                let lower = max(1, target - 40), upper = min(count, target + 39)
                #expect(window.page.messages.map(\.roomSequence) == (lower...upper).map(UInt64.init))
                #expect(window.page.messages.count <= 80)
                #expect(window.page.olderCursor?.timelineSequence == (lower > 1 ? UInt64(lower) : nil))
                #expect(window.newerBoundary?.timelineSequence == (upper < count ? UInt64(upper + 1) : nil))
                let refreshed = try await f.store.conversationTimelinePage(in: room, before: window.newerBoundary, limit: window.page.messages.count)
                #expect(refreshed == window.page)
            }
            try await f.close()
        } catch {
            // The progress callback must outlive all accesses, including a
            // failing assertion setup or a database read that throws.
            try? await f.store.close()
            throw error
        }
    }

    @Test("message and activity ties keep a complete ordering through seek, refresh and paging")
    func mixedTimeline() async throws {
        let f = try fixture()
        try await seed(f.store, count: 10)
        let target = messageID(5), room = room
        try await f.store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_timeline_activity_projections VALUES (?, ?, 5, 'direct_message_restricted', 5)", arguments: [target.rawValue, room.rawValue])
            try db.execute(sql: "INSERT INTO v2_message_reactions VALUES (?, ?, ?, '👍')", arguments: [target.rawValue, room.rawValue, self.user.rawValue])
            try db.execute(sql: "INSERT INTO v2_message_favorites(message_id,room_id,is_favorited,updated_at,revision) VALUES (?, ?, 1, 5, 1)", arguments: [target.rawValue, room.rawValue])
            try db.execute(sql: "INSERT INTO v2_group_pinned_messages (room_id, message_id, is_pinned, updated_at) VALUES (?, ?, 1, 5)", arguments: [room.rawValue, target.rawValue])
        }
        guard case .found(let window) = try await f.store.conversationTimelineWindow(in: room, for: user, around: target, before: 1, after: 1) else { throw CancellationError() }
        #expect(window.page.messages.map(\.roomSequence) == [4, 5])
        #expect(window.page.activities.map(\.timelineSequence) == [5])
        #expect(window.newerBoundary?.timelineSequence == 6)
        #expect(window.page.reactions.count == 1 && window.page.favoritedMessageIDs == [target] && window.page.pinnedMessageIDs == [target])
        let refreshed = try await f.store.conversationTimelinePage(in: room, before: window.newerBoundary, limit: 3)
        #expect(refreshed == window.page)
        let activityCursor = V2ClientTimelineCursor(timelineSequence: 5, itemID: target.rawValue, kind: .activity)
        let beforeActivity = try await f.store.conversationTimelinePage(in: room, before: activityCursor, limit: 1)
        #expect(beforeActivity.messages.map(\.messageID) == [target])
        let beforeMessage = try await f.store.conversationTimelinePage(in: room, before: .init(timelineSequence: 5, itemID: target.rawValue), limit: 1)
        #expect(beforeMessage.messages.map(\.roomSequence) == [4])
        guard case .found(let exact) = try await f.store.conversationTimelineWindow(in: room, for: user, around: target, before: 0, after: 0) else { throw CancellationError() }
        #expect(exact.newerBoundary?.kind == .activity)
        #expect(try await f.store.conversationTimelinePage(in: room, before: exact.newerBoundary, limit: 1).messages.map(\.messageID) == [target])
        try await f.close()
    }

    @Test("wrong account, room, missing and withdrawn targets do not expose content")
    func unavailableTargets() async throws {
        let f = try fixture()
        try await seed(f.store, count: 3)
        #expect(try await f.store.conversationTimelineWindow(in: room, for: .init(uuid: UUID()), around: messageID(1), before: 1, after: 1) == .unavailable)
        #expect(try await f.store.conversationTimelineWindow(in: .init(uuid: UUID()), for: user, around: messageID(1), before: 1, after: 1) == .unavailable)
        #expect(try await f.store.conversationTimelineWindow(in: room, for: user, around: messageID(100), before: 1, after: 1) == .unavailable)
        let room = room
        try await f.store.databasePool.write { db in try db.execute(sql: "INSERT INTO v2_room_event_authorizations VALUES (?, 0)", arguments: [room.rawValue]) }
        #expect(try await f.store.conversationTimelineWindow(in: room, for: user, around: messageID(1), before: 1, after: 1) == .unavailable)
        try await f.store.databasePool.write { db in
            try db.execute(sql: "DELETE FROM v2_room_event_authorizations")
            try db.execute(sql: "UPDATE v2_message_projections SET is_withdrawn = 1, text_body = ''")
        }
        #expect(try await f.store.conversationTimelineWindow(in: room, for: user, around: messageID(1), before: 1, after: 1) == .withdrawn)
        try await f.store.databasePool.write { db in try db.execute(sql: "DELETE FROM v2_message_projections") }
        #expect(try await f.store.conversationTimelineWindow(in: room, for: user, around: messageID(1), before: 1, after: 1) == .unavailable)
        try await f.close()
    }

    @Test("window limits reject overflow and preserve the 800 item cap", arguments: [(-1, 0), (0, -1), (800, 0), (400, 400), (Int.max, Int.max)])
    func limits(values: (Int, Int)) async throws {
        let f = try fixture()
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            try await f.store.conversationTimelineWindow(in: room, for: user, around: messageID(1), before: values.0, after: values.1)
        }
        try await f.close()
    }

    private func seed(_ store: GRDBV2LocalSyncStore, count: Int) async throws {
        let room = room, user = user
        try await store.databasePool.write { db in
            try db.execute(sql: """
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x < ?)
            INSERT INTO v2_message_projections (message_id, source_event_id, room_id, room_sequence, timeline_sequence, message_revision, sender_user_id, text_body, server_created_at)
            SELECT printf('00000000-0000-0000-0001-%012d',x), printf('00000000-0000-0000-0002-%012d',x), ?, x, x, 1, ?, 'history', x FROM n
            """, arguments: [count, room.rawValue, user.rawValue])
        }
    }
    private func messageID(_ number: Int) -> MessageID { try! .init(String(format: "00000000-0000-0000-0001-%012d", number)) }
    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "timeline-seek-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "local.sqlite"), installationBinding: .init(value: UUID()), userID: user)
        return .init(store: store, directory: directory)
    }
    private struct Fixture {
        let store: GRDBV2LocalSyncStore
        let directory: URL
        func close() async throws { try await store.close(); try FileManager.default.removeItem(at: directory) }
    }
}

private final class TimelineQueryWork: Sendable {
    private let steps = Mutex(0)
    func record() { steps.withLock { $0 += 100 } }
    func reset() { steps.withLock { $0 = 0 } }
    var value: Int { steps.withLock { $0 } }
}
