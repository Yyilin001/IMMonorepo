import Foundation
import Testing
import IMV2Core
@testable import IMV2ClientRuntime
@testable import IMV2SharedRuntime

@Suite(.timeLimit(.minutes(1))) struct ConversationFacadeTests {
    @Test func independentWindowsKeepPagingAndCancellationLocal() async throws {
        let f = try Fixture()
        try await f.seed(count: 6)
        let first = try await f.service.openTimeline(in: f.room, limit: 2)
        let second = try await f.service.openTimeline(in: f.room, limit: 3)
        #expect(try messages(await first.read()) == [5, 6])
        #expect(try messages(await second.read()) == [4, 5, 6])
        #expect(try messages(await first.nextPage()) == [3, 4])
        #expect(try messages(await second.read()) == [4, 5, 6])
        var observerA = await first.updates().makeAsyncIterator()
        var observerB = await second.updates().makeAsyncIterator()
        #expect(try messages(#require(await observerA.next())) == [3, 4])
        #expect(try messages(#require(await observerB.next())) == [4, 5, 6])
        await first.close()
        await #expect(throws: V2ConversationServiceError.self) { try await first.read() }
        try await f.insert(7)
        var latest: [UInt64] = []
        while latest.last != 7 { latest = try messages(#require(await observerB.next())) }
        #expect(latest == [5, 6, 7])
        await second.close()
        try await f.close()
    }

    @Test func bufferedUpdatesCannotRestoreAnOldPageOrClosedAccount() async throws {
        let f = try Fixture(); try await f.seed(count: 4)
        let window = try await f.service.openTimeline(in: f.room, limit: 2)
        let oldPage = try await window.read()
        let (stream, continuation) = AsyncThrowingStream<V2ConversationWindowUpdate, any Error>.makeStream()
        var updates = V2ConversationWindowUpdates(window: window, stream: stream).makeAsyncIterator()
        continuation.yield(.init(value: oldPage, revision: 0))
        let newPage = try await window.nextPage()
        continuation.yield(.init(value: newPage, revision: 1))
        #expect(try messages(#require(await updates.next())) == [1, 2])
        continuation.yield(.init(value: newPage, revision: 1))
        await f.service.close()
        await #expect(throws: V2ConversationServiceError.self) { try await updates.next() }
        continuation.finish()
        try await f.close()
    }

    @Test func independentListsAndEmptyTerminalPages() async throws {
        let f = try Fixture()
        try await f.seed(count: 2)
        let active = try await f.service.openList(limit: 1)
        let archived = try await f.service.openList(isArchived: true, limit: 1)
        guard case .conversations(let a) = try await active.read(),
              case .conversations(let b) = try await archived.read() else { Issue.record("list expected"); return }
        #expect(a.page.entries.map(\.roomID) == [f.room])
        #expect(b.page.entries.isEmpty)
        _ = try await archived.nextPage()
        guard case .conversations(let stillActive) = try await active.read() else { Issue.record("list expected"); return }
        #expect(stillActive.page.entries.map(\.roomID) == [f.room])
        try await f.close()
        await #expect(throws: V2ConversationServiceError.self) { try await active.read() }
    }

    @Test func authorizationChangesClearAnOpenTimeline() async throws {
        let f = try Fixture()
        try await f.seed(count: 3)
        let protected = V2ConversationService(accountID: f.user, store: f.store)
        try await f.store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_room_profile_projections(room_id,source_event_id,title,owner_user_id,capacity_class,created_at) VALUES (?, ?, 'Group', ?, 'standard', 1)", arguments: [f.room.rawValue, UUID().uuidString, f.user.rawValue])
            try db.execute(sql: "INSERT INTO v2_room_event_authorizations VALUES (?, 1)", arguments: [f.room.rawValue])
        }
        let window = try await protected.openTimeline(in: f.room)
        #expect(try messages(await window.read()) == [1, 2, 3])
        var updates = await window.updates().makeAsyncIterator()
        _ = try await updates.next()
        try await f.store.databasePool.write { db in
            try db.execute(sql: "UPDATE v2_room_event_authorizations SET is_authorized=0 WHERE room_id=?", arguments: [f.room.rawValue])
        }
        var visible = try messages(#require(await updates.next()))
        while !visible.isEmpty { visible = try messages(#require(await updates.next())) }
        #expect(visible.isEmpty)
        await protected.close()
        await #expect(throws: V2ConversationServiceError.self) { try await window.reset() }
        try await f.close()
    }

    @Test func closeDrainsAnUncooperativeReadAndRejectsLateResult() async throws {
        let f = try Fixture(); try await f.seed(count: 1)
        let barrier = Barrier()
        let service = V2ConversationService(accountID: f.user, store: f.store, requiresAuthorization: false,
            requestLatestVisible: { _ in await barrier.wait() })
        let window = try await service.openList()
        let reading = Task { try await window.read() }
        try await barrier.started()
        let closing = Task { await service.close() }
        // A second window cannot acquire a new owner once close starts.
        while await serviceIsOpen(service) { await Task.yield() }
        await barrier.release()
        await closing.value
        await #expect(throws: (any Error).self) { try await reading.value }
        try await f.close()
    }

    private func serviceIsOpen(_ service: V2ConversationService) async -> Bool {
        do { let temporary = try await service.openList(); await temporary.close(); return true } catch { return false }
    }
    private func messages(_ value: V2ConversationWindowContent) throws -> [UInt64] {
        guard case .timeline(let snapshot) = value else { throw V2ConversationServiceError.invalidQuery }
        return snapshot.page.messages.map(\.roomSequence)
    }
}

private struct Fixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("facade-" + UUID().uuidString)
    let user = UserID(uuid: UUID())
    let room = RoomID(uuid: UUID())
    let store: GRDBV2LocalSyncStore
    let service: V2ConversationService
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try GRDBV2LocalSyncStore(databaseURL: root.appendingPathComponent("local.sqlite"), installationBinding: .init(value: UUID()), userID: user)
        service = V2ConversationService(accountID: user, store: store, requiresAuthorization: false)
    }
    func seed(count: Int) async throws { for n in 1...count { try await insert(n) } }
    func insert(_ n: Int) async throws {
        try await store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_conversation_list_entries(room_id,last_activity) VALUES (?,?) ON CONFLICT(room_id) DO UPDATE SET last_activity=excluded.last_activity", arguments: [room.rawValue,n])
            try db.execute(sql: "INSERT INTO v2_message_projections (message_id, source_event_id, room_id, room_sequence, timeline_sequence, message_revision, sender_user_id, text_body, server_created_at) VALUES (?, ?, ?, ?, ?, 1, ?, 'shared', ?)",
                arguments: [UUID().uuidString, UUID().uuidString, room.rawValue, n, n, user.rawValue, n])
        }
    }
    func close() async throws { await service.close(); try await store.close(); try FileManager.default.removeItem(at: root) }
}

private actor Barrier {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func started() async throws { while !entered { try Task.checkCancellation(); await Task.yield() } }
    func release() { waiter?.resume(); waiter = nil }
}
