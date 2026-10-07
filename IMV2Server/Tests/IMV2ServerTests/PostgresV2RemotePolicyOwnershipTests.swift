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
import Vapor
import VaporTesting
import IMV2ServerHTTP

@Suite("authenticated distributed policy ownership", .serialized, .timeLimit(.minutes(2)))
struct PostgresV2RemotePolicyOwnershipTests {
    @Test("cache-only policy claims round trip and legacy claims decode as ordinary reads")
    func cacheOnlyWireCompatibility() throws {
        let request = try V2PolicyOwnershipClaimWire(endpoint: "policy-test",
            scopes: [.init(account: UUID())], cachedOnly: true)
        let bytes = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(V2PolicyOwnershipClaimWire.self, from: bytes) == request)
        var legacy = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        legacy.removeValue(forKey: "cachedOnly")
        let decoded = try JSONDecoder().decode(V2PolicyOwnershipClaimWire.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        #expect(!decoded.cachedOnly && decoded.endpoint == request.endpoint && decoded.scopes == request.scopes)
    }

    @Test("early authority renewal reuses facts without reopening policy tables")
    func earlyAuthorityRenewal() async throws {
        try await PostgresV2RoomWriteStoreIntegrationTests().withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, roomDrainRequired: false)
            let dispatcher = PostgresV2PolicyMutationDispatcher(database: database,
                projectionDelivery: SuccessfulProjectionDelivery(),
                legacyAuthorization: .init(controlDatabase: database, ownerDatabases: [:]))
            let directory = PostgresV2PolicyOwnerDirectory(journal: journal, dispatcher: dispatcher,
                leaseSeconds: 5, revoke: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget })
            do {
                let scope = V2PolicyAuthorizationScope.account(senderUUID)
                let initial = try await directory.registrationStates(scopes: [scope])[0]
                let hidden = ["public_user_profiles", "special_accounts", "account_disables", "user_blocks",
                    "user_relationships", "user_stranger_message_preferences"]
                for table in hidden {
                    try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_renew_hidden")").run()
                }
                let renewed = try await directory.registrationStates(scopes: [scope], minimumRemaining: .seconds(10))[0]
                #expect(renewed.facts == initial.facts)
                #expect(renewed.owner.epoch == initial.owner.epoch && renewed.owner.revision == initial.owner.revision)
                #expect(renewed.owner.validUntil > initial.owner.validUntil)
                for table in hidden {
                    try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_renew_hidden") RENAME TO \(unsafeRaw: table)").run()
                }
                await directory.shutdown()
            } catch { await directory.shutdown(); throw error }
        }
    }

    @Test("native TCP routes four dependencies to assigned owners and rejects foreign scopes before SQL",
          arguments: [false, true])
    func distributedClaims(usesCurrentState: Bool) async throws {
        try await PostgresV2RoomWriteStoreIntegrationTests().withForwardOwnerDatabases(mode: .standard) { database, roomDatabase, sql, _, _ in
            let schema = "im_v2"
            let a = senderUUID, b = memberTwoUUID
            let scopes: [V2PolicyAuthorizationScope] = [.account(a), .account(b), .pair(a, b), .stranger(b)]
            let identities = (0..<2).map { _ in V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID()) }
            let hostUUIDs = try identities.map { try #require($0.hostID.uuidValue) }
            let keys = (0..<3).map { _ in Curve25519.Signing.PrivateKey() }
            let signers = try keys.enumerated().map { index, key in
                try V2ActorSigningIdentity(serviceID: .init("claim-node-\(index)"), privateKey: key.rawRepresentation)
            }
            let trust = try V2ActorTrustStore(services: [
                .init(serviceID: signers[0].serviceID, publicKey: keys[0].publicKey.rawRepresentation, permissions: [], hostedIDs: [identities[0].hostID]),
                .init(serviceID: signers[1].serviceID, publicKey: keys[1].publicKey.rawRepresentation, permissions: [], hostedIDs: [identities[1].hostID]),
                .init(serviceID: signers[2].serviceID, publicKey: keys[2].publicKey.rawRepresentation, permissions: [.policyRegistration, .policyMutation])
            ])
            let configuration = try V2RoomRuntimeConfiguration(), limits = try V2ActorAuthenticationLimits()
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema,
                roomDrainRequired: !usesCurrentState)
            let dispatcher = PostgresV2PolicyMutationDispatcher(database: database,
                projectionDelivery: SuccessfulProjectionDelivery(),
                legacyAuthorization: .init(controlDatabase: database, ownerDatabases: [:]))
            let fence = PostgresV2RoomPolicyLeaseFence(database: roomDatabase)
            let firstKey = scopes[0].key
            let placement = try V2PolicyOwnerPlacement(.init(revision: 1, partitionCount: 16, owners: [
                .init(hostID: hostUUIDs[0], endpoint: "policy-0", partitions: [3]),
                .init(hostID: hostUUIDs[1], endpoint: "policy-1", partitions: (0..<16).filter { $0 != 3 })
            ]))
            try await PostgresV2PolicyDeploymentPlacementStore(database: database).require(placement)
            #expect(try placement.partition(for: firstKey) == 3)
            let nodeCaches = (0..<2).map { _ in V2NodePolicyStateCache() }
            let mutationBinding = V2PolicyClusterClientBinding()
            let directories = identities.enumerated().map { index, identity in
                PostgresV2PolicyOwnerDirectory(journal: journal, dispatcher: dispatcher,
                    ownerID: identity.incarnationID, maximumOwners: 4, maximumRoots: 8,
                    committed: { scope in
                        if usesCurrentState {
                            let publisher = V2PolicyCacheInvalidationPublisher(placement: placement.configuration,
                                hostID: hostUUIDs[index], cache: nodeCaches[index],
                                client: { try await mutationBinding.client() })
                            try await publisher.invalidate(scopeKey: scope.key)
                        }
                    },
                    ownsScope: { placement.owns($0, hostID: hostUUIDs[index]) },
                    revoke: { try await fence.revoke($0) })
            }
            let ports = [Int.random(in: 30_000...39_999), Int.random(in: 40_000...49_999), Int.random(in: 50_000...60_000)]
            var systems: [ClusterSystem] = []
            for i in 0..<3 { systems.append(await ClusterSystem("claim-node-\(i)", settings: settings("claim-node-\(i)", ports[i]))) }
            var hosts: [V2RoomActivationHost<V2RoomRequest, V2RoomResponse>] = []
            var stores: [V2RoomServerLeaseStore] = []
            var inbounds: [V2RoomClusterInboundService] = []
            var endpoints: [V2RoomHostEndpoint] = []
            var stateServices: [PolicyStateResponseOverride] = []
            let client = V2RoomClusterClient(system: systems[2], signer: signers[2], trust: trust, limits: limits, configuration: configuration)
            try await mutationBinding.bind(client)
            do {
                for i in 0..<2 {
                    let endpointName = "policy-\(i)"
                    let leases = try V2RoomServerLeaseStore(databases: [endpointName: database]); stores.append(leases)
                    let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(identity: identities[i],
                        leaseStore: leases, configuration: configuration, budget: .init(configuration: configuration),
                        classify: { $0.turnSchedulingClass }, factory: .init { _ in
                            .init(restore: { _ in }, execute: { _ in .rolledBack(.invalidRequest) }, invalidateReservation: { _ in }, close: {})
                        }); hosts.append(host); await host.start()
                    let stateService = PolicyStateResponseOverride(service: .init(owners: directories[i], endpoint: endpointName, cache: nodeCaches[i]))
                    stateServices.append(stateService)
                    let inbound = try V2RoomClusterInboundService(identity: identities[i], host: host,
                        authenticator: .init(host: identities[i], trust: trust, limits: limits), signer: signers[i], limits: limits,
                        allowedShards: [endpointName], serviceShardAccess: [signers[2].serviceID: [endpointName]],
                        maximumInboundRequests: 8, actorSystem: systems[i],
                        policyOwnership: stateService,
                        policyMutations: V2PolicyMutationService(owners: directories[i], endpoint: endpointName))
                    inbounds.append(inbound)
                    let endpoint = V2RoomHostEndpoint(actorSystem: systems[i], service: inbound)
                    endpoints.append(endpoint)
                    try await client.register(.init(identity: identities[i], endpointID: endpoint.id, address: "127.0.0.1",
                        port: ports[i], accessibleShardIDs: [endpointName], availableRooms: 0, isHealthy: true))
                }
                #expect(endpoints.count == 2)
                let localOnly = PostgresV2RemotePolicyOwners(
                    clientProvider: { throw V2PolicyAuthorizationLifecycleError.busy },
                    localOwners: directories[0], resolve: { _ in throw V2PolicyAuthorizationLifecycleError.invalidTarget })
                let localStates = try await localOnly.registrationStates(scopes: [scopes[0]])
                #expect(localStates.count == 1)
                #expect(localStates.first?.owner.ownerID == identities[0].incarnationID)
                let routes = PostgresV2PolicyDeploymentRoutes(placement: placement, client: client)
                let cachedRemote = PostgresV2RemotePolicyOwners(clientProvider: { client },
                    localOwners: directories[0], stateCache: nodeCaches[0],
                    resolve: { try await routes.resolveScope($0) })
                let binding = V2PolicyClusterClientBinding()
                let remote = PostgresV2RemotePolicyOwners(clientProvider: { try await binding.client() }, probesRemoteMemory: true,
                    resolve: { try await routes.resolveScope($0) })
                await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) { try await remote.registrationStates(scopes: scopes) }
                try await binding.bind(client)
                #expect(try await binding.client() === client)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.identityConflict) { try await binding.bind(client) }
                await #expect(throws: V2RoomCallFailure.notAccepted(.unavailable)) {
                    try await client.resolvePolicyHost(hostID: .init(uuid: UUID()), endpoint: "policy-0")
                }
                await #expect(throws: V2RoomCallFailure.notAccepted(.unavailable)) {
                    try await client.resolvePolicyHost(hostID: identities[0].hostID, endpoint: "policy-1")
                }
                let states = try await remote.registrationStates(scopes: scopes)
                let claims = states.map(\.owner)
                #expect(claims.count == 4)
                for claim in claims {
                    #expect(claim.ownerID == identities[claim.scope.key == firstKey ? 0 : 1].incarnationID)
                    #expect(claim.epoch == 1 && claim.revision == 1)
                }
                // Occupy all directory roots with actual SQL waiting on a
                // scope lock; the authenticated TCP claim must preserve the
                // service's temporary overload rather than encode unknown.
                let busyGate = PolicyBusyWireGate()
                let blocker = Task {
                    try await database.transaction { transaction in
                        let connection = try #require(transaction as? any SQLDatabase)
                        _ = try await connection.raw("SELECT scope_key FROM im_v2.policy_authorization_scopes WHERE scope_key=\(bind: firstKey) FOR UPDATE").all()
                        await busyGate.hold()
                    }
                }
                var blockedClaims: [Task<[V2PolicyOwnerLease], any Error>] = []
                do {
                    let deadline = ContinuousClock.now + .seconds(5)
                    while !(await busyGate.entered), .now < deadline { await Task.yield() }
                    try #require(await busyGate.entered)
                    for _ in 0..<8 { blockedClaims.append(Task { try await directories[0].registrationOwners(scopes: [scopes[0]]) }) }
                    while await directories[0].pressure().roots != 8, .now < deadline { await Task.yield() }
                    try #require(await directories[0].pressure().roots == 8)
                    let claim = try V2PolicyOwnershipClaimWire(endpoint: "policy-0", scopes: [scopes[0].policyWire])
                    let warmStates = try await client.claimPolicyStates(claim, on: identities[0],
                        expectedOwnerID: identities[0].incarnationID, deadline: .now + .seconds(5))
                    let expectedWarmScope = try scopes[0].policyWire
                    #expect(warmStates.count == 1 && warmStates[0].owner.scope == expectedWarmScope)
                    #expect(await directories[0].pressure().roots == 8)
                    // Only genuinely uncached requests compete with these
                    // suspended SQL roots. Memory hits remain available.
                    var uncached = V2PolicyAuthorizationScope.account(UUID())
                    while !placement.owns(uncached.key, hostID: hostUUIDs[0]) { uncached = .account(UUID()) }
                    let coldProbe = try V2PolicyOwnershipClaimWire(endpoint: "policy-0", scopes: [uncached.policyWire], cachedOnly: true)
                    let probeMiss = try await client.claimPolicyStates(coldProbe, on: identities[0],
                        expectedOwnerID: identities[0].incarnationID, deadline: .now + .seconds(5))
                    #expect(probeMiss.isEmpty)
                    #expect(await directories[0].pressure().roots == 8)
                    let warmRemote = try await v2ReadPolicyState(
                        callerDeadline: .now + .seconds(5), cachedOperation: {
                            try await remote.cachedRegistrationStates(scopes: scopes)
                        }, operation: {
                            Issue.record("Remote memory facts triggered a cold read")
                            return try await remote.registrationStates(scopes: scopes)
                        })
                    #expect(warmRemote.count == 4)
                    #expect(await directories[0].pressure().roots == 8)
                    let coldClaim = try V2PolicyOwnershipClaimWire(endpoint: "policy-0", scopes: [uncached.policyWire])
                    await #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
                        try await client.claimPolicyStates(coldClaim, on: identities[0],
                            expectedOwnerID: identities[0].incarnationID, deadline: .now + .seconds(5))
                    }
                    await busyGate.release(); try await blocker.value
                    for task in blockedClaims { _ = try await task.value }
                    #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_scopes WHERE scope_key=\(bind: uncached.key)")
                        .first(decoding: WireCount.self)?.value == 0)
                } catch {
                    await busyGate.release(); _ = await blocker.result
                    for task in blockedClaims { _ = await task.result }
                    throw error
                }
                let pair = V2DirectSendControlPair(sender: a, recipient: b)
                let baseline = try await V2DirectSendControlPolicyFence(database: database).withLockedPolicies(pairs: [pair]) { _, policies in
                    try #require(policies[pair])
                }
                let hidden = ["public_user_profiles", "special_accounts", "account_disables", "user_blocks",
                    "user_relationships", "user_stranger_message_preferences"]
                for table in hidden { try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_remote_hidden")").run() }
                // Actual TCP now returns facts from remote owner memory, and
                // registration performs no control-fact reads on this node.
                let cached = try await remote.registrationStates(scopes: scopes)
                // Local and foreign scopes share the mutation directories.
                // Hidden fact tables prove both branches use cached facts;
                // resolving a local scope is a test failure.
                let mixed = PostgresV2RemotePolicyOwners(clientProvider: { client }, localOwners: directories[0],
                    resolve: { key in
                        guard key != firstKey else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
                        return try await routes.resolveScope(key)
                    })
                let mixedStates = try await mixed.registrationStates(scopes: scopes)
                #expect(mixedStates.map(\.owner) == cached.map(\.owner))
                let snapshot: V2RegisteredDirectPolicySnapshot?
                if usesCurrentState {
                    // The current path reads facts without installing a room
                    // registration. Compare the same business facts directly.
                    let sender = try #require(cached.first { $0.owner.scope.key == scopes[0].key })
                    let recipient = try #require(cached.first { $0.owner.scope.key == scopes[1].key })
                    let social = try #require(cached.first { $0.owner.scope.key == scopes[2].key })
                    let stranger = try #require(cached.first { $0.owner.scope.key == scopes[3].key })
                    guard case .account(let senderFacts) = sender.facts,
                          case .account(let recipientFacts) = recipient.facts,
                          case .pair(let socialFacts) = social.facts,
                          case .stranger(let settings) = stranger.facts else {
                        throw V2PolicyAuthorizationLifecycleError.corruptPersistence
                    }
                    #expect(senderFacts.controlAccount == baseline.sender)
                    #expect(recipientFacts.controlAccount == baseline.recipient)
                    #expect(socialFacts.blocked == baseline.blocked && socialFacts.isFriend == baseline.isFriend)
                    #expect(settings.allowsStrangers == baseline.allowsStrangers)
                    snapshot = nil
                } else {
                    snapshot = try await PostgresV2DirectPolicySnapshotStore(database: database).register(
                        pair: pair, states: cached, registrationID: UUID(), roomID: UUID(),
                        activationID: UUID(), roomOwnerEpoch: 1, endpoint: "room-b", durationSeconds: 20)
                    #expect(snapshot?.policy == baseline)
                }
                for table in hidden { try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_remote_hidden") RENAME TO \(unsafeRaw: table)").run() }
                await stateServices[0].set(.expiresDuringTransit)
                #expect(try await remote.cachedRegistrationStates(scopes: [scopes[0]]) == nil)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) {
                    try await remote.registrationStates(scopes: [scopes[0]])
                }
                await stateServices[0].set(.wrongAccount)
                await #expect(throws: V2PolicyAuthorizationLifecycleError.invalidTarget) {
                    try await remote.cachedRegistrationStates(scopes: [scopes[0]])
                }
                await #expect(throws: V2PolicyAuthorizationLifecycleError.invalidTarget) {
                    try await remote.registrationStates(scopes: [scopes[0]])
                }
                await stateServices[0].set(.normal)
                if usesCurrentState {
                    _ = try await cachedRemote.registrationStates(scopes: scopes)
                    let before = await stateServices[1].claims
                    // A broken remote responder is unreachable on the hot path.
                    await stateServices[1].set(.wrongAccount)
                    for _ in 0..<100 {
                        #expect(try await cachedRemote.cachedRegistrationStates(scopes: scopes)?.count == 4)
                        #expect(try await cachedRemote.registrationStates(scopes: scopes).count == 4)
                    }
                    #expect(await stateServices[1].claims == before)
                    await stateServices[1].set(.normal)
                    let invalidation = try V2PolicyCacheInvalidationWire(endpoint: "policy-0", scope: scopes[0].policyWire)
                    try await client.invalidatePolicyCache(invalidation, on: identities[0], deadline: .now + .seconds(5))
                    #expect(try await cachedRemote.cachedRegistrationStates(scopes: scopes) == nil)
                    #expect(try await cachedRemote.registrationStates(scopes: scopes).count == 4)
                    // Force an early renewal through the actual TCP service;
                    // both owner versions and facts remain unchanged.
                    let refresh = try V2PolicyOwnershipClaimWire(endpoint: "policy-0", scopes: [scopes[0].policyWire], refresh: true)
                    let renewed = try await client.claimPolicyStates(refresh, on: identities[0],
                        expectedOwnerID: identities[0].incarnationID, deadline: .now + .seconds(5))
                    #expect(renewed.count == 1 && renewed[0].owner.revision == 1)
                }
                let holder = snapshot?.holder
                if let holder {
                    try await fence.install(holder)
                    #expect(holder.generation == 1)
                }
                let reversed = try await remote.registrationOwners(scopes: [.pair(b, a)])
                #expect(reversed.first?.scope.key == scopes[2].key)
                #expect(reversed.first?.epoch == claims.first(where: { $0.scope.key == scopes[2].key })?.epoch)
                // Reject a mixed local/foreign batch before any ownership claim.
                var foreign = V2PolicyAuthorizationScope.account(UUID())
                while placement.owns(foreign.key, hostID: hostUUIDs[0]) { foreign = .account(UUID()) }
                let foreignScope = foreign
                await #expect(throws: V2PolicyAuthorizationLifecycleError.ownerChanged) {
                    try await directories[0].registrationOwners(scopes: [scopes[0], foreignScope])
                }
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).policy_authorization_scopes WHERE scope_key=\(bind: foreign.key)").first(decoding: Count.self)?.value == 0)
                let wrongOwner = PostgresV2RemotePolicyOwners(client: client, resolve: { _ in
                    .init(host: identities[0], endpoint: "policy-0", ownerID: UUID())
                })
                await #expect(throws: V2RoomCallFailure.outcomeUnknown) { try await wrongOwner.registrationOwners(scopes: [scopes[0]]) }
                let remoteMutations = PostgresV2RemotePolicyMutations(client: client, resolve: { try await routes.resolveScope($0) })
                let localSocial = PostgresV2SocialRelationshipStore(database: database,
                    projectionDelivery: SuccessfulProjectionDelivery())
                let routedSocial = localSocial.usingPolicyOwners(remoteMutations)
                let operationID = UUID()
                let command = try await localSocial.freezeSocialFixture(actorUserID: .init(uuid: a), targetUserID: .init(uuid: b),
                    operation: .userBlock(.init(uuid: operationID)), action: .userBlock(.block), now: Date())
                let original = try await routedSocial.submitSocialOperation(command, now: Date())
                guard case .receipt(let receipt) = original else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                #expect(receipt.outcome == .applied(.userBlock(isBlocked: true, revision: 1)))
                #expect(try await routedSocial.submitSocialOperation(command, now: Date()) == original)
                if usesCurrentState {
                    #expect(try await cachedRemote.cachedRegistrationStates(scopes: scopes) == nil)
                    let changed = try await cachedRemote.registrationStates(scopes: scopes)
                    let social = try #require(changed.first { $0.owner.scope.key == scopes[2].key })
                    if case .pair(let facts) = social.facts { #expect(facts.blocked) }
                    else { Issue.record("expected blocked pair") }
                }
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.user_blocks WHERE blocker_user_id=\(bind: a) AND blocked_user_id=\(bind: b)").first(decoding: Count.self)?.value == 1)
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_changes WHERE committed").first(decoding: Count.self)?.value == 1)
                if let holder {
                    await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) { try await fence.install(holder) }
                }
                let conflict = try await localSocial.freezeSocialFixture(actorUserID: .init(uuid: a), targetUserID: .init(uuid: b),
                    operation: .userBlock(.init(uuid: operationID)), action: .userBlock(.unblock), now: Date())
                #expect(try await routedSocial.submitSocialOperation(conflict, now: Date()) == .fingerprintConflict)
                // Scope and command identity are checked before any seal or SQL effect.
                let mutation = V2DurablePolicyMutation.social(command)
                let forgedScope = try V2PolicyMutationWire(endpoint: "policy-1", scope: .init(account: b),
                    operationKey: mutation.operationKey, fingerprint: mutation.fingerprint, command: Data(mutation.json.utf8))
                await #expect(throws: V2PolicyAuthorizationLifecycleError.invalidTarget) {
                    try await V2PolicyMutationService(owners: directories[1], endpoint: "policy-1").mutatePolicy(forgedScope, deadline: .now + .seconds(5))
                }
                let preference = PostgresV2AccountPreferenceOperationStore(database: database,
                    projectionDelivery: SuccessfulProjectionDelivery(),
                    authorizationCoordinator: .init(controlDatabase: database, ownerDatabases: [:]))
                let preferenceCommand = try await preference.freezePreferenceFixture(owner: .init(uuid: b),
                    operation: .strangerMessagePreference(.init(uuid: UUID())), value: .strangerMessage(.deny), now: Date())
                let routedPreference = preference.usingPolicyOwners(remoteMutations)
                let preferenceResult = try await routedPreference.submit(preferenceCommand, now: Date())
                guard case .receipt(let preferenceReceipt) = preferenceResult else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                #expect(preferenceReceipt.outcome == .applied(value: .strangerMessage(.deny), revision: 1))
                #expect(try await routedPreference.submit(preferenceCommand, now: Date()) == preferenceResult)
                if usesCurrentState {
                    #expect(try await cachedRemote.cachedRegistrationStates(scopes: scopes) == nil)
                    let changed = try await cachedRemote.registrationStates(scopes: scopes)
                    let settings = try #require(changed.first { $0.owner.scope.key == scopes[3].key })
                    if case .stranger(let facts) = settings.facts { #expect(!facts.allowsStrangers) }
                    else { Issue.record("expected denied stranger messages") }
                }
                let disableService = try V2PostgresAccountDisableService(database: database, operatorPrincipal: "remote-policy-test",
                    authorizationCoordinator: .init(controlDatabase: database, ownerDatabases: [:])).usingPolicyOwners(remoteMutations)
                let disableCommand = try V2AccountDisableCommand(userID: .init(uuid: b), operationID: UUID(), reason: .policyEnforcement)
                let beforeDisable = try await remote.registrationStates(scopes: scopes)
                let disableHolder: V2PolicyAuthorizationHolder?
                if usesCurrentState { disableHolder = nil }
                else {
                    let permit = try await PostgresV2DirectPolicySnapshotStore(database: database).register(
                        pair: pair, states: beforeDisable, registrationID: UUID(), roomID: UUID(),
                        activationID: UUID(), roomOwnerEpoch: 1, endpoint: "room-b", durationSeconds: 20)
                    disableHolder = permit.holder
                    try await fence.install(permit.holder)
                }
                try await verifyDisableHTTP(service: disableService, command: disableCommand)
                let unavailable = PostgresV2RemotePolicyMutations(client: client, resolve: { _ in
                    throw V2RoomCallFailure.notAccepted(.unavailable)
                })
                try await verifyUnavailableDisableHTTP(service: disableService.usingPolicyOwners(unavailable), command: disableCommand)
                if let disableHolder {
                    await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) { try await fence.install(disableHolder) }
                }
                let disableResult = try await disableService.disable(disableCommand)
                guard case .idempotent(let disabledAt) = disableResult else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                #expect(try await disableService.disable(disableCommand) == .idempotent(disabledAt: disabledAt))
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.account_disables WHERE user_id=\(bind: b)").first(decoding: Count.self)?.value == 1)
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_changes WHERE committed").first(decoding: Count.self)?.value == 3)
                // Both domain mutations and the real operator HTTP route
                // have acknowledged. With fact tables hidden, authenticated
                // TCP reads must return the committed memory values.
                for table in hidden { try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_remote_hidden")").run() }
                let refreshed = try #require(try await remote.cachedRegistrationStates(scopes: scopes))
                if usesCurrentState {
                    #expect(try await cachedRemote.cachedRegistrationStates(scopes: scopes) == nil)
                    let nodeFacts = try await cachedRemote.registrationStates(scopes: scopes)
                    let disabled = try #require(nodeFacts.first { $0.owner.scope.key == scopes[1].key })
                    if case .account(let facts) = disabled.facts { #expect(!facts.isActive) }
                    else { Issue.record("expected disabled account") }
                }
                for table in hidden { try await sql.raw("ALTER TABLE im_v2.\(unsafeRaw: table + "_remote_hidden") RENAME TO \(unsafeRaw: table)").run() }
                if usesCurrentState {
                    #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_holders").first(decoding: Count.self)?.value == 0)
                    #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.room_policy_authorization_leases").first(decoding: Count.self)?.value == 0)
                    #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.policy_authorization_revocations").first(decoding: Count.self)?.value == 0)
                }
                guard let recipient = refreshed.first(where: { $0.owner.scope.key == scopes[1].key }),
                      case .account(let account) = recipient.facts,
                      let socialState = refreshed.first(where: { $0.owner.scope.key == scopes[2].key }),
                      case .pair(let social) = socialState.facts else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                #expect(!account.isActive && recipient.owner.revision == 2)
                let stranger = try #require(refreshed.first(where: { $0.owner.scope == .stranger(b) }))
                guard case .stranger(let settings) = stranger.facts else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                #expect(!settings.allowsStrangers && stranger.owner.revision == 2)
                #expect(social.blocked && socialState.owner.revision == 2)
                if !usesCurrentState {
                    await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) {
                        try await PostgresV2DirectPolicySnapshotStore(database: database).register(pair: pair, states: states,
                            registrationID: UUID(), roomID: UUID(), activationID: UUID(), roomOwnerEpoch: 1,
                            endpoint: "room-b", durationSeconds: 20)
                    }
                }
                // A signed response is not sufficient if durable ownership has moved.
                try await sql.raw("UPDATE \(unsafeRaw: schema).policy_authorization_scopes SET owner_valid_until=clock_timestamp()-interval '1 second' WHERE scope_key=\(bind: firstKey)").run()
                let successor = try await journal.acquireOwner(scope: scopes[0], ownerID: UUID(), durationSeconds: 30)
                #expect(successor.epoch == 2)
                await #expect(throws: usesCurrentState ? V2PolicyAuthorizationLifecycleError.invalidRequest : .ownerChanged) {
                    try await journal.register(owners: claims, registrationID: UUID(), roomID: UUID(),
                        activationID: UUID(), roomOwnerEpoch: 1, endpoint: "room-b", durationSeconds: 20)
                }
                await binding.close()
                await #expect(throws: V2PolicyAuthorizationLifecycleError.closed) { try await remote.registrationStates(scopes: scopes) }
                await #expect(throws: V2PolicyAuthorizationLifecycleError.closed) { try await binding.bind(client) }
            } catch {
                await client.stop()
                for inbound in inbounds { await inbound.stop() }
                for host in hosts { _ = await host.stop(deadline: .now + .seconds(5)) }
                for store in stores { await store.shutdownLifecycle(); await store.shutdownRenewals() }
                for cache in nodeCaches { await cache.shutdown() }
            for directory in directories { await directory.shutdown() }
                for system in systems.reversed() { try? await system.shutdown().wait() }
                throw error
            }
            withExtendedLifetime(endpoints) {}
            #expect(await client.quiesce(deadline: .now + .seconds(5)))
            await client.stop()
            for inbound in inbounds { #expect(await inbound.quiesce(deadline: .now + .seconds(5))); await inbound.stop() }
            for host in hosts { #expect(await host.stop(deadline: .now + .seconds(5)).completed) }
            for store in stores { await store.shutdownLifecycle(); await store.shutdownRenewals() }
            for cache in nodeCaches { await cache.shutdown() }
            for directory in directories { await directory.shutdown() }
            for system in systems.reversed() { try await system.shutdown().wait() }
        }
    }
    private func verifyDisableHTTP(service: V2PostgresAccountDisableService, command: V2AccountDisableCommand) async throws {
        let app = try await Application(.testing)
        do {
            let token = Data(repeating: 19, count: 32).base64EncodedString()
            V2VaporAccountDisableOperatorRoutes(authenticator: try .init(base64EncodedBearerToken: token),
                service: service).register(on: app)
            let input = V2AccountDisableHTTPRequest(operationID: command.operationID,
                userID: command.userID.rawValue, reason: command.reason)
            try await app.testing { client in
                let denied = try await client.send(.post, to: "internal/v2/accounts/disable", beforeSend: {
                    try $0.content.encode(input)
                })
                #expect(denied.status == .unauthorized)
                var timestamp: Int64?
                for outcome in ["disabled", "idempotent"] {
                    let response = try await client.send(.post, headers: [.authorization: "Bearer \(token)"],
                        to: "internal/v2/accounts/disable", beforeSend: { try $0.content.encode(input) })
                    #expect(response.status == .ok)
                    #expect(response.headers[.cacheControl] == "no-store")
                    #expect(response.headers[.pragma] == "no-cache")
                    let body = try await response.content.decode(V2AccountDisableHTTPResponse.self)
                    #expect(body.operationID == command.operationID && body.outcome == outcome)
                    if let timestamp { #expect(body.disabledAtMilliseconds == timestamp) }
                    else { timestamp = body.disabledAtMilliseconds }
                }
                let conflict = V2AccountDisableHTTPRequest(operationID: command.operationID,
                    userID: command.userID.rawValue, reason: .credentialCompromise)
                let response = try await client.send(.post, headers: [.authorization: "Bearer \(token)"],
                    to: "internal/v2/accounts/disable", beforeSend: { try $0.content.encode(conflict) })
                #expect(response.status == .conflict)
            }
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    private func verifyUnavailableDisableHTTP(service: V2PostgresAccountDisableService,
        command: V2AccountDisableCommand) async throws {
        let app = try await Application(.testing)
        do {
            let token = Data(repeating: 20, count: 32).base64EncodedString()
            V2VaporAccountDisableOperatorRoutes(authenticator: try .init(base64EncodedBearerToken: token),
                service: service).register(on: app)
            let input = V2AccountDisableHTTPRequest(operationID: command.operationID,
                userID: command.userID.rawValue, reason: command.reason)
            try await app.testing { client in
                let response = try await client.send(.post, headers: [.authorization: "Bearer \(token)"],
                    to: "internal/v2/accounts/disable", beforeSend: { try $0.content.encode(input) })
                // The local database is available and already has a receipt.
                // Missing owner routing must not fall back to the legacy writer.
                #expect(response.status == .serviceUnavailable)
                #expect(response.headers[.cacheControl] == "no-store")
                #expect(response.headers[.pragma] == "no-cache")
                #expect((try await response.body.data() ?? Data()).isEmpty)
            }
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    private struct WireCount: Decodable { let value: Int64 }

    private func settings(_ name: String, _ port: Int) -> ClusterSystemSettings {
        var settings = ClusterSystemSettings(name: name, host: "127.0.0.1", port: port)
        settings.threadPoolSize = 1
        settings.serialization.registerInbound(V2ActorAuthenticationError.self)
        settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [V2ActorAuthenticationError.self])
        return settings
    }
    private struct Count: Decodable { let value: Int64 }
}

private actor PolicyStateResponseOverride: V2PolicyOwnershipServing {
    enum Mode { case normal, expiresDuringTransit, wrongAccount }
    private let service: V2PolicyOwnershipService
    private var mode = Mode.normal
    private(set) var claims = 0
    init(service: V2PolicyOwnershipService) { self.service = service }
    func set(_ mode: Mode) { self.mode = mode }
    func invalidatePolicyCache(_ request: V2PolicyCacheInvalidationWire, deadline: ContinuousClock.Instant) async throws {
        try await service.invalidatePolicyCache(request, deadline: deadline)
    }
    func claimPolicyOwnership(_ request: V2PolicyOwnershipClaimWire, deadline: ContinuousClock.Instant) async throws -> [V2PolicyOwnerStateWire] {
        claims += 1
        let selected = mode
        let states = try await service.claimPolicyOwnership(request, deadline: deadline)
        return try states.map { original in
            switch selected {
            case .normal: return original
            case .expiresDuringTransit:
                return try .init(owner: original.owner, facts: original.facts, remainingSeconds: 1e-9)
            case .wrongAccount:
                let facts = V2PolicyOwnerFacts.account(.init(userID: UUID(), isActive: true, specialKind: nil,
                    specialStatus: nil, allowsServiceMessages: nil, allowsCustomerMessages: nil))
                return try .init(owner: original.owner, facts: JSONEncoder().encode(facts), remainingSeconds: original.remainingSeconds)
            }
        }
    }
}

private actor PolicyBusyWireGate {
    private(set) var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
