import Foundation

/// Read data has a durable version, not an ownership lease or TTL.
public struct V2PolicySnapshotWire: Codable, Equatable, Sendable {
    public let scope: V2PolicyScopeWire
    public let version: Int64
    public let facts: Data
    public init(scope: V2PolicyScopeWire, version: Int64, facts: Data) throws {
        guard version > 0, !facts.isEmpty, facts.count <= 16_384 else {
            throw V2ActorContractError.invalidConfiguration("policy snapshot")
        }
        self.scope = scope; self.version = version; self.facts = facts
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(scope: c.decode(V2PolicyScopeWire.self, forKey: .scope),
            version: c.decode(Int64.self, forKey: .version), facts: c.decode(Data.self, forKey: .facts))
    }
}
public struct V2PolicySnapshotSubscriberWire: Codable, Hashable, Sendable {
    public let hostID: V2ActorHostID
    public let endpoint: String
    public init(hostID: V2ActorHostID, endpoint: String) throws {
        guard hostID.uuidValue != nil, !endpoint.isEmpty, endpoint.utf8.count <= 512 else {
            throw V2ActorContractError.invalidConfiguration("policy subscriber")
        }
        self.hostID = hostID; self.endpoint = endpoint
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(hostID: c.decode(V2ActorHostID.self, forKey: .hostID), endpoint: c.decode(String.self, forKey: .endpoint))
    }
}
public struct V2PolicySnapshotRequestWire: Codable, Equatable, Sendable {
    public let endpoint: String
    public let scopes: [V2PolicyScopeWire]
    public let subscriber: V2PolicySnapshotSubscriberWire
    public init(endpoint: String, scopes: [V2PolicyScopeWire], subscriber: V2PolicySnapshotSubscriberWire) throws {
        guard !endpoint.isEmpty, endpoint.utf8.count <= 512, !scopes.isEmpty, scopes.count <= 4,
              Set(scopes.map(\.key)).count == scopes.count else {
            throw V2ActorContractError.invalidConfiguration("policy snapshot request")
        }
        self.endpoint = endpoint; self.scopes = scopes; self.subscriber = subscriber
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(endpoint: c.decode(String.self, forKey: .endpoint), scopes: c.decode([V2PolicyScopeWire].self, forKey: .scopes),
            subscriber: c.decode(V2PolicySnapshotSubscriberWire.self, forKey: .subscriber))
    }
}
public struct V2PolicySnapshotUpdateWire: Codable, Equatable, Sendable {
    public let endpoint: String
    public let snapshot: V2PolicySnapshotWire
    public init(endpoint: String, snapshot: V2PolicySnapshotWire) throws {
        guard !endpoint.isEmpty, endpoint.utf8.count <= 512 else {
            throw V2ActorContractError.invalidConfiguration("policy snapshot update")
        }
        self.endpoint = endpoint; self.snapshot = snapshot
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(endpoint: c.decode(String.self, forKey: .endpoint), snapshot: c.decode(V2PolicySnapshotWire.self, forKey: .snapshot))
    }
}
