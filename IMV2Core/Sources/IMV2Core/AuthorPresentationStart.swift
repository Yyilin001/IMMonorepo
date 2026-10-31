import Foundation

/// Starts a connection-local profile stream. Message rooms only select where
/// authorized message deliveries may offer author hints. Starting a view grants
/// neither room membership nor access to any profile or message.
public struct V2AuthorPresentationStart: Equatable, Sendable {
    public static let maximumMessageRooms = 8
    public let streamID: UUID
    public let viewID: UUID
    public let messageRoomIDs: [RoomID]

    public init(streamID: UUID, viewID: UUID, messageRoomIDs: [RoomID]) throws {
        guard messageRoomIDs.count <= Self.maximumMessageRooms,
              Set(messageRoomIDs).count == messageRoomIDs.count,
              messageRoomIDs.allSatisfy({ $0.uuidValue != nil }) else {
            throw V2ResourceValidationError.invalidPresentationLease
        }
        self.streamID = streamID; self.viewID = viewID; self.messageRoomIDs = messageRoomIDs
    }
}
