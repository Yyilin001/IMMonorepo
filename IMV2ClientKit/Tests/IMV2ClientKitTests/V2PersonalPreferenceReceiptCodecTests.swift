import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

struct V2PersonalPreferenceReceiptCodecTests {
    private func receipt() throws -> IMV2PersonalPreferenceReceipt {
        var value = IMV2PersonalPreferenceReceipt()
        value.actorUserID = "user"; value.roomID = "room"; value.operationID = "operation"
        value.kind = .conversationState
        value.fingerprintVersion = 1; value.fingerprint = Data(repeating: 3, count: 32)
        value.resolvedAtMs = 1000
        var state = IMV2ConversationStateSet()
        state.roomID = "room"; state.isPinned = true; state.updatedAtMs = 1000; state.revision = 1
        value.conversationState = state
        return value
    }
    @Test func originalReceiptDecodesAndRejectsCrossScopeValue() throws {
        var wire = try receipt()
        let value = try V2PersonalPreferenceReceiptCodec.decode(wire)
        #expect(value.identity.accountID.rawValue == "user")
        wire.conversationState.roomID = "other-room"
        #expect(throws: (any Error).self) { try V2PersonalPreferenceReceiptCodec.decode(wire) }
    }
    @Test func invalidOutcomeAndRevisionAreNotProofs() throws {
        var wire = try receipt()
        wire.conversationState.revision = 0
        #expect(throws: (any Error).self) { try V2PersonalPreferenceReceiptCodec.decode(wire) }
        wire = try receipt(); wire.closed = false
        #expect(throws: (any Error).self) { try V2PersonalPreferenceReceiptCodec.decode(wire) }
        wire = try receipt(); wire.messageID = "unexpected"
        #expect(throws: (any Error).self) { try V2PersonalPreferenceReceiptCodec.decode(wire) }
        wire = try receipt(); wire.rejected = .init(); wire.rejected.reason = .revisionConflict
        #expect(throws: (any Error).self) { try V2PersonalPreferenceReceiptCodec.decode(wire) }
        wire.rejected.currentRevision = 0
        #expect(try V2PersonalPreferenceReceiptCodec.decode(wire).outcome == .rejected(.revisionConflict(current: .initial)))
        wire.rejected.reason = .permissionDenied
        #expect(throws: (any Error).self) { try V2PersonalPreferenceReceiptCodec.decode(wire) }
    }
}
