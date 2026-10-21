import Foundation
import IMV2ActorContracts

/// A process-local stable voter, independent of any room admission or owner.
/// The session authenticator already requires dedicated placementVote authority.
/// This second boundary binds the authenticated service to the fixed voter ID;
/// neither membership nor the payload's candidate/leader supplies that binding.
package actor V2PlacementRaftEndpoint: V2PlacementRaftServing {
    package nonisolated let shards: Set<String>
    package nonisolated let localID: V2ActorHostID
    private let voters: [String: V2PlacementRaftVoter]
    private var logs: [String: V2PlacementRaftLeaderLog]?
    private var trust: V2ActorTrustStore?
    private let writers: [V2ActorServiceID: Set<String>]
    private let roomHosts: [V2ActorHostID: Set<String>]
    private let readers: [V2ActorServiceID: Set<String>]
    private let roles: [V2ActorServiceID: V2ActorHostID]
    private init(voters: [String: V2PlacementRaftVoter], localID: V2ActorHostID, roles: [V2ActorServiceID: V2ActorHostID], readers: [V2ActorServiceID: Set<String>], writers: [V2ActorServiceID: Set<String>], roomHosts: [V2ActorHostID: Set<String>]) {
        self.voters = voters; self.roles = roles; self.localID = localID; self.shards = Set(voters.keys); self.readers = readers; self.writers = writers; self.roomHosts = roomHosts
    }
    package static func open(voters: [String: V2PlacementRaftVoter], localID: V2ActorHostID,
                             roles: [V2ActorServiceID: V2ActorHostID], readers: [V2ActorServiceID: Set<String>], writers: [V2ActorServiceID: Set<String>], roomHosts: [V2ActorHostID: Set<String>]) async throws -> V2PlacementRaftEndpoint {
        let roster = Set(roles.values)
        guard !voters.isEmpty, roles.count == 3, roster.count == 3, roster.contains(localID),
              voters.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              readers.values.allSatisfy({ !$0.isEmpty && $0.isSubset(of: Set(voters.keys)) }),
              writers.values.allSatisfy({ !$0.isEmpty && $0.isSubset(of: Set(voters.keys)) }),
              roomHosts.values.allSatisfy({ !$0.isEmpty && $0.isSubset(of: Set(voters.keys)) }) else {
            throw V2PlacementRaftError.invalidConfiguration
        }
        var groups = Set<UUID>()
        for voter in voters.values {
            let state = try await voter.committedState()
            guard state.voterID == localID, state.voters == roster, groups.insert(state.groupID).inserted else { throw V2PlacementRaftError.invalidConfiguration }
        }
        return .init(voters: voters, localID: localID, roles: roles, readers: readers, writers: writers, roomHosts: roomHosts)
    }
    package func bind(_ logs: [String: V2PlacementRaftLeaderLog]) async throws {
        guard self.logs == nil, Set(logs.keys) == shards else { throw V2PlacementRaftError.invalidConfiguration }
        for (shard, log) in logs {
            guard let voter = voters[shard], log.voter === voter, log.localID == localID,
                  try await voter.committedState().groupID == log.groupID else { throw V2PlacementRaftError.invalidConfiguration }
        }
        guard self.logs == nil else { throw V2PlacementRaftError.invalidConfiguration }
        self.logs = logs
    }
    package func readPlacement(_ request: V2PlacementRaftWire, serviceID: V2ActorServiceID,
                               deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftWire {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw V2ActorPlacementError.unavailable }
        guard request.isBounded, (readers[serviceID] ?? trust?.authorizedSources(for: serviceID, configured: nil, requiring: [.placementRead]) ?? []).contains(request.shardID),
              let voter = voters[request.shardID] else { throw V2ActorAuthenticationError.forbidden }
        let decoded = try V2PlacementRaftReadCodec.decodeRequest(request)
        let groupID = decoded.groupID
        guard try await voter.committedState().groupID == groupID else { throw V2PlacementRaftError.wrongGroup }
        if let log = logs?[request.shardID] {
            do {
                if decoded.includeArchiveUsage {
                    let inspection = try await log.inspect(deadline: deadline)
                    return try V2PlacementRaftReadCodec.encode(.inspected(inspection.snapshot, inspection.archiveUsage),
                        shard: request.shardID, groupID: groupID)
                }
                let snapshot = try await log.load(deadline: deadline)
                return try V2PlacementRaftReadCodec.encode(.ready(snapshot), shard: request.shardID, groupID: groupID)
            } catch V2PlacementRaftError.notLeader {} catch V2PlacementRaftError.notReady {} catch V2ActorPlacementError.unavailable {}
        }
        return try V2PlacementRaftReadCodec.encode(.retry(await voter.inspection().leader), shard: request.shardID, groupID: groupID)
    }
    package func writePlacement(_ wire: V2PlacementRaftWire, serviceID: V2ActorServiceID,
                                callerIncarnation: UUID, deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftWire {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw V2ActorPlacementError.unavailable }
        guard wire.isBounded, let trust,
              trust.authorizedSources(for: serviceID, configured: writers[serviceID], requiring: [.placementWrite]).contains(wire.shardID), let voter = voters[wire.shardID], let log = logs?[wire.shardID] else {
            throw V2ActorAuthenticationError.forbidden
        }
        let request = try V2PlacementRaftWriteCodec.decodeRequest(wire)
        guard try await voter.committedState().groupID == request.expected.clusterID else { throw V2PlacementRaftError.wrongGroup }
        func roomHost(_ host: V2ActorHostIdentity) throws {
            guard trust.authorizedSources(for: try trust.configuredHostServiceID(for: host.hostID), configured: roomHosts[host.hostID]).contains(wire.shardID) else { throw V2ActorAuthenticationError.forbidden }
        }
        switch request.command {
        case .installServiceMembership(let membership):
            guard request.certificate == nil,
                  try trust.configuredService(serviceID).permissions.contains(.placementMembership) else {
                throw V2ActorAuthenticationError.forbidden
            }
            // Every proposed endpoint must already belong to an admitted
            // realtime service. This controller need not be a serving member.
            guard let first = membership.peers.first else { throw V2ActorAuthenticationError.invalidConfiguration }
            try trust.validateRealtimeRoster(membership.peers,
                local: .init(nodeID: first.nodeID, serviceID: first.serviceID, incarnationID: UUID()),
                address: first.address, port: first.port)
            try trust.validateRoomRoster(membership.roomPeers, configured: roomHosts)
        case .admitHost(let hostID):
            guard trust.authorizedSources(for: try trust.configuredHostServiceID(for: hostID), configured: roomHosts[hostID]).contains(wire.shardID),
                  try trust.configuredHostServiceID(for: hostID) == serviceID,
                  request.certificate == nil else { throw V2ActorAuthenticationError.forbidden }
        case .registerHost(let previous, let successor):
            try roomHost(successor)
            guard previous.hostID == successor.hostID, successor.incarnationID == callerIncarnation,
                  try trust.configuredHostServiceID(for: successor.hostID) == serviceID,
                  request.certificate == nil else { throw V2ActorAuthenticationError.forbidden }
        case .retireHost(let host):
            try roomHost(host)
            if try trust.configuredService(serviceID).permissions.contains(.placementExclude) {
                guard request.certificate?.signerID == serviceID else { throw V2ActorAuthenticationError.forbidden }
            } else {
                guard host.incarnationID == callerIncarnation,
                      try trust.configuredHostServiceID(for: host.hostID) == serviceID else { throw V2ActorAuthenticationError.forbidden }
            }
        case .beginTransfer(_, let owner, let transfer):
            try roomHost(owner.host); try roomHost(transfer.successor)
            guard request.certificate == nil else { throw V2ActorAuthenticationError.forbidden }
        case .completeTransfer(_, let owner, _): try roomHost(owner.host)
        case .cancelTransfer(_, let owner, _):
            try roomHost(owner.host)
            guard request.certificate == nil else { throw V2ActorAuthenticationError.forbidden }
        }
        let reply: V2PlacementRaftWriteCodec.Reply
        do {
            // A durable exact receipt already certifies a terminal operation.
            // Replay must not depend on contacting a now-retired old process.
            if let prior = try await log.certifiedReceipt(request.command, requestID: request.requestID, deadline: deadline, originRevision: request.originRevision) {
                reply = .ready(prior)
            } else {
                switch request.command {
                case .completeTransfer(let partition, let owner, let transferID):
                    if request.certificate == nil {
                        // Never trust the caller's retired bit: require a fresh
                        // quorum read of the exact CAS snapshot. Its retirement
                        // was admitted only with a native full-Host drain proof.
                        let committed = try await log.load(deadline: deadline)
                        guard committed == request.expected,
                              committed.slots.indices.contains(partition),
                              committed.slots[partition].owner == owner,
                              committed.slots[partition].retired,
                              committed.slots[partition].transfer?.id == transferID else {
                            throw V2ActorAuthenticationError.forbidden
                        }
                        break
                    }
                    guard let certificate = request.certificate,
                          case .partition(let proof) = try V2PlacementDrainCertificate.verify(certificate,
                            shard: wire.shardID, groupID: request.expected.clusterID, trust: trust),
                          proof.partition == partition, proof.owner == owner, proof.transferID == transferID else {
                        throw V2ActorAuthenticationError.forbidden
                    }
                case .retireHost(let host):
                    guard let certificate = request.certificate else {
                        throw V2ActorAuthenticationError.forbidden
                    }
                    switch try V2PlacementDrainCertificate.verify(certificate,
                        shard: wire.shardID, groupID: request.expected.clusterID, trust: trust) {
                    case .host(let provedHost, let previous, let registrationID):
                        guard provedHost == host,
                              let registered = try await log.certifiedReceipt(.registerHost(previous: previous, successor: host),
                                requestID: registrationID, deadline: deadline),
                              registered.registration(for: host.hostID) == .init(host: host, retired: false) else {
                            throw V2ActorAuthenticationError.forbidden
                        }
                    case .excludedHost(let provedHost, let operationID):
                        guard provedHost == host, operationID == request.requestID,
                              certificate.signerID == serviceID,
                              try trust.configuredService(serviceID).permissions.contains(.placementExclude) else {
                            throw V2ActorAuthenticationError.forbidden
                        }
                        let committed = try await log.load(deadline: deadline)
                        guard committed == request.expected else { throw V2ActorPlacementError.staleRevision }
                        guard committed.registration(for: host.hostID) == .init(host: host, retired: false) else {
                            throw V2ActorPlacementError.staleOwner
                        }
                    case .partition: throw V2ActorAuthenticationError.forbidden
                    }
                default: break
                }
                reply = .ready(try await log.append(request.command, expected: request.expected,
                    requestID: request.requestID, deadline: deadline, originRevision: request.originRevision))
            }
        } catch V2PlacementRaftError.notLeader { reply = .retry(await voter.inspection().leader) }
          catch V2PlacementRaftError.notReady { reply = .retry(await voter.inspection().leader) }
          catch let error as V2ActorPlacementError { reply = .rejected(error) }
        return try V2PlacementRaftWriteCodec.encode(reply, groupID: request.expected.clusterID, shard: wire.shardID)
    }
    package func validateTrust(_ trust: V2ActorTrustStore) throws {
        for service in writers.keys {
            guard try trust.configuredService(service).permissions.contains(.placementWrite) else { throw V2ActorAuthenticationError.forbidden }
        }
        for host in roomHosts.keys { _ = try trust.configuredHostServiceID(for: host) }
        for service in readers.keys {
            guard try trust.configuredService(service).permissions.contains(.placementRead) else {
                throw V2ActorAuthenticationError.forbidden
            }
        }
        for (service, id) in roles {
            guard try trust.configuredHostServiceID(for: id, requiring: [.placementVote]) == service else {
                throw V2ActorAuthenticationError.forbidden
            }
        }
        self.trust = trust
    }
    package func exchangeRaft(_ request: V2PlacementRaftWire, serviceID: V2ActorServiceID,
                              callerIncarnation: UUID, deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftWire {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw V2ActorPlacementError.unavailable }
        guard request.isBounded, let voter = voters[request.shardID], let peer = roles[serviceID] else {
            throw V2ActorAuthenticationError.forbidden
        }
        let reply: V2PlacementRaftWireCodec.Reply
        switch try V2PlacementRaftWireCodec.decodeRequest(request) {
        case .vote(let value): reply = .vote(try await voter.vote(value, from: peer))
        case .append(let value): reply = .append(try await voter.append(value, from: peer))
        case .snapshot(let value): reply = .snapshot(try await voter.snapshot(value, from: peer))
        }
        // Actual stable storage settles before the transport returns, even
        // when the caller's deadline expires or its connection disappears.
        return try V2PlacementRaftWireCodec.encode(reply, shard: request.shardID)
    }
}

/// Discovery resolves only an already configured voting role. It cannot add a
/// fourth voter or change the logical group. Client authenticates exact process
/// recipient/reply bindings; codec and voter validate group, term and request.
package struct V2PlacementRaftClusterTransport: V2PlacementRaftElectionTransport {
    package let shardID: String
    package let client: V2RoomClusterClient
    package let resolve: @Sendable (V2ActorHostID, ContinuousClock.Instant) async throws -> V2ActorHostIdentity
    package func append(_ request: V2PlacementRaftAppendRequest, to peer: V2ActorHostID,
                        deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftAppendReply {
        let wire = try V2PlacementRaftWireCodec.encode(.append(request), shard: shardID)
        let host = try await resolve(peer, deadline)
        guard host.hostID == peer else { throw V2PlacementRaftError.unauthorizedVoter }
        let reply = try await client.exchangeRaft(wire, on: host, deadline: deadline)
        guard case .append(let value) = try V2PlacementRaftWireCodec.decodeReply(reply, shard: shardID) else {
            throw V2PlacementRaftError.invalidMessage
        }
        return value
    }
    package func snapshot(_ request: V2PlacementRaftSnapshotChunk, to peer: V2ActorHostID,
                          deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftSnapshotReply {
        let wire = try V2PlacementRaftWireCodec.encode(.snapshot(request), shard: shardID)
        let host = try await resolve(peer, deadline)
        guard host.hostID == peer else { throw V2PlacementRaftError.unauthorizedVoter }
        let reply = try await client.exchangeRaft(wire, on: host, deadline: deadline)
        guard case .snapshot(let value) = try V2PlacementRaftWireCodec.decodeReply(reply, shard: shardID) else {
            throw V2PlacementRaftError.invalidMessage
        }
        return value
    }
    package init(shardID: String, client: V2RoomClusterClient,
                 resolve: @escaping @Sendable (V2ActorHostID, ContinuousClock.Instant) async throws -> V2ActorHostIdentity) {
        self.shardID = shardID; self.client = client; self.resolve = resolve
    }
    package func vote(_ request: V2PlacementRaftVoteRequest, to peer: V2ActorHostID,
                      deadline: ContinuousClock.Instant) async throws -> V2PlacementRaftVoteReply {
        let wire = try V2PlacementRaftWireCodec.encode(.vote(request), shard: shardID)
        let host = try await resolve(peer, deadline)
        guard host.hostID == peer else { throw V2PlacementRaftError.unauthorizedVoter }
        let reply = try await client.exchangeRaft(wire, on: host, deadline: deadline)
        guard case .vote(let value) = try V2PlacementRaftWireCodec.decodeReply(reply, shard: shardID) else {
            throw V2PlacementRaftError.invalidMessage
        }
        return value
    }
}
