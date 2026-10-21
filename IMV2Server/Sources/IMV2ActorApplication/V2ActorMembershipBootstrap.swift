import IMV2ActorCluster
import IMV2ActorContracts

package enum V2ActorMembershipBootstrap {
    /// Caller supplies a fresh committed record before opening business hosts.
    /// A restarted or joining node starts at that version, including joint
    /// state, rather than manufacturing a new stable version from local config.
    package static func qualification(record: V2ActorServiceMembershipRecord,
        configuration: V2RoomActorApplicationConfiguration) throws -> V2ActorServiceQualification {
        guard let local = configuration.realtimePeers.first(where: {
            $0.serviceID == configuration.signer.serviceID.rawValue &&
            $0.address == configuration.address && $0.port == configuration.port
        }) else { throw V2RoomActorApplicationConfigurationError.invalidConfiguration }
        try configuration.trust.validateRealtimeRoster(record.peers,
            local: .init(nodeID: local.nodeID, serviceID: local.serviceID,
                incarnationID: configuration.placementControl.processIncarnation),
            address: configuration.address, port: configuration.port, requiresLocalMember: false)
        return try .init(localNodeID: local.nodeID, membership: record.membership, allowNonMember: true)
    }
}
