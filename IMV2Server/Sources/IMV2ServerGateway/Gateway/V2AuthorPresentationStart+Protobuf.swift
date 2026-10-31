import Foundation
import IMV2Core

extension IMV2AuthorPresentationStart {
    func domain() throws -> V2AuthorPresentationStart {
        guard let stream = UUID(uuidString: streamID), let view = UUID(uuidString: viewID),
              messageRoomIds.count <= V2AuthorPresentationStart.maximumMessageRooms else {
            throw V2GatewaySessionError.unsupportedCommand
        }
        return try .init(streamID: stream, viewID: view, messageRoomIDs: messageRoomIds.map { try RoomID($0) })
    }
}
