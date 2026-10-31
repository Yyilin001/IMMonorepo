import Foundation
import IMV2Core
import Testing
@testable import IMV2ServerGateway

struct V2AuthorPresentationContextWireTests {
    @Test func allContextsRoundTripAndMalformedContextsFailClosed() throws {
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let pairs: [(IMV2ProfilePresentationKey.OneOf_Context, V2ProfileViewContext)] = [
            (.relationship(true), .relationship), (.directConversation(true), .directConversation),
            (.roomID(room.rawValue), .room(room)), (.groupJoinReviewRoomID(room.rawValue), .groupJoinReview(room))]
        for (wire, context) in pairs {
            var key = IMV2ProfilePresentationKey(); key.userID = user.rawValue; key.context = wire
            let decoded = try IMV2ProfilePresentationKey(serializedBytes: key.serializedData())
            #expect(try decoded.domain() == .init(userID: user, context: context))
        }
        for context: IMV2ProfilePresentationKey.OneOf_Context? in [nil, .relationship(false), .directConversation(false),
            .roomID("bad"), .groupJoinReviewRoomID("bad")] {
            var key = IMV2ProfilePresentationKey(); key.userID = user.rawValue; key.context = context
            #expect(throws: (any Error).self) { try key.domain() }
        }
    }

    @Test func startBoundsAndReceiptsValidateFullKeys() throws {
        var start = IMV2AuthorPresentationStart(); start.streamID = UUID().uuidString; start.viewID = UUID().uuidString
        #expect(try start.domain().messageRoomIDs.isEmpty)
        start.messageRoomIds = (0..<9).map { _ in UUID().uuidString }
        #expect(throws: (any Error).self) { try start.domain() }
        let user = UUID().uuidString
        var relationship = IMV2ProfilePresentationKey(); relationship.userID = user; relationship.relationship = true
        var direct = IMV2ProfilePresentationKey(); direct.userID = user; direct.directConversation = true
        var receipt = IMV2AuthorPresentationReceipt(); receipt.streamID = start.streamID; receipt.viewID = start.viewID
        receipt.sequence = 1; receipt.keys = [relationship, direct]; receipt.minimumRemainingMilliseconds = 0
        #expect(try receipt.domain().keys.count == 2)
        receipt.keys = [relationship, relationship]
        #expect(throws: (any Error).self) { try receipt.domain() }
    }
}
