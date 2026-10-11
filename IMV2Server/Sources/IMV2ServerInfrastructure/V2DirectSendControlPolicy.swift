import Foundation

/// Current Policy Owner account and relationship facts.
/// Room execution binds this snapshot to its live activation.
struct V2DirectSendControlPolicy: Codable, Equatable, Sendable {
    let sender: V2DirectSendControlAccount
    let recipient: V2DirectSendControlAccount
    let blocked: Bool
    let isFriend: Bool
    let allowsStrangers: Bool
    /// Scope versions distinguish a policy changed and restored between sends.
    var stateVersions: [String: Int64]? = nil
}

struct V2DirectSendControlAccount: Codable, Equatable, Sendable {
    let userID: UUID
    let isActive: Bool
    let specialKind: String?
    let specialStatus: String?
    let allowsServiceMessages: Bool?
    let allowsCustomerMessages: Bool?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id", isActive = "is_active"
        case specialKind = "special_kind", specialStatus = "special_status"
        case allowsServiceMessages = "allows_service_messages"
        case allowsCustomerMessages = "allows_customer_messages"
    }
}

struct V2DirectSendControlPair: Sendable {
    let sender: UUID
    let recipient: UUID

}
