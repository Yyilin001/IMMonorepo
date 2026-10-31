import Foundation
import Testing
@testable import IMV2Core

struct AuthorPresentationInterestsTests {
    @Test func emptyReplacementAndBounds() throws {
        let stream = UUID(), view = UUID(), room = RoomID(uuid: UUID())
        let users = (0..<128).map { _ in UserID(uuid: UUID()) }
        for values in [[], users] {
            let request = try V2AuthorPresentationInterests(streamID: stream, viewID: view, roomID: room,
                sequence: 1, userIDs: values)
            #expect(request.userIDs == values)
        }
        for values in [[users[0], users[0]], users + [.init(uuid: UUID())]] {
            #expect(throws: V2ResourceValidationError.self) {
                try V2AuthorPresentationInterests(streamID: stream, viewID: view, roomID: room,
                    sequence: 1, userIDs: values)
            }
        }
        for sequence in [UInt64(0), UInt64.max] {
            #expect(throws: V2ResourceValidationError.self) {
                try V2AuthorPresentationInterests(streamID: stream, viewID: view, roomID: room,
                    sequence: sequence, userIDs: users)
            }
        }
    }
}
