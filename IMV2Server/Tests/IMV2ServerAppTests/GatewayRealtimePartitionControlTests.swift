import Foundation
import Crypto
import DistributedCluster
import IMV2Core
@testable import IMV2ActorCluster
import FluentKit
import FluentPostgresDriver
import IMV2ActorContracts
import IMV2Server
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ServerInfrastructure
import Logging
import NIOPosix
import SQLKit
import Synchronization
import Testing
import Vapor
@testable import IMV2ServerApp

@Suite("Production realtime partition lease controller", .serialized, .timeLimit(.minutes(1)))
struct GatewayRealtimePartitionControlTests {
    @Test("A standby starts against the committed roster without claiming a lease")
    func standbyControllerDoesNotAcquireAuthority() async throws {
        let identity = V2GatewayRealtimeIdentity(nodeID: "b", serviceID: "b", incarnationID: UUID())
        let roster: Set<String> = ["a"]
        let qualification = try V2ActorServiceQualification(localNodeID: "b",
            membership: .init(revision: 1, current: roster), allowNonMember: true)
        let store = PartitionControllerControlledStore()
        let installations = Mutex<[GatewayRealtimePartitionControl.Installed]>([])
        let controller = try GatewayRealtimePartitionControl(identity: identity, roster: roster,
            store: store, qualification: qualification, availableHosts: { ["a", "b"] },
            install: { values in installations.withLock { $0 = values } })
        try await controller.start()
        #expect(qualification.snapshot() == nil)
        #expect(await store.counts().claims == 0)
        #expect(await store.counts().renewals == 0)
        #expect(await controller.pressureSnapshot().installed == 0)
        #expect(installations.withLock { $0.isEmpty })
        try await controller.shutdown()
    }

    @Test("Qualification recovery wakes the serial lease worker before its periodic tick")
    func qualificationRecoveryDoesNotWaitForPeriodicTick() async throws {
        let identity = V2GatewayRealtimeIdentity(nodeID: "a", serviceID: "a", incarnationID: UUID())
        let roster: Set<String> = ["a", "b", "c"]
        let qualification = try V2ActorServiceQualification(localNodeID: "a", roster: roster)
        let store = PartitionControllerControlledStore()
        let controller = try GatewayRealtimePartitionControl(identity: identity, roster: roster,
            store: store, qualification: qualification, availableHosts: { roster }, install: { _ in })
        try await controller.start()
        #expect(await store.counts().claims == 0)
        qualification.update(witnesses: ["b": .now + .seconds(30)], membershipRevision: 1)
        await controller.qualificationDidChange()
        let deadline = ContinuousClock.now + .seconds(1)
        while await controller.pressureSnapshot().installed == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await controller.pressureSnapshot().installed > 0)
        #expect(await store.counts().claims == 1)
        try await controller.shutdown()
        #expect(await store.retainedCount() == 0)
    }

    @Test("A fixed three-voter roster without a majority never claims or renews")
    func unqualifiedControllerDoesNotAcquireAuthority() async throws {
        let identity = V2GatewayRealtimeIdentity(nodeID: "a", serviceID: "a", incarnationID: UUID())
        let roster: Set<String> = ["a", "b", "c"]
        let qualification = try V2ActorServiceQualification(localNodeID: "a", roster: roster)
        let store = PartitionControllerControlledStore()
        let controller = try GatewayRealtimePartitionControl(identity: identity, roster: roster, store: store,
            qualification: qualification, availableHosts: { ["a"] }, install: { _ in })
        try await controller.start()
        #expect(await store.counts().claims == 0)
        #expect(await store.counts().renewals == 0)
        #expect(await controller.pressureSnapshot().installed == 0)
        try await controller.shutdown()
    }

    @Test("Revocation or membership change withdraws service while an actual renewal is still pending", arguments: [false, true])
    func qualificationLossFencesLateRenewal(membershipChange: Bool) async throws {
        let identity = V2GatewayRealtimeIdentity(nodeID: "a", serviceID: "a", incarnationID: UUID())
        let roster: Set<String> = ["a", "b", "c"]
        let qualification = try V2ActorServiceQualification(localNodeID: "a", roster: roster)
        qualification.update(witnesses: ["b": .now + .seconds(30)], membershipRevision: 1)
        let gate = PartitionControllerGate()
        let recoveryGate = PartitionControllerGate()
        let store = PartitionControllerControlledStore(renewGate: gate, recoveryClaimGate: recoveryGate)
        let installations = Mutex<[GatewayRealtimePartitionControl.Installed]>([])
        let controller = try GatewayRealtimePartitionControl(identity: identity, roster: roster, store: store,
            qualification: qualification, availableHosts: { roster },
            install: { values in installations.withLock { $0 = values } })
        do {
            try await controller.start()
            #expect(!installations.withLock { $0.isEmpty })
            await gate.waitEntered() // The unchanged production five-second tick.
            if membershipChange {
                try qualification.installMembership(.init(revision: 2, current: roster, next: ["a", "c", "d"]))
            } else { qualification.revoke() }
            await controller.qualificationDidChange()
            #expect(installations.withLock { $0.isEmpty })
            #expect(await controller.pressureSnapshot().installed == 0)
            #expect(await store.counts().releases == 0) // No cleanup races actual renewal SQL.
            // A fresh proof must not authorize the response submitted by the old proof.
            qualification.update(witnesses: ["c": .now + .seconds(30)], membershipRevision: membershipChange ? 2 : 1)
            await controller.qualificationDidChange()
            await gate.release()
            let settleDeadline = ContinuousClock.now + .seconds(2)
            while await store.counts().releases == 0, ContinuousClock.now < settleDeadline { await Task.yield() }
            await recoveryGate.waitEntered()
            #expect(await controller.pressureSnapshot().installed == 0)
            #expect(installations.withLock { $0.isEmpty }) // Old renewal did not restore service.
            await recoveryGate.release()
            try await controller.shutdown()
            #expect(installations.withLock { $0.isEmpty })
            let counts = await store.counts()
            #expect(counts.claims == 2 && counts.renewals == 1 && counts.releases > 0)
            #expect(await store.retainedCount() == 0)
        } catch {
            await gate.release(); await recoveryGate.release(); try? await controller.shutdown(); throw error
        }
    }

    @Test("Closing during an actual claim cannot install its late authority")
    func closedControllerDrainsLateClaim() async throws {
        let identity = V2GatewayRealtimeIdentity(nodeID: "a", serviceID: "a", incarnationID: UUID())
        let roster: Set<String> = ["a", "b", "c"]
        let qualification = try V2ActorServiceQualification(localNodeID: "a", roster: roster)
        qualification.update(witnesses: ["b": .now + .seconds(30)], membershipRevision: 1)
        let gate = PartitionControllerGate()
        let store = PartitionControllerControlledStore(claimGate: gate)
        let nonemptyInstalls = Mutex(0)
        let controller = try GatewayRealtimePartitionControl(identity: identity, roster: roster, store: store,
            qualification: qualification, availableHosts: { roster }, install: { values in
                if !values.isEmpty { nonemptyInstalls.withLock { $0 += 1 } }
            })
        let start = Task { try await controller.start() }
        await gate.waitEntered()
        let finished = Mutex(false)
        let shutdown = Task { try await controller.shutdown(); finished.withLock { $0 = true } }
        for _ in 0..<20 { await Task.yield() }
        #expect(!finished.withLock { $0 })
        #expect(await store.counts().releases == 0)
        await gate.release()
        _ = try? await start.value
        try await shutdown.value
        #expect(nonemptyInstalls.withLock { $0 } == 0)
        #expect(await store.retainedCount() == 0)
        #expect(await store.counts().releases == 1)
    }

    @Test("Unavailable control storage preserves only the original lease's signed cached service")
    func unavailableControlStoreDoesNotRefreshCachedAuthority() async throws {
        guard let url = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" else { return }
        let resources = V2DatabaseResources(eventLoopGroup: MultiThreadedEventLoopGroup(numberOfThreads: 1),
            logger: Logger(label: "imv2.control.outage.tests"), ownsEventLoopGroup: true, threadPoolThreads: 1)
        let schema = "imv2_outage_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let hostPort = Int.random(in: 30_000...44_999), viewerPort = Int.random(in: 45_000...60_000)
        var hostSettings = ClusterSystemSettings(name: "control-outage-host", host: "127.0.0.1", port: hostPort)
        hostSettings.threadPoolSize = 1; hostSettings.downingStrategy = .none; hostSettings.onDownAction = .none
        var viewerSettings = ClusterSystemSettings(name: "control-outage-viewer", host: "127.0.0.1", port: viewerPort)
        viewerSettings.threadPoolSize = 1; viewerSettings.downingStrategy = .none; viewerSettings.onDownAction = .none
        let hostSystem = await ClusterSystem("control-outage-host", settings: hostSettings)
        let viewerSystem = await ClusterSystem("control-outage-viewer", settings: viewerSettings)
        var controller: GatewayRealtimePartitionControl?
        var hostShard: V2RealtimeShardTransportHandle?, viewerShard: V2RealtimeShardTransportHandle?
        var hostDelivery: V2RealtimeTransportHandle?, viewerDelivery: V2RealtimeTransportHandle?
        var service: V2RealtimeShardService?, outage: PartitionControllerUnavailableStore?
        do {
            resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let authority = try String(contentsOf: root.appending(path: "IMV2/sql/schema.sql"), encoding: .utf8)
            let begin = try #require(authority.range(of: "CREATE TABLE im_v2.realtime_partition_leases ("))
            let end = try #require(authority.range(of: "CREATE TABLE im_v2.user_sync_wake_outbox (", range: begin.upperBound..<authority.endIndex))
            try await sql.raw("CREATE SCHEMA \(unsafeRaw:schema)").run()
            for statement in authority[begin.lowerBound..<end.lowerBound].replacingOccurrences(of: "im_v2", with: schema)
                .split(separator: ";") where !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await sql.raw("\(unsafeRaw:String(statement))").run()
            }
            let hostKey = Curve25519.Signing.PrivateKey(), viewerKey = Curve25519.Signing.PrivateKey()
            let hostSigner = try V2ActorSigningIdentity(serviceID: V2ActorServiceID("outage-host"), privateKey: hostKey.rawRepresentation)
            let viewerSigner = try V2ActorSigningIdentity(serviceID: V2ActorServiceID("outage-viewer"), privateKey: viewerKey.rawRepresentation)
            let hostID = V2GatewayRealtimeIdentity(nodeID: "outage-host", serviceID: hostSigner.serviceID.rawValue, incarnationID: UUID())
            let viewerID = V2GatewayRealtimeIdentity(nodeID: "outage-viewer", serviceID: viewerSigner.serviceID.rawValue, incarnationID: UUID())
            let trust = try V2ActorTrustStore(services: [
                .init(serviceID: hostSigner.serviceID, publicKey: hostKey.publicKey.rawRepresentation,
                      permissions: [.realtimePublish, .realtimeReceive], gatewayNodeIDs: [hostID.nodeID]),
                .init(serviceID: viewerSigner.serviceID, publicKey: viewerKey.publicKey.rawRepresentation,
                      permissions: [.realtimePublish, .realtimeReceive], gatewayNodeIDs: [viewerID.nodeID])
            ])
            let peers: [V2RealtimeShardDiscoveryPeer] = [
                .init(nodeID: hostID.nodeID, serviceID: hostID.serviceID, address: "127.0.0.1", port: hostPort),
                .init(nodeID: viewerID.nodeID, serviceID: viewerID.serviceID, address: "127.0.0.1", port: viewerPort)
            ]
            let roster = Set(peers.map(\.nodeID)), qualification = try V2ActorServiceQualification(localNodeID: hostID.nodeID, roster: roster)
            let access: [V2ActorServiceID: Set<String>] = [hostSigner.serviceID: ["rooms"], viewerSigner.serviceID: ["rooms"]]
            let ingress = PartitionOutageIngress()
            let hd = try buildRealtimeTransport(system: hostSystem, identity: hostID, address: "127.0.0.1", port: hostPort,
                signer: hostSigner, trust: trust, ingress: ingress, serviceOwnerAccess: access, limits: .init())
            hostDelivery = hd
            let vd = try buildRealtimeTransport(system: viewerSystem, identity: viewerID, address: "127.0.0.1", port: viewerPort,
                signer: viewerSigner, trust: trust, ingress: ingress, serviceOwnerAccess: access, limits: .init())
            viewerDelivery = vd
            let serving = V2RealtimeShardService(qualification: qualification, send: { target, batch in try await hd.send(batch, to: target) })
            service = serving
            let hs = try buildRealtimeShardTransport(system: hostSystem, identity: hostID, address: "127.0.0.1", port: hostPort,
                signer: hostSigner, trust: trust, serving: serving, serviceOwnerAccess: access, discoveryPeers: peers,
                limits: .init(), serviceQualification: qualification)
            hostShard = hs
            let vs = try buildRealtimeShardTransport(system: viewerSystem, identity: viewerID, address: "127.0.0.1", port: viewerPort,
                signer: viewerSigner, trust: trust, serving: PartitionOutageUnusedServing(), serviceOwnerAccess: access,
                discoveryPeers: peers, limits: .init())
            viewerShard = vs
            await hs.start(); await vs.start()
            let qualifiedDeadline = ContinuousClock.now + .seconds(10)
            while qualification.snapshot() == nil {
                guard ContinuousClock.now < qualifiedDeadline else { throw V2ActorAuthenticationError.sessionExpired }
                await Task.yield()
            }
            let actual = try PostgresV2RealtimePartitionLeaseStore(database: database, schema: schema)
            let failing = PartitionControllerUnavailableStore(underlying: actual)
            outage = failing
            let installation = PartitionOutageInstallation(service: serving, handle: hs)
            let value = try GatewayRealtimePartitionControl(identity: hostID, roster: roster, store: failing,
                qualification: qualification, availableHosts: { await hs.reachableNodeIDs() },
                install: { values in try await installation.apply(values) })
            controller = value
            await hs.setQualificationObserver { await value.qualificationDidChange() }
            try await value.start()
            let first = try #require(await installation.values.first)
            var room = try RoomID(UUID().uuidString)
            while V2RealtimeTopicKey(kind: .roomEvents, id: room.rawValue).partitionID() != first.token.partitionID {
                room = try RoomID(UUID().uuidString)
            }
            let topic = V2RealtimeTopic(kind: .roomEvents, id: room.rawValue, owner: try V2RoomDataOwner(shardID: "rooms", epoch: 1))
            let descriptor = try await vs.resolve(partitionID: first.token.partitionID)
            #expect(descriptor.token == first.token)
            let session = V2RealtimeShardSession(gateway: vd.descriptor, sessionID: UUID(), sessionGeneration: 1)
            let interests = [V2RealtimeShardInterest(key: .init(topic), interestGeneration: 1)]
            let mutation = V2RealtimeShardMutation.snapshotChunk(snapshotID: UUID(), index: 0, total: 1,
                digest: try V2RealtimeShardFingerprint.snapshot(interests), interests: interests)
            let request = V2RealtimeShardControlRequest(token: first.token, session: session, baseRevision: 0, nextRevision: 1,
                mutation: mutation, payloadFingerprint: try V2RealtimeShardFingerprint.control(token: first.token,
                    session: session, baseRevision: 0, nextRevision: 1, mutation: mutation))
            let initialControl = try await vs.control(descriptor, request: request)
            #expect(initialControl.status == .applied, "initial snapshot: \(initialControl)")
            let committed = try await sql.raw("SELECT partition_id,lease_epoch,lease_token,expires_at FROM \(unsafeRaw:schema).realtime_partition_leases ORDER BY partition_id").all(decoding: PartitionControllerRow.self)
            await failing.waitUnavailable() // Actual unchanged five-second Controller renewal attempt.
            let before = await vs.metricsSnapshot()
            let firstPublication = try await vs.publish(descriptor, request: .init(token: first.token, topic: topic,
                payload: .roomWake(roomID: room, highWatermark: 1)))
            #expect(firstPublication == .accepted, "cached publication during storage failure: \(firstPublication)")
            #expect(ingress.count.withLock { $0 } == 1)
            // Subscriber sessions have their own heartbeat. The first snapshot
            // was capped by the initial qualification deadline (~20s); later
            // partition qualification refresh must NOT implicitly renew it.
            // Keep that same session via actual signed Actor control, exactly
            // as production does, without a storage call or revision mutation.
            let renewMutation = V2RealtimeShardMutation.renew
            let renewRequest = V2RealtimeShardControlRequest(token: first.token, session: session,
                baseRevision: 0, nextRevision: 0, mutation: renewMutation,
                payloadFingerprint: try V2RealtimeShardFingerprint.control(token: first.token, session: session,
                    baseRevision: 0, nextRevision: 0, mutation: renewMutation))
            let lateObservation = first.databaseDeadline - .seconds(2)
            while ContinuousClock.now < lateObservation {
                let currentDescriptor = try await vs.resolve(partitionID: first.token.partitionID)
                let renewalBegan = ContinuousClock.now
                let renewed = try await vs.control(currentDescriptor, request: renewRequest)
                #expect(renewed.status == .applied && renewed.appliedRevision == 1,
                    "same-session heartbeat while storage unavailable: \(renewed)")
                let originalRemaining = renewalBegan.duration(to: first.databaseDeadline).components
                let originalBound = originalRemaining.seconds * 1_000 + originalRemaining.attoseconds / 1_000_000_000_000_000
                #expect(renewed.remainingSessionMilliseconds <= originalBound,
                    "session heartbeat must not extend original database authority")
                try await ContinuousClock().sleep(until: min(.now + .seconds(5), lateObservation))
            }
            // This observes the ORIGINAL DB deadline, not a virtual clock or altered TTL.
            let cached = try await vs.resolve(partitionID: first.token.partitionID)
            #expect(cached.token == first.token && cached.remainingLeaseMilliseconds <= 2_000)
            let latePublication = try await vs.publish(cached, request: .init(token: first.token, topic: topic,
                payload: .roomWake(roomID: room, highWatermark: 2)))
            #expect(latePublication == .accepted, "late cached publication: \(latePublication)")
            #expect(ingress.count.withLock { $0 } == 2)
            #expect(await installation.deadlineNeverExpanded)
            #expect(try await sql.raw("SELECT partition_id,lease_epoch,lease_token,expires_at FROM \(unsafeRaw:schema).realtime_partition_leases ORDER BY partition_id").all(decoding: PartitionControllerRow.self) == committed)
            try await ContinuousClock().sleep(until: first.databaseDeadline)
            let withdrewDeadline = ContinuousClock.now + .seconds(2)
            while await value.pressureSnapshot().installed != 0 {
                guard ContinuousClock.now < withdrewDeadline else { throw V2ActorAuthenticationError.sessionExpired }
                await Task.yield()
            }
            await #expect(throws: (any Error).self) {
                _ = try await vs.publish(descriptor, request: .init(token: first.token, topic: topic,
                    payload: .roomWake(roomID: room, highWatermark: 3)))
            }
            #expect(ingress.count.withLock { $0 } == 2)
            // Also exercise the server's synchronous fence: rejection is not
            // merely the caller refusing an expired cached advertisement.
            #expect(try await serving.publish(.init(token: first.token, topic: topic,
                payload: .roomWake(roomID: room, highWatermark: 3))) == .retiredEpoch)
            #expect(ingress.count.withLock { $0 } == 2)
            let after = await vs.metricsSnapshot()
            #expect(after.cacheMisses == before.cacheMisses && after.publishStarted - before.publishStarted == 2)
            #expect(after.publishSettled - before.publishSettled == 2)
            await failing.restoreForCleanup()
            try await value.shutdown()
            await serving.shutdown()
            #expect(await hs.stop(deadline: .now + .seconds(3)))
            #expect(await vs.stop(deadline: .now + .seconds(3)))
            #expect(await hd.stop(deadline: .now + .seconds(3)))
            #expect(await vd.stop(deadline: .now + .seconds(3)))
            #expect(try await actual.confirm(await failing.initialLeases).isEmpty)
            try await sql.raw("DROP SCHEMA \(unsafeRaw:schema) CASCADE").run()
            try await resources.shutdown()
            try await hostSystem.shutdown().wait(); try await viewerSystem.shutdown().wait()
        } catch {
            await outage?.restoreForCleanup()
            try? await controller?.shutdown(); await service?.shutdown()
            _ = await hostShard?.stop(deadline: .now + .seconds(3)); _ = await viewerShard?.stop(deadline: .now + .seconds(3))
            _ = await hostDelivery?.stop(deadline: .now + .seconds(3)); _ = await viewerDelivery?.stop(deadline: .now + .seconds(3))
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS \(unsafeRaw:schema) CASCADE").run() }
            try? await resources.shutdown()
            try? await hostSystem.shutdown().wait(); try? await viewerSystem.shutdown().wait()
            throw error
        }
    }

    @Test("Unknown claim confirms its original token and shutdown waits for actual controller settlement")
    func confirmedClaimRetryAndActualShutdown() async throws {
        guard let url = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" else { return }
        let resources = V2DatabaseResources(eventLoopGroup: MultiThreadedEventLoopGroup(numberOfThreads: 1),
            logger: Logger(label: "imv2.partition.controller.tests"), ownsEventLoopGroup: true, threadPoolThreads: 1)
        let schema = "imv2_controller_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var controller: GatewayRealtimePartitionControl?
        let gate = PartitionControllerGate()
        do {
            resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
            // Install the exact checked-in control table, not a reduced authority fixture.
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let authority = try String(contentsOf: root.appending(path: "IMV2/sql/schema.sql"), encoding: .utf8)
            let start = try #require(authority.range(of: "CREATE TABLE im_v2.realtime_partition_leases ("))
            let end = try #require(authority.range(of: "CREATE TABLE im_v2.user_sync_wake_outbox (", range: start.upperBound..<authority.endIndex))
            let statements = authority[start.lowerBound..<end.lowerBound].replacingOccurrences(of: "im_v2", with: schema)
            try await sql.raw("CREATE SCHEMA \(unsafeRaw:schema)").run()
            for statement in statements.split(separator: ";") where !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await sql.raw("\(unsafeRaw:String(statement))").run()
            }
            let identity = V2GatewayRealtimeIdentity(nodeID: "controller", serviceID: "controller", incarnationID: UUID())
            let actual = try PostgresV2RealtimePartitionLeaseStore(database: database, schema: schema)
            let forwarding = PartitionControllerFaultStore(underlying: actual, gate: gate)
            let installations = Mutex<[GatewayRealtimePartitionControl.Installed]>([])
            let value = try GatewayRealtimePartitionControl(identity: identity, roster: [identity.nodeID], store: forwarding,
                qualification: try .init(localNodeID: identity.nodeID, roster: [identity.nodeID]),
                availableHosts: { [identity.nodeID] }, install: { values in installations.withLock { $0 = values } })
            controller = value
            await #expect(throws: V2RoomCallFailure.outcomeUnknown) { try await value.start() }
            #expect(installations.withLock { $0.isEmpty })
            func rows() async throws -> [PartitionControllerRow] {
                try await sql.raw("SELECT partition_id,lease_epoch,lease_token,expires_at FROM \(unsafeRaw:schema).realtime_partition_leases ORDER BY partition_id").all(decoding: PartitionControllerRow.self)
            }
            let committed = try await rows()
            #expect(committed.count == 256 && committed.allSatisfy { $0.epoch == 1 && $0.token != nil })
            try await value.start()
            #expect(try await rows() == committed) // Confirming uncertainty never refreshes the original expiry.
            let tokens = await forwarding.claimTokens
            #expect(tokens.count == 2 && Set(tokens).count == 1)
            let bounds = await forwarding.confirmationBounds
            #expect(installations.withLock { values in values.allSatisfy { $0.deadline <= bounds[$0.lease.partitionID]! } })
            #expect(installations.withLock { $0.count == 256 && $0.allSatisfy { $0.deadline > .now } })
            await gate.waitEntered() // The production five-second renewal tick, after real SQL COMMIT.
            let finished = Mutex(false)
            let shutdown = Task { try await value.shutdown(); finished.withLock { $0 = true } }
            let again = Task { try await value.shutdown() }
            for _ in 0..<20 { await Task.yield() }
            #expect(!finished.withLock { $0 })
            await gate.release()
            try await shutdown.value; try await again.value
            #expect(installations.withLock { $0.isEmpty })
            #expect(try await actual.confirm(await forwarding.lastConfirmed()).isEmpty)
            try await sql.raw("DROP SCHEMA \(unsafeRaw:schema) CASCADE").run()
            try await resources.shutdown()
        } catch {
            await gate.release()
            try? await controller?.shutdown()
            if let sql = resources.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS \(unsafeRaw:schema) CASCADE").run()
            }
            try? await resources.shutdown()
            throw error
        }
    }
}

private struct PartitionControllerRow: Decodable, Equatable {
    let id: Int; let epoch: Int64; let token: UUID?; let expiry: Date
    enum CodingKeys: String, CodingKey { case id = "partition_id", epoch = "lease_epoch", token = "lease_token", expiry = "expires_at" }
}
private actor PartitionControllerFaultStore: V2RealtimePartitionLeaseStore {
    let underlying: PostgresV2RealtimePartitionLeaseStore
    let gate: PartitionControllerGate
    var claimTokens: [UUID] = []
    var confirmed: [V2RealtimePartitionLease] = []
    var confirmationBounds: [Int:ContinuousClock.Instant] = [:]
    init(underlying: PostgresV2RealtimePartitionLeaseStore, gate: PartitionControllerGate) { self.underlying = underlying; self.gate = gate }
    func lastConfirmed() -> [V2RealtimePartitionLease] { confirmed }
    func claim(partitionIDs: [Int], identity: V2GatewayRealtimeIdentity, token: UUID, leaseDuration: TimeInterval) async throws -> [V2RealtimePartitionLease] {
        claimTokens.append(token)
        let began = ContinuousClock.now
        let result = try await underlying.claim(partitionIDs: partitionIDs, identity: identity, token: token, leaseDuration: leaseDuration)
        confirmed = result
        confirmationBounds = Dictionary(uniqueKeysWithValues: result.map { ($0.partitionID, began + .seconds($0.remainingLeaseSeconds) - .milliseconds(500)) })
        if claimTokens.count == 1 { throw V2RoomCallFailure.outcomeUnknown }
        return result
    }
    func renew(_ leases: [V2RealtimePartitionLease], leaseDuration: TimeInterval) async throws -> [V2RealtimePartitionLease] {
        _ = try await underlying.renew(leases, leaseDuration: leaseDuration)
        await gate.enter()
        throw V2RoomCallFailure.outcomeUnknown // SQL is confirmed; the controller still cannot use an uncertain response.
    }
    func confirm(_ leases: [V2RealtimePartitionLease]) async throws -> [V2RealtimePartitionLease] { try await underlying.confirm(leases) }
    func release(_ leases: [V2RealtimePartitionLease]) async throws { try await underlying.release(leases) }
}
private actor PartitionControllerGate {
    var entered = false, released = false
    var blocked: CheckedContinuation<Void,Never>?
    var observers: [CheckedContinuation<Void,Never>] = []
    func enter() async {
        entered = true; for observer in observers { observer.resume() }; observers.removeAll()
        if !released { await withCheckedContinuation { blocked = $0 } }
    }
    func waitEntered() async { if !entered { await withCheckedContinuation { observers.append($0) } } }
    func release() { released = true; blocked?.resume(); blocked = nil }
}

/// Controlled storage preserves actual future settlement independently of the
/// caller's cancellation. These tests exercise the production controller, not
/// its rendezvous implementation or PostgreSQL authority semantics.
private actor PartitionControllerControlledStore: V2RealtimePartitionLeaseStore {
    let claimGate: PartitionControllerGate?
    let renewGate: PartitionControllerGate?
    let recoveryClaimGate: PartitionControllerGate?
    var claims = 0, renewals = 0, releases = 0
    var retained: [Int: V2RealtimePartitionLease] = [:]
    init(claimGate: PartitionControllerGate? = nil, renewGate: PartitionControllerGate? = nil,
         recoveryClaimGate: PartitionControllerGate? = nil) {
        self.claimGate = claimGate; self.renewGate = renewGate; self.recoveryClaimGate = recoveryClaimGate
    }
    func counts() -> (claims: Int, renewals: Int, releases: Int) { (claims, renewals, releases) }
    func retainedCount() -> Int { retained.count }
    func claim(partitionIDs: [Int], identity: V2GatewayRealtimeIdentity, token: UUID,
        leaseDuration: TimeInterval) async throws -> [V2RealtimePartitionLease] {
        claims += 1
        if claims > 1, let recoveryClaimGate { await recoveryClaimGate.enter() }
        let leases = partitionIDs.map { V2RealtimePartitionLease(partitionID: $0, identity: identity,
            epoch: 1, token: token, remainingLeaseSeconds: leaseDuration) }
        for lease in leases { retained[lease.partitionID] = lease }
        if let claimGate { await claimGate.enter() }
        return leases
    }
    func renew(_ leases: [V2RealtimePartitionLease], leaseDuration: TimeInterval) async throws -> [V2RealtimePartitionLease] {
        renewals += 1
        if let renewGate { await renewGate.enter() }
        return leases.map { .init(partitionID: $0.partitionID, identity: $0.identity,
            epoch: $0.epoch, token: $0.token, remainingLeaseSeconds: leaseDuration) }
    }
    func confirm(_ leases: [V2RealtimePartitionLease]) async throws -> [V2RealtimePartitionLease] {
        leases.filter { retained[$0.partitionID]?.token == $0.token }
    }
    func release(_ leases: [V2RealtimePartitionLease]) async throws {
        releases += 1
        for lease in leases where retained[lease.partitionID]?.token == lease.token
            && retained[lease.partitionID]?.epoch == lease.epoch { retained.removeValue(forKey: lease.partitionID) }
    }
}

private actor PartitionControllerUnavailableStore: V2RealtimePartitionLeaseStore {
    enum Failure: Error { case unavailable }
    let underlying: PostgresV2RealtimePartitionLeaseStore
    var unavailable = false
    var cleanupAllowed = false
    var initialLeases: [V2RealtimePartitionLease] = []
    var observers: [CheckedContinuation<Void, Never>] = []
    init(underlying: PostgresV2RealtimePartitionLeaseStore) { self.underlying = underlying }
    func waitUnavailable() async { if !unavailable { await withCheckedContinuation { observers.append($0) } } }
    func restoreForCleanup() { cleanupAllowed = true }
    func claim(partitionIDs: [Int], identity: V2GatewayRealtimeIdentity, token: UUID, leaseDuration: TimeInterval) async throws -> [V2RealtimePartitionLease] {
        guard !unavailable else { throw Failure.unavailable }
        let leases = try await underlying.claim(partitionIDs: partitionIDs, identity: identity, token: token, leaseDuration: leaseDuration)
        initialLeases = leases; return leases
    }
    func renew(_ leases: [V2RealtimePartitionLease], leaseDuration: TimeInterval) async throws -> [V2RealtimePartitionLease] {
        unavailable = true
        for observer in observers { observer.resume() }; observers.removeAll()
        throw Failure.unavailable // No database call: no uncertain extension is hidden from the test.
    }
    func confirm(_ leases: [V2RealtimePartitionLease]) async throws -> [V2RealtimePartitionLease] {
        guard !unavailable else { throw Failure.unavailable }; return try await underlying.confirm(leases)
    }
    func release(_ leases: [V2RealtimePartitionLease]) async throws {
        guard !unavailable || cleanupAllowed else { throw Failure.unavailable }; try await underlying.release(leases)
    }
}
private actor PartitionOutageInstallation {
    let service: V2RealtimeShardService
    let handle: V2RealtimeShardTransportHandle
    var values: [GatewayRealtimePartitionControl.Installed] = []
    var bounds: [V2RealtimeShardToken: ContinuousClock.Instant] = [:]
    var deadlineNeverExpanded = true
    init(service: V2RealtimeShardService, handle: V2RealtimeShardTransportHandle) { self.service = service; self.handle = handle }
    func apply(_ next: [GatewayRealtimePartitionControl.Installed]) async throws {
        let previous = values; values = next
        for value in previous where !next.contains(where: { $0.token == value.token }) { await service.retire(token: value.token) }
        var advertisements: [V2RealtimeShardLeaseAdvertisement] = []
        for value in next {
            if let bound = bounds[value.token] { deadlineNeverExpanded = deadlineNeverExpanded && value.databaseDeadline <= bound && value.deadline <= bound }
            else { bounds[value.token] = value.databaseDeadline }
            await service.install(token: value.token, deadline: value.deadline, qualificationGeneration: value.qualificationGeneration)
            let remaining = ContinuousClock.now.duration(to: value.deadline).components
            let milliseconds = remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000
            if milliseconds > 0 { advertisements.append(.init(token: value.token, remainingLeaseMilliseconds: milliseconds)) }
        }
        try await handle.installPartitions(advertisements)
    }
}
private final class PartitionOutageIngress: V2RealtimeIngress, Sendable {
    let count = Mutex(0)
    func offer(_ batch: V2RealtimeBatch) -> V2RealtimeAcceptance { count.withLock { $0 += 1 }; return .accepted }
}
private struct PartitionOutageUnusedServing: V2RealtimeShardServing {
    func control(_ request: V2RealtimeShardControlRequest) async throws -> V2RealtimeShardControlReply {
        .init(appliedRevision: 0, remainingSessionMilliseconds: 0, status: .notInstalled)
    }
    func publish(_ request: V2RealtimeShardPublishRequest) async throws -> V2RealtimeShardPublishReply { .notInstalled }
}
