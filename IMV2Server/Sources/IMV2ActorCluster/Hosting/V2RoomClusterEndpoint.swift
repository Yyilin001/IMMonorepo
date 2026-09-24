import Distributed
import DistributedCluster
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core

/// The only distributed entry point before a room has an activation. Its
/// ActorID is distributed out of band by authenticated configuration.
public distributed actor V2RoomHostEndpoint {
    public typealias ActorSystem = ClusterSystem
    private let service: V2RoomClusterInboundService

    public init(actorSystem: ClusterSystem, service: V2RoomClusterInboundService) {
        self.actorSystem = actorSystem
        self.service = service
    }

    public distributed func openSession(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try await service.openSession(packet)
    }

    public distributed func exchange(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try await service.exchange(packet, boundToken: nil)
    }
}

/// One physical distributed actor exists per locally ready activation. Its
/// identity has no authority after the exact token retires, even if a remote
/// process still retains this ActorID.
public distributed actor V2RoomClusterActor {
    public typealias ActorSystem = ClusterSystem
    private let token: V2RoomActivationToken
    private let service: V2RoomClusterInboundService

    public init(actorSystem: ClusterSystem, token: V2RoomActivationToken,
                service: V2RoomClusterInboundService) {
        self.actorSystem = actorSystem
        self.token = token
        self.service = service
    }

    public distributed func exchange(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try await service.exchange(packet, boundToken: token)
    }
}

/// Remote packets and node-minted local capabilities share permission, replay,
/// shard, recipient, session, deadline and exact-activation checks. Cluster
/// membership is never an authorization fact.
public actor V2RoomClusterInboundService {
    private let identity: V2ActorHostIdentity
    private let host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>
    private let authenticator: V2ActorSessionAuthenticator
    private let signer: V2ActorSigningIdentity
    private let limits: V2ActorAuthenticationLimits
    private let allowedShards: Set<String>
    private let serviceShardAccess: [V2ActorServiceID: Set<String>]
    private let maximumInboundRequests: Int
    private let localGeneration: UUID
    private let actorSystem: ClusterSystem
    private var roomActors: [V2RoomActivationToken: V2RoomClusterActor] = [:]
    private var watcher: Task<Void, Never>?
    private var accepting = true
    private var activeRequests = 0

    public init(identity: V2ActorHostIdentity,
                host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>,
                authenticator: V2ActorSessionAuthenticator,
                signer: V2ActorSigningIdentity,
                limits: V2ActorAuthenticationLimits,
                allowedShards: Set<String>,
                serviceShardAccess: [V2ActorServiceID: Set<String>],
                maximumInboundRequests: Int,
                localGeneration: UUID = UUID(),
                actorSystem: ClusterSystem) throws {
        guard !allowedShards.isEmpty, !serviceShardAccess.isEmpty,
              maximumInboundRequests > 0,
              serviceShardAccess.values.allSatisfy({ !$0.isEmpty && $0.isSubset(of: allowedShards) })
        else { throw V2ActorAuthenticationError.invalidConfiguration }
        self.identity = identity
        self.host = host
        self.authenticator = authenticator
        self.signer = signer
        self.limits = limits
        self.allowedShards = allowedShards
        self.serviceShardAccess = serviceShardAccess
        self.maximumInboundRequests = maximumInboundRequests
        self.localGeneration = localGeneration
        self.actorSystem = actorSystem
    }

    public func startWatching() async {
        guard watcher == nil else { return }
        let changes = await host.changes()
        watcher = Task { [weak self] in
            for await _ in changes { await self?.reconcileActors() }
        }
    }

    public func stop() {
        accepting = false
        watcher?.cancel()
        watcher = nil
        roomActors.removeAll()
    }

    public func quiesce(deadline: ContinuousClock.Instant) async -> Bool {
        accepting = false
        while activeRequests > 0 && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { break }
        }
        return activeRequests == 0
    }

    public func openSession(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try beginRequest()
        defer { activeRequests -= 1 }
        let grant = try await authenticator.openSession(packet)
        guard accepting else { throw V2ActorAuthenticationError.overloaded }
        return try signer.sign(grant, maximumBytes: limits.maximumReplyBytes)
    }

    func openLocalSession(_ packet: V2ActorSignedPacket, generation: UUID) async throws
        -> (V2ActorSignedPacket, V2ActorLocalCapability) {
        try beginRequest()
        defer { activeRequests -= 1 }
        guard generation == localGeneration else { throw V2ActorAuthenticationError.wrongRecipient }
        let (grant, capability) = try await authenticator.openLocalSession(packet, generation: generation)
        guard accepting else { throw V2ActorAuthenticationError.overloaded }
        return (try signer.sign(grant, maximumBytes: limits.maximumReplyBytes), capability)
    }

    public func exchange(_ packet: V2ActorSignedPacket,
                         boundToken: V2RoomActivationToken?) async throws -> V2ActorSignedPacket {
        try beginRequest()
        defer { activeRequests -= 1 }
        let verified = try await authenticator.accept(packet)
        let reply = try await exchangeVerified(verified, boundToken: boundToken)
        return try signer.sign(reply, maximumBytes: limits.maximumReplyBytes)
    }

    func exchangeLocal(_ payload: V2ActorLocalPayload<V2ActorAuthenticatedCall>,
                       capability: V2ActorLocalCapability, generation: UUID,
                       boundToken: V2RoomActivationToken?) async throws
        -> V2ActorLocalPayload<V2ActorAuthenticatedReply> {
        try beginRequest()
        defer { activeRequests -= 1 }
        guard generation == localGeneration else { throw V2ActorAuthenticationError.wrongRecipient }
        let verified = try await authenticator.acceptLocal(payload, capability: capability,
                                                           generation: generation)
        let reply = try await exchangeVerified(verified, boundToken: boundToken)
        let encoded = try V2ActorLocalPayload(reply)
        guard encoded.byteCount <= limits.maximumReplyBytes else { throw V2ActorAuthenticationError.oversized }
        return encoded
    }

    private func exchangeVerified(_ verified: V2ActorVerifiedCall,
                                  boundToken: V2RoomActivationToken?) async throws -> V2ActorAuthenticatedReply {
        guard accepting else { throw V2ActorAuthenticationError.overloaded }
        let request = verified.call.request
        let token = requestToken(request)
        if let boundToken {
            guard token == boundToken, !isHostOnly(request) else {
                throw V2ActorAuthenticationError.wrongRecipient
            }
        } else {
            guard isHostOnly(request) else { throw V2ActorAuthenticationError.wrongRecipient }
        }
        let shard = requestShard(request)
        guard allowedShards.contains(shard),
              serviceShardAccess[verified.call.serviceID]?.contains(shard) == true else {
            throw V2ActorAuthenticationError.forbidden
        }
        let response: V2ActorRPCResponse
        do { response = try await dispatch(request, deadline: verified.deadline) }
        catch let failure as V2RoomCallFailure { response = .failure(failure) }
        catch let leaseError as V2RoomActivationLeaseError where leaseError == .roomNotFound {
            response = .failure(.notAccepted(.notFound))
        } catch {
            // An invocation might already have entered SQL. Never invent a
            // rollback or a definitely-not-accepted result from this catch.
            if case .lookup = request { response = .failure(.notAccepted(.unavailable)) }
            else { response = .failure(.outcomeUnknown) }
        }
        return V2ActorAuthenticatedReply(call: verified.call, response: response)
    }

    public func reconcileActors() async {
        let ready = Set(await host.readyTokens())
        guard accepting else { return }
        let retired = roomActors.keys.filter { !ready.contains($0) }
        for token in retired {
            roomActors.removeValue(forKey: token)
        }
        for token in ready where roomActors[token] == nil {
            roomActors[token] = V2RoomClusterActor(actorSystem: actorSystem, token: token, service: self)
        }
    }

    public func actorCount() -> Int { roomActors.count }

    public func inFlightRequestCount() -> Int { activeRequests }

    private func beginRequest() throws {
        guard accepting, activeRequests < maximumInboundRequests else {
            throw V2ActorAuthenticationError.overloaded
        }
        activeRequests += 1
    }

    private func physicalReference(for token: V2RoomActivationToken) async throws -> Data {
        guard accepting, token.host == identity, (await host.readyTokens()).contains(token) else {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        if roomActors[token] == nil {
            roomActors[token] = V2RoomClusterActor(actorSystem: actorSystem, token: token, service: self)
        }
        guard let actor = roomActors[token], accepting,
              (await host.readyTokens()).contains(token) else {
            roomActors.removeValue(forKey: token)
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        return try JSONEncoder().encode(actor.id)
    }

    private func dispatch(_ request: V2ActorRPCRequest,
                          deadline: ContinuousClock.Instant) async throws -> V2ActorRPCResponse {
        switch request {
        case .activate(let roomID, let owner):
            let resolution = try await host.activate(roomID: roomID, owner: owner, deadline: deadline)
            switch resolution {
            case .ready(let token):
                guard token.roomID == roomID, token.owner == owner, token.host == identity else {
                    throw V2RoomCallFailure.notAccepted(.staleActivation)
                }
                return .ready(token: token, physicalReference: try await physicalReference(for: token))
            case .occupied(let lease):
                guard lease.token.roomID == roomID, lease.token.owner == owner else {
                    throw V2RoomCallFailure.notAccepted(.staleActivation)
                }
                return .occupied(lease)
            }
        case .lookup(let token):
            return .ready(token: token, physicalReference: try await physicalReference(for: token))
        case .invoke(let token, let request):
            let bytes: Data
            do { bytes = try JSONEncoder().encode(request) }
            catch { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
            return .result(try await host.invoke(token: token, encodedRequest: bytes, deadline: deadline))
        case .reserve(let token, let requestID):
            return .reserved(try await host.reserve(token: token, requestID: requestID, deadline: deadline))
        case .markDispatched(let grant):
            try await host.markReservationDispatched(grant)
            return .acknowledged
        case .abortReservation(let grant):
            return .completed(await host.abortReservation(grant))
        case .finishReservation(let grant, let completion):
            return .completed(await host.finishReservation(grant, completion: completion))
        }
    }

    private func requestToken(_ request: V2ActorRPCRequest) -> V2RoomActivationToken? {
        switch request {
        case .activate: nil
        case .lookup(let token), .invoke(let token, _), .reserve(let token, _): token
        case .markDispatched(let grant), .abortReservation(let grant), .finishReservation(let grant, _): grant.token
        }
    }

    private func requestShard(_ request: V2ActorRPCRequest) -> String {
        switch request {
        case .activate(_, let owner): owner.shardID
        case .lookup(let token), .invoke(let token, _), .reserve(let token, _): token.owner.shardID
        case .markDispatched(let grant), .abortReservation(let grant), .finishReservation(let grant, _):
            grant.token.owner.shardID
        }
    }

    private func isHostOnly(_ request: V2ActorRPCRequest) -> Bool {
        switch request {
        case .activate, .lookup: true
        default: false
        }
    }
}
