import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Account room notification inbox")
struct V2AccountRoomChangeInboxTests {
    @Test func coalescingPreservesWireSequence() throws {
        let epoch = UUID(), room = UUID()
        var inbox = try V2AccountRoomChangeInbox(maximumPendingRooms: 1)
        try inbox.begin(epoch: epoch.uuidString)
        try inbox.accept(change(epoch, room, 1, 10))
        try inbox.accept(change(epoch, room, 2, 8))
        #expect(inbox.next() == .changed(epoch: epoch, roomID: .init(uuid: room), highWatermark: 10))
        try inbox.accept(change(epoch, room, 3, 12))
        #expect(inbox.next() == .changed(epoch: epoch, roomID: .init(uuid: room), highWatermark: 12))
        #expect(inbox.next() == nil)
    }

    @Test(arguments: [UInt64(0), 2, 9])
    func gapsAreRejected(sequence: UInt64) throws {
        let epoch = UUID()
        var inbox = V2AccountRoomChangeInbox()
        try inbox.begin(epoch: epoch.uuidString)
        #expect(throws: V2AccountRoomChangeError.sequenceGap) {
            try inbox.accept(change(epoch, UUID(), sequence, 1))
        }
    }

    @Test func coverageExceedsDetailedSubscriptionLimit() throws {
        let epoch = UUID()
        var inbox = V2AccountRoomChangeInbox()
        try inbox.begin(epoch: epoch.uuidString)
        let rooms = (0..<1000).map { _ in UUID() }
        for (i, room) in rooms.enumerated() { try inbox.accept(change(epoch, room, UInt64(i + 1), 1)) }
        for room in rooms { #expect(inbox.next() == .changed(epoch: epoch, roomID: .init(uuid: room), highWatermark: 1)) }
        #expect(inbox.next() == nil)
    }

    @Test func overflowAndEpochMismatchAreExplicit() throws {
        let epoch = UUID()
        var inbox = try V2AccountRoomChangeInbox(maximumPendingRooms: 1)
        #expect(throws: V2AccountRoomChangeError.notStarted) { try inbox.accept(change(epoch, UUID(), 1, 1)) }
        try inbox.begin(epoch: epoch.uuidString)
        #expect(throws: V2AccountRoomChangeError.wrongEpoch) { try inbox.accept(change(UUID(), UUID(), 1, 1)) }
        try inbox.accept(change(epoch, UUID(), 1, 1))
        #expect(throws: V2AccountRoomChangeError.bufferOverflow) { try inbox.accept(change(epoch, UUID(), 2, 1)) }
    }

    @Test func resetInvalidatesBufferedChanges() throws {
        let epoch = UUID()
        var inbox = V2AccountRoomChangeInbox()
        try inbox.begin(epoch: epoch.uuidString)
        try inbox.accept(change(epoch, UUID(), 1, 1))
        var reset = IMV2AccountRoomResyncRequired()
        reset.connectionEpoch = epoch.uuidString
        try inbox.accept(reset)
        #expect(inbox.next() == .resyncRequired(epoch: epoch))
        try inbox.accept(reset)
        #expect(inbox.next() == nil)
        #expect(throws: V2AccountRoomChangeError.invalidNotification) { try inbox.accept(change(epoch, UUID(), 2, 1)) }
    }

    private func change(_ epoch: UUID, _ room: UUID, _ sequence: UInt64, _ head: UInt64) -> IMV2AccountRoomChanged {
        var value = IMV2AccountRoomChanged()
        value.connectionEpoch = epoch.uuidString
        value.roomID = room.uuidString
        value.notificationSequence = sequence
        value.highWatermark = head
        return value
    }
}
