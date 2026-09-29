@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("Group join cursor timestamp bounds")
struct V2GroupJoinPageCursorTests {
    @Test("New cursors retain exact finite PostgreSQL comparison keys",
          arguments: [-211_813_488_000_000_000, -1, 0, 1, 9_223_371_331_199_999_999] as [Int64])
    func exactBounds(microseconds: Int64) throws {
        let room = UUID(), request = UUID()
        let encoded = try V2GroupJoinPageCursor(roomID: room, timestamp: .init(microseconds: microseconds), requestID: request).encoded()
        let decoded = try V2GroupJoinPageCursor.decode(encoded, roomID: room)
        #expect(decoded.requestID == request)
        let timestamp = try #require(decoded.timestampBinding() as? V2GroupJoinCursorTimestamp)
        #expect(timestamp.microseconds == microseconds)
    }

    @Test("Invalid database comparison keys cannot be emitted or accepted",
          arguments: [Int64.min, -211_813_488_000_000_001, 9_223_371_331_200_000_000, Int64.max])
    func invalidBounds(microseconds: Int64) throws {
        let room = UUID()
        let cursor = V2GroupJoinPageCursor(roomID: room, timestamp: .init(microseconds: microseconds), requestID: UUID())
        #expect(throws: V2GroupInvitationServiceError.corruptPersistenceState) { try cursor.encoded() }
        let encoded = try JSONEncoder().encode(cursor).base64EncodedString()
        #expect(throws: V2GroupInvitationServiceError.invalidRequest) { try V2GroupJoinPageCursor.decode(encoded, roomID: room) }
    }

    @Test("A cursor must have exactly the timestamp representation belonging to its version")
    func invalidRepresentations() throws {
        let room = UUID()
        let base: [String: Any] = ["version": 2, "filter": "pending", "roomID": room.uuidString,
                                   "requestID": UUID().uuidString, "createdAtMicroseconds": 1]
        for mutation: [String: Any] in [
            ["createdAtMicroseconds": NSNull()], ["createdAtMicroseconds": 0.5],
            ["createdAt": "2026-09-05T01:02:03.123456Z"], ["version": 1], ["version": 99]
        ] {
            let payload = base.merging(mutation) { _, new in new }
            let encoded = try JSONSerialization.data(withJSONObject: payload).base64EncodedString()
            #expect(throws: V2GroupInvitationServiceError.invalidRequest) { try V2GroupJoinPageCursor.decode(encoded, roomID: room) }
        }
    }
}
