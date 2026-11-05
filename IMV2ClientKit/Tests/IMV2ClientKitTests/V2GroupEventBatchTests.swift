import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

struct V2GroupEventBatchTests {
    @Test(arguments: ["valid", "missing", "duplicate", "wrongRoom", "backward", "stalled"])
    func validatesEveryRoomBeforeReturning(scenario: String) async throws {
        let rooms = [RoomID(uuid: UUID()), RoomID(uuid: UUID())]
        let transport = V2ProtobufSyncTransport(wire: BatchWire { request in
            var response = IMV2Envelope()
            response.groupEventPageBatch.rooms = request.groupEventPullBatch.rooms.map { pull in
                var result = IMV2GroupEventPageResult(); result.roomID = pull.roomID
                result.page.roomID = pull.roomID; result.page.nextRoomSequence = 10
                return result
            }
            switch scenario {
            case "missing": response.groupEventPageBatch.rooms.removeLast()
            case "duplicate": response.groupEventPageBatch.rooms[1] = response.groupEventPageBatch.rooms[0]
            case "wrongRoom": response.groupEventPageBatch.rooms[1].page.roomID = rooms[0].rawValue
            case "backward": response.groupEventPageBatch.rooms[1].page.nextRoomSequence = 9
            case "stalled": response.groupEventPageBatch.rooms[1].page.hasMore_p = true
            default: break
            }
            return response
        }, protocolVersion: UInt8(IMV2ProtocolVersion.current))
        let requests = rooms.map { V2ClientGroupEventPull(roomID: $0, afterRoomSequence: 10, pageSize: 1) }
        if scenario == "valid" { #expect(try await transport.pullGroupEventPages(requests).count == 2) }
        else { await #expect(throws: V2RealtimeTransportError.unexpectedResponse) { try await transport.pullGroupEventPages(requests) } }
    }

    @Test(arguments: ["FORBIDDEN", "BATCH_PAGE_REQUIRES_SINGLE_PULL"])
    func largeEventFallbackDoesNotBypassAuthorization(code: String) async throws {
        let room = RoomID(uuid: UUID())
        let transport = V2ProtobufSyncTransport(wire: BatchWire { request in
            var response = IMV2Envelope()
            if case .groupEventPullBatch = request.body {
                var result = IMV2GroupEventPageResult(); result.roomID = room.rawValue; result.error.code = code
                response.groupEventPageBatch.rooms = [result]
            } else {
                #expect(code == "BATCH_PAGE_REQUIRES_SINGLE_PULL")
                #expect(request.groupEventPull.afterRoomSequence == 10)
                response.error.code = "FORBIDDEN"
            }
            return response
        }, protocolVersion: UInt8(IMV2ProtocolVersion.current))
        let result = try await transport.pullGroupEventPages([.init(roomID: room, afterRoomSequence: 10, pageSize: 1)])
        guard case .failure(.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: _, currentRevision: _)) = result[room] else {
            Issue.record("Authorization failure lost"); return
        }
    }

    @Test(arguments: [false, true])
    func batchSharesRoomFlightsAndCancellationDoesNotAdvanceCursor(cancel: Bool) async throws {
        let room = RoomID(uuid: UUID()), store = BatchCursorStore(), wire = BatchFlightWire()
        let engine = V2GroupEventSyncEngine(transport: wire, store: store)
        let batch = Task { try await engine.synchronizePages(targets: [(room, 1)],
            commit: { try await store.applyGroupEventPageReportingChanges($0) }, unavailable: { _ in Issue.record("Unexpected denial") }) }
        await wire.waitUntilStarted()
        #expect(try await !engine.applyOnlineEvents(.init(roomID: room, highWatermark: 1, liveEvents: [])))
        if cancel { batch.cancel() }
        let single = Task { try await engine.synchronizeOnePage(roomID: room) }
        await wire.release()
        if cancel { await #expect(throws: CancellationError.self) { try await batch.value } }
        else { _ = try await batch.value }
        _ = try await single.value
        #expect(await wire.cursors == (cancel ? [0, 0] : [0, 1]))
        #expect(await store.groupEventCursor(roomID: room) == (cancel ? 1 : 2))
    }
}
private struct BatchWire: V2AuthenticatedFrameTransport {
    let respond: @Sendable (IMV2Envelope) -> IMV2Envelope
    func request(_ frame: V2Frame) async throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        var response = respond(request); response.requestID = request.requestID; response.protocolVersion = request.protocolVersion
        return try V2ProtobufFrameCodec.encode(response, frameVersion: frame.version)
    }
}
private actor BatchCursorStore: V2LocalGroupEventStore {
    var cursor: UInt64 = 0
    func groupEventCursor(roomID: RoomID) -> UInt64 { cursor }
    func applyGroupEventPage(_ page: V2ClientGroupEventPage) -> UInt64 { cursor = page.nextRoomSequence; return cursor }
    func applyGroupEventPageReportingChanges(_ page: V2ClientGroupEventPage) throws -> V2GroupEventPageCommit {
        cursor = page.nextRoomSequence; return try .init(appliedThrough: cursor, insertedEventCount: 0)
    }
}
private actor BatchFlightWire: V2ClientGroupEventTransport {
    var cursors: [UInt64] = []
    var gate: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async { while cursors.isEmpty { await Task.yield() } }
    func release() { gate?.resume(); gate = nil }
    func pullGroupEvents(roomID: RoomID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2ClientGroupEventPage {
        cursors.append(afterRoomSequence)
        if cursors.count == 1 { await withCheckedContinuation { gate = $0 } }
        return try .init(roomID: roomID, events: [], nextRoomSequence: afterRoomSequence + 1, hasMore: false)
    }
}
