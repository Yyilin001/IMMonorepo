import Foundation

/// Ephemeral, recipient-specific supplement for visible profiles and message authors.
/// It must never enter a message log, message hash, durable projection or journal.
/// `streamID` and `sequence` bind delivery ordering to one negotiated connection;
/// neither is evidence of profile authorization.
public struct V2AuthorPresentationDelta: Equatable, Codable, Sendable {
    public static let maximumEntries = 16
    /// Bound for the client nonce and its server-relative monotonic timing anchor.
    public static let maximumViewAgeMilliseconds: Int64 = 30_000
    /// Payload budget only. The transport must additionally check the complete
    /// protobuf envelope and frame against its negotiated uncompressed budget.
    public static let maximumEncodedBytes = 32 * 1_024
    /// Includes the frame header and uncompressed protobuf envelope.
    public static let maximumFrameBytes = 33 * 1_024

    public let streamID: UUID
    /// Client-created connection view nonce. Each key is independently authorized.
    public let viewID: UUID
    public let sequence: UInt64
    /// Elapsed monotonic time since the server accepted this view, captured
    /// no later than batch.serverNow. Never a wall-clock offset.
    public let serverViewAgeMilliseconds: Int64
    public let actorUserID: UserID
    public let deviceID: DeviceID
    public let batch: V2ProfilePresentationBatchResponse
    public let retryAfterMilliseconds: Int64?
    // All public fields are immutable. Retain the representation already
    // encoded for admission instead of encoding every recipient batch again
    // at send time. This implementation detail is not part of wire/equality.
    private var encodedPayload = Data()

    public init(streamID: UUID, viewID: UUID, sequence: UInt64, actorUserID: UserID, deviceID: DeviceID,
                serverViewAgeMilliseconds: Int64, batch: V2ProfilePresentationBatchResponse,
                retryAfterMilliseconds: Int64? = nil) throws {
        guard sequence > 0, sequence <= UInt64(Int64.max),
              (0..<Self.maximumViewAgeMilliseconds).contains(serverViewAgeMilliseconds),
              actorUserID.uuidValue != nil, deviceID.uuidValue != nil,
              (1...Self.maximumEntries).contains(batch.results.count),
              batch.results.allSatisfy({ $0.key.isValidAuthorPresentationKey })
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
        self.deviceID = deviceID; self.batch = batch
        self.serverViewAgeMilliseconds = serverViewAgeMilliseconds
        self.retryAfterMilliseconds = retryAfterMilliseconds
        let bytes = try JSONEncoder().encode(self)
        guard bytes.count <= Self.maximumEncodedBytes else {
            throw V2ResourceValidationError.invalidPresentationLease
        }
        encodedPayload = bytes
    }

    public func encoded() throws -> Data {
        encodedPayload
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.streamID == rhs.streamID && lhs.viewID == rhs.viewID && lhs.sequence == rhs.sequence
            && lhs.serverViewAgeMilliseconds == rhs.serverViewAgeMilliseconds
            && lhs.actorUserID == rhs.actorUserID && lhs.deviceID == rhs.deviceID
            && lhs.batch == rhs.batch && lhs.retryAfterMilliseconds == rhs.retryAfterMilliseconds
    }

    /// Bound the untrusted payload before decoding, including unknown fields.
    public static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= maximumEncodedBytes else { throw V2ResourceValidationError.invalidPresentationLease }
        return try JSONDecoder().decode(Self.self, from: bytes)
    }

    private enum CodingKeys: String, CodingKey {
        case streamID, viewID, sequence, serverViewAgeMilliseconds, actorUserID, deviceID, batch, retryAfterMilliseconds
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(streamID: values.decode(UUID.self, forKey: .streamID),
            viewID: values.decode(UUID.self, forKey: .viewID),
            sequence: values.decode(UInt64.self, forKey: .sequence), actorUserID: values.decode(UserID.self, forKey: .actorUserID),
            deviceID: values.decode(DeviceID.self, forKey: .deviceID),
            serverViewAgeMilliseconds: values.decode(Int64.self, forKey: .serverViewAgeMilliseconds),
            batch: values.decode(V2ProfilePresentationBatchResponse.self, forKey: .batch),
            retryAfterMilliseconds: values.decodeIfPresent(Int64.self, forKey: .retryAfterMilliseconds))
    }
}
