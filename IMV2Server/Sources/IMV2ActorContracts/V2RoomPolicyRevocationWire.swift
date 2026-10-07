import Foundation
import IMV2Core

/// A server-created revocation target. Expired leases still require actual
/// durable revocation; neither expiry nor this transport value is an ACK.
public struct V2RoomPolicyRevocationWire: Codable, Equatable, Sendable {
    public let registrationID: UUID
    public let roomID: RoomID
    public let activationID: UUID
    public let roomOwnerEpoch: Int64
    public let generation: Int64
    public let endpoint: String
    public let validUntil: Date

    public init(registrationID: UUID, roomID: RoomID, activationID: UUID, roomOwnerEpoch: Int64,
                generation: Int64, endpoint: String, validUntil: Date) throws {
        guard roomID.uuidValue != nil, roomOwnerEpoch >= 0, generation > 0,
              !endpoint.isEmpty, endpoint.utf8.count <= 512,
              validUntil.timeIntervalSinceReferenceDate.isFinite else {
            throw V2ActorContractError.invalidConfiguration("policy revocation target")
        }
        self.registrationID = registrationID; self.roomID = roomID; self.activationID = activationID
        self.roomOwnerEpoch = roomOwnerEpoch; self.generation = generation
        self.endpoint = endpoint; self.validUntil = validUntil
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(registrationID: c.decode(UUID.self, forKey: .registrationID), roomID: c.decode(RoomID.self, forKey: .roomID),
            activationID: c.decode(UUID.self, forKey: .activationID), roomOwnerEpoch: c.decode(Int64.self, forKey: .roomOwnerEpoch),
            generation: c.decode(Int64.self, forKey: .generation), endpoint: c.decode(String.self, forKey: .endpoint),
            validUntil: c.decode(Date.self, forKey: .validUntil))
    }
}
