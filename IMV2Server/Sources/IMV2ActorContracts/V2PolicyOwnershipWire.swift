import Foundation

/// Canonical account/pair identity, independent of the process serving it.
public struct V2PolicyScopeWire: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case account, stranger, pair }
    public let kind: Kind
    public let first: UUID
    public let second: UUID?
    public var key: String {
        switch kind {
        case .account, .stranger: kind.rawValue + ":" + first.uuidString.lowercased()
        case .pair: "pair:" + first.uuidString.lowercased() + ":" + second!.uuidString.lowercased()
        }
    }
    public init(account: UUID) { kind = .account; first = account; second = nil }
    public init(stranger: UUID) { kind = .stranger; first = stranger; second = nil }

    public init(pair first: UUID, _ second: UUID) throws {
        guard first != second else { throw V2ActorContractError.invalidConfiguration("policy pair") }
        kind = .pair
        if first.uuidString < second.uuidString { self.first = first; self.second = second }
        else { self.first = second; self.second = first }
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind), first = try c.decode(UUID.self, forKey: .first)
        let second = try c.decodeIfPresent(UUID.self, forKey: .second)
        if kind == .pair {
            guard let second else { throw V2ActorContractError.invalidConfiguration("policy pair") }
            try self.init(pair: first, second)
        } else {
            guard second == nil else { throw V2ActorContractError.invalidConfiguration("policy account") }
            if kind == .stranger { self.init(stranger: first) }
            else { self.init(account: first) }
        }
    }
}
