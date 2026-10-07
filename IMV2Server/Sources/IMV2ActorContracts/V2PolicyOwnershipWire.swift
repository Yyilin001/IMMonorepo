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

public struct V2PolicyOwnershipClaimWire: Codable, Equatable, Sendable {
    public let endpoint: String
    public let scopes: [V2PolicyScopeWire]
    /// A cache probe must return an empty miss rather than load or renew SQL.
    public let cachedOnly: Bool
    public let refresh: Bool
    public init(endpoint: String, scopes: [V2PolicyScopeWire], cachedOnly: Bool = false, refresh: Bool = false) throws {
        guard !endpoint.isEmpty, endpoint.utf8.count <= 512, !scopes.isEmpty, scopes.count <= 4,
              Set(scopes.map(\.key)).count == scopes.count, !(cachedOnly && refresh) else {
            throw V2ActorContractError.invalidConfiguration("policy ownership claim")
        }
        self.endpoint = endpoint; self.scopes = scopes; self.cachedOnly = cachedOnly; self.refresh = refresh
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(endpoint: c.decode(String.self, forKey: .endpoint), scopes: c.decode([V2PolicyScopeWire].self, forKey: .scopes),
            cachedOnly: c.decodeIfPresent(Bool.self, forKey: .cachedOnly) ?? false,
            refresh: c.decodeIfPresent(Bool.self, forKey: .refresh) ?? false)
    }
}

/// Cold-load metadata, never a room execution permit. The journal rechecks
/// these epochs and revisions against durable ownership before registration.
public struct V2PolicyOwnerLeaseWire: Codable, Equatable, Sendable {
    public let scope: V2PolicyScopeWire
    public let ownerID: UUID
    public let epoch: Int64
    public let revision: Int64
    public let validUntil: Date
    public init(scope: V2PolicyScopeWire, ownerID: UUID, epoch: Int64, revision: Int64, validUntil: Date) throws {
        guard epoch > 0, revision > 0, validUntil.timeIntervalSinceReferenceDate.isFinite else {
            throw V2ActorContractError.invalidConfiguration("policy owner lease")
        }
        self.scope = scope; self.ownerID = ownerID; self.epoch = epoch
        self.revision = revision; self.validUntil = validUntil
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(scope: c.decode(V2PolicyScopeWire.self, forKey: .scope), ownerID: c.decode(UUID.self, forKey: .ownerID),
            epoch: c.decode(Int64.self, forKey: .epoch), revision: c.decode(Int64.self, forKey: .revision),
            validUntil: c.decode(Date.self, forKey: .validUntil))
    }
}

/// Signed scope facts with a remaining monotonic lifetime sampled by the owner.
/// Receivers subtract the whole RPC duration; wall clocks are not compared.
public struct V2PolicyOwnerStateWire: Codable, Equatable, Sendable {
    public let owner: V2PolicyOwnerLeaseWire
    public let facts: Data
    public let remainingSeconds: Double
    public init(owner: V2PolicyOwnerLeaseWire, facts: Data, remainingSeconds: Double) throws {
        guard !facts.isEmpty, facts.count <= 16_384, remainingSeconds.isFinite,
              remainingSeconds > 0, remainingSeconds <= 300 else {
            throw V2ActorContractError.invalidConfiguration("policy owner state")
        }
        self.owner = owner; self.facts = facts; self.remainingSeconds = remainingSeconds
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(owner: c.decode(V2PolicyOwnerLeaseWire.self, forKey: .owner),
            facts: c.decode(Data.self, forKey: .facts), remainingSeconds: c.decode(Double.self, forKey: .remainingSeconds))
    }
}

/// Scope invalidation affects shared node facts, never room execution permits.
public struct V2PolicyCacheInvalidationWire: Codable, Equatable, Sendable {
    public let endpoint: String
    public let scope: V2PolicyScopeWire
    public init(endpoint: String, scope: V2PolicyScopeWire) throws {
        guard !endpoint.isEmpty, endpoint.utf8.count <= 512 else {
            throw V2ActorContractError.invalidConfiguration("policy cache invalidation")
        }
        self.endpoint = endpoint; self.scope = scope
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(endpoint: c.decode(String.self, forKey: .endpoint), scope: c.decode(V2PolicyScopeWire.self, forKey: .scope))
    }
}
