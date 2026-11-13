import Foundation
import Testing
import IMV2Core
@testable import IMV2ClientRuntime
@testable import IMV2SharedRuntime

@Suite(.timeLimit(.minutes(1))) struct SearchReceiptFacadeTests {
    @Test func independentSearchCursorsAndAccountIsolation() async throws {
        let f = try Fixture(); try await f.seed()
        let other = try Fixture(); try await other.seed()
        try await f.store.messageSearch.prepareMessageSearchIndex()
        try await other.store.messageSearch.prepareMessageSearchIndex()
        let a = try await f.search.search(.init(query: "搜索", scope: .room(f.room), limit: 1))
        let cursor = try #require(a.nextCursor)
        let b = try await f.search.search(.init(query: "搜索", limit: 3))
        #expect(b.hits.count == 3)
        let next = try await f.search.search(.init(query: "搜索", scope: .room(f.room), limit: 1, cursor: cursor))
        #expect(next.hits.first?.messageID != a.hits.first?.messageID)
        await #expect(throws: V2MessageSearchError.cursorDoesNotMatchScope) {
            try await other.search.search(.init(query: "搜索", scope: .room(f.room), cursor: cursor))
        }
        await f.search.close()
        await #expect(throws: (any Error).self) { try await f.search.search(.init(query: "搜索")) }
        try await f.close(); try await other.close()
    }
    @Test func viewportUsesRoomSequenceSkipsStaleRowsAndCoalescesWithNativeRead() async throws {
        let f = try Fixture(); try await f.seed()
        try await f.receipts.recordVisible(in: f.room, messageIDs: [f.ids[0], MessageID(uuid: UUID())])
        #expect(try await f.receipts.recordReadThrough(in: f.room, roomSequence: 1) == false)
        #expect(try await f.receipts.recordReadThrough(in: f.room, roomSequence: 2))
        try await f.receipts.recordVisible(in: f.room, messageIDs: [f.ids[2]])
        #expect(try await f.receipts.recordReadThrough(in: f.room, roomSequence: 3) == false)
        // timeline_sequence is 100+, but viewport reporting must only persist room_sequence 3.
        #expect(try await f.receipts.recordReadThrough(in: f.room, roomSequence: 4))
        var a = await f.receipts.updates(in: f.room).makeAsyncIterator()
        var b = await f.receipts.updates(in: f.room).makeAsyncIterator()
        #expect(try await a.next() != nil); #expect(try await b.next() != nil)
        await f.receipts.close()
        await #expect(throws: V2ReadReceiptServiceError.self) { try await f.receipts.recordReadThrough(in: f.room, roomSequence: 5) }
        try await f.close()
    }
    @Test func privacyPausesViewportPublicationAndSubscriberCancellationIsLocal() async throws {
        let f = try Fixture(); try await f.seed()
        try await f.store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_read_receipt_preference VALUES (1,1,1,0,1)")
        }
        #expect(try await f.receipts.state(in: f.room).allowsPublication == false)
        try await f.receipts.recordVisible(in: f.room, messageIDs: [f.ids[2]])
        // Native checkpoint admission remains durable while publication is paused.
        #expect(try await f.receipts.recordReadThrough(in: f.room, roomSequence: 1))
        let first = Task { for try await _ in await f.receipts.updates(in: f.room) { try Task.checkCancellation() } }
        var second = await f.receipts.updates(in: f.room).makeAsyncIterator()
        #expect(try await second.next() != nil)
        first.cancel(); _ = await first.result
        #expect(try await f.receipts.recordReadThrough(in: f.room, roomSequence: 2))
        #expect(try await f.store.prepareNextReadReceiptIntent(accountID: f.user))
        #expect(try await second.next()?.work != nil)
        try await f.store.databasePool.write { db in try db.execute(sql: "UPDATE v2_read_receipt_preference SET allows_group_read_receipts=1") }
        try await f.receipts.recordVisible(in: f.room, messageIDs: [f.ids[2]])
        #expect(try await f.receipts.recordReadThrough(in: f.room, roomSequence: 3) == false)
        try await f.close()
    }
    @Test func readersRecheckAuthorizationAfterNetworkAndCloseDrains() async throws {
        let f = try Fixture(); try await f.seed()
        await f.remote.block()
        let reading = Task { try await f.receipts.readers(in: f.room, messageID: f.ids[0]) }
        try await f.remote.waitUntilEntered()
        try await f.store.databasePool.write { db in try db.execute(sql: "UPDATE v2_room_event_authorizations SET is_authorized=0") }
        await f.remote.release()
        await #expect(throws: V2ReadReceiptServiceError.self) { try await reading.value }
        try await f.store.databasePool.write { db in try db.execute(sql: "UPDATE v2_room_event_authorizations SET is_authorized=1") }
        await f.remote.block()
        let second = Task { try await f.receipts.readers(in: f.room, messageID: f.ids[0]) }
        try await f.remote.waitUntilEntered()
        let closing = Task { await f.receipts.close(); #expect(await f.remote.released) }
        while true {
            do { _ = try await f.receipts.state(in: f.room); await Task.yield() }
            catch { break }
        }
        await f.remote.release(); await closing.value
        await #expect(throws: (any Error).self) { try await second.value }
        try await f.close()
    }
}

private struct Fixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-receipt-facade-" + UUID().uuidString)
    let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
    let ids = (0..<3).map { _ in MessageID(uuid: UUID()) }
    let store: GRDBV2LocalSyncStore
    let search: V2SearchService
    let receipts: V2ReadReceiptService
    let remote = ReceiptRemote()
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try GRDBV2LocalSyncStore(databaseURL: root.appendingPathComponent("local.sqlite"), installationBinding: .init(value: UUID()), userID: user)
        search = .init(store: store)
        receipts = .init(accountID: user, store: store, receipts: .init(accountID: user, store: store, client: remote), transport: remote)
    }
    func seed() async throws {
        try await store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_room_profile_projections(room_id,source_event_id,title,owner_user_id,capacity_class,created_at) VALUES (?, ?, 'Group', ?, 'standard', 1)", arguments: [room.rawValue, UUID().uuidString, user.rawValue])
            try db.execute(sql: "INSERT INTO v2_room_event_authorizations VALUES (?, 1)", arguments: [room.rawValue])
            for (i, id) in ids.enumerated() {
                try db.execute(sql: "INSERT INTO v2_message_projections(message_id,source_event_id,room_id,room_sequence,timeline_sequence,message_revision,sender_user_id,text_body,server_created_at) VALUES (?, ?, ?, ?, ?, 1, ?, '搜索内容', ?)", arguments: [id.rawValue, UUID().uuidString, room.rawValue, i+1, i+101, user.rawValue, i+1])
            }
        }
    }
    func close() async throws { await receipts.close(); await search.close(); try await store.close(); try FileManager.default.removeItem(at: root) }
}
private actor ReceiptRemote: V2ReadReceiptOperationClient, V2ClientReadReceiptTransport {
    private var shouldBlock = false, entered = false
    private(set) var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func block() { shouldBlock = true; entered = false; released = false }
    func waitUntilEntered() async throws { while !entered { try Task.checkCancellation(); await Task.yield() } }
    func release() { released = true; shouldBlock = false; continuation?.resume(); continuation = nil }
    func listReadReceiptReaders(roomID: RoomID, messageID: MessageID, cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage {
        if shouldBlock { entered = true; await withCheckedContinuation { continuation = $0 } }
        return try .init(roomID: roomID, messageID: messageID, readers: [], nextCursor: nil)
    }
    func recordReadReceipt(roomID: RoomID, operationID: ReadReceiptOperationID, readThroughRoomSequence: UInt64) throws -> V2ClientReadReceipt { throw URLError(.notConnectedToInternet) }
    func submit(_ command: V2RecordReadReceiptCommand) throws -> V2ReadReceiptOperationReceipt { throw URLError(.notConnectedToInternet) }
    func recover(_ request: V2ReadReceiptRecoveryRequest) throws -> V2ReadReceiptRecoveryResult { throw URLError(.notConnectedToInternet) }
}
