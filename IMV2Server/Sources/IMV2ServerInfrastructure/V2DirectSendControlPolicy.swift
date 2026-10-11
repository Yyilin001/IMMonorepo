import Foundation
import IMV2ServerApplication

/// Current Policy Owner account and relationship facts.
/// Room execution binds this snapshot to its live activation.
struct V2DirectSendControlPolicy: Codable, Equatable, Sendable {
    let sender: V2DirectSendControlAccount
    let recipient: V2DirectSendControlAccount
    let blocked: Bool
    let isFriend: Bool
    let allowsStrangers: Bool
    /// Scope versions distinguish a policy changed and restored between sends.
    var stateVersions: V2DirectSendPolicyVersions? = nil
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

/// UUID identities stay typed until a policy is actually serialized.
/// The encoded representation remains the existing scope-key JSON object.
struct V2DirectSendPolicyVersions: Codable, Equatable, Sendable {
    let values: [V2PolicyAuthorizationScope: Int64]
    var count: Int { values.count }
    init(values: [V2PolicyAuthorizationScope: Int64]) { self.values = values }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: values.map { ($0.key.key, $0.value) }))
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode([String: Int64].self)
        var values: [V2PolicyAuthorizationScope: Int64] = [:]
        for (key, version) in encoded {
            let parts = key.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 2, let first = UUID(uuidString: String(parts[1])) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid policy scope")
            }
            let scope: V2PolicyAuthorizationScope
            switch (parts[0], parts.count) {
            case ("account", 2): scope = .account(first)
            case ("stranger", 2): scope = .stranger(first)
            case ("pair", 3):
                guard let second = UUID(uuidString: String(parts[2])), second != first else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid policy pair")
                }
                scope = V2PolicyAuthorizationScope.pair(first, second).canonical
            default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid policy scope")
            }
            guard values.updateValue(version, forKey: scope) == nil else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "duplicate policy scope")
            }
        }
        self.values = values
    }
}
