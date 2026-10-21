import Foundation
import IMV2ActorContracts

/// Committed control state. Endpoints are part of the authorized record, not
/// inferred from discovery. This record does not grant partition ownership.
package struct V2ActorServiceMembershipRecord: Codable, Equatable, Sendable {
    package let revision: UInt64
    package let current: [String]
    package let next: [String]?
    package let peers: [V2RealtimeShardDiscoveryPeer]
    package let roomPeers: [V2RoomDiscoveryPeer]
    package var membership: V2ActorServiceQualification.Membership {
        // Construction and decoding both validate these immutable fields.
        try! .init(revision: revision, current: Set(current), next: next.map(Set.init))
    }
    package init(revision: UInt64, current: [String], next: [String]? = nil,
                 peers: [V2RealtimeShardDiscoveryPeer], roomPeers: [V2RoomDiscoveryPeer] = []) throws {
        let member = try V2ActorServiceQualification.Membership(revision: revision,
            current: Set(current), next: next.map(Set.init))
        guard (next == nil || revision < UInt64.max),
              Set(current).count == current.count, next.map({ Set($0).count == $0.count }) != false,
              peers.count == member.nodes.count, Set(peers.map(\.nodeID)) == member.nodes,
              Set(peers.map { "\($0.address):\($0.port)" }).count == peers.count,
              peers.allSatisfy({ !$0.address.isEmpty && $0.address.utf8.count <= 253 &&
                  $0.address != "0.0.0.0" && $0.address != "::" && (1...65535).contains($0.port) &&
                  (try? V2ActorServiceID($0.serviceID)) != nil }) else {
            throw V2ActorPlacementError.invalidConfiguration
        }
        guard roomPeers.count <= 64, Set(roomPeers.map(\.hostID)).count == roomPeers.count,
              Set(roomPeers.map(\.serviceID)).count == roomPeers.count,
              roomPeers.allSatisfy({ room in peers.contains {
                  $0.serviceID == room.serviceID.rawValue && $0.address == room.address && $0.port == room.port
              } }) else { throw V2ActorPlacementError.invalidConfiguration }
        self.roomPeers = roomPeers.sorted { $0.hostID.rawValue < $1.hostID.rawValue }
        self.revision = revision; self.current = current.sorted(); self.next = next?.sorted()
        self.peers = peers.sorted { $0.nodeID < $1.nodeID }
    }
    private enum CodingKeys: CodingKey { case revision, current, next, peers, roomPeers }
    package init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(revision: values.decode(UInt64.self, forKey: .revision),
            current: values.decode([String].self, forKey: .current),
            next: values.decodeIfPresent([String].self, forKey: .next),
            peers: values.decode([V2RealtimeShardDiscoveryPeer].self, forKey: .peers),
            roomPeers: values.decode([V2RoomDiscoveryPeer].self, forKey: .roomPeers))
    }
    package func validateSuccessor(of previous: Self?) throws {
        guard let previous else {
            guard revision == 1, next == nil else { throw V2ActorPlacementError.invalidTransition }
            return
        }
        guard previous.revision < UInt64.max, revision == previous.revision + 1 else {
            throw V2ActorPlacementError.staleRevision
        }
        if let target = previous.next {
            guard current == target, next == nil else { throw V2ActorPlacementError.invalidTransition }
        } else {
            guard current == previous.current, next != nil else { throw V2ActorPlacementError.invalidTransition }
        }
        let roomByID = Dictionary(uniqueKeysWithValues: roomPeers.map { ($0.hostID, $0) })
        // A retained realtime host keeps exactly the same room authorization.
        // Removed hosts disappear with the final roster; joint state keeps both sides.
        let services = Set(peers.map(\.serviceID))
        guard previous.roomPeers.allSatisfy({
            services.contains($0.serviceID.rawValue) ? roomByID[$0.hostID] == $0 : roomByID[$0.hostID] == nil
        }), previous.next == nil || roomPeers.allSatisfy({ previous.roomPeers.contains($0) }) else {
            throw V2ActorPlacementError.invalidTransition
        }
        let byID = Dictionary(uniqueKeysWithValues: peers.map { ($0.nodeID, $0) })
        guard previous.peers.allSatisfy({ byID[$0.nodeID] == nil || byID[$0.nodeID] == $0 }) else {
            throw V2ActorPlacementError.invalidTransition
        }
    }
}
