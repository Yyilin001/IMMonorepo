import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Authenticated user room directory cursor")
struct V2UserRoomDirectoryCursorTests {
    @Test("cursor cannot move between users, topologies or signing keys")
    func binding() throws {
        let codec = try V2UserRoomDirectoryCursorCodec(key: Data(repeating: 7, count: 32))
        let user = UserID(uuid: UUID()), after = RoomID(uuid: UUID())
        let token = try codec.encode(userID: user, topologyGeneration: "a", storeIndex: 1, after: after)
        let position = try codec.decode(token, userID: user, topologyGeneration: "a", storeCount: 2)
        #expect(position.storeIndex == 1 && position.after == after)
        #expect(throws: V2RoomRecoveryReadError.invalidCursor) {
            try codec.decode(token, userID: .init(uuid: UUID()), topologyGeneration: "a", storeCount: 2)
        }
        #expect(throws: V2RoomRecoveryReadError.topologyChanged) {
            try codec.decode(token, userID: user, topologyGeneration: "b", storeCount: 2)
        }
        #expect(throws: V2RoomRecoveryReadError.invalidCursor) {
            try codec.decode(token, userID: user, topologyGeneration: "a", storeCount: 1)
        }
        let other = try V2UserRoomDirectoryCursorCodec(key: Data(repeating: 8, count: 32))
        #expect(throws: V2RoomRecoveryReadError.invalidCursor) {
            try other.decode(token, userID: user, topologyGeneration: "a", storeCount: 2)
        }
    }

    @Test("tampered and oversized cursors fail before scan position is trusted")
    func malformed() throws {
        let codec = try V2UserRoomDirectoryCursorCodec(key: Data(repeating: 7, count: 32))
        let user = UserID(uuid: UUID())
        let token = try codec.encode(userID: user, topologyGeneration: "a", storeIndex: 0, after: nil)
        for malformed in ["", token + ".", "A" + token.dropFirst(), String(repeating: "a", count: 2049)] {
            #expect(throws: V2RoomRecoveryReadError.invalidCursor) {
                try codec.decode(malformed, userID: user, topologyGeneration: "a", storeCount: 1)
            }
        }
    }
}
