import Foundation
import Synchronization
import Testing
import IMV2Core
import IMV2ServerContracts
@testable import IMV2ActorContracts
@testable import IMV2ServerApplication

struct V2JournalChunkBudgetTests {
    @Test func byteAndItemBoundariesPreserveOrderAndRejectOversizedItems() throws {
        let items = ["a", "bb", "ccc", "dddd"]
        let limit = V2ActorPayloadBudget.retainedBytes(of: Array(items.prefix(2)))
        let groups = try V2RealtimeJournalFanout.chunks(items, maximumItems: 2, maximumBytes: limit)
        #expect(groups.flatMap { $0 } == items)
        #expect(groups.allSatisfy { $0.count <= 2 && V2ActorPayloadBudget.retainedBytes(of: $0) <= limit })
        #expect(groups.first == Array(items.prefix(2)))
        #expect(try V2RealtimeJournalFanout.chunks([String](), maximumItems: 1, maximumBytes: 32).isEmpty)
        #expect(throws: V2RealtimeJournalError.invalidInput) {
            try V2RealtimeJournalFanout.chunks([String(repeating: "x", count: 1000)], maximumItems: 64, maximumBytes: limit)
        }
    }
    @Test func eachItemIsMeasuredOnceAcrossChunkBoundaries() throws {
        let calls = BudgetCalls()
        let items = (0..<129).map { _ in BudgetProbe(calls: calls) }
        let groups = try V2RealtimeJournalFanout.chunks(items, maximumItems: 64, maximumBytes: 4096)
        #expect(groups.flatMap { $0 }.count == items.count)
        #expect(calls.count.withLock { $0 } == items.count)
    }
    @Test func typedJournalCostsCoverReflectionAndEncodedPayloads() throws {
        let room = try RoomID(String(repeating: "r", count: 128))
        let user = try UserID(String(repeating: "u", count: 128))
        let grant = V2RealtimeJournalRoomAuthorization(roomID: room, ownerEpoch: 1,
            permissionVersion: 2, controlVersion: 3,
            viewerMembershipRevisions: [user: 4, UserID(uuid: UUID()): 5], highWatermark: 6)
        let changes: [V2RealtimeJournalProjectionChange] = [
            .authorization(grant), .head(roomID: room, highWatermark: 1, ownerEpoch: 2, permissionVersion: 3),
            .invalidate(roomID: room), .controlInvalidation(roomID: room, ownerEpoch: 1, controlVersion: 2),
            .userControlInvalidation(userID: user, controlVersion: 1, deviceID: nil),
            .userControlInvalidation(userID: user, controlVersion: 2, deviceID: UUID(), membershipRoomID: room)
        ]
        let entries = changes.enumerated().map { V2RealtimeJournalProjectionEntry(sequence: Int64($0.offset + 1), change: $0.element) }
        for entry in entries {
            #expect(V2ActorPayloadBudget.retainedBytes(of: entry.change) >= V2ActorPayloadBudget.reflectedBytes(of: entry.change))
            #expect(V2ActorPayloadBudget.retainedBytes(of: entry) >= V2ActorPayloadBudget.reflectedBytes(of: entry))
            #expect(try V2ActorProtobuf.encode(entry).count <= V2ActorPayloadBudget.retainedBytes(of: entry))
        }
        let head = V2RealtimeJournalRoomHead(roomID: room, highWatermark: 1, ownerEpoch: 2, controlVersion: 3)
        #expect(V2ActorPayloadBudget.retainedBytes(of: head) >= V2ActorPayloadBudget.reflectedBytes(of: head))
        #expect(try V2ActorProtobuf.encode(head).count <= V2ActorPayloadBudget.retainedBytes(of: head))
    }
}
private final class BudgetCalls: Sendable { let count = Mutex(0) }
private struct BudgetProbe: V2ActorBudgetedPayload {
    let calls: BudgetCalls
    var actorRetainedBytes: Int { calls.count.withLock { $0 += 1 }; return 128 }
}
