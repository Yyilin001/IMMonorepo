import Crypto
import Distributed
import DistributedCluster
import Foundation
import IMV2ActorContracts
import Synchronization

/// A cached advertisement never grants its original remaining duration twice.
func v2RealtimeShardDescriptorSnapshot(_ descriptor: V2RealtimeShardDescriptor,
                                      expiresAt: ContinuousClock.Instant,
                                      now: ContinuousClock.Instant) -> V2RealtimeShardDescriptor? {
    let duration = now.duration(to: expiresAt).components
    let remaining = min(descriptor.remainingLeaseMilliseconds,
        duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
    guard remaining > 0 else { return nil }
    return .init(token: descriptor.token, endpointReference: descriptor.endpointReference,
        address: descriptor.address, port: descriptor.port, remainingLeaseMilliseconds: remaining)
}

struct ShardDiscoveryRequest: Codable, Sendable {
    let requester: V2GatewayRealtimeIdentity
    let recipientNodeID: String
    let challenge: UUID
    let rosterDigest: Data
}

func v2VerifyShardDiscoveryRequest(_ packet: V2ActorSignedPacket, trust: V2ActorTrustStore,
    recipient: V2GatewayRealtimeIdentity, roster: [String: String], rosterDigest: Data) throws -> ShardDiscoveryRequest {
    let (request, trusted) = try trust.verify(packet, as: ShardDiscoveryRequest.self, maximumBytes: 16_384)
    try trust.validateRealtimeReceiver(request.requester)
    guard request.recipientNodeID == recipient.nodeID, request.rosterDigest == rosterDigest,
          roster[request.requester.nodeID] == request.requester.serviceID,
          trusted.serviceID.rawValue == request.requester.serviceID else { throw V2ActorAuthenticationError.wrongRecipient }
    return request
}

struct ShardAdvertisement: Codable, Sendable {
    let requester: V2GatewayRealtimeIdentity
    let rosterDigest: Data
    let version: Int
    let challenge: UUID
    let identity: V2GatewayRealtimeIdentity
    let beaconID: ClusterSystem.ActorID
    let endpointID: ClusterSystem.ActorID
    let endpointReference: Data
    let partitions: [V2RealtimeShardLeaseAdvertisement]
}
actor V2RealtimeShardPublisher {
    let identity: V2GatewayRealtimeIdentity
    let signer: V2ActorSigningIdentity
    let endpointID: ClusterSystem.ActorID
    let endpointReference: Data
    let trust: V2ActorTrustStore
    let roster: [String: String]
    let rosterDigest: Data
    private var leases: [Int: (V2RealtimeShardToken, ContinuousClock.Instant)] = [:]
    private var accepting = true
    init(identity: V2GatewayRealtimeIdentity, signer: V2ActorSigningIdentity, endpointID: ClusterSystem.ActorID, endpointReference: Data, trust: V2ActorTrustStore, roster: [String: String], rosterDigest: Data) {
        self.trust = trust; self.roster = roster; self.rosterDigest = rosterDigest
        self.identity = identity; self.signer = signer; self.endpointID = endpointID; self.endpointReference = endpointReference
    }
    func install(_ values: [V2RealtimeShardLeaseAdvertisement]) throws {
        guard accepting, values.count <= 256, Set(values.map { $0.token.partitionID }).count == values.count,
              values.allSatisfy({ $0.token.host == identity && (0..<256).contains($0.token.partitionID) && $0.token.epoch > 0 && (1...300_000).contains($0.remainingLeaseMilliseconds) }) else {
            throw V2ActorAuthenticationError.invalidRequest
        }
        // Replacement is a complete authoritative set, including retirements.
        let now = ContinuousClock.now
        leases = Dictionary(uniqueKeysWithValues: values.map { ($0.token.partitionID, ($0.token, now + .milliseconds($0.remainingLeaseMilliseconds))) })
    }
    func advertise(packet: V2ActorSignedPacket, beaconID: ClusterSystem.ActorID) throws -> V2ActorSignedPacket {
        let request = try v2VerifyShardDiscoveryRequest(packet, trust: trust, recipient: identity, roster: roster, rosterDigest: rosterDigest)
        guard accepting else { throw V2ActorAuthenticationError.overloaded }
        let now = ContinuousClock.now
        let values = leases.values.compactMap { token, deadline -> V2RealtimeShardLeaseAdvertisement? in
            let duration = now.duration(to: deadline).components
            let milliseconds = duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000
            guard milliseconds > 0 else { return nil }
            return .init(token: token, remainingLeaseMilliseconds: milliseconds)
        }.sorted { $0.token.partitionID < $1.token.partitionID }
        return try signer.sign(ShardAdvertisement(requester: request.requester, rosterDigest: rosterDigest, version: 1, challenge: request.challenge, identity: identity,
            beaconID: beaconID, endpointID: endpointID, endpointReference: endpointReference, partitions: values), maximumBytes: 262_144)
    }
    func stop() { accepting = false; leases.removeAll() }
}
public distributed actor V2RealtimeShardDiscoveryBeacon {
    public typealias ActorSystem = ClusterSystem
    let publisher: V2RealtimeShardPublisher
    init(actorSystem: ClusterSystem, publisher: V2RealtimeShardPublisher) { self.actorSystem = actorSystem; self.publisher = publisher }
    static func key(nodeID: String) -> DistributedReception.Key<V2RealtimeShardDiscoveryBeacon> {
        .init(Self.self, id: "imv2/realtime-shards/v1/\(nodeID)")
    }
    public distributed func advertise(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try await publisher.advertise(packet: packet, beaconID: id)
    }
}

private distributed actor ShardReferenceWatcher: LifecycleWatch {
    typealias ActorSystem = ClusterSystem
    private let notify: @Sendable (ClusterSystem.ActorID) async -> Void
    private var endpoints: [String: V2RealtimeShardEndpoint] = [:]
    init(actorSystem: ClusterSystem, notify: @escaping @Sendable (ClusterSystem.ActorID) async -> Void) {
        self.actorSystem = actorSystem; self.notify = notify
    }
    func observe(nodeID: String, endpoint: V2RealtimeShardEndpoint) {
        if let old = endpoints[nodeID], old.id != endpoint.id { unwatchTermination(of: old) }
        endpoints[nodeID] = watchTermination(of: endpoint)
    }
    func clear() { for endpoint in endpoints.values { unwatchTermination(of: endpoint) }; endpoints.removeAll() }
    func terminated(actor id: ClusterSystem.ActorID) async {
        endpoints = endpoints.filter { $0.value.id != id }
        await notify(id)
    }
}

/// Hot calls retain a typed endpoint/session. Receptionist candidates grant no
/// authority: only challenge-bound signed lease advertisements populate this cache.
public actor V2RealtimeShardTransportHandle: V2RealtimeShardTransport {
    public nonisolated let serviceQualification: V2ActorServiceQualification
    private let signer: V2ActorSigningIdentity
    private let rosterDigest: Data
    private var qualificationObserver: (@Sendable () async -> Void)?
    public let identity: V2GatewayRealtimeIdentity
    private let system: ClusterSystem
    private let trust: V2ActorTrustStore
    private let peers: [V2RealtimeShardDiscoveryPeer]
    private let resolutionTimeout: Duration
    private let sender: V2RealtimeShardSender
    private let endpoint: V2RealtimeShardEndpoint
    private let inbound: V2RealtimeShardInbound
    private let publisher: V2RealtimeShardPublisher
    private let beacon: V2RealtimeShardDiscoveryBeacon
    private struct Cached: Sendable { let descriptor: V2RealtimeShardDescriptor; let expires: ContinuousClock.Instant }
    private var cache: [Int: Cached] = [:]
    private var stopped = false
    private nonisolated let receptionistLookups = Mutex((background: UInt64(0), foreground: UInt64(0)))
    private var cacheHits: UInt64 = 0, cacheMisses: UInt64 = 0, invalidations: UInt64 = 0, discoveryPasses: UInt64 = 0
    private var watcher: ShardReferenceWatcher?
    private var watchedReferences: [String: ClusterSystem.ActorID] = [:]
    private var watchedDescriptors: [String: V2GatewayRealtimeDescriptor] = [:]
    private var watchedIdentities: [String: V2GatewayRealtimeIdentity] = [:]
    private struct RetiringReference {
        let identity: V2GatewayRealtimeIdentity
        let id: ClusterSystem.ActorID
        let replaced: Bool
        let reference: Data
    }
    private var retiringReferences: [ClusterSystem.ActorID: RetiringReference] = [:]
    private var softSuspendedReferences: Set<ClusterSystem.ActorID> = []
    private var retiredReferences: [String: ClusterSystem.ActorID] = [:]
    private var rejectedTokens: [Int: V2RealtimeShardToken] = [:]
    private var worker: Task<Void, Never>?
    private struct DiscoveryResult: Sendable {
        let generation: UInt64
        let values: [Cached]
        let reachable: [String: ContinuousClock.Instant]
        let references: [String: ClusterSystem.ActorID]
        let identities: [String: V2GatewayRealtimeIdentity]
        let descriptors: [String: V2GatewayRealtimeDescriptor]
    }
    private var pollGeneration: UInt64 = 0
    private var appliedPollGeneration: UInt64 = 0
    private var reachable: [String: ContinuousClock.Instant] = [:]
    private var poll: Task<Void, Never>?
    private var peerCursor = 0
    private struct ResolutionWaiter {
        let partitionID: Int
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<V2RealtimeShardDescriptor, any Error>
        let timer: Task<Void, Never>
    }
    private var resolutionWaiters: [UUID: ResolutionWaiter] = [:]
    init(system: ClusterSystem, identity: V2GatewayRealtimeIdentity, trust: V2ActorTrustStore, signer: V2ActorSigningIdentity, rosterDigest: Data, qualification: V2ActorServiceQualification,
         peers: [V2RealtimeShardDiscoveryPeer], sender: V2RealtimeShardSender,
         endpoint: V2RealtimeShardEndpoint, inbound: V2RealtimeShardInbound,
         publisher: V2RealtimeShardPublisher, beacon: V2RealtimeShardDiscoveryBeacon, resolutionTimeout: Duration) {
        self.serviceQualification = qualification; self.signer = signer; self.rosterDigest = rosterDigest
        self.system = system; self.identity = identity; self.trust = trust; self.peers = peers; self.resolutionTimeout = resolutionTimeout
        self.sender = sender; self.endpoint = endpoint; self.inbound = inbound
        self.publisher = publisher; self.beacon = beacon
    }
    public func setQualificationObserver(_ notify: @escaping @Sendable () async -> Void) async {
        guard !stopped else { await notify(); return }
        qualificationObserver = notify
        await notify()
    }
    private func publishQualification() async {
        guard !stopped else { return }
        serviceQualification.update(witnesses: reachable)
        await qualificationObserver?()
    }
    func start() async {
        watcher = ShardReferenceWatcher(actorSystem: system) { [weak self] id in await self?.referenceTerminated(id) }
        for peer in peers { system.cluster.join(host: peer.address, port: peer.port) }
        await system.receptionist.checkIn(beacon, with: V2RealtimeShardDiscoveryBeacon.key(nodeID: identity.nodeID))
        guard !stopped, worker == nil else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
            await self?.workerFinished()
        }
    }
    private func workerFinished() { worker = nil }
    public func installPartitions(_ values: [V2RealtimeShardLeaseAdvertisement]) async throws {
        guard !stopped else { throw V2ActorAuthenticationError.overloaded }
        try await publisher.install(values)
    }
    public func reachableNodeIDs() -> Set<String> {
        guard !stopped else { return [] }
        return Set(reachable.filter { $0.value > .now }.keys).union([identity.nodeID])
    }
    public func resolve(partitionID: Int) async throws -> V2RealtimeShardDescriptor {
        try Task.checkCancellation()
        guard !stopped, (0..<256).contains(partitionID) else { throw V2ActorAuthenticationError.invalidRequest }
        if let value = cache[partitionID], let snapshot = v2RealtimeShardDescriptorSnapshot(value.descriptor, expiresAt: value.expires, now: .now) {
            cacheHits &+= 1; return snapshot
        }
        cacheMisses &+= 1
        guard resolutionWaiters.count < 1_024 else { throw V2ActorAuthenticationError.overloaded }
        ensurePollStarted(foreground: true)
        let id = UUID(), deadline = ContinuousClock.now + resolutionTimeout
        let resolved = try await withTaskCancellationHandler { () async throws -> V2RealtimeShardDescriptor in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<V2RealtimeShardDescriptor, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) }
                    catch { return }
                    await self?.finishResolution(id, error: V2ActorAuthenticationError.sessionExpired)
                }
                resolutionWaiters[id] = .init(partitionID: partitionID, deadline: deadline, continuation: continuation, timer: timer)
            }
        } onCancel: {
            Task { await self.finishResolution(id, error: CancellationError()) }
        }
        try Task.checkCancellation()
        return resolved
    }
    private func finishResolution(_ id: UUID, error: any Error) {
        guard let waiter = resolutionWaiters.removeValue(forKey: id) else { return }
        waiter.timer.cancel(); waiter.continuation.resume(throwing: error)
    }
    private func completeReadyResolutions() {
        for (id, waiter) in resolutionWaiters {
            if waiter.deadline <= .now { finishResolution(id, error: V2ActorAuthenticationError.sessionExpired); continue }
            guard let cached = cache[waiter.partitionID],
                  let descriptor = v2RealtimeShardDescriptorSnapshot(cached.descriptor, expiresAt: cached.expires, now: .now) else { continue }
            resolutionWaiters.removeValue(forKey: id)
            waiter.timer.cancel(); waiter.continuation.resume(returning: descriptor)
        }
    }
    public func invalidate(_ descriptor: V2RealtimeShardDescriptor) {
        // Exact-token CAS: an old reply cannot evict a replacement incarnation.
        if cache[descriptor.token.partitionID]?.descriptor.token == descriptor.token {
            cache.removeValue(forKey: descriptor.token.partitionID)
            invalidations &+= 1
        }
    }
    private func retire(_ descriptor: V2RealtimeShardDescriptor) {
        if let previous = rejectedTokens[descriptor.token.partitionID], previous.epoch > descriptor.token.epoch { return }
        rejectedTokens[descriptor.token.partitionID] = descriptor.token
        invalidate(descriptor)
    }
    public func control(_ descriptor: V2RealtimeShardDescriptor, request: V2RealtimeShardControlRequest) async throws -> V2RealtimeShardControlReply {
        guard !stopped, descriptor.token == request.token else { throw V2ActorAuthenticationError.wrongRecipient }
        try descriptor.validate()
        guard let current = cache[descriptor.token.partitionID], current.descriptor.token == descriptor.token,
              current.expires > .now else { throw V2ActorAuthenticationError.sessionExpired }
        let result = try await sender.exchange(.control(request), to: descriptor.endpoint,
            admissionDeadline: current.expires)
        guard case .control(let reply) = result else { throw V2ActorAuthenticationError.wrongRecipient }
        if reply.status == .retiredEpoch || reply.status == .retiredIncarnation { retire(descriptor) }
        return reply
    }
    public func publish(_ descriptor: V2RealtimeShardDescriptor, request: V2RealtimeShardPublishRequest) async throws -> V2RealtimeShardPublishReply {
        guard !stopped, descriptor.token == request.token else { throw V2ActorAuthenticationError.wrongRecipient }
        try descriptor.validate()
        guard let current = cache[descriptor.token.partitionID], current.descriptor.token == descriptor.token,
              current.expires > .now else { throw V2ActorAuthenticationError.sessionExpired }
        let result = try await sender.exchange(.publish(request), to: descriptor.endpoint)
        guard case .publish(let reply) = result else { throw V2ActorAuthenticationError.wrongRecipient }
        if reply == .retiredEpoch || reply == .retiredIncarnation { retire(descriptor) }
        return reply
    }
    private func refresh() async {
        ensurePollStarted(foreground: false)
        if let poll { await poll.value }
        await publishQualification()
    }
    private func ensurePollStarted(foreground: Bool) {
        guard !stopped, poll == nil else { return }
        pollGeneration += 1
        let generation = pollGeneration
        let system = system, trust = trust, signer = signer, localIdentity = identity, rosterDigest = rosterDigest
        // Rotating the bounded pass prevents an unavailable prefix in a large
        // roster from excluding the same later peers on every budget expiry.
        let peers = Array(self.peers[peerCursor...] + self.peers[..<peerCursor])
        peerCursor = (peerCursor + min(8, peers.count)) % peers.count
        let passDeadline = ContinuousClock.now + .seconds(8)
        let task = Task<Void, Never> {
            await withTaskGroup(of: DiscoveryResult.self) { group in
                var next = 0
                func submit(_ peer: V2RealtimeShardDiscoveryPeer) {
                    group.addTask {
                        let peerDeadline = min(passDeadline, ContinuousClock.now + .seconds(2))
                        // Counts the actual invocation boundary, not misses or
                        // completed passes. Source belongs to the creating pass;
                        // cancelled/shared waiters never relabel its work.
                        self.recordReceptionistLookup(foreground: foreground)
                        let candidates = await system.receptionist.lookup(V2RealtimeShardDiscoveryBeacon.key(nodeID: peer.nodeID))
                        if candidates.isEmpty { system.cluster.join(host: peer.address, port: peer.port) }
                        guard candidates.count <= 4 else { return DiscoveryResult(generation: generation, values: [], reachable: [:], references: [:], identities: [:], descriptors: [:]) }
                        for beacon in candidates.sorted(by: { $0.id < $1.id }) {
                            guard !Task.isCancelled, ContinuousClock.now < peerDeadline else { break }
                            do {
                                let started = ContinuousClock.now, challenge = UUID()
                                let timeout = started.duration(to: peerDeadline)
                                let request = try signer.sign(ShardDiscoveryRequest(requester: localIdentity, recipientNodeID: peer.nodeID, challenge: challenge, rosterDigest: rosterDigest), maximumBytes: 16_384)
                                let packet = try await RemoteCall.with(timeout: timeout) { try await beacon.advertise(request) }
                                let (advertisement, trusted) = try trust.verify(packet, as: ShardAdvertisement.self, maximumBytes: 262_144)
                                let identity = advertisement.identity
                                try trust.validateRealtimeReceiver(identity)
                                guard trusted.serviceID.rawValue == peer.serviceID, identity.serviceID == peer.serviceID,
                                      identity.nodeID == peer.nodeID, advertisement.version == 1,
                                      advertisement.requester == localIdentity, advertisement.rosterDigest == rosterDigest,
                                      advertisement.challenge == challenge, advertisement.beaconID == beacon.id,
                                      advertisement.endpointID.node == beacon.id.node,
                                      beacon.id.node.endpoint.host == peer.address, beacon.id.node.endpoint.port == peer.port,
                                      advertisement.partitions.count <= 256,
                                      Set(advertisement.partitions.map { $0.token.partitionID }).count == advertisement.partitions.count else { throw V2ActorAuthenticationError.wrongRecipient }
                                // Preserve the exact opaque bytes bound by the host. Re-encoding
                                // the ActorID is unnecessary and would replace the signed byte identity.
                                let reference = advertisement.endpointReference
                                guard !reference.isEmpty, reference.count <= 16_384,
                                      try V2ActorProtobuf.decode(ClusterSystem.ActorID.self, from: reference) == advertisement.endpointID else {
                                    throw V2ActorAuthenticationError.wrongRecipient
                                }
                                let values = try advertisement.partitions.map { lease in
                                    let descriptor = V2RealtimeShardDescriptor(token: lease.token, endpointReference: reference,
                                        address: peer.address, port: peer.port, remainingLeaseMilliseconds: lease.remainingLeaseMilliseconds)
                                    try descriptor.validate()
                                    guard lease.token.host == identity else { throw V2ActorAuthenticationError.wrongRecipient }
                                    return Cached(descriptor: descriptor, expires: started + .milliseconds(lease.remainingLeaseMilliseconds))
                                }
                                return DiscoveryResult(generation: generation, values: values, reachable: [peer.nodeID: started + .seconds(20)], references: [peer.nodeID: advertisement.endpointID], identities: [peer.nodeID: identity], descriptors: [peer.nodeID: .init(identity: identity, endpointReference: reference, address: peer.address, port: peer.port)])
                            } catch { continue }
                        }
                        return DiscoveryResult(generation: generation, values: [], reachable: [:], references: [:], identities: [:], descriptors: [:])
                    }
                }
                while next < min(8, peers.count) { submit(peers[next]); next += 1 }
                for await result in group {
                    // Install each authenticated peer immediately. Slow unrelated
                    // peers remain actually owned by this task group.
                    await self.installDiscovered(result)
                    if !Task.isCancelled, ContinuousClock.now < passDeadline, next < peers.count {
                        submit(peers[next]); next += 1
                    }
                }
            }
            await self.pollFinished(generation)
        }
        poll = task
    }
    private func pollFinished(_ generation: UInt64) async {
        guard generation == pollGeneration else { return }
        await reapRetiredReferences()
        poll = nil; discoveryPasses &+= 1
        // An empty/unsuccessful discovery pass is not a recipient/authentication
        // failure. Receptionist replication may still be arriving. Keep each
        // waiter under its ORIGINAL deadline; the next shared pass can satisfy it.
        // Its existing timer remains responsible for bounded failure/cancellation.
    }
    private func referenceTerminated(_ id: ClusterSystem.ActorID) async {
        for (nodeID, current) in watchedReferences where current == id {
            if let identity = watchedIdentities[nodeID] { _ = enqueueRetirement(identity: identity, id: id, replaced: true) }
            softSuspendedReferences.remove(id)
            retiredReferences[nodeID] = id
            reachable.removeValue(forKey: nodeID)
            watchedReferences.removeValue(forKey: nodeID)
            watchedIdentities.removeValue(forKey: nodeID)
            watchedDescriptors.removeValue(forKey: nodeID)
        }
        await publishQualification()
        cache = cache.filter { (try? V2ActorProtobuf.decode(ClusterSystem.ActorID.self, from: $0.value.descriptor.endpointReference)) != id }
    }
    private func installDiscovered(_ result: DiscoveryResult) async {
        guard !stopped, result.generation >= appliedPollGeneration else { return }
        appliedPollGeneration = result.generation
        for (nodeID, id) in result.references {
            guard let discoveredIdentity = result.identities[nodeID],
                  let healthDeadline = result.reachable[nodeID], healthDeadline > .now,
                  let descriptor = result.descriptors[nodeID],
                  retiredReferences[nodeID] != id,
                  let endpoint = try? V2RealtimeShardEndpoint.resolve(id: id, using: system), let watcher else { continue }
            if let previousID = watchedReferences[nodeID], previousID != id, let previousIdentity = watchedIdentities[nodeID] {
                // The protocol binds one endpoint to one incarnation. Replacing
                // only its actor ID must not down a node hosting the new actor.
                guard previousIdentity != discoveredIdentity, previousID.node != id.node else { continue }
                guard enqueueRetirement(identity: previousIdentity, id: previousID, replaced: true) else { continue }
            }
            // A soft outage is reversible only after actual old calls and
            // handshake openings settle. Drop old sessions before reopening.
            if softSuspendedReferences.contains(id) || retiringReferences[id]?.replaced == false {
                guard await sender.beginRetirement(discoveredIdentity, reference: descriptor.endpointReference) else { continue }
                guard !stopped, result.generation == appliedPollGeneration, retiredReferences[nodeID] != id,
                      retiringReferences[id]?.replaced != true else { continue }
                retiringReferences.removeValue(forKey: id)
                softSuspendedReferences.remove(id)
                guard !stopped, retiredReferences[nodeID] != id else { continue }
            }
            guard !stopped, result.generation == appliedPollGeneration else { return }
            do { try await sender.installAuthenticatedReference(descriptor, observation: result.generation) } catch { continue }
            guard !stopped, retiredReferences[nodeID] != id, result.generation == appliedPollGeneration else { continue }
            let sameReference = watchedReferences[nodeID] == id
            // Install the signed identity and its health evidence atomically BEFORE
            // the watch await. The periodic reaper may run during that await; a
            // partially installed new reference must never appear expired.
            reachable[nodeID] = sameReference ? max(reachable[nodeID] ?? healthDeadline, healthDeadline) : healthDeadline
            serviceQualification.update(witnesses: reachable)
            watchedReferences[nodeID] = id
            watchedIdentities[nodeID] = discoveredIdentity
            watchedDescriptors[nodeID] = descriptor
            await qualificationObserver?()
            guard !stopped else { return }
            await watcher.whenLocal { local in local.observe(nodeID: nodeID, endpoint: endpoint) }
            guard !stopped, appliedPollGeneration == result.generation else { return }
        }
        let now = ContinuousClock.now
        // Keep the last authenticated deadline for watched roster entries. An
        // absent timestamp is not proof of expiry, and the map is roster-bounded.
        cache = cache.filter { $0.value.expires > now }
        for value in result.values where value.expires > now {
            guard !stopped else { return }
            if rejectedTokens[value.descriptor.token.partitionID] == value.descriptor.token { continue }
            guard let id = result.references[value.descriptor.token.host.nodeID],
                  retiredReferences[value.descriptor.token.host.nodeID] != id,
                  watchedReferences[value.descriptor.token.host.nodeID] == id else { continue }
            let key = value.descriptor.token.partitionID
            if let previous = cache[key] {
                guard value.descriptor.token.epoch >= previous.descriptor.token.epoch else { continue }
                if value.descriptor.token.epoch == previous.descriptor.token.epoch && value.descriptor.token != previous.descriptor.token { continue }
            }
            cache[key] = value
        }
        completeReadyResolutions()
    }
    private func enqueueRetirement(identity: V2GatewayRealtimeIdentity, id: ClusterSystem.ActorID, replaced: Bool = false) -> Bool {
        // Membership affects route availability only; it grants no PG ownership.
        guard id.node != endpoint.id.node else { return true }
        if let current = retiringReferences[id] {
            if replaced && !current.replaced { retiringReferences[id] = .init(identity: identity, id: id, replaced: true, reference: current.reference) }
            return true
        }
        guard retiringReferences.count < 256, let descriptor = watchedDescriptors[identity.nodeID], descriptor.identity == identity else { return false }
        retiringReferences[id] = .init(identity: identity, id: id, replaced: replaced, reference: descriptor.endpointReference)
        return true
    }
    private func reapRetiredReferences() async {
        let now = ContinuousClock.now
        for (nodeID, id) in watchedReferences {
            guard id.node != endpoint.id.node,
                  reachable[nodeID].map({ $0 <= now }) == true,
                  let previousIdentity = watchedIdentities[nodeID], !softSuspendedReferences.contains(id) else { continue }
            _ = enqueueRetirement(identity: previousIdentity, id: id)
        }
        for (id, retiring) in retiringReferences {
            // Even a renewed witness must not reuse the pre-outage session.
            guard await sender.beginRetirement(retiring.identity, reference: retiring.reference) else { continue }
            guard let current = retiringReferences[id] else { continue }
            if !current.replaced {
                cache = cache.filter { (try? V2ActorProtobuf.decode(ClusterSystem.ActorID.self, from: $0.value.descriptor.endpointReference))?.node != id.node }
                softSuspendedReferences.insert(id)
                retiringReferences.removeValue(forKey: id)
                // Keep exact watch/identity; a new authenticated challenge may
                // reopen it with a new handshake. No membership down/blacklist.
                continue
            }
            // The await may have installed a new incarnation. Retire only the
            // exact old physical node; never down this local ClusterSystem.
            guard id.node != endpoint.id.node else { retiringReferences.removeValue(forKey: id); continue }
            softSuspendedReferences.remove(id)
            retiredReferences[retiring.identity.nodeID] = id
            if watchedReferences[retiring.identity.nodeID] == id {
                watchedReferences.removeValue(forKey: retiring.identity.nodeID)
                watchedIdentities.removeValue(forKey: retiring.identity.nodeID)
                watchedDescriptors.removeValue(forKey: retiring.identity.nodeID)
                reachable.removeValue(forKey: retiring.identity.nodeID)
            }
            cache = cache.filter { (try? V2ActorProtobuf.decode(ClusterSystem.ActorID.self, from: $0.value.descriptor.endpointReference))?.node != id.node }
            system.log.warning("Realtime shard reference retirement: actual calls settled", metadata: [
                "realtime/retirement_reason": "authenticated_replacement_or_termination"
            ])
            system.cluster.down(member: .init(node: id.node, status: .up))
            if let peer = peers.first(where: { $0.nodeID == retiring.identity.nodeID }) {
                system.cluster.join(host: peer.address, port: peer.port)
            }
            retiringReferences.removeValue(forKey: id)
        }
    }
    private nonisolated func recordReceptionistLookup(foreground: Bool) {
        receptionistLookups.withLock {
            if foreground { $0.foreground &+= 1 } else { $0.background &+= 1 }
        }
    }
    public func metricsSnapshot() async -> V2RealtimeShardTransportMetricsSnapshot {
        let counters = await sender.metrics()
        let lookups = receptionistLookups.withLock { $0 }
        return .init(cacheHits: cacheHits, cacheMisses: cacheMisses, cacheInvalidations: invalidations,
            discoveryPasses: discoveryPasses, discoveryActive: poll == nil ? 0 : 1,
            cachedPartitions: cache.values.filter { $0.expires > .now }.count,
            reachableNodes: reachableNodeIDs().count,
            controlStarted: counters.0, controlSettled: counters.1, controlActive: counters.2,
            publishStarted: counters.3, publishSettled: counters.4, publishActive: counters.5,
            rpcRejected: counters.6, pendingHandshakes: counters.7, capacityRejections: counters.8, backgroundReceptionistLookups: lookups.background, foregroundReceptionistLookups: lookups.foreground,
            controlQueued: counters.9, controlQueueSeconds: counters.10, controlQueueSettled: counters.11)
    }
    public func stop(deadline: ContinuousClock.Instant) async -> Bool {
        stopped = true; serviceQualification.revoke(); worker?.cancel(); poll?.cancel()
        await qualificationObserver?()
        for id in Array(resolutionWaiters.keys) { finishResolution(id, error: V2ActorAuthenticationError.overloaded) }
        await publisher.stop()
        let inboundDone = await inbound.stop(deadline: deadline)
        let senderDone = await sender.stop(deadline: deadline)
        while (worker != nil || poll != nil) && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
        }
        guard inboundDone, senderDone, worker == nil, poll == nil else { return false }
        qualificationObserver = nil
        if let watcher { await watcher.whenLocal { $0.clear() } }
        watcher = nil; cache.removeAll(); retiringReferences.removeAll(); softSuspendedReferences.removeAll(); return true
    }
}

func buildRealtimeShardTransport(system: ClusterSystem, identity: V2GatewayRealtimeIdentity,
    address: String, port: Int, signer: V2ActorSigningIdentity, trust: V2ActorTrustStore,
    serving: any V2RealtimeShardServing, serviceOwnerAccess: [V2ActorServiceID: Set<String>],
    discoveryPeers: [V2RealtimeShardDiscoveryPeer], limits: V2RealtimeTransportLimits,
    serviceQualification: V2ActorServiceQualification? = nil) throws -> V2RealtimeShardTransportHandle {
    guard identity.serviceID == signer.serviceID.rawValue, !serviceOwnerAccess.isEmpty,
          discoveryPeers.count <= 64, Set(discoveryPeers.map(\.nodeID)).count == discoveryPeers.count,
          discoveryPeers.allSatisfy({ !$0.nodeID.isEmpty && !$0.serviceID.isEmpty && !$0.address.isEmpty && (1...65_535).contains($0.port) }) else { throw V2ActorAuthenticationError.invalidConfiguration }
    try trust.validateRealtimeReceiver(identity)
    try trust.validateRealtimeRoster(discoveryPeers, local: identity, address: address, port: port)
    let inbound = V2RealtimeShardInbound(identity: identity, signer: signer, trust: trust, serving: serving,
        serviceOwnerAccess: serviceOwnerAccess, limits: limits, diagnostic: { stage in
            system.log.warning("Realtime shard authentication rejected", metadata: ["realtime/authentication_stage": "\(stage)"])
        })
    let endpoint = V2RealtimeShardEndpoint(actorSystem: system, service: inbound)
    let endpointReference = try V2ActorProtobuf.encode(endpoint.id)
    inbound.bindEndpointReference(endpointReference)
    let roster = Dictionary(uniqueKeysWithValues: discoveryPeers.map { ($0.nodeID, $0.serviceID) })
    let rosterData = try V2ActorProtobuf.encode(roster.sorted { $0.key < $1.key }.map { [$0.key, $0.value] })
    let digest = Data(SHA256.hash(data: rosterData))
    guard serviceQualification?.matches(localNodeID: identity.nodeID, roster: Set(roster.keys)) != false else { throw V2ActorAuthenticationError.invalidConfiguration }
    let qualification = try serviceQualification ?? V2ActorServiceQualification(localNodeID: identity.nodeID, roster: Set(roster.keys))
    let publisher = V2RealtimeShardPublisher(identity: identity, signer: signer, endpointID: endpoint.id, endpointReference: endpointReference, trust: trust, roster: roster, rosterDigest: digest)
    let beacon = V2RealtimeShardDiscoveryBeacon(actorSystem: system, publisher: publisher)
    return V2RealtimeShardTransportHandle(system: system, identity: identity, trust: trust, signer: signer, rosterDigest: digest, qualification: qualification, peers: discoveryPeers,
        sender: try V2RealtimeShardSender(system: system, signer: signer, trust: trust, limits: limits, incarnation: identity.incarnationID,
            initialReference: .init(identity: identity, endpointReference: endpointReference, address: address, port: port)),
        endpoint: endpoint, inbound: inbound, publisher: publisher, beacon: beacon, resolutionTimeout: limits.callTimeout)
}
