import Foundation

/// Exact local capacity rejection before a shard publication is dispatched.
/// Authentication, shutdown and unknown remote outcomes never use this error.
public enum V2RealtimeLocalAdmissionBackpressure: Error, Equatable, Sendable {
    case globalRPCs, peerRPCs
}

public struct V2RealtimeTopicKey: Hashable, Codable, Sendable {
    public let kind: V2RealtimeTopicKind
    public let id: String
    public init(kind: V2RealtimeTopicKind, id: String) {
        self.kind = kind
        // PostgreSQL UUID::text is the persistent topic/partition spelling.
        // Opaque identifiers retain their original case and identity.
        self.id = UUID(uuidString: id)?.uuidString.lowercased() ?? id
    }
    private enum CodingKeys: String, CodingKey { case kind, id }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try container.decode(V2RealtimeTopicKind.self, forKey: .kind),
            id: try container.decode(String.self, forKey: .id))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind); try container.encode(id, forKey: .id)
    }
    public init(_ topic: V2RealtimeTopic) { self.init(kind: topic.kind, id: topic.id) }
    public func partitionID(partitionCount: Int = 256) -> Int {
        precondition(partitionCount > 0 && partitionCount <= 256)
        var bytes: [UInt8] = [1]
        for value in [kind.rawValue, id] {
            let encoded = Array(value.utf8)
            let length = UInt32(encoded.count)
            bytes += [UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
                      UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)]
            bytes += encoded
        }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Int(hash % UInt64(partitionCount))
    }
}
public struct V2RealtimeShardToken: Hashable, Codable, Sendable {
    public let partitionID: Int
    public let host: V2GatewayRealtimeIdentity
    public let epoch: Int64
    public let leaseToken: UUID
    public init(partitionID: Int, host: V2GatewayRealtimeIdentity, epoch: Int64, leaseToken: UUID) {
        self.partitionID = partitionID; self.host = host; self.epoch = epoch; self.leaseToken = leaseToken
    }
}
public struct V2RealtimeShardLeaseAdvertisement: Codable, Sendable {
    public let token: V2RealtimeShardToken
    public let remainingLeaseMilliseconds: Int64
    public init(token: V2RealtimeShardToken, remainingLeaseMilliseconds: Int64) {
        self.token = token; self.remainingLeaseMilliseconds = remainingLeaseMilliseconds
    }
}
public struct V2RealtimeShardDescriptor: Hashable, Codable, Sendable {
    public let token: V2RealtimeShardToken
    public let endpointReference: Data
    public let address: String
    public let port: Int
    public let remainingLeaseMilliseconds: Int64
    public init(token: V2RealtimeShardToken, endpointReference: Data, address: String, port: Int,
                remainingLeaseMilliseconds: Int64) {
        self.token = token; self.endpointReference = endpointReference; self.address = address; self.port = port
        self.remainingLeaseMilliseconds = remainingLeaseMilliseconds
    }
    public var endpoint: V2GatewayRealtimeDescriptor {
        .init(identity: token.host, endpointReference: endpointReference, address: address, port: port)
    }
    public func validate() throws {
        try endpoint.validate()
        guard (0..<256).contains(token.partitionID), token.epoch > 0,
              (1...300_000).contains(remainingLeaseMilliseconds) else {
            throw V2ActorContractError.invalidConfiguration("realtime shard descriptor")
        }
    }
}
public struct V2RealtimeShardSession: Hashable, Codable, Sendable {
    public let gateway: V2GatewayRealtimeDescriptor
    public let sessionID: UUID
    public let sessionGeneration: Int64
    public init(gateway: V2GatewayRealtimeDescriptor, sessionID: UUID, sessionGeneration: Int64) {
        self.gateway = gateway; self.sessionID = sessionID; self.sessionGeneration = sessionGeneration
    }
}
public struct V2RealtimeShardInterest: Hashable, Codable, Sendable {
    public let key: V2RealtimeTopicKey
    public let interestGeneration: Int64
    public init(key: V2RealtimeTopicKey, interestGeneration: Int64) { self.key = key; self.interestGeneration = interestGeneration }
}
public enum V2RealtimeShardInterestChange: Equatable, Codable, Sendable {
    case upsert(V2RealtimeShardInterest)
    case remove(key: V2RealtimeTopicKey, generation: Int64)
}
public enum V2RealtimeShardMutation: Equatable, Codable, Sendable {
    case delta([V2RealtimeShardInterestChange])
    case snapshotChunk(snapshotID: UUID, index: Int, total: Int, digest: Data, interests: [V2RealtimeShardInterest])
    /// Heartbeat uses baseRevision=nextRevision=0 and never mutates subscription revision.
    case renew
    case close
}
public struct V2RealtimeShardControlRequest: Equatable, Codable, Sendable {
    public let token: V2RealtimeShardToken
    public let session: V2RealtimeShardSession
    public let baseRevision: Int64
    public let nextRevision: Int64
    public let mutation: V2RealtimeShardMutation
    public let payloadFingerprint: Data
    public init(token: V2RealtimeShardToken, session: V2RealtimeShardSession, baseRevision: Int64,
                nextRevision: Int64, mutation: V2RealtimeShardMutation, payloadFingerprint: Data) {
        self.token = token; self.session = session; self.baseRevision = baseRevision; self.nextRevision = nextRevision
        self.mutation = mutation; self.payloadFingerprint = payloadFingerprint
    }
}
public struct V2RealtimeShardControlReply: Equatable, Codable, Sendable {
    public enum Status: String, Codable, Sendable { case applied, requiresSnapshot, notInstalled, retiredEpoch, retiredIncarnation, overloaded }
    public let appliedRevision: Int64
    public let remainingSessionMilliseconds: Int64
    public let status: Status
    public init(appliedRevision: Int64, remainingSessionMilliseconds: Int64, status: Status) {
        self.appliedRevision = appliedRevision; self.remainingSessionMilliseconds = remainingSessionMilliseconds; self.status = status
    }
}
public struct V2RealtimeShardPublishRequest: Equatable, Codable, Sendable {
    public let token: V2RealtimeShardToken
    public let topic: V2RealtimeTopic
    public let payload: V2RealtimePayload
    public init(token: V2RealtimeShardToken, topic: V2RealtimeTopic, payload: V2RealtimePayload) {
        self.token = token; self.topic = topic; self.payload = payload
    }
}
public enum V2RealtimeShardPublishReply: String, Codable, Equatable, Sendable {
    case noSubscribers, accepted, acceptedAsWatermark, notInstalled, retiredEpoch, retiredIncarnation, overloaded
}

public protocol V2RealtimeShardTransport: Sendable {
    func resolve(partitionID: Int) async throws -> V2RealtimeShardDescriptor
    func control(_ descriptor: V2RealtimeShardDescriptor, request: V2RealtimeShardControlRequest) async throws -> V2RealtimeShardControlReply
    func publish(_ descriptor: V2RealtimeShardDescriptor, request: V2RealtimeShardPublishRequest) async throws -> V2RealtimeShardPublishReply
    func invalidate(_ descriptor: V2RealtimeShardDescriptor) async
}
public protocol V2RealtimeShardServing: Sendable {
    func control(_ request: V2RealtimeShardControlRequest) async throws -> V2RealtimeShardControlReply
    func publish(_ request: V2RealtimeShardPublishRequest) async throws -> V2RealtimeShardPublishReply
}
public struct V2RealtimeShardDiscoveryPeer: Hashable, Sendable {
    public let nodeID: String
    public let serviceID: String
    public let address: String
    public let port: Int
    public init(nodeID: String, serviceID: String, address: String, port: Int) {
        self.nodeID = nodeID; self.serviceID = serviceID; self.address = address; self.port = port
    }
}

/// Fixed counters only: no node, topic, token or SQL labels. Control waits in
/// one bounded sender queue; active calls include their shared handshake wait.
public enum V2RealtimeRPCAdmissionLane: String, CaseIterable, Sendable { case control, publish }
public enum V2RealtimeRPCAdmissionRejection: String, CaseIterable, Sendable { case stopped, global, peer, queueFull, queueTimeout }

public struct V2RealtimeShardTransportMetricsSnapshot: Sendable {
    public let cacheHits: UInt64
    public let cacheMisses: UInt64
    public let cacheInvalidations: UInt64
    /// Actual Receptionist invocations, classified by the shared pass creator.
    public let backgroundReceptionistLookups: UInt64
    public let foregroundReceptionistLookups: UInt64
    public let discoveryPasses: UInt64
    public let discoveryActive: Int
    public let cachedPartitions: Int
    public let reachableNodes: Int
    public let controlStarted: UInt64
    public let controlSettled: UInt64
    public let controlActive: Int
    public let controlQueued: Int
    public let controlQueueSeconds: Double
    public let controlQueueSettled: UInt64
    public let publishStarted: UInt64
    public let publishSettled: UInt64
    public let publishActive: Int
    public let capacityRejections: [V2RealtimeRPCAdmissionLane: [V2RealtimeRPCAdmissionRejection: UInt64]]
    public let rpcRejected: UInt64
    public let pendingHandshakes: Int
    public init(cacheHits: UInt64, cacheMisses: UInt64, cacheInvalidations: UInt64,
                discoveryPasses: UInt64, discoveryActive: Int, cachedPartitions: Int, reachableNodes: Int,
                controlStarted: UInt64, controlSettled: UInt64, controlActive: Int,
                publishStarted: UInt64, publishSettled: UInt64, publishActive: Int,
                rpcRejected: UInt64, pendingHandshakes: Int,
                capacityRejections: [V2RealtimeRPCAdmissionLane: [V2RealtimeRPCAdmissionRejection: UInt64]] = [:],
                backgroundReceptionistLookups: UInt64 = 0, foregroundReceptionistLookups: UInt64 = 0,
                controlQueued: Int = 0, controlQueueSeconds: Double = 0, controlQueueSettled: UInt64 = 0) {
        self.cacheHits = cacheHits; self.cacheMisses = cacheMisses; self.cacheInvalidations = cacheInvalidations
        self.backgroundReceptionistLookups = backgroundReceptionistLookups; self.foregroundReceptionistLookups = foregroundReceptionistLookups
        self.discoveryPasses = discoveryPasses; self.discoveryActive = discoveryActive
        self.cachedPartitions = cachedPartitions; self.reachableNodes = reachableNodes
        self.controlStarted = controlStarted; self.controlSettled = controlSettled; self.controlActive = controlActive
        self.controlQueued = controlQueued; self.controlQueueSeconds = controlQueueSeconds; self.controlQueueSettled = controlQueueSettled
        self.publishStarted = publishStarted; self.publishSettled = publishSettled; self.publishActive = publishActive
        self.capacityRejections = capacityRejections
        self.rpcRejected = rpcRejected; self.pendingHandshakes = pendingHandshakes
    }
}
