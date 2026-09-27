import Foundation

/// Ephemeral, recipient-specific supplement to an already delivered room message.
/// It must never enter a message log, message hash, durable projection or journal.
/// `streamID` and `sequence` bind delivery ordering to one negotiated connection;
/// neither is evidence of profile authorization.
public struct V2AuthorPresentationDelta: Equatable, Codable, Sendable {
    public static let maximumEntries = 16
    /// Shared causal timing window, also deducted from server compression hints.
    public static let maximumViewAgeMilliseconds: Int64 = 30_000
    /// Payload budget only. The transport must additionally check the complete
    /// protobuf envelope and frame against its negotiated uncompressed budget.
    public static let maximumEncodedBytes = 32 * 1_024
    /// Includes the frame header and uncompressed protobuf envelope.
    public static let maximumFrameBytes = 33 * 1_024

    public let streamID: UUID
    /// Client-created foreground activation nonce, echoed only after the
    /// corresponding room subscription has passed its normal authorization.
    public let viewID: UUID
    public let sequence: UInt64
    public let actorUserID: UserID
    public let deviceID: DeviceID
    public let roomID: RoomID
    public let batch: V2ProfilePresentationBatchResponse
    public let retryAfterMilliseconds: Int64?

    public init(streamID: UUID, viewID: UUID, sequence: UInt64, actorUserID: UserID, deviceID: DeviceID,
                roomID: RoomID, batch: V2ProfilePresentationBatchResponse,
                retryAfterMilliseconds: Int64? = nil) throws {
        guard sequence > 0, sequence <= UInt64(Int64.max),
              actorUserID.uuidValue != nil, deviceID.uuidValue != nil, roomID.uuidValue != nil,
              (1...Self.maximumEntries).contains(batch.results.count),
              batch.results.allSatisfy({ $0.key.context == .room(roomID) && $0.key.userID.uuidValue != nil })
        else { throw V2ResourceValidationError.invalidPresentationLease }
        var retryable = false
        for result in batch.results {
            switch result {
            case .presentation(let value, _):
                guard value.lease.actorUserID == actorUserID, value.lease.deviceID == deviceID else {
                    throw V2ResourceValidationError.invalidPresentationLease
                }
            case .retryable: retryable = true
            case .unavailable: break
            }
        }
        guard retryable == (retryAfterMilliseconds != nil),
              retryAfterMilliseconds.map({ (100...60_000).contains($0) }) ?? true else {
            throw V2ResourceValidationError.invalidPresentationLease
        }
        self.streamID = streamID; self.viewID = viewID; self.sequence = sequence; self.actorUserID = actorUserID
        self.deviceID = deviceID; self.roomID = roomID; self.batch = batch
        self.retryAfterMilliseconds = retryAfterMilliseconds
        guard try JSONEncoder().encode(self).count <= Self.maximumEncodedBytes else {
            throw V2ResourceValidationError.invalidPresentationLease
        }
    }

    public func encoded() throws -> Data {
        let bytes = try JSONEncoder().encode(self)
        guard bytes.count <= Self.maximumEncodedBytes else { throw V2ResourceValidationError.invalidPresentationLease }
        return bytes
    }

    /// Bound the untrusted payload before decoding, including unknown fields.
    public static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= maximumEncodedBytes else { throw V2ResourceValidationError.invalidPresentationLease }
        return try JSONDecoder().decode(Self.self, from: bytes)
    }

    private enum CodingKeys: String, CodingKey {
        case streamID, viewID, sequence, actorUserID, deviceID, roomID, batch, retryAfterMilliseconds
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(streamID: values.decode(UUID.self, forKey: .streamID),
            viewID: values.decode(UUID.self, forKey: .viewID),
            sequence: values.decode(UInt64.self, forKey: .sequence), actorUserID: values.decode(UserID.self, forKey: .actorUserID),
            deviceID: values.decode(DeviceID.self, forKey: .deviceID), roomID: values.decode(RoomID.self, forKey: .roomID),
            batch: values.decode(V2ProfilePresentationBatchResponse.self, forKey: .batch),
            retryAfterMilliseconds: values.decodeIfPresent(Int64.self, forKey: .retryAfterMilliseconds))
    }
}
