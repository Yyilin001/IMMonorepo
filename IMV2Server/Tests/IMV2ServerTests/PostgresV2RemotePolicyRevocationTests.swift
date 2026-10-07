import Crypto
import DistributedCluster
import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2ActorCluster
@testable import IMV2Server
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("authenticated remote policy revocation", .serialized, .timeLimit(.minutes(2)))
struct PostgresV2RemotePolicyRevocationTests {
    @Test("native TCP revocation cannot acknowledge a live SQL holder, including cancelled callers", arguments: [false, true])
    func remoteRevocationWaitsForSQL(cancel: Bool) async throws {
        try await withUserEventDatabase { database, sql, schema in
            let hostKey = Curve25519.Signing.PrivateKey(), policyKey = Curve25519.Signing.PrivateKey()
            let identity = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
            let locator = try V2RoomPolicyEndpointLocator(hostID: identity.hostID.uuidValue!, shardID: "room-b")
            let hostSigner = try V2ActorSigningIdentity(serviceID: .init("policy-room"), privateKey: hostKey.rawRepresentation)
            let policySigner = try V2ActorSigningIdentity(serviceID: .init("policy-owner"), privateKey: policyKey.rawRepresentation)
            let trust = try V2ActorTrustStore(services: [
                .init(serviceID: hostSigner.serviceID, publicKey: hostKey.publicKey.rawRepresentation, permissions: [], hostedIDs: [identity.hostID]),
                .init(serviceID: policySigner.serviceID, publicKey: policyKey.publicKey.rawRepresentation, permissions: [.policyRevocation])
            ])
            let configuration = try V2RoomRuntimeConfiguration(), limits = try V2ActorAuthenticationLimits()
            let leases = try V2RoomServerLeaseStore(databases: ["room-b": database])
            let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(identity: identity,
                leaseStore: leases, configuration: configuration, budget: .init(configuration: configuration),
                classify: { $0.turnSchedulingClass }, factory: .init { _ in
                    .init(restore: { _ in }, execute: { _ in .rolledBack(.invalidRequest) }, invalidateReservation: { _ in }, close: {})
                })
            let serverPort = Int.random(in: 30_000...44_999), clientPort = Int.random(in: 45_000...60_000)
            let server = await ClusterSystem("policy-revoke-room", settings: settings("policy-revoke-room", serverPort))
            let callerSystem = await ClusterSystem("policy-revoke-owner", settings: settings("policy-revoke-owner", clientPort))
            let fence = PostgresV2RoomPolicyLeaseFence(database: database, schema: schema)
            let service = V2RoomPolicyAuthorizationService(directory: .init(endpoint: locator.encoded, maximumRooms: 1,
                factory: { _ in throw V2PolicyAuthorizationLifecycleError.invalidRequest }, fallback: { try await fence.revoke($0) }))
            let router = try V2RoomPolicyRevocationRouter(hostID: locator.hostID, services: ["room-b": service])
            #expect(throws: (any Error).self) {
                try V2RoomPolicyRevocationRouter(hostID: UUID(), services: ["room-b": service])
            }
            #expect(throws: (any Error).self) {
                try V2RoomPolicyRevocationRouter(hostID: locator.hostID, services: ["wrong-store": service])
            }
            let inbound = try V2RoomClusterInboundService(identity: identity, host: host,
                authenticator: .init(host: identity, trust: trust, limits: limits), signer: hostSigner, limits: limits,
                allowedShards: ["room-b"], serviceShardAccess: [policySigner.serviceID: ["room-b"]],
                maximumInboundRequests: 4, actorSystem: server, policyRevocations: router)
            let endpoint = V2RoomHostEndpoint(actorSystem: server, service: inbound)
            let descriptor = try V2RoomClusterHostDescriptor(identity: identity, endpointID: endpoint.id,
                address: "127.0.0.1", port: serverPort, accessibleShardIDs: ["room-b"], availableRooms: 1, isHealthy: true)
            let client = V2RoomClusterClient(system: callerSystem, signer: policySigner, trust: trust, limits: limits, configuration: configuration)
            let retry = V2RoomClusterClient(system: callerSystem, signer: policySigner, trust: trust, limits: limits, configuration: configuration)
            await host.start()
            let gate = RemoteSQLGate()
            var held: Task<Void, any Error>?
            var revoking: Task<V2PolicyAuthorizationRevocationProof, any Error>?
            do {
                try await client.register(descriptor); try await retry.register(descriptor)
                let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
                let owner = try await journal.acquireOwner(scope: .account(UUID()), ownerID: UUID(), durationSeconds: 30)
                let holder = try await journal.register(owners: [owner], registrationID: UUID(), roomID: UUID(),
                    activationID: UUID(), roomOwnerEpoch: 0, endpoint: locator.encoded, durationSeconds: 20)
                try await fence.install(holder)
                // A signed request reaching a host with the same shard still
                // cannot authorize another stable host's revocation target.
                let foreign = try V2RoomPolicyEndpointLocator(hostID: UUID(), shardID: "room-b")
                let wrongHost = try V2RoomPolicyRevocationWire(registrationID: holder.registrationID,
                    roomID: .init(uuid: holder.roomID), activationID: holder.activationID,
                    roomOwnerEpoch: holder.roomOwnerEpoch, generation: holder.generation,
                    endpoint: foreign.encoded, validUntil: holder.validUntil)
                await #expect(throws: (any Error).self) {
                    try await client.revokePolicyAuthorization(wrongHost, on: identity, deadline: .now + .seconds(5))
                }
                let unpinned = PostgresV2RemotePolicyRevoker(client: retry, roomHosts: [locator.hostID: ["other-store"]])
                await #expect(throws: V2PolicyAuthorizationLifecycleError.invalidTarget) { try await unpinned.revoke(holder) }
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).room_policy_authorization_leases WHERE registration_id=\(bind: holder.registrationID) AND revoked").first(decoding: Count.self)?.value == 0)
                let change = try await journal.beginChange(owner: owner, operationKey: "remote-block",
                    fingerprint: Data(repeating: 1, count: 32), commandJSON: "{}")
                let transaction = Task {
                    try await database.transaction { transaction in
                        try await fence.requireActive(holder, transaction: transaction)
                        let sql = try #require(transaction as? any SQLDatabase)
                        let pid = try #require(try await sql.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: Count.self)).value
                        await gate.hold(pid: pid)
                    }
                }; held = transaction
                try await eventually { await gate.pid != nil }
                let pid = try #require(await gate.pid)
                let revoker = PostgresV2RemotePolicyRevoker(client: client, roomHosts: [locator.hostID: ["room-b"]])
                let task = Task { try await revoker.revoke(holder) }; revoking = task
                try await eventually {
                    try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer = ANY(pg_blocking_pids(pid))").first(decoding: Count.self)?.value ?? 0 > 0
                }
                #expect(try await journal.targets(operationKey: change.operationKey) == [holder])
                await #expect(throws: V2PolicyAuthorizationLifecycleError.notDrained) {
                    try await journal.commitChange(owner: owner, operationKey: change.operationKey) { _, _ in Data([1]) }
                }
                if cancel {
                    task.cancel()
                    guard case .failure = await task.result else { throw V2PolicyAuthorizationLifecycleError.notDrained }
                    #expect(try await journal.targets(operationKey: change.operationKey) == [holder])
                }
                await gate.release(); try await transaction.value
                let proof: V2PolicyAuthorizationRevocationProof
                if cancel {
                    proof = try await PostgresV2RemotePolicyRevoker(client: retry, roomHosts: [locator.hostID: ["room-b"]]).revoke(holder)
                } else { proof = try await task.value }
                #expect(proof.holder == holder)
                try await journal.acknowledge(operationKey: change.operationKey, proof: proof)
                #expect(try await journal.commitChange(owner: owner, operationKey: change.operationKey) { _, _ in Data([1]) } == Data([1]))
                await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) { try await fence.install(holder) }
                let substituted = V2PolicyAuthorizationHolder(registrationID: holder.registrationID, roomID: holder.roomID,
                    activationID: holder.activationID, roomOwnerEpoch: holder.roomOwnerEpoch, generation: holder.generation + 1,
                    endpoint: holder.endpoint, validUntil: holder.validUntil)
                await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
                    try await PostgresV2RemotePolicyRevoker(client: retry, roomHosts: [locator.hostID: ["room-b"]]).revoke(substituted)
                }
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).room_policy_authorization_leases WHERE registration_id=\(bind: holder.registrationID) AND generation=\(bind: holder.generation) AND revoked").first(decoding: Count.self)?.value == 1)
            } catch {
                await gate.release(); _ = await held?.result; _ = await revoking?.result
                await client.stop(); await retry.stop(); await inbound.stop(); try? await service.shutdown()
                _ = await host.stop(deadline: .now + .seconds(5)); await leases.shutdownLifecycle(); await leases.shutdownRenewals()
                try? await callerSystem.shutdown().wait(); try? await server.shutdown().wait(); throw error
            }
            #expect(await client.quiesce(deadline: .now + .seconds(5)))
            #expect(await retry.quiesce(deadline: .now + .seconds(5)))
            #expect(await inbound.quiesce(deadline: .now + .seconds(5)))
            await client.stop(); await retry.stop(); await inbound.stop(); try await service.shutdown()
            #expect(await host.stop(deadline: .now + .seconds(5)).completed)
            await leases.shutdownLifecycle(); await leases.shutdownRenewals()
            try await callerSystem.shutdown().wait(); try await server.shutdown().wait()
        }
    }
    @Test("a restarted stable host settles old SQL permits while another host shares the shard")
    func restartedHostRevokesOldPermit() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let stable = V2ActorHostID(uuid: UUID()), other = V2ActorHostID(uuid: UUID())
            let oldIdentity = V2ActorHostIdentity(hostID: stable, incarnationID: UUID())
            let newIdentity = V2ActorHostIdentity(hostID: stable, incarnationID: UUID())
            let otherIdentity = V2ActorHostIdentity(hostID: other, incarnationID: UUID())
            let hostKey = Curve25519.Signing.PrivateKey(), callerKey = Curve25519.Signing.PrivateKey()
            let hostSigner = try V2ActorSigningIdentity(serviceID: .init("restart-room"), privateKey: hostKey.rawRepresentation)
            let callerSigner = try V2ActorSigningIdentity(serviceID: .init("restart-owner"), privateKey: callerKey.rawRepresentation)
            let trust = try V2ActorTrustStore(services: [
                .init(serviceID: hostSigner.serviceID, publicKey: hostKey.publicKey.rawRepresentation,
                    permissions: [], hostedIDs: [stable, other]),
                .init(serviceID: callerSigner.serviceID, publicKey: callerKey.publicKey.rawRepresentation,
                    permissions: [.policyRevocation])
            ])
            let configuration = try V2RoomRuntimeConfiguration(), limits = try V2ActorAuthenticationLimits()
            let callerSystem = await ClusterSystem("restart-owner", settings: settings("restart-owner", Int.random(in: 50_000...59_999)))
            let client = V2RoomClusterClient(system: callerSystem, signer: callerSigner, trust: trust,
                limits: limits, configuration: configuration)
            let gate = RemoteSQLGate(), calls = RemoteRevocationCalls()
            var nodes: [RemoteRevocationNode] = []
            var held: Task<Void, any Error>?
            var revoking: Task<V2PolicyAuthorizationRevocationProof, any Error>?
            do {
                let original = try await revocationNode(database: database, schema: schema, identity: oldIdentity,
                    signer: hostSigner, caller: callerSigner.serviceID, trust: trust, calls: calls)
                nodes.append(original)
                let decoy = try await revocationNode(database: database, schema: schema, identity: otherIdentity,
                    signer: hostSigner, caller: callerSigner.serviceID, trust: trust, calls: calls)
                nodes.append(decoy)
                try await client.register(original.descriptor); try await client.register(decoy.descriptor)
                #expect(try await client.resolvePolicyHost(hostID: stable, endpoint: "room-b") == oldIdentity)
                let locator = try V2RoomPolicyEndpointLocator(hostID: stable.uuidValue!, shardID: "room-b")
                let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
                let owner = try await journal.acquireOwner(scope: .account(UUID()), ownerID: UUID(), durationSeconds: 30)
                let holder = try await journal.register(owners: [owner], registrationID: UUID(), roomID: UUID(),
                    activationID: UUID(), roomOwnerEpoch: 0, endpoint: locator.encoded, durationSeconds: 20)
                let fence = PostgresV2RoomPolicyLeaseFence(database: database, schema: schema)
                try await fence.install(holder)
                let change = try await journal.beginChange(owner: owner, operationKey: "restart-block",
                    fingerprint: Data(repeating: 2, count: 32), commandJSON: "{}")
                let transaction = Task {
                    try await database.transaction { transaction in
                        try await fence.requireActive(holder, transaction: transaction)
                        let sql = try #require(transaction as? any SQLDatabase)
                        let pid = try #require(try await sql.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: Count.self)).value
                        await gate.hold(pid: pid)
                    }
                }; held = transaction
                try await eventually { await gate.pid != nil }
                // Tear down the actual server, runtime, endpoint and directory.
                // The independently held SQL transaction remains a real drain obligation.
                try await original.stop(); nodes.removeFirst()
                let replacement = try await revocationNode(database: database, schema: schema, identity: newIdentity,
                    signer: hostSigner, caller: callerSigner.serviceID, trust: trust, calls: calls)
                nodes.append(replacement)
                try await client.register(replacement.descriptor)
                #expect(try await client.resolvePolicyHost(hostID: stable, endpoint: "room-b") == newIdentity)
                #expect(try await client.resolvePolicyHost(hostID: other, endpoint: "room-b") == otherIdentity)
                let revoker = PostgresV2RemotePolicyRevoker(client: client,
                    roomHosts: [stable.uuidValue!: ["room-b"], other.uuidValue!: ["room-b"]])
                let task = Task { try await revoker.revoke(holder) }; revoking = task
                let pid = try #require(await gate.pid)
                try await eventually {
                    try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE \(bind: pid)::integer = ANY(pg_blocking_pids(pid))").first(decoding: Count.self)?.value ?? 0 > 0
                }
                #expect(await calls.count(newIdentity) == 1)
                #expect(await calls.count(oldIdentity) == 0)
                #expect(await calls.count(otherIdentity) == 0)
                #expect(try await journal.targets(operationKey: change.operationKey) == [holder])
                await #expect(throws: V2PolicyAuthorizationLifecycleError.notDrained) {
                    try await journal.commitChange(owner: owner, operationKey: change.operationKey) { _, _ in Data([2]) }
                }
                await gate.release(); try await transaction.value
                let proof = try await task.value
                #expect(proof.holder == holder)
                try await journal.acknowledge(operationKey: change.operationKey, proof: proof)
                #expect(try await journal.commitChange(owner: owner, operationKey: change.operationKey) { _, _ in Data([2]) } == Data([2]))
                await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) { try await fence.install(holder) }
            } catch {
                await gate.release(); _ = await held?.result; _ = await revoking?.result
                await client.stop(); for node in nodes { try? await node.stop() }
                try? await callerSystem.shutdown().wait(); throw error
            }
            #expect(await client.quiesce(deadline: .now + .seconds(5)))
            await client.stop(); for node in nodes { try await node.stop() }
            try await callerSystem.shutdown().wait()
        }
    }

    private func revocationNode(database: any Database, schema: String, identity: V2ActorHostIdentity,
        signer: V2ActorSigningIdentity, caller: V2ActorServiceID, trust: V2ActorTrustStore,
        calls: RemoteRevocationCalls) async throws -> RemoteRevocationNode {
        let configuration = try V2RoomRuntimeConfiguration(), limits = try V2ActorAuthenticationLimits()
        let leases = try V2RoomServerLeaseStore(databases: ["room-b": database])
        let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(identity: identity,
            leaseStore: leases, configuration: configuration, budget: .init(configuration: configuration),
            classify: { $0.turnSchedulingClass }, factory: .init { _ in
                .init(restore: { _ in }, execute: { _ in .rolledBack(.invalidRequest) }, invalidateReservation: { _ in }, close: {})
            })
        let port = Int.random(in: 30_000...49_999), name = "restart-" + identity.incarnationID.uuidString
        let system = await ClusterSystem(name, settings: settings(name, port))
        let locator = try V2RoomPolicyEndpointLocator(hostID: identity.hostID.uuidValue!, shardID: "room-b")
        let fence = PostgresV2RoomPolicyLeaseFence(database: database, schema: schema)
        let service = V2RoomPolicyAuthorizationService(directory: .init(endpoint: locator.encoded, maximumRooms: 1,
            factory: { _ in throw V2PolicyAuthorizationLifecycleError.invalidRequest }, fallback: { holder in
                await calls.record(identity)
                return try await fence.revoke(holder)
            }))
        let router = try V2RoomPolicyRevocationRouter(hostID: locator.hostID, services: ["room-b": service])
        let inbound = try V2RoomClusterInboundService(identity: identity, host: host,
            authenticator: .init(host: identity, trust: trust, limits: limits), signer: signer, limits: limits,
            allowedShards: ["room-b"], serviceShardAccess: [caller: ["room-b"]],
            maximumInboundRequests: 4, actorSystem: system, policyRevocations: router)
        let endpoint = V2RoomHostEndpoint(actorSystem: system, service: inbound)
        // No free room slots on either host: routing is independent of capacity.
        let descriptor = try V2RoomClusterHostDescriptor(identity: identity, endpointID: endpoint.id,
            address: "127.0.0.1", port: port, accessibleShardIDs: ["room-b"], availableRooms: 0, isHealthy: true)
        await host.start()
        return .init(system: system, leases: leases, host: host, service: service, inbound: inbound, endpoint: endpoint, descriptor: descriptor)
    }

    private func settings(_ name: String, _ port: Int) -> ClusterSystemSettings {
        var settings = ClusterSystemSettings(name: name, host: "127.0.0.1", port: port)
        settings.threadPoolSize = 1
        settings.serialization.registerInbound(V2ActorAuthenticationError.self)
        settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [V2ActorAuthenticationError.self])
        return settings
    }
    private func eventually(_ predicate: @Sendable () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while .now < deadline { if try await predicate() { return }; await Task.yield() }
        throw V2PolicyAuthorizationLifecycleError.notDrained
    }
    private struct Count: Decodable { let value: Int64 }
}
private actor RemoteSQLGate {
    private(set) var pid: Int64?
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func hold(pid: Int64) async {
        self.pid = pid
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private actor RemoteRevocationCalls {
    private var counts: [V2ActorHostIdentity: Int] = [:]
    func record(_ host: V2ActorHostIdentity) { counts[host, default: 0] += 1 }
    func count(_ host: V2ActorHostIdentity) -> Int { counts[host, default: 0] }
}
private struct RemoteRevocationNode {
    let system: ClusterSystem
    let leases: V2RoomServerLeaseStore
    let host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>
    let service: V2RoomPolicyAuthorizationService
    let inbound: V2RoomClusterInboundService
    let endpoint: V2RoomHostEndpoint
    let descriptor: V2RoomClusterHostDescriptor
    func stop() async throws {
        await inbound.stop(); try? await service.shutdown()
        #expect(await host.stop(deadline: .now + .seconds(5)).completed)
        await leases.shutdownLifecycle(); await leases.shutdownRenewals()
        try await system.shutdown().wait()
    }
}
