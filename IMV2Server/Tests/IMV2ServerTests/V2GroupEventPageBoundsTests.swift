import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

struct V2GroupEventPageBoundsTests {
    @Test(arguments: [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func requestCursorBounds(value: UInt64) async throws {
        let store = CursorRequestProbe()
        let service = V2GroupEventLogService(store: store)
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        if value > UInt64(Int64.max) {
            await #expect(throws: V2GroupEventLogError.invalidRequest) {
                try await service.pull(roomID: room, actorUserID: user, afterRoomSequence: value, pageSize: 1)
            }
            #expect(await store.received.isEmpty)
        } else {
            let page = try await service.pull(roomID: room, actorUserID: user, afterRoomSequence: value, pageSize: 1)
            #expect(page.nextRoomSequence == value)
            #expect(await store.received == [value])
        }
    }

    @Test(arguments: ["ordinary", "fallback", "prepared"], ["backward", "stalled", "oldEvent", "duplicate", "reordered", "pastWatermark", "emptyEnd", "filtered", "gap"])
    func cursorProgress(path: String, scenario: String) async throws {
        let room = try RoomID("room"), user = try UserID("user")
        let sequences: [UInt64] = switch scenario {
        case "oldEvent": [10]
        case "duplicate": [11, 11]
        case "reordered": [12, 11]
        case "pastWatermark": [13]
        case "gap": [11, 15]
        default: []
        }
        let next: UInt64 = scenario == "backward" ? 9 : scenario == "stalled" || scenario == "emptyEnd" ? 10 : scenario == "gap" ? 15 : 12
        let hasMore = scenario == "stalled" || scenario == "filtered"
        let entries = try sequences.map { try V2GroupEventLogEntry(sourceEventID: .init("event-\($0)"), roomSequence: $0, projectionKind: "message", payload: Data([1])) }
        let page = try V2GroupEventLogPage(roomID: room, events: entries, nextRoomSequence: next, hasMore: hasMore)
        let store: any V2GroupEventLogStore = path == "prepared" ? PreparedPageBoundsStore(page: page) : PageBoundsStore(page: page)
        let service = V2GroupEventLogService(store: store)
        func pull() async throws -> V2GroupEventLogPage {
            if path == "ordinary" { return try await service.pull(roomID: room, actorUserID: user, afterRoomSequence: 10, pageSize: 10) }
            let context = V2PreparedGroupEventPageEncodingContext(requestID: 1, frameVersion: 21, compression: nil,
                maximumUncompressedPayloadBytes: 65536, compressionThresholdBytes: 1024, maximumExpansionRatio: 64,
                maximumGroupEventPagePayloadBytes: 60000,
                cache: .init(configuration: .init(maximumEntries: 1, maximumBytes: 65536, shardCount: 1)))
            guard case .page(let actual) = try await service.pullPrepared(roomID: room, actorUserID: user, afterRoomSequence: 10, pageSize: 10, context: context) else { throw V2GroupEventLogError.invalidRequest }
            return actual
        }
        if ["emptyEnd", "filtered", "gap"].contains(scenario) { #expect(try await pull() == page) }
        else { await #expect(throws: V2GroupEventLogError.corruptPersistenceState) { try await pull() } }
    }

    @Test(arguments: ["ordinary", "fallback", "prepared"], [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func responseBounds(path: String, value: UInt64) async throws {
        let room = try RoomID("room"), user = try UserID("user")
        for field in ["next", "event"] {
            func constructPage() throws -> V2GroupEventLogPage {
            let entries: [V2GroupEventLogEntry] = field == "event" ? [try .init(sourceEventID: .init("event"), roomSequence: value, projectionKind: "message", payload: Data([1]))] : []
            return try V2GroupEventLogPage(roomID: room, events: entries, nextRoomSequence: field == "next" ? value : UInt64(Int64.max), hasMore: false)
            }
            if value > UInt64(Int64.max) || (field == "event" && value == 0) {
                #expect(throws: V2GroupEventLogError.corruptPersistenceState) { try constructPage() }
                continue
            }
            let page = try constructPage()
            let store: any V2GroupEventLogStore = path == "prepared" ? PreparedPageBoundsStore(page: page) : PageBoundsStore(page: page)
            let service = V2GroupEventLogService(store: store)
            func pull() async throws -> V2GroupEventLogPage {
                if path == "ordinary" { return try await service.pull(roomID: room, actorUserID: user, afterRoomSequence: 0, pageSize: 10) }
                let context = V2PreparedGroupEventPageEncodingContext(requestID: 1, frameVersion: 21, compression: nil,
                    maximumUncompressedPayloadBytes: 65536, compressionThresholdBytes: 1024, maximumExpansionRatio: 64,
                    maximumGroupEventPagePayloadBytes: 60000,
                    cache: .init(configuration: .init(maximumEntries: 1, maximumBytes: 65536, shardCount: 1)))
                guard case .page(let returned) = try await service.pullPrepared(roomID: room, actorUserID: user, afterRoomSequence: 0, pageSize: 10, context: context) else { throw V2GroupEventLogError.invalidRequest }
                return returned
            }
            #expect(try await pull() == page)
        }
    }
}

private struct PageBoundsStore: V2GroupEventLogStore {
    let page: V2GroupEventLogPage
    func pull(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage { page }
    func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription { throw V2GroupEventLogError.invalidRequest }
}
private struct PreparedPageBoundsStore: V2PreparedGroupEventLogStore {
    let page: V2GroupEventLogPage
    func pull(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage { page }
    func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription { throw V2GroupEventLogError.invalidRequest }
    func pullPrepared(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int, context: V2PreparedGroupEventPageEncodingContext) async throws -> V2PreparedGroupEventPullResult { .page(page) }
}

private actor CursorRequestProbe: V2GroupEventLogStore {
    var received: [UInt64] = []
    func pull(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage {
        received.append(afterRoomSequence)
        return try .init(roomID: roomID, events: [], nextRoomSequence: afterRoomSequence, hasMore: false)
    }
    func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription {
        throw V2GroupEventLogError.invalidRequest
    }
}
