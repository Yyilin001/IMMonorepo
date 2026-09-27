import Foundation

public enum GroupAvatarOperationIDTag: V2IdentifierTag {}
public typealias GroupAvatarOperationID = V2Identifier<GroupAvatarOperationIDTag>

public enum V2GroupAvatarMutation: Equatable, Codable, Sendable {
    case set(MediaID)
    case remove

    public var mediaID: MediaID? {
        switch self { case .set(let value): value; case .remove: nil }
    }
}

/// Persistent intent. Upload completion does not itself change the group avatar.
public struct V2GroupAvatarCommand: Equatable, Codable, Sendable {
    public let operationID: GroupAvatarOperationID
    public let roomID: RoomID
    public let expectedRevision: UInt64
    public let mutation: V2GroupAvatarMutation

    public init(operationID: GroupAvatarOperationID, roomID: RoomID,
                expectedRevision: UInt64, mutation: V2GroupAvatarMutation) throws {
        guard operationID.uuidValue != nil, roomID.uuidValue != nil,
              mutation.mediaID.map({ $0.uuidValue != nil }) ?? true else { throw V2CoreError.invalidIdentifier }
        guard expectedRevision <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.operationID = operationID; self.roomID = roomID
        self.expectedRevision = expectedRevision; self.mutation = mutation
    }

    private enum CodingKeys: String, CodingKey { case operationID, roomID, expectedRevision, mutation }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(operationID: values.decode(GroupAvatarOperationID.self, forKey: .operationID),
                      roomID: values.decode(RoomID.self, forKey: .roomID),
                      expectedRevision: values.decode(UInt64.self, forKey: .expectedRevision),
                      mutation: values.decode(V2GroupAvatarMutation.self, forKey: .mutation))
    }
}

/// Logical state, not a download capability. Revision zero means never configured.
public struct V2GroupAvatarState: Equatable, Codable, Sendable {
    public let roomID: RoomID
    public let mediaID: MediaID?
    public let revision: UInt64

    public init(roomID: RoomID, mediaID: MediaID?, revision: UInt64) throws {
        guard roomID.uuidValue != nil, mediaID.map({ $0.uuidValue != nil }) ?? true else { throw V2CoreError.invalidIdentifier }
        guard revision <= UInt64(Int64.max), revision > 0 || mediaID == nil else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID; self.mediaID = mediaID; self.revision = revision
    }
    private enum CodingKeys: String, CodingKey { case roomID, mediaID, revision }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(roomID: values.decode(RoomID.self, forKey: .roomID),
                      mediaID: values.decodeIfPresent(MediaID.self, forKey: .mediaID),
                      revision: values.decode(UInt64.self, forKey: .revision))
    }
}

/// Durable command receipt. Replays return the original state, even after another edit.
public struct V2GroupAvatarChange: Equatable, Codable, Sendable {
    public let state: V2GroupAvatarState
    public let roomSequence: UInt64
    public let updatedAtUnixMilliseconds: Int64
    public var updatedAt: Date { V2ResourceTime.date(updatedAtUnixMilliseconds) }

    public init(state: V2GroupAvatarState, roomSequence: UInt64, updatedAt: Date) throws {
        try self.init(state: state, roomSequence: roomSequence, updatedAtUnixMilliseconds: V2ResourceTime.milliseconds(updatedAt))
    }
    private init(state: V2GroupAvatarState, roomSequence: UInt64, updatedAtUnixMilliseconds: Int64) throws {
        guard state.revision > 0, roomSequence > 0, roomSequence <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.state = state; self.roomSequence = roomSequence; self.updatedAtUnixMilliseconds = updatedAtUnixMilliseconds
    }
    private enum CodingKeys: String, CodingKey { case state, roomSequence, updatedAtUnixMilliseconds }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(state: values.decode(V2GroupAvatarState.self, forKey: .state),
                      roomSequence: values.decode(UInt64.self, forKey: .roomSequence),
                      updatedAtUnixMilliseconds: values.decode(Int64.self, forKey: .updatedAtUnixMilliseconds))
    }
}
