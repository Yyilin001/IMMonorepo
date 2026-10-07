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
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("lease-free policy snapshots over PostgreSQL and TCP", .serialized, .timeLimit(.minutes(2)))
struct PostgresV2PolicyFactsSnapshotTests {
    @Test("single statement preserves defaults, request order, and committed version/facts consistency")
    func singleStatementConsistency() async throws {
        try await PostgresV2RoomWriteStoreIntegrationTests().withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, roomDrainRequired: false)
            let missing = UUID()
            let scopes: [V2PolicyAuthorizationScope] = [.stranger(missing), .pair(missing, senderUUID), .account(missing), .account(senderUUID)]
            let defaults = try await journal.readSnapshots(scopes: scopes)
            #expect(defaults.map { $0.scope.key } == scopes.map(\.key))
            #expect(defaults.allSatisfy { $0.version == 1 })
            if case .stranger(let value) = defaults[0].facts { #expect(value.allowsStrangers) } else { Issue.record("wrong stranger facts") }
            if case .pair(let value) = defaults[1].facts { #expect(!value.blocked && !value.isFriend) } else { Issue.record("wrong pair facts") }
            if case .account(let value) = defaults[2].facts { #expect(!value.isActive && value.specialKind == nil) } else { Issue.record("wrong account facts") }
            let scope = V2PolicyAuthorizationScope.stranger(senderUUID)
            try await sql.raw("INSERT INTO im_v2.policy_authorization_scopes (scope_key, revision) VALUES (\(bind: scope.key),1)").run()
            try await sql.raw("INSERT INTO im_v2.user_stranger_message_preferences (user_id,allows_stranger_messages,updated_at) VALUES (\(bind: senderUUID),true,clock_timestamp()) ON CONFLICT (user_id) DO UPDATE SET allows_stranger_messages=true").run()
            let writer = Task {
                for revision in 2...41 {
                    try await database.transaction { transaction in
                        let transactionSQL = try #require(transaction as? any SQLDatabase)
                        try await transactionSQL.raw("UPDATE im_v2.user_stranger_message_preferences SET allows_stranger_messages=\(bind: revision % 2 == 1) WHERE user_id=\(bind: senderUUID)").run()
                        await Task.yield()
                        try await transactionSQL.raw("UPDATE im_v2.policy_authorization_scopes SET revision=\(bind: revision) WHERE scope_key=\(bind: scope.key)").run()
                    }
                }
            }
            do {
                for _ in 0..<100 {
                    let snapshot = try await journal.readSnapshot(scope: scope)
                    if case .stranger(let value) = snapshot.facts {
                        #expect(value.allowsStrangers == (snapshot.version % 2 == 1))
                    } else { Issue.record("wrong snapshot facts") }
                }
                try await writer.value
            } catch { _ = await writer.result; throw error }
            try await sql.raw("UPDATE im_v2.policy_authorization_scopes SET pending_change_key='snapshot-test-pending' WHERE scope_key=\(bind: scope.key)").run()
            await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) { try await journal.readSnapshot(scope: scope) }
        }
    }

    @Test("initialization does not claim ownership and ignores business read locks")
    func readOnlyInitialization() async throws {
        try await PostgresV2RoomWriteStoreIntegrationTests().withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let gate = SnapshotSQLGate()
            let locked = Task {
                try await database.transaction { transaction in
                    let sql = try #require(transaction as? any SQLDatabase)
                    try await v2AcquireOrderedDirectAuthorizationLocks(["account-state:" + senderUUID.uuidString], shared: false, sql: sql)
                    _ = try await sql.raw("SELECT user_id FROM im_v2.public_user_profiles WHERE user_id=\(bind: senderUUID) FOR UPDATE").all()
                    await gate.hold()
                }
            }
            while !(await gate.entered) { await Task.yield() }
            do {
                let journal = PostgresV2PolicyAuthorizationJournal(database: database, roomDrainRequired: false)
                let value = try await V2RoomSQLDeadline.withDeadline(.now + .seconds(2)) {
                    try await journal.readSnapshot(scope: .account(senderUUID))
                }
                #expect(value.version == 1)
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_scopes").first(decoding: Count.self)?.value == 0)
                await gate.release(); try await locked.value
            } catch { await gate.release(); _ = await locked.result; throw error }
        }
    }

    @Test("TCP snapshot reads stay hot without leases and committed changes push new facts")
    func nativeSnapshotPush() async throws {
        try await PostgresV2RoomWriteStoreIntegrationTests().withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let identities = (0..<2).map { _ in V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID()) }
            let keys = (0..<2).map { _ in Curve25519.Signing.PrivateKey() }
            let signers = try keys.enumerated().map { index, key in
                try V2ActorSigningIdentity(serviceID: .init("snapshot-node-\(index)"), privateKey: key.rawRepresentation)
            }
            let trust = try V2ActorTrustStore(services: try identities.enumerated().map { index, identity in
                try .init(serviceID: signers[index].serviceID, publicKey: keys[index].publicKey.rawRepresentation,
                    permissions: [.policyRegistration, .policyMutation], hostedIDs: [identity.hostID])
            })
            let configuration = try V2RoomRuntimeConfiguration(), limits = try V2ActorAuthenticationLimits()
            let names = ["snapshot-owner", "snapshot-gateway"]
            let ports = [Int.random(in: 30_000...39_999), Int.random(in: 40_000...49_999)]
            var systems: [ClusterSystem] = []
            for index in 0..<2 { systems.append(await ClusterSystem(names[index], settings: settings(names[index], ports[index]))) }
            let clients = (0..<2).map { V2RoomClusterClient(system: systems[$0], signer: signers[$0], trust: trust, limits: limits, configuration: configuration) }
            let caches = (0..<2).map { _ in V2NodePolicyStateCache() }
            let subscriber = try V2PolicySnapshotSubscriberWire(hostID: identities[1].hostID, endpoint: names[1])
            let publisher = V2PolicySnapshotPublisher(targets: [subscriber], localHostID: identities[0].hostID,
                cache: caches[0], client: { clients[0] })
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, roomDrainRequired: false)
            let dispatcher = PostgresV2PolicyMutationDispatcher(database: database, projectionDelivery: SuccessfulProjectionDelivery(),
                legacyAuthorization: .init(controlDatabase: database, ownerDatabases: [:]))
            let directories = (0..<2).map { index in
                PostgresV2PolicyOwnerDirectory(journal: journal, dispatcher: dispatcher, ownerID: identities[index].incarnationID,
                    snapshotPublisher: index == 0 ? publisher : nil, leaseSeconds: 0.05,
                    ownsScope: { _ in index == 0 }, revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget })
            }
            var stores: [V2RoomServerLeaseStore] = []
            var hosts: [V2RoomActivationHost<V2RoomRequest, V2RoomResponse>] = []
            var inbounds: [V2RoomClusterInboundService] = []
            var endpoints: [V2RoomHostEndpoint] = []
            var serving: [SnapshotCountingService] = []
            func stop() async {
                for client in clients { await client.stop() }
                for inbound in inbounds { await inbound.stop() }
                for host in hosts { _ = await host.stop(deadline: .now + .seconds(5)) }
                for store in stores { await store.shutdownLifecycle(); await store.shutdownRenewals() }
                for directory in directories { await directory.shutdown() }
                for cache in caches { await cache.shutdown() }
                for system in systems { try? await system.shutdown().wait() }
            }
            do {
                for index in 0..<2 {
                    let leases = try V2RoomServerLeaseStore(databases: [names[index]: database]); stores.append(leases)
                    let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(identity: identities[index], leaseStore: leases,
                        configuration: configuration, budget: .init(configuration: configuration), classify: { $0.turnSchedulingClass },
                        factory: .init { _ in .init(restore: { _ in }, execute: { _ in .rolledBack(.invalidRequest) }, invalidateReservation: { _ in }, close: {}) })
                    hosts.append(host); await host.start()
                    let service = SnapshotCountingService(service: .init(owners: directories[index], endpoint: names[index], cache: caches[index]))
                    serving.append(service)
                    let inbound = try V2RoomClusterInboundService(identity: identities[index], host: host,
                        authenticator: .init(host: identities[index], trust: trust, limits: limits), signer: signers[index], limits: limits,
                        allowedShards: [names[index]], serviceShardAccess: [signers[1 - index].serviceID: [names[index]]],
                        maximumInboundRequests: 128, actorSystem: systems[index], policyOwnership: service)
                    inbounds.append(inbound)
                    let endpoint = V2RoomHostEndpoint(actorSystem: systems[index], service: inbound); endpoints.append(endpoint)
                    try await clients[1 - index].register(.init(identity: identities[index], endpointID: endpoint.id,
                        address: "127.0.0.1", port: ports[index], accessibleShardIDs: [names[index]], availableRooms: 0, isHealthy: true))
                }
                let remote = PostgresV2RemotePolicyOwners(clientProvider: { clients[1] }, stateCache: caches[1], subscriber: subscriber,
                    resolve: { _ in .init(host: identities[0], endpoint: names[0], ownerID: identities[0].incarnationID) })
                let scopes: [V2PolicyAuthorizationScope] = [.account(senderUUID), .account(memberTwoUUID), .pair(senderUUID, memberTwoUUID), .stranger(memberTwoUUID)]
                let first = try await remote.registrationSnapshots(scopes: scopes)
                #expect(first.count == 4 && first.allSatisfy { $0.version == 1 })
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_scopes").first(decoding: Count.self)?.value == 0)
                #expect(await serving[0].reads == 1)
                let hidden = ["public_user_profiles", "special_accounts", "account_disables", "user_blocks", "user_relationships", "user_stranger_message_preferences", "policy_authorization_scopes"]
                for table in hidden { try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_snapshot_hidden")").run() }
                try await Task.sleep(for: .milliseconds(100))
                for _ in 0..<100 { #expect(try await remote.registrationSnapshots(scopes: scopes) == first) }
                #expect(await serving[0].reads == 1)
                for table in hidden { try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_snapshot_hidden") RENAME TO \(unsafeRaw: table)").run() }
                let social = PostgresV2SocialRelationshipStore(database: database, projectionDelivery: SuccessfulProjectionDelivery())
                let block = try await social.freezeSocialFixture(actorUserID: senderID, targetUserID: .init(uuid: memberTwoUUID),
                    operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now: Date())
                _ = try await directories[0].change(.social(block))
                let blocked = try #require(try await remote.cachedSnapshots(scopes: [scopes[2]])?.first)
                if case .pair(let facts) = blocked.facts { #expect(facts.blocked) }
                #expect(blocked.version == 2)
                let preference = PostgresV2AccountPreferenceOperationStore(database: database,
                    projectionDelivery: SuccessfulProjectionDelivery(), authorizationCoordinator: .init(controlDatabase: database, ownerDatabases: [:]))
                let deny = try await preference.freezePreferenceFixture(owner: .init(uuid: memberTwoUUID),
                    operation: .strangerMessagePreference(.init(uuid: UUID())), value: .strangerMessage(.deny), now: Date())
                _ = try await directories[0].change(.strangerPreference(deny))
                let denied = try #require(try await remote.cachedSnapshots(scopes: [scopes[3]])?.first)
                if case .stranger(let facts) = denied.facts { #expect(!facts.allowsStrangers) }
                _ = try await V2PostgresAccountDisableService(database: database, operatorPrincipal: "snapshot:test",
                    authorizationCoordinator: .init(controlDatabase: database, ownerDatabases: [:])).usingPolicyOwners(directories[0])
                    .disable(.init(userID: .init(uuid: memberTwoUUID), operationID: UUID(), reason: .policyEnforcement))
                let disabled = try #require(try await remote.cachedSnapshots(scopes: [scopes[1]])?.first)
                if case .account(let facts) = disabled.facts { #expect(!facts.isActive) }
                #expect(await serving[0].reads == 1)
                #expect(await serving[1].updates >= 3)
                #expect(endpoints.count == 2)
                await stop()
            } catch { await stop(); throw error }
        }
    }
    private func settings(_ name: String, _ port: Int) -> ClusterSystemSettings {
        var settings = ClusterSystemSettings(name: name, host: "127.0.0.1", port: port)
        settings.threadPoolSize = 1
        settings.serialization.registerInbound(V2ActorAuthenticationError.self)
        settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [V2ActorAuthenticationError.self])
        return settings
    }
    private struct Count: Decodable { let value: Int64 }
}
private actor SnapshotSQLGate {
    private(set) var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
}
private actor SnapshotCountingService: V2PolicyOwnershipServing {
    let service: V2PolicyOwnershipService
    private(set) var reads = 0
    private(set) var updates = 0
    init(service: V2PolicyOwnershipService) { self.service = service }
    func policySnapshots(_ request: V2PolicySnapshotRequestWire, deadline: ContinuousClock.Instant) async throws -> [V2PolicySnapshotWire] {
        reads += 1; return try await service.policySnapshots(request, deadline: deadline)
    }
    func updatePolicySnapshot(_ request: V2PolicySnapshotUpdateWire, deadline: ContinuousClock.Instant) async throws {
        updates += 1; try await service.updatePolicySnapshot(request, deadline: deadline)
    }
    func claimPolicyOwnership(_ request: V2PolicyOwnershipClaimWire, deadline: ContinuousClock.Instant) async throws -> [V2PolicyOwnerStateWire] {
        try await service.claimPolicyOwnership(request, deadline: deadline)
    }
}
