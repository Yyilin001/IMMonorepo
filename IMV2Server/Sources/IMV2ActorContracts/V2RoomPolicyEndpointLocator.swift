import Foundation

/// Stable host and physical room-store alias. Incarnation is deliberately
/// excluded: a restarted host must settle the original durable obligation.
public struct V2RoomPolicyEndpointLocator: Equatable, Sendable {
    public let hostID: UUID
    public let shardID: String
    public static let prefix = "policy-room-v1:"

    public init(hostID: UUID, shardID: String) throws {
        guard !shardID.isEmpty, shardID.utf8.count <= 128,
              !shardID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw V2ActorContractError.invalidConfiguration("policy room endpoint")
        }
        self.hostID = hostID; self.shardID = shardID
    }

    public var encoded: String {
        Self.prefix + hostID.uuidString.lowercased() + ":" + Data(shardID.utf8).base64EncodedString()
    }

    public init(encoded: String) throws {
        let parts = encoded.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "policy-room-v1",
              let host = UUID(uuidString: String(parts[1])),
              let bytes = Data(base64Encoded: String(parts[2])),
              let shard = String(data: bytes, encoding: .utf8) else {
            throw V2ActorContractError.invalidConfiguration("policy room endpoint")
        }
        try self.init(hostID: host, shardID: shard)
        guard self.encoded == encoded else {
            throw V2ActorContractError.invalidConfiguration("noncanonical policy room endpoint")
        }
    }
}
