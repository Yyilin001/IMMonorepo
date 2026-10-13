import Foundation

/// Read data has a durable version, not an ownership lease or TTL.
public struct V2PolicySnapshotWire: Codable, Equatable, Sendable {
    public let scope: V2PolicyScopeWire
    public let version: Int64
    public let facts: V2PolicyOwnerFacts
    public init(scope: V2PolicyScopeWire, version: Int64, facts: V2PolicyOwnerFacts) throws {
        guard version > 0, V2ActorPayloadBudget.retainedBytes(of: facts) <= 16_384 else {
            throw V2ActorContractError.invalidConfiguration("policy snapshot")
        }
        switch (scope.kind, facts) {
        case (.account, .account(let account)) where account.userID == scope.first: break
        case (.stranger, .stranger(let setting)) where setting.userID == scope.first: break
        case (.pair, .pair): break
        default: throw V2ActorContractError.invalidConfiguration("policy snapshot scope")
        }
        self.scope = scope; self.version = version; self.facts = facts
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(scope: c.decode(V2PolicyScopeWire.self, forKey: .scope),
            version: c.decode(Int64.self, forKey: .version), facts: c.decode(V2PolicyOwnerFacts.self, forKey: .facts))
    }
}
public struct V2PolicySnapshotSubscriberWire: Codable, Hashable, Sendable {
    public let host: V2ActorHostIdentity
    public var hostID: V2ActorHostID { host.hostID }
    public let endpoint: String
    public init(host: V2ActorHostIdentity, endpoint: String) throws {
        guard host.hostID.uuidValue != nil, !endpoint.isEmpty, endpoint.utf8.count <= 512 else {
            throw V2ActorContractError.invalidConfiguration("policy subscriber")
        }
        self.host = host; self.endpoint = endpoint
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(host: c.decode(V2ActorHostIdentity.self, forKey: .host), endpoint: c.decode(String.self, forKey: .endpoint))
    }
}
public struct V2PolicySnapshotRequestWire: Codable, Equatable, Sendable {
    public let endpoint: String
    public let scopes: [V2PolicyScopeWire]
    public let subscriber: V2PolicySnapshotSubscriberWire
    public let interestRevision: UInt64
    public init(endpoint: String, scopes: [V2PolicyScopeWire], subscriber: V2PolicySnapshotSubscriberWire,
                interestRevision: UInt64 = 1) throws {
        guard !endpoint.isEmpty, endpoint.utf8.count <= 512, !scopes.isEmpty, scopes.count <= 4,
              Set(scopes.map(\.key)).count == scopes.count, interestRevision > 0 else {
            throw V2ActorContractError.invalidConfiguration("policy snapshot request")
        }
        self.endpoint = endpoint; self.scopes = scopes; self.subscriber = subscriber; self.interestRevision = interestRevision
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(endpoint: c.decode(String.self, forKey: .endpoint), scopes: c.decode([V2PolicyScopeWire].self, forKey: .scopes),
            subscriber: c.decode(V2PolicySnapshotSubscriberWire.self, forKey: .subscriber),
            interestRevision: c.decode(UInt64.self, forKey: .interestRevision))
    }
}
/// A source/recipient incarnation pair has one control generation, shared by
/// every interested scope. A retired generation can never refresh old facts.
public struct V2PolicyControlSessionWire: Codable, Hashable, Sendable {
    public let source: V2ActorHostIdentity
    public let recipient: V2ActorHostIdentity
    public let generation: UInt64
    public init(source: V2ActorHostIdentity, recipient: V2ActorHostIdentity, generation: UInt64) throws {
        guard source.hostID.uuidValue != nil, recipient.hostID.uuidValue != nil, generation > 0 else {
            throw V2ActorContractError.invalidConfiguration("policy control session")
        }
        self.source = source; self.recipient = recipient; self.generation = generation
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(source: c.decode(V2ActorHostIdentity.self, forKey: .source),
            recipient: c.decode(V2ActorHostIdentity.self, forKey: .recipient),
            generation: c.decode(UInt64.self, forKey: .generation))
    }
}
public struct V2PolicySnapshotBatchWire: Codable, Equatable, Sendable {
    public let session: V2PolicyControlSessionWire
    public let snapshots: [V2PolicySnapshotWire]
    public let interestRevision: UInt64
    public init(session: V2PolicyControlSessionWire, snapshots: [V2PolicySnapshotWire], interestRevision: UInt64 = 1) throws {
        guard !snapshots.isEmpty, snapshots.count <= 4,
              Set(snapshots.map(\.scope.key)).count == snapshots.count, interestRevision > 0 else {
            throw V2ActorContractError.invalidConfiguration("policy snapshot batch")
        }
        self.session = session; self.snapshots = snapshots; self.interestRevision = interestRevision
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(session: c.decode(V2PolicyControlSessionWire.self, forKey: .session),
            snapshots: c.decode([V2PolicySnapshotWire].self, forKey: .snapshots),
            interestRevision: c.decode(UInt64.self, forKey: .interestRevision))
    }
}

/// Interest is owned by the recipient's cache, independently of policy/control
/// versions. A delayed release may remove only the registration it names.
public struct V2PolicyInterestReleaseWire: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public let scope: V2PolicyScopeWire
        public let revision: UInt64
        public init(scope: V2PolicyScopeWire, revision: UInt64) throws {
            guard revision > 0 else { throw V2ActorContractError.invalidConfiguration("policy interest revision") }
            self.scope = scope; self.revision = revision
        }
    }
    public enum Payload: Codable, Equatable, Sendable {
        case scopes([Item])
        case reset(throughRevision: UInt64, sessionGeneration: UInt64?)
    }
    public let endpoint: String
    public let source: V2ActorHostIdentity
    public let subscriber: V2PolicySnapshotSubscriberWire
    public let payload: Payload
    public init(endpoint: String, source: V2ActorHostIdentity, subscriber: V2PolicySnapshotSubscriberWire, payload: Payload) throws {
        guard !endpoint.isEmpty, endpoint.utf8.count <= 512, source.hostID.uuidValue != nil else {
            throw V2ActorContractError.invalidConfiguration("policy interest release")
        }
        switch payload {
        case .scopes(let items):
            guard !items.isEmpty, items.count <= 64, items.allSatisfy({ $0.revision > 0 }),
                  Set(items.map { $0.scope.key }).count == items.count else {
                throw V2ActorContractError.invalidConfiguration("policy interest release scopes")
            }
        case .reset(let revision, let generation):
            guard revision > 0, generation.map({ $0 > 0 }) ?? true else {
                throw V2ActorContractError.invalidConfiguration("policy interest reset")
            }
        }
        self.endpoint = endpoint; self.source = source; self.subscriber = subscriber; self.payload = payload
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(endpoint: c.decode(String.self, forKey: .endpoint), source: c.decode(V2ActorHostIdentity.self, forKey: .source),
            subscriber: c.decode(V2PolicySnapshotSubscriberWire.self, forKey: .subscriber), payload: c.decode(Payload.self, forKey: .payload))
    }
}
public struct V2PolicySnapshotUpdateWire: Codable, Equatable, Sendable {
    public enum Payload: Codable, Equatable, Sendable {
        case snapshot(V2PolicySnapshotWire)
        case heartbeat
        case retire
    }
    public let endpoint: String
    public let session: V2PolicyControlSessionWire
    public let sequence: UInt64
    public let payload: Payload
    public init(endpoint: String, session: V2PolicyControlSessionWire, sequence: UInt64, payload: Payload) throws {
        guard !endpoint.isEmpty, endpoint.utf8.count <= 512, sequence > 0 else {
            throw V2ActorContractError.invalidConfiguration("policy snapshot update")
        }
        self.endpoint = endpoint; self.session = session; self.sequence = sequence; self.payload = payload
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(endpoint: c.decode(String.self, forKey: .endpoint),
            session: c.decode(V2PolicyControlSessionWire.self, forKey: .session),
            sequence: c.decode(UInt64.self, forKey: .sequence), payload: c.decode(Payload.self, forKey: .payload))
    }
}
