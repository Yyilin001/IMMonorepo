import Foundation

/// Policy snapshots are models in process and Protobuf fields across nodes.
/// A snapshot never wraps another encoded document inside the RPC body.
public struct V2PolicyAccountFacts: Codable, Equatable, Sendable {
    public let userID: UUID
    public let isActive: Bool
    public let specialKind: String?
    public let specialStatus: String?
    public let allowsServiceMessages: Bool?
    public let allowsCustomerMessages: Bool?
    public init(userID: UUID, isActive: Bool, specialKind: String? = nil, specialStatus: String? = nil,
                allowsServiceMessages: Bool? = nil, allowsCustomerMessages: Bool? = nil) {
        self.userID = userID; self.isActive = isActive; self.specialKind = specialKind; self.specialStatus = specialStatus
        self.allowsServiceMessages = allowsServiceMessages; self.allowsCustomerMessages = allowsCustomerMessages
    }
}
public struct V2PolicyPairFacts: Codable, Equatable, Sendable {
    public let blocked: Bool
    public let isFriend: Bool
    public init(blocked: Bool, isFriend: Bool) { self.blocked = blocked; self.isFriend = isFriend }
}
public struct V2PolicyStrangerFacts: Codable, Equatable, Sendable {
    public let userID: UUID
    public let allowsStrangers: Bool
    public init(userID: UUID, allowsStrangers: Bool) { self.userID = userID; self.allowsStrangers = allowsStrangers }
}
public enum V2PolicyOwnerFacts: Codable, Equatable, Sendable {
    case account(V2PolicyAccountFacts)
    case stranger(V2PolicyStrangerFacts)
    case pair(V2PolicyPairFacts)
}
