import Foundation

/// One delivery generation for a physical Host/Gateway pair. Room grants bind
/// to it; transport authentication alone cannot reopen a retired generation.
public struct V2RoomDeliverySession: Codable, Hashable, Sendable {
    public let host: V2ActorHostIdentity
    public let gateway: V2GatewayRealtimeIdentity
    public let generation: UInt64
    public init(host: V2ActorHostIdentity, gateway: V2GatewayRealtimeIdentity, generation: UInt64) {
        self.host = host; self.gateway = gateway; self.generation = generation
    }
    public func validate() throws {
        guard generation > 0, !host.hostID.rawValue.isEmpty,
              host.hostID.rawValue.utf8.count <= 128,
              !gateway.nodeID.isEmpty, gateway.nodeID.utf8.count <= 128,
              !gateway.serviceID.isEmpty, gateway.serviceID.utf8.count <= 128 else {
            throw V2ActorContractError.invalidConfiguration("room delivery session")
        }
    }
}

public struct V2RoomDeliverySessionPulse: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case open, heartbeat, retire }
    public let session: V2RoomDeliverySession
    public let kind: Kind
    public let sequence: UInt64
    public init(session: V2RoomDeliverySession, kind: Kind, sequence: UInt64) {
        self.session = session; self.kind = kind; self.sequence = sequence
    }
}

public enum V2RoomDeliverySessionResult: String, Codable, Sendable {
    case accepted, resetRequired, stale
}
