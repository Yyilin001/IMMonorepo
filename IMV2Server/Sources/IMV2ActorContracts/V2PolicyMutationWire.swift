import Foundation

/// Immutable trusted-server command. Domain validation occurs at the policy
/// boundary before sealing holders; transport metadata must match that command.
public struct V2PolicyMutationWire: Codable, Equatable, Sendable {
    public let endpoint: String
    public let scope: V2PolicyScopeWire
    public let operationKey: String
    public let fingerprint: Data
    public let command: Data
    public init(endpoint: String, scope: V2PolicyScopeWire, operationKey: String, fingerprint: Data, command: Data) throws {
        guard !endpoint.isEmpty, endpoint.utf8.count <= 512, !operationKey.isEmpty,
              operationKey.utf8.count <= 512, fingerprint.count == 32, !command.isEmpty, command.count <= 16_384 else {
            throw V2ActorContractError.invalidConfiguration("policy mutation")
        }
        self.endpoint = endpoint; self.scope = scope; self.operationKey = operationKey
        self.fingerprint = fingerprint; self.command = command
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(endpoint: c.decode(String.self, forKey: .endpoint), scope: c.decode(V2PolicyScopeWire.self, forKey: .scope),
            operationKey: c.decode(String.self, forKey: .operationKey), fingerprint: c.decode(Data.self, forKey: .fingerprint),
            command: c.decode(Data.self, forKey: .command))
    }
}

public struct V2PolicyMutationReceiptWire: Codable, Equatable, Sendable {
    public let scope: V2PolicyScopeWire
    public let operationKey: String
    public let fingerprint: Data
    public let receipt: Data
    public let replayed: Bool
    public init(scope: V2PolicyScopeWire, operationKey: String, fingerprint: Data, receipt: Data, replayed: Bool) throws {
        guard !operationKey.isEmpty, operationKey.utf8.count <= 512, fingerprint.count == 32,
              !receipt.isEmpty, receipt.count <= 65_536 else { throw V2ActorContractError.invalidConfiguration("policy receipt") }
        self.scope = scope; self.operationKey = operationKey; self.fingerprint = fingerprint
        self.receipt = receipt; self.replayed = replayed
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(scope: c.decode(V2PolicyScopeWire.self, forKey: .scope), operationKey: c.decode(String.self, forKey: .operationKey),
            fingerprint: c.decode(Data.self, forKey: .fingerprint), receipt: c.decode(Data.self, forKey: .receipt), replayed: c.decode(Bool.self, forKey: .replayed))
    }
    public func matches(_ request: V2PolicyMutationWire) -> Bool {
        scope == request.scope && operationKey == request.operationKey && fingerprint == request.fingerprint
    }
}
