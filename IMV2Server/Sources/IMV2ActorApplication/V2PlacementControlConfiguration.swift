import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import NIOSSL

/// Mandatory, fixed three-voter deployment. Control endpoints are separate
/// from room endpoints; readers neither open storage nor acquire voting roles.
public struct V2PlacementControlConfiguration: Sendable {
    package let clusterID: UUID
    package let node: V2RoomClusterClientNodeConfiguration
    package let identity: V2ActorHostIdentity?
    package let processIncarnation: UUID
    package let discovery: V2RoomDiscoveryConfiguration
    package let roles: [V2ActorServiceID: V2ActorHostID]
    package let readers: [V2ActorServiceID: Set<String>]
    package let writers: [V2ActorServiceID: Set<String>]
    package let roomHosts: [V2ActorHostID: Set<String>]
    package let storagePaths: [String: URL]
    package let shards: Set<String>

    init(document: Document, name: String, address: String, roomPort: Int, tls: TLSConfiguration,
         signer: V2ActorSigningIdentity, trust: V2ActorTrustStore, processIncarnation: UUID,
         shards: Set<String>, roomPeers: [V2RoomDiscoveryPeer], serviceAccess: [V2ActorServiceID: Set<String>]) throws {
        guard document.voters.count == 3, (document.localVoterID != nil || document.port != roomPort),
              Set(document.voters.map(\.hostID)).count == 3, Set(document.voters.map(\.serviceID)).count == 3,
              Set(document.voters.map { "\($0.address):\($0.port)" }).count == 3 else {
            throw V2RoomActorApplicationConfigurationError.invalidConfiguration
        }
        var roles: [V2ActorServiceID: V2ActorHostID] = [:], peers: [V2RoomDiscoveryPeer] = []
        let roomIDs = Set(roomPeers.map(\.hostID))
        for value in document.voters {
            let id = V2ActorHostID(uuid: value.hostID), service = try V2ActorServiceID(value.serviceID)
            guard !roomIDs.contains(id), Set(value.shardIDs) == shards, value.shardIDs.count == shards.count,
                  Self.validAddress(value.address),
                  try trust.configuredHostServiceID(for: id, requiring: [.placementVote, .placementRead]) == service,
                  serviceAccess[service]?.isSuperset(of: shards) == true,
                  !roomPeers.contains(where: { $0.address == value.address && $0.port == value.port }) else {
                throw V2RoomActorApplicationConfigurationError.invalidConfiguration
            }
            roles[service] = id
            peers.append(try .init(hostID: id, serviceID: service, address: value.address, port: value.port,
                                  accessibleShardIDs: shards, maximumRooms: 1))
        }
        let identity = document.localVoterID.map { V2ActorHostIdentity(hostID: .init(uuid: $0), incarnationID: processIncarnation) }
        var paths: [String: URL] = [:]
        if let identity {
            guard roles[signer.serviceID] == identity.hostID,
                  peers.contains(where: { $0.hostID == identity.hostID && $0.address == address && $0.port == document.port }),
                  Set(document.storagePaths.keys) == shards,
                  Set(document.storagePaths.values).count == document.storagePaths.count else {
                throw V2RoomActorApplicationConfigurationError.invalidConfiguration
            }
            for (shard, value) in document.storagePaths {
                guard value.hasPrefix("/"), !value.hasSuffix("/"), !value.contains("\0") else {
                    throw V2RoomActorApplicationConfigurationError.invalidConfiguration
                }
                paths[shard] = URL(fileURLWithPath: value).standardizedFileURL
            }
            guard Set(paths.values).count == paths.count else { throw V2RoomActorApplicationConfigurationError.invalidConfiguration }
        } else {
            guard document.storagePaths.isEmpty, roles[signer.serviceID] == nil,
                  !peers.contains(where: { $0.address == address && $0.port == document.port }) else {
                throw V2RoomActorApplicationConfigurationError.invalidConfiguration
            }
        }
        var readers: [V2ActorServiceID: Set<String>] = [:], writers: [V2ActorServiceID: Set<String>] = [:]
        for (service, access) in serviceAccess {
            let permissions = try trust.configuredService(service).permissions, scopes = access.intersection(shards)
            if permissions.contains(.placementRead), !scopes.isEmpty { readers[service] = scopes }
            if permissions.contains(.placementWrite), !scopes.isEmpty { writers[service] = scopes }
        }
        guard readers[signer.serviceID]?.isSuperset(of: shards) == true,
              roomPeers.allSatisfy({ writers[$0.serviceID]?.isSuperset(of: $0.accessibleShardIDs) == true }) else {
            throw V2RoomActorApplicationConfigurationError.invalidConfiguration
        }
        self.clusterID = document.clusterID
        self.node = try .init(name: name + "-placement", host: address, port: document.port,
                              tls: tls, threadPoolSize: document.threadPoolSize)
        self.identity = identity; self.processIncarnation = processIncarnation
        self.discovery = try .init(peers: peers); self.roles = roles; self.readers = readers; self.writers = writers
        self.roomHosts = Dictionary(uniqueKeysWithValues: roomPeers.map { ($0.hostID, $0.accessibleShardIDs) })
        self.storagePaths = paths; self.shards = shards
    }
    private static func validAddress(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 253 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 46
        }
    }
    struct Document: Decodable, Sendable {
        let clusterID: UUID
        let port: Int
        let threadPoolSize: Int
        let localVoterID: UUID?
        let storagePaths: [String: String]
        let voters: [Voter]
        struct Voter: Decodable, Sendable {
            let hostID: UUID
            let serviceID: String
            let address: String
            let port: Int
            let shardIDs: [String]
        }
    }
}
