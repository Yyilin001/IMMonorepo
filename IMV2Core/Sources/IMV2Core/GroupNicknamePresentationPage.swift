import Foundation

/// A bounded nickname-directory scan with independently authorized results.
/// Cursor progress follows the scanned members, including unavailable/retryable
/// entries. This is temporary display access, never a durable member projection.
public struct V2GroupNicknamePresentationPageResponse: Equatable, Codable, Sendable {
    public let roomID: RoomID
    public let batch: V2ProfilePresentationBatchResponse
    public let nextCursor: UserID?

    public init(roomID: RoomID, batch: V2ProfilePresentationBatchResponse, nextCursor: UserID?) throws {
        let users = batch.results.map { $0.key.userID }
        guard roomID.uuidValue != nil, batch.serverNowUnixMilliseconds >= 0,
              users.allSatisfy({ $0.uuidValue != nil }),
              zip(users, users.dropFirst()).allSatisfy({ $0.rawValue < $1.rawValue }),
              batch.results.allSatisfy({ $0.key.context == .room(roomID) }),
              nextCursor == nil || (!users.isEmpty && nextCursor == users.last)
        else { throw V2ResourceValidationError.invalidPresentationLease }
        for result in batch.results {
            // Listing names must not pre-sign/download a page of avatars.
            if case .presentation(_, let avatar) = result, avatar != nil {
                throw V2ResourceValidationError.invalidPresentationLease
            }
        }
        self.roomID = roomID; self.batch = batch; self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey { case roomID, batch, nextCursor }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(roomID: values.decode(RoomID.self, forKey: .roomID),
            batch: values.decode(V2ProfilePresentationBatchResponse.self, forKey: .batch),
            nextCursor: values.decodeIfPresent(UserID.self, forKey: .nextCursor))
    }
}
