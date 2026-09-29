@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing
@testable import IMV2ServerGateway

@Suite("Account room notification buffering")
struct V2AccountRoomChangeBufferTests {
    @Test("more than 128 pending rooms receive consecutive notification sequences")
    func allRooms() throws {
        let epoch = UUID()
        var buffer = try V2AccountRoomChangeBuffer(epoch: epoch)
        let rooms = (0..<1000).map { _ in RoomID(uuid: UUID()) }
        for room in rooms { try buffer.offer(roomID: room, highWatermark: 1) }
        for (index, room) in rooms.enumerated() {
            #expect(buffer.next() == .changed(epoch: epoch, sequence: UInt64(index + 1), roomID: room, highWatermark: 1))
        }
        #expect(buffer.pendingRoomCount == 0)
        #expect(buffer.next() == nil)
        #expect(!buffer.requiresRestart)
    }

    @Test("coalescing happens before sequence allocation and preserves fairness")
    func coalescing() throws {
        let epoch = UUID(), hot = RoomID(uuid: UUID()), cold = RoomID(uuid: UUID())
        var buffer = try V2AccountRoomChangeBuffer(epoch: epoch)
        try buffer.offer(roomID: hot, highWatermark: 2)
        try buffer.offer(roomID: cold, highWatermark: 3)
        for watermark in [5, 4, 9, 7] { try buffer.offer(roomID: hot, highWatermark: UInt64(watermark)) }
        #expect(buffer.next() == .changed(epoch: epoch, sequence: 1, roomID: hot, highWatermark: 9))
        try buffer.offer(roomID: hot, highWatermark: 10)
        #expect(buffer.next() == .changed(epoch: epoch, sequence: 2, roomID: cold, highWatermark: 3))
        #expect(buffer.next() == .changed(epoch: epoch, sequence: 3, roomID: hot, highWatermark: 10))
    }

    @Test("revocation preserves other rooms and a rejoin receives a fresh FIFO position")
    func revokeAndRejoin() throws {
        let epoch = UUID(), first = RoomID(uuid: UUID()), revoked = RoomID(uuid: UUID()), last = RoomID(uuid: UUID())
        var buffer = try V2AccountRoomChangeBuffer(epoch: epoch)
        for room in [first, revoked, last] { try buffer.offer(roomID: room, highWatermark: 1) }
        #expect(buffer.next() == .changed(epoch: epoch, sequence: 1, roomID: first, highWatermark: 1))
        buffer.revoke(roomID: revoked)
        try buffer.offer(roomID: revoked, highWatermark: 3)
        #expect(buffer.next() == .changed(epoch: epoch, sequence: 2, roomID: last, highWatermark: 1))
        #expect(buffer.next() == .changed(epoch: epoch, sequence: 3, roomID: revoked, highWatermark: 3))
        #expect(buffer.next() == nil)
        #expect(!buffer.requiresRestart)
        buffer.invalidate()
        buffer.revoke(roomID: revoked)
        #expect(buffer.next() == .resyncRequired(epoch: epoch))
    }

    @Test("overflow emits one recovery boundary and stops the old epoch")
    func overflow() throws {
        let epoch = UUID()
        var buffer = try V2AccountRoomChangeBuffer(epoch: epoch, maximumPendingRooms: 2)
        for _ in 0..<3 { try buffer.offer(roomID: .init(uuid: UUID()), highWatermark: 1) }
        #expect(buffer.pendingRoomCount == 0)
        #expect(buffer.requiresRestart)
        #expect(buffer.next() == .resyncRequired(epoch: epoch))
        try buffer.offer(roomID: .init(uuid: UUID()), highWatermark: 3)
        buffer.invalidate()
        #expect(buffer.next() == nil)
    }

    @Test("capacity bounds pending changes rather than lifetime room count")
    func boundedPending() throws {
        var buffer = try V2AccountRoomChangeBuffer(epoch: UUID(), maximumPendingRooms: 1)
        for _ in 0..<1000 {
            try buffer.offer(roomID: .init(uuid: UUID()), highWatermark: 1)
            #expect(buffer.next() != nil)
        }
        #expect(!buffer.requiresRestart)
    }

    @Test("the wire carries epoch and sequence only for actual changes")
    func wire() throws {
        let epoch = UUID(), room = RoomID(uuid: UUID())
        let changed = V2AccountRoomNotification.changed(epoch: epoch, sequence: 2, roomID: room, highWatermark: 5).envelope()
        #expect(changed.accountRoomChanged.connectionEpoch == epoch.uuidString.lowercased())
        #expect(changed.accountRoomChanged.notificationSequence == 2)
        #expect(changed.accountRoomChanged.roomID == room.rawValue)
        let reset = V2AccountRoomNotification.resyncRequired(epoch: epoch).envelope()
        #expect(reset.body == .accountRoomResyncRequired(reset.accountRoomResyncRequired))
        #expect(reset.accountRoomResyncRequired.connectionEpoch == epoch.uuidString.lowercased())
    }
}
