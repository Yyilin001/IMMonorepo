import Crypto
import DistributedCluster
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2ActorCluster
@testable import IMV2Server
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("caller-only TCP forward delegates reservations and policy writes to the host", arguments: [false, true])
    func policyRemoteForwardPair(splitHosts: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let profile = try forwardImportTestProfile(), limits = try V2MessageCommandLimits(maxUTF8Bytes: 128)
            let now = Date(), sourceRoom = RoomID(uuid: roomUUID)
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes'").run()
            let opened = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { now }).openedIdentity(actorUserID: senderID,
                    operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                    firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let source = try await V2SendMessageService(store: PostgresV2RoomWriteStore(database: database),
                capacityProfile: profile, limits: limits, now: { now }).send(.init(roomID: sourceRoom,
                    actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "remote pair source"))
            let receipt = try #require(source.acceptanceReceipt)
            let identity = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
            let sourceIdentity = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
            let keys = [Curve25519.Signing.PrivateKey(), Curve25519.Signing.PrivateKey(), Curve25519.Signing.PrivateKey()]
            let hostSigner = try V2ActorSigningIdentity(serviceID: .init("pair-host"), privateKey: keys[0].rawRepresentation)
            let callerSigner = try V2ActorSigningIdentity(serviceID: .init("pair-caller"), privateKey: keys[1].rawRepresentation)
            let sourceSigner = try V2ActorSigningIdentity(serviceID: .init("pair-source"), privateKey: keys[2].rawRepresentation)
            let trust = try V2ActorTrustStore(services: [
                .init(serviceID: hostSigner.serviceID, publicKey: keys[0].publicKey.rawRepresentation,
                    permissions: [.roomCoordination], hostedIDs: [identity.hostID]),
                .init(serviceID: callerSigner.serviceID, publicKey: keys[1].publicKey.rawRepresentation,
                    permissions: [.roomCoordination, .policyMutation]),
                .init(serviceID: sourceSigner.serviceID, publicKey: keys[2].publicKey.rawRepresentation,
                    permissions: [.roomCoordination], hostedIDs: [sourceIdentity.hostID])
            ])
            let runtime = try V2RoomRuntimeConfiguration(), authentication = try V2ActorAuthenticationLimits()
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let leases = try V2RoomServerLeaseStore(databases: ["room-a": database])
            let legacy = V2DirectAuthorizationCoordinator(controlDatabase: database, ownerDatabases: [:])
            let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: database),
                dispatcher: .init(database: database, projectionDelivery: SuccessfulProjectionDelivery(), legacyAuthorization: legacy))
            let policies = V2RoomPolicyAuthorizationService(roomDatabase: database,
                policyOwners: owners, endpoint: "room-a", maximumRooms: 2)
            let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(identity: identity, leaseStore: leases,
                configuration: runtime, budget: .init(configuration: runtime), classify: { $0.turnSchedulingClass },
                factory: .init { token in .init(restore: { _ in }, execute: { _ in .rolledBack(.invalidRequest) },
                    invalidateReservation: { _ in }, close: {
                        do { await policies.retire(token: token) }
                        catch { Issue.record("Policy registration retirement failed") }
                    }) })
            let sourceHost = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(identity: sourceIdentity, leaseStore: leases,
                configuration: runtime, budget: .init(configuration: runtime), classify: { $0.turnSchedulingClass },
                factory: .init { token in .init(restore: { _ in }, execute: { _ in .rolledBack(.invalidRequest) },
                    invalidateReservation: { _ in }, close: {
                        do { await policies.retire(token: token) }
                        catch { Issue.record("Policy registration retirement failed") }
                    }) })
            let executor = V2ActorForwardPairDomainExecutor(database: database,
                write: PostgresV2RoomWriteStore(database: database), capacityProfile: profile, limits: limits)
                .usingPolicyAuthorizations(policies)
            let pairs = V2RoomForwardPairService(executors: ["room-a": executor])
            let replies = RemotePairReplyGate(service: pairs)
            let ports = [Int.random(in: 30_000...39_999), Int.random(in: 40_000...49_999), Int.random(in: 50_000...60_000)]
            let system = await ClusterSystem("pair-host", settings: remotePairSettings("pair-host", port: ports[0]))
            let callerSystem = await ClusterSystem("pair-caller", settings: remotePairSettings("pair-caller", port: ports[1]))
            let sourceSystem = await ClusterSystem("pair-source", settings: remotePairSettings("pair-source", port: ports[2]))
            let inbound = try V2RoomClusterInboundService(identity: identity, host: host,
                authenticator: .init(host: identity, trust: trust, limits: authentication), signer: hostSigner, limits: authentication,
                allowedShards: ["room-a"], serviceShardAccess: [callerSigner.serviceID: ["room-a"], hostSigner.serviceID: ["room-a"]],
                maximumInboundRequests: 8, actorSystem: system,
                policyMutations: V2PolicyMutationService(owners: owners, endpoint: "room-a"), forwardPairs: replies)
            let endpoint = V2RoomHostEndpoint(actorSystem: system, service: inbound)
            let sourceInbound = try V2RoomClusterInboundService(identity: sourceIdentity, host: sourceHost,
                authenticator: .init(host: sourceIdentity, trust: trust, limits: authentication), signer: sourceSigner,
                limits: authentication, allowedShards: ["room-a"],
                serviceShardAccess: [callerSigner.serviceID: ["room-a"], hostSigner.serviceID: ["room-a"]],
                maximumInboundRequests: 8, actorSystem: sourceSystem)
            let sourceEndpoint = V2RoomHostEndpoint(actorSystem: sourceSystem, service: sourceInbound)
            let client = V2RoomClusterClient(system: callerSystem, signer: callerSigner, trust: trust,
                limits: authentication, configuration: runtime)
            let hostClient = V2RoomClusterClient(system: system, signer: hostSigner, trust: trust,
                limits: authentication, configuration: runtime)
            let routes = try await V2DeploymentRoomShardRouter.load(database: database)
            let directory = V2RoomDirectory(owners: V2RoomServerOwnerResolver(router: routes), leases: leases,
                hosts: hostClient, transport: hostClient, configuration: runtime)
            let coordinator = V2RoomReservationCoordinator(operations: await directory.reservationOperations(), configuration: runtime)
            var phase = "activation"
            do {
                await host.start()
                await sourceHost.start()
                let targetDescriptor = try V2RoomClusterHostDescriptor(identity: identity, endpointID: endpoint.id, address: "127.0.0.1",
                    port: ports[0], accessibleShardIDs: ["room-a"], availableRooms: 2, isHealthy: true)
                let sourceDescriptor = try V2RoomClusterHostDescriptor(identity: sourceIdentity, endpointID: sourceEndpoint.id, address: "127.0.0.1",
                    port: ports[2], accessibleShardIDs: ["room-a"], availableRooms: 0, isHealthy: true)
                for descriptor in [targetDescriptor, sourceDescriptor] {
                    try await client.register(descriptor); try await hostClient.register(descriptor)
                }
                guard case .ready(let initialToken) = try await client.activate(on: identity, roomID: opened.roomID, owner: owner,
                    deadline: .now + .seconds(10)) else { throw V2RoomCallFailure.notAccepted(.unavailable) }
                var token = initialToken
                let sourceLocation = splitHosts ? sourceIdentity : identity
                guard case .ready(let sourceToken) = try await client.activate(on: sourceLocation, roomID: sourceRoom,
                    owner: owner, deadline: .now + .seconds(10)) else { throw V2RoomCallFailure.notAccepted(.unavailable) }
                #expect(sourceToken.host == sourceLocation)
                let pair = V2ActorForwardPairWire(actorUserID: senderID, operationID: .init(uuid: UUID()),
                    source: try .init(roomID: sourceRoom, messageID: receipt.messageID, revision: .init(1)), targetRoomID: opened.roomID)
                await #expect(throws: V2RoomCallFailure.notAccepted(.unavailable)) {
                    try await client.forwardPair(pair, token: token, deadline: .now + .seconds(5))
                }
                try await pairs.bind(coordinator)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.identityConflict) { try await pairs.bind(coordinator) }
                phase = "first acceptance"
                let first = try await client.forwardPair(pair, token: token, deadline: .now + .seconds(10))
                #expect(first.messageID != nil && first.errorCode == nil)
                #expect(try await directory.resolve(sourceRoom, deadline: .now + .seconds(5)) == sourceToken)
                #expect(try await directory.resolve(opened.roomID, deadline: .now + .seconds(5)) == token)
                #expect(try await client.forwardPair(pair, token: token, deadline: .now + .seconds(10)) == first)
                #expect(await coordinator.activePairCount() == 0)
                phase = "warm forwarding without global policy tables"
                let hidden = ["public_user_profiles", "special_accounts", "account_disables", "user_blocks",
                    "user_relationships", "user_stranger_message_preferences"]
                for table in hidden {
                    try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_pair_hidden")").run()
                }
                let warm = V2ActorForwardPairWire(actorUserID: senderID, operationID: .init(uuid: UUID()),
                    source: pair.source, targetRoomID: opened.roomID)
                let warmResult = try await client.forwardPair(warm, token: token, deadline: .now + .seconds(10))
                #expect(warmResult.messageID != nil && warmResult.errorCode == nil && warmResult.messageID != first.messageID)
                for table in hidden {
                    try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_pair_hidden") RENAME TO \(unsafeRaw: table)").run()
                }
                phase = "accepted SQL with delayed RPC reply"
                let delayed = V2ActorForwardPairWire(actorUserID: senderID, operationID: .init(uuid: UUID()),
                    source: pair.source, targetRoomID: opened.roomID)
                let delayedResult = try await remotePairLostReply(pair: delayed, token: token,
                    client: client, inbound: inbound, coordinator: coordinator, replies: replies)
                #expect(delayedResult.messageID != nil && delayedResult.errorCode == nil)
                phase = "stranger quota is a definite business rejection"
                let limited = V2ActorForwardPairWire(actorUserID: senderID, operationID: .init(uuid: UUID()),
                    source: pair.source, targetRoomID: opened.roomID)
                let limitedResult = try await client.forwardPair(limited, token: token, deadline: .now + .seconds(10))
                #expect(limitedResult.messageID == nil && limitedResult.errorCode == "RATE_LIMITED")
                let localSocial = PostgresV2SocialRelationshipStore(database: database, projectionDelivery: SuccessfulProjectionDelivery())
                let mutations = PostgresV2RemotePolicyMutations(client: client, resolve: { _ in
                    .init(host: identity, endpoint: "room-a")
                })
                phase = "remote friendship enables further sends"
                let requested = try await localSocial.freezeSocialFixture(actorUserID: senderID,
                    targetUserID: .init(uuid: memberTwoUUID), operation: .relationship(.init(uuid: UUID())),
                    action: .relationship(.request), now: Date())
                _ = try await mutations.change(.social(requested))
                let accepted = try await localSocial.freezeSocialFixture(actorUserID: .init(uuid: memberTwoUUID),
                    targetUserID: senderID, operation: .relationship(.init(uuid: UUID())),
                    action: .relationship(.accept), now: Date())
                _ = try await mutations.change(.social(accepted))
                let friendWarm = V2ActorForwardPairWire(actorUserID: senderID, operationID: .init(uuid: UUID()),
                    source: pair.source, targetRoomID: opened.roomID)
                let friendResult = try await client.forwardPair(friendWarm, token: token, deadline: .now + .seconds(10))
                #expect(friendResult.messageID != nil && friendResult.errorCode == nil)
                phase = "caller cancellation while actual SQL waits"
                let cancelled = V2ActorForwardPairWire(actorUserID: senderID, operationID: .init(uuid: UUID()),
                    source: pair.source, targetRoomID: opened.roomID)
                let cancellationRecovery = try await remotePairCancelledSQL(pair: cancelled, token: token,
                    database: database, sql: sql, client: client, inbound: inbound, coordinator: coordinator, directory: directory)
                let cancelledResult = cancellationRecovery.result
                token = cancellationRecovery.token
                #expect(cancelledResult.messageID != nil && cancelledResult.errorCode == nil)
                let block = try await localSocial.freezeSocialFixture(actorUserID: senderID, targetUserID: .init(uuid: memberTwoUUID),
                    operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now: Date())
                phase = "remote block"
                _ = try await mutations.change(.social(block))
                let next = V2ActorForwardPairWire(actorUserID: senderID, operationID: .init(uuid: UUID()), source: pair.source,
                    targetRoomID: opened.roomID)
                phase = "fresh rejection after block"
                let rejected = try await client.forwardPair(next, token: token, deadline: .now + .seconds(10))
                #expect(rejected.messageID == nil && rejected.errorCode == "DIRECT_MESSAGE_RESTRICTED")
                phase = "replay after source withdrawal"
                try await sql.raw("UPDATE im_v2.messages SET withdrawn_at=clock_timestamp(), withdrawn_by_user_id=\(bind: senderUUID) WHERE message_id=\(bind: receipt.messageID.uuidValue!)").run()
                #expect(try await client.forwardPair(pair, token: token, deadline: .now + .seconds(10)) == first)
                #expect(try await client.forwardPair(delayed, token: token, deadline: .now + .seconds(10)) == delayedResult)
                #expect(try await client.forwardPair(cancelled, token: token, deadline: .now + .seconds(10)) == cancelledResult)
                let stale = V2RoomActivationToken(roomID: token.roomID, owner: token.owner,
                    activationEpoch: try .init(token.activationEpoch.rawValue + 1), host: token.host)
                await #expect(throws: V2RoomCallFailure.notAccepted(.staleActivation)) {
                    try await client.forwardPair(pair, token: stale, deadline: .now + .seconds(5))
                }
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.messages WHERE room_id=\(bind: opened.roomID.uuidValue!)")
                    .first(decoding: RemotePairCount.self)?.value == 5)
                await pairs.close()
                await #expect(throws: V2PolicyAuthorizationLifecycleError.closed) { try await pairs.bind(coordinator) }
                await #expect(throws: V2RoomCallFailure.notAccepted(.retired)) {
                    try await client.forwardPair(next, token: token, deadline: .now + .seconds(5))
                }
                #expect(await coordinator.activePairCount() == 0)
                await inbound.stop(); _ = await host.stop(deadline: .now + .seconds(10))
                await sourceInbound.stop(); _ = await sourceHost.stop(deadline: .now + .seconds(10))
                #expect(await directory.quiesce(deadline: .now + .seconds(10)))
                #expect(await hostClient.quiesce(deadline: .now + .seconds(10)))
                await policies.shutdown(); await owners.shutdown(); await leases.shutdownLifecycle()
                await routes.shutdown()
                try await callerSystem.shutdown().wait(); try await sourceSystem.shutdown().wait(); try await system.shutdown().wait()
            } catch {
                Issue.record("Remote forward pair failed during \(phase)")
                await replies.release()
                await pairs.close(); await inbound.stop(); _ = await host.stop(deadline: .now + .seconds(10))
                await sourceInbound.stop(); _ = await sourceHost.stop(deadline: .now + .seconds(10))
                _ = await directory.quiesce(deadline: .now + .seconds(10))
                _ = await hostClient.quiesce(deadline: .now + .seconds(10))
                await policies.shutdown(); await owners.shutdown(); await leases.shutdownLifecycle()
                await routes.shutdown()
                try? await callerSystem.shutdown().wait(); try? await sourceSystem.shutdown().wait(); try? await system.shutdown().wait(); throw error
            }
        }
    }
}

private func remotePairLostReply(pair: V2ActorForwardPairWire, token: V2RoomActivationToken,
    client: V2RoomClusterClient, inbound: V2RoomClusterInboundService,
    coordinator: V2RoomReservationCoordinator, replies: RemotePairReplyGate) async throws -> V2ActorForwardMessageResultWire {
    await replies.hold(pair.operationID)
    let sending = Task { try await client.forwardPair(pair, token: token, deadline: .now + .seconds(1)) }
    do {
        try await remotePairObserve { await replies.isHeld }
        #expect(await coordinator.activePairCount() == 0)
        #expect(await inbound.inFlightRequestCount() > 0)
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) { try await sending.value }
        // The Cluster remote-call future may itself time out. Only the host's
        // actual root proves unfinished server work; client counts cannot.
        #expect(await inbound.inFlightRequestCount() > 0)
        #expect(await replies.isHeld)
        let replay = try await client.forwardPair(pair, token: token, deadline: .now + .seconds(10))
        #expect(replay == (await replies.result))
        await replies.release()
        try await remotePairObserve { await client.dispatchedCallCount() == 0 }
        try await remotePairObserve { await inbound.inFlightRequestCount() == 0 }
        return replay
    } catch {
        await replies.release(); _ = await sending.result
        try? await remotePairObserve { await client.dispatchedCallCount() == 0 }
        throw error
    }
}

private func remotePairCancelledSQL(pair: V2ActorForwardPairWire, token: V2RoomActivationToken,
    database: any Database, sql: any SQLDatabase, client: V2RoomClusterClient,
    inbound: V2RoomClusterInboundService, coordinator: V2RoomReservationCoordinator, directory: V2RoomDirectory) async throws
    -> (result: V2ActorForwardMessageResultWire, token: V2RoomActivationToken) {
    let held = RemotePairSQLHold()
    let holding = Task {
        try await database.transaction { transaction in
            let connection = try #require(transaction as? any SQLDatabase)
            // Every mode checks the durable room owner in its transaction.
            // Current-state authorization intentionally creates no policy
            // lease, so use the real common room row as the SQL barrier.
            let rows = try await connection.raw("SELECT room_id FROM im_v2.rooms WHERE room_id=\(bind: token.roomID.uuidValue!) FOR UPDATE").all()
            try #require(!rows.isEmpty)
            let pid = try #require(try await connection.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: RemotePairCount.self)).value
            await held.wait(pid: pid)
        }
    }
    var sending: Task<V2ActorForwardMessageResultWire, any Error>?
    var phase = "database holder"
    do {
        try await remotePairObserve { await held.pid != nil }
        let pid = try #require(await held.pid)
        let task = Task { try await client.forwardPair(pair, token: token, deadline: .now + .seconds(10)) }
        sending = task
        phase = "observe physical SQL blocking"
        try await remotePairObserve {
            try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer=ANY(pg_blocking_pids(pid))")
                .first(decoding: RemotePairCount.self)?.value ?? 0 > 0
        }
        #expect(await coordinator.activePairCount() == 1)
        task.cancel()
        phase = "cancelled caller response"
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) { try await task.value }
        #expect(await coordinator.activePairCount() == 1)
        #expect(await inbound.inFlightRequestCount() > 0)
        #expect(await client.dispatchedCallCount() > 0)
        // Releasing the actual database holder allows the original remote SQL
        // to complete; cancellation must not release either room reservation.
        await held.release(); try await holding.value
        phase = "original RPC settlement"
        try await remotePairObserve { await client.dispatchedCallCount() == 0 }
        try await remotePairObserve { await coordinator.activePairCount() == 0 }
        let saved = try await sql.raw("SELECT result_message_id AS value FROM im_v2.message_forward_operations WHERE actor_user_id=\(bind: pair.actorUserID.uuidValue!) AND operation_id=\(bind: pair.operationID.uuidValue!) AND source_message_id=\(bind: pair.source.messageID.uuidValue!) AND target_room_id=\(bind: pair.targetRoomID.uuidValue!)")
            .first(decoding: RemotePairReceiptRow.self)?.value
        // Unknown completion can safely retire both original activations. A
        // recovery resolves current authority; an old token cannot be revived.
        phase = "resolve current activation for durable recovery"
        phase = "immutable receipt replay"
        let replay = try await directory.callForwardPair(pair, deadline: .now + .seconds(10)) { token, pair, deadline in
            try await client.forwardPair(pair, token: token, deadline: deadline)
        }
        let current = try await directory.resolve(pair.targetRoomID, deadline: .now + .seconds(5))
        if let saved { #expect(replay.messageID?.uuidValue == saved) }
        return (replay, current)
    } catch {
        Issue.record("Cancelled forward SQL failed during \(phase)")
        await held.release(); _ = await holding.result
        if let sending { _ = await sending.result }
        try? await remotePairObserve { await client.dispatchedCallCount() == 0 }
        throw error
    }
}

private actor RemotePairSQLHold {
    private(set) var pid: Int64?
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait(pid: Int64) async {
        self.pid = pid
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private func remotePairObserve(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw RemotePairObservationFailure.timeout }
        await Task.yield()
    }
}

private enum RemotePairObservationFailure: Error { case timeout }

private actor RemotePairReplyGate: V2RoomForwardPairServing {
    private let service: V2RoomForwardPairService
    private var operation: MessageForwardOperationID?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var isHeld = false
    private(set) var result: V2ActorForwardMessageResultWire?

    init(service: V2RoomForwardPairService) { self.service = service }
    func hold(_ operation: MessageForwardOperationID) {
        precondition(self.operation == nil && continuation == nil)
        self.operation = operation; released = false; isHeld = false; result = nil
    }
    func release() {
        released = true; continuation?.resume(); continuation = nil
    }
    func forwardPair(_ pair: V2ActorForwardPairWire, token: V2RoomActivationToken,
        deadline: ContinuousClock.Instant) async throws -> V2ActorForwardMessageResultWire {
        let shouldHold = operation == pair.operationID
        let value = try await service.forwardPair(pair, token: token, deadline: deadline)
        if shouldHold {
            operation = nil; result = value; isHeld = true
            if !released { await withCheckedContinuation { continuation = $0 } }
        }
        return value
    }
}

private func remotePairSettings(_ name: String, port: Int) -> ClusterSystemSettings {
    var settings = ClusterSystemSettings(name: name, host: "127.0.0.1", port: port)
    settings.threadPoolSize = 1
    settings.serialization.registerInbound(V2ActorAuthenticationError.self)
    settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [V2ActorAuthenticationError.self])
    return settings
}
private struct RemotePairCount: Decodable { let value: Int64 }
private struct RemotePairReceiptRow: Decodable { let value: UUID? }
