import Foundation

/// Immutable trusted-server command. Domain validation occurs at the policy
/// boundary before sealing holders; transport metadata must match that command.
public struct V2PolicyMutationWire: Codable, Equatable, Sendable {
    public let endpoint: String
    public let scope: V2PolicyScopeWire
    public let operationKey: String
    public let fingerprint: Data
    public let command: V2PolicyMutationCommand
    public init(endpoint: String, scope: V2PolicyScopeWire, operationKey: String, fingerprint: Data, command: V2PolicyMutationCommand) throws {
        guard !endpoint.isEmpty, endpoint.utf8.count <= 512, !operationKey.isEmpty,
              operationKey.utf8.count <= 512, fingerprint.count == 32, V2ActorPayloadBudget.retainedBytes(of: command) <= 16_384 else {
            throw V2ActorContractError.invalidConfiguration("policy mutation")
        }
        self.endpoint = endpoint; self.scope = scope; self.operationKey = operationKey
        self.fingerprint = fingerprint; self.command = command
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(endpoint: c.decode(String.self, forKey: .endpoint), scope: c.decode(V2PolicyScopeWire.self, forKey: .scope),
            operationKey: c.decode(String.self, forKey: .operationKey), fingerprint: c.decode(Data.self, forKey: .fingerprint),
            command: c.decode(V2PolicyMutationCommand.self, forKey: .command))
    }
}

public struct V2PolicyMutationReceiptWire: Codable, Equatable, Sendable {
    public let scope: V2PolicyScopeWire
    public let operationKey: String
    public let fingerprint: Data
    public let receipt: V2PolicyMutationResult
    public let replayed: Bool
    public init(scope: V2PolicyScopeWire, operationKey: String, fingerprint: Data, receipt: V2PolicyMutationResult, replayed: Bool) throws {
        guard !operationKey.isEmpty, operationKey.utf8.count <= 512, fingerprint.count == 32,
              V2ActorPayloadBudget.retainedBytes(of: receipt) <= 65_536 else { throw V2ActorContractError.invalidConfiguration("policy receipt") }
        self.scope = scope; self.operationKey = operationKey; self.fingerprint = fingerprint
        self.receipt = receipt; self.replayed = replayed
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(scope: c.decode(V2PolicyScopeWire.self, forKey: .scope), operationKey: c.decode(String.self, forKey: .operationKey),
            fingerprint: c.decode(Data.self, forKey: .fingerprint), receipt: c.decode(V2PolicyMutationResult.self, forKey: .receipt), replayed: c.decode(Bool.self, forKey: .replayed))
    }
    public func matches(_ request: V2PolicyMutationWire) -> Bool {
        scope == request.scope && operationKey == request.operationKey && fingerprint == request.fingerprint
    }
}
