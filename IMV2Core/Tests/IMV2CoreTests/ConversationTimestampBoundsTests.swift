import Foundation
import IMV2Core
import Testing

struct ConversationTimestampBoundsTests {
    @Test("conversation mute expiry must fit a positive signed wire timestamp", arguments: [
        Double.nan, Double.infinity, -Double.infinity, Double(Int64.max) / 1_000,
        Double(Int64.min).nextDown / 1_000, 0, -1, 0.0001
    ])
    func rejectsInvalidMuteExpiry(seconds: Double) throws {
        #expect(throws: V2CoreError.invalidPositiveValue) {
            try V2ConversationStateCommand(operationID: .init("operation"), roomID: .init("room"),
                isPinned: false, isArchived: false, muteUntil: Date(timeIntervalSince1970: seconds),expectedRevision:.initial,firstSubmissionDeadlineMilliseconds:1000)
        }
    }

    @Test("valid and absent conversation mute expiry retain the original intent", arguments: [
        nil, 1_750_000_000.1239, 9_000_000_000_000_000.0
    ] as [Double?])
    func preservesValidMuteExpiry(seconds: Double?) throws {
        let date = seconds.map { Date(timeIntervalSince1970: $0) }
        let command = try V2ConversationStateCommand(operationID: .init("operation"), roomID: .init("room"),
            isPinned: true, isArchived: false, muteUntil: date,expectedRevision:.initial,firstSubmissionDeadlineMilliseconds:1000)
        #expect(command.muteUntil == date.map { Date(timeIntervalSince1970:($0.timeIntervalSince1970*1000).rounded(.towardZero)/1000) })
    }
}
