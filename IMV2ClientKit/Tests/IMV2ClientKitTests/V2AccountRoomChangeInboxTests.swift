import Foundation
@testable import IMV2ClientKit
import Testing

@Suite("Account coverage recovery inbox")
struct V2AccountRoomChangeInboxTests {
    @Test func boundaryIsConsumedOnce() throws {
        let epoch = UUID()
        var inbox = V2AccountRoomChangeInbox()
        try inbox.begin(epoch: epoch.uuidString)
        var reset = IMV2AccountRoomResyncRequired(); reset.connectionEpoch = epoch.uuidString
        try inbox.accept(reset); try inbox.accept(reset)
        #expect(inbox.next() == .resyncRequired(epoch: epoch))
        try inbox.accept(reset)
        #expect(inbox.next() == nil)
    }

    @Test func identityIsRequired() throws {
        let epoch = UUID()
        var inbox = V2AccountRoomChangeInbox()
        var reset = IMV2AccountRoomResyncRequired(); reset.connectionEpoch = epoch.uuidString
        #expect(throws: V2AccountRoomChangeError.notStarted) { try inbox.accept(reset) }
        try inbox.begin(epoch: UUID().uuidString)
        #expect(throws: V2AccountRoomChangeError.wrongEpoch) { try inbox.accept(reset) }
    }

    @Test func replacementWaitsForConsumedBoundary() throws {
        let old = UUID(), next = UUID()
        var inbox = V2AccountRoomChangeInbox()
        try inbox.begin(epoch: old.uuidString)
        #expect(throws: V2AccountRoomChangeError.invalidNotification) { try inbox.begin(epoch: next.uuidString) }
        var reset = IMV2AccountRoomResyncRequired(); reset.connectionEpoch = old.uuidString
        try inbox.accept(reset)
        #expect(throws: V2AccountRoomChangeError.invalidNotification) { try inbox.begin(epoch: next.uuidString) }
        #expect(inbox.next() == .resyncRequired(epoch: old))
        #expect(throws: V2AccountRoomChangeError.invalidNotification) { try inbox.begin(epoch: old.uuidString) }
        try inbox.begin(epoch: next.uuidString)
        #expect(inbox.next() == nil)
        #expect(throws: V2AccountRoomChangeError.wrongEpoch) { try inbox.accept(reset) }
        reset.connectionEpoch = next.uuidString
        try inbox.accept(reset)
        #expect(inbox.next() == .resyncRequired(epoch: next))
    }
}
