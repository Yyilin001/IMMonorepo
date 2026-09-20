import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Finite room-log catch-up", .timeLimit(.minutes(1)))
struct V2RoomLogCatchUpTests {
    @Test("a server claiming more without cursor progress is rejected")
    func rejectsNoProgressLoop() async throws {
        let room = try makeRooms(1)[0]
        let engine = V2GroupEventSyncEngine(
            transport: NoProgressCatchUpTransport(), store: CatchUpStore(rooms: [room])
        )
        await #expect(throws: V2RealtimeTransportError.unexpectedResponse) {
            _ = try await engine.synchronizeOnePage(roomID: room)
        }
    }

    @Test("foreground and maintenance pulls serialize the complete room cursor operation")
    func concurrentPagesUseCommittedCursor() async throws {
        let room = try makeRooms(1)[0]
        let store = CatchUpStore(rooms: [room])
        let transport = GatedCatchUpTransport(room: room)
        let engine = V2GroupEventSyncEngine(transport: transport, store: store)
        let foreground = Task { try await engine.synchronizeOnePage(roomID: room) }
        await transport.started.wait()
        let maintenance = Task { try await engine.synchronizeOnePage(roomID: room) }
        await transport.release.signal()
        _ = try await foreground.value
        _ = try await maintenance.value
        #expect(await transport.cursors() == [0, 1])
        #expect(await store.groupEventCursor(roomID: room) == 2)
    }

    @Test("cancelling a pull rejects a transport that returns late and leaves it resumable")
    func cancelledPageDoesNotApplyLateResponse() async throws {
        let room = try makeRooms(1)[0]
        let store = CatchUpStore(rooms: [room])
        let transport = GatedCatchUpTransport(room: room)
        let engine = V2GroupEventSyncEngine(transport: transport, store: store)
        let work = Task { try await engine.synchronizeOnePage(roomID: room) }
        await transport.started.wait()
        work.cancel()
        await transport.release.signal()
        await #expect(throws: CancellationError.self) { _ = try await work.value }
        #expect(await store.groupEventCursor(roomID: room) == 0)
        _ = try await engine.synchronizeOnePage(roomID: room)
        #expect(await transport.cursors() == [0, 0])
        #expect(await store.groupEventCursor(roomID: room) == 1)
    }

    private func makeRooms(_ count: Int) throws -> [RoomID] {
        try (1...count).map { try .init(String(format: "00000000-0000-0000-0000-%012x", $0)) }
    }
}

private actor CatchUpStore: V2LocalGroupEventStore {
    private var rooms: [RoomID]
    private var sequences: [RoomID: UInt64] = [:]
    private var fenced = false
    let fenceHit = CatchUpSignal()
    init(rooms: [RoomID]) { self.rooms = rooms }
    func add(_ room: RoomID) { rooms.append(room) }
    func setFenced(_ value: Bool) { fenced = value }
    func knownRoomLogRoomIDs(after roomID: RoomID?, limit: Int) -> [RoomID] {
        Array(rooms.sorted { $0.rawValue < $1.rawValue }
            .filter { candidate in roomID.map { candidate.rawValue > $0.rawValue } ?? true }.prefix(limit))
    }
    func isKnownRoomLogRoom(roomID: RoomID) -> Bool { rooms.contains(roomID) }
    func markRoomEventUnauthorized(roomID: RoomID) { rooms.removeAll { $0 == roomID } }
    func groupEventCursor(roomID: RoomID) -> UInt64 { sequences[roomID, default: 0] }
    func applyGroupEventPage(_ page: V2ClientGroupEventPage) async throws -> UInt64 {
        if fenced {
            await fenceHit.signal()
            throw V2ClientSyncError.resetPending
        }
        sequences[page.roomID] = page.nextRoomSequence
        return page.nextRoomSequence
    }
    func applyGroupEventPageReportingChanges(_ page: V2ClientGroupEventPage) async throws -> V2GroupEventPageCommit {
        let inserted = page.events.filter { $0.roomSequence > sequences[page.roomID, default: 0] }.count
        return try .init(appliedThrough: try await applyGroupEventPage(page), insertedEventCount: inserted)
    }
}

private actor CatchUpTransport: V2ClientGroupEventTransport {
    private let tails: [RoomID: UInt64]
    private var requests: [RoomID] = []
    init(tails: [RoomID: UInt64]) { self.tails = tails }
    func pullGroupEvents(roomID: RoomID, afterRoomSequence: UInt64, pageSize: Int) throws -> V2ClientGroupEventPage {
        requests.append(roomID)
        let tail = tails[roomID, default: 0]
        let next = min(tail, afterRoomSequence + UInt64(pageSize))
        let events = try (afterRoomSequence..<next).map { value in
            try V2ClientGroupEvent(sourceEventID: try .init(UUID().uuidString), roomSequence: value + 1, projectionKind: "message", payload: Data())
        }
        return try .init(roomID: roomID, events: events, nextRoomSequence: next, hasMore: next < tail)
    }
    func roomsRequested() -> [RoomID] { requests }
}

private struct NoProgressCatchUpTransport: V2ClientGroupEventTransport {
    func pullGroupEvents(roomID: RoomID, afterRoomSequence: UInt64, pageSize: Int) throws -> V2ClientGroupEventPage {
        try .init(roomID: roomID, events: [], nextRoomSequence: afterRoomSequence, hasMore: true)
    }
}

private actor CatchUpSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor GatedCatchUpTransport: V2ClientGroupEventTransport {
    let started = CatchUpSignal()
    let release = CatchUpSignal()
    private let room: RoomID
    private var requestedCursors: [UInt64] = []
    init(room: RoomID) { self.room = room }
    func pullGroupEvents(roomID: RoomID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2ClientGroupEventPage {
        requestedCursors.append(afterRoomSequence)
        if requestedCursors.count == 1 {
            await started.signal()
            await release.wait() // Deliberately ignores cancellation.
        }
        return try .init(roomID: room, events: [], nextRoomSequence: afterRoomSequence + 1, hasMore: false)
    }
    func cursors() -> [UInt64] { requestedCursors }
}
