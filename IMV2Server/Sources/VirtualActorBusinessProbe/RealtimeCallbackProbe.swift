import Crypto
import FluentPostgresDriver
import FluentKit
import IMV2Server
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ServerInfrastructure
import Logging
import NIOPosix
import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2Core
import NIOSSL
import Synchronization
import SQLKit

/// Two independent processes exercise the production caller-only Node and wire.
/// File markers establish barriers; sleeps only poll those barriers.
enum RealtimeCallbackProbe {
    private enum Failure: Error { case missingEnvironment, assertion(String), timeout }
    private struct Configuration: Decodable, Sendable {
        let name: String
        let port: Int
        let serviceID: String
        let peerServiceID: String
        let peerPort: Int
        let signingKeyPath: String
        let peerPublicKeyBase64: String
        let certificatePath: String
        let privateKeyPath: String
        let trustRootPath: String
        let databaseURL: String?
        let outboxKind: String?
        let topicID: String?
        let partitionHandoff: Bool?
    }
    private final class Ingress: V2RealtimeIngress {
        let count = Mutex(0)
        let fence = Mutex<V2RealtimeInterestCoordinator?>(nil)
        let lastAccepted = Mutex<V2RealtimeDelivery?>(nil)
        let gateDirectory: URL?
        init(gateDirectory: URL? = nil) { self.gateDirectory = gateDirectory }
        func offer(_ batch: V2RealtimeBatch) -> V2RealtimeAcceptance {
            if let fence = fence.withLock({ $0 }), !batch.deliveries.allSatisfy({ fence.accepts($0) }) { return .stale }
            count.withLock { $0 += batch.deliveries.count }
            lastAccepted.withLock { $0 = batch.deliveries.last }
            if let gateDirectory {
                do {
                    try Data("entered".utf8).write(to: gateDirectory.appendingPathComponent("offer-held"), options: .atomic)
                    let deadline = ContinuousClock.now + .seconds(10)
                    while !FileManager.default.fileExists(atPath: gateDirectory.appendingPathComponent("offer-release").path) {
                        guard ContinuousClock.now < deadline else { return .overloaded }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                } catch { return .closed }
            }
            return .accepted
        }
    }
    private static func wait(_ path: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(40)
        while !FileManager.default.fileExists(atPath: path.path) {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    static func run(receiver: Bool) async throws {
        guard let configPath = ProcessInfo.processInfo.environment["VA_REALTIME_CONFIGURATION"],
              let evidencePath = ProcessInfo.processInfo.environment["VA_REALTIME_EVIDENCE"] else { throw Failure.missingEnvironment }
        let evidence = URL(fileURLWithPath: evidencePath, isDirectory: true)
        func marker(_ name: String) -> URL { evidence.appendingPathComponent(name) }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: configPath)))
        let privateKey = try Data(contentsOf: URL(fileURLWithPath: config.signingKeyPath))
        let signer = try V2ActorSigningIdentity(serviceID: V2ActorServiceID(config.serviceID), privateKey: privateKey)
        let ownPublicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey).publicKey.rawRepresentation
        guard let peerKey = Data(base64Encoded: config.peerPublicKeyBase64) else { throw Failure.missingEnvironment }
        let trust = try V2ActorTrustStore(services: [
            .init(serviceID: signer.serviceID, publicKey: ownPublicKey, permissions: [.realtimePublish, .realtimeReceive], gatewayNodeIDs: [config.serviceID]),
            .init(serviceID: V2ActorServiceID(config.peerServiceID), publicKey: peerKey, permissions: [.realtimePublish, .realtimeReceive], gatewayNodeIDs: [config.peerServiceID])
        ])
        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: try NIOSSLCertificate.fromPEMFile(config.certificatePath).map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(file: config.privateKeyPath, format: .pem)))
        tls.minimumTLSVersion = .tlsv13; tls.maximumTLSVersion = .tlsv13
        tls.certificateVerification = .fullVerification
        tls.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(config.trustRootPath))
        let node = V2RoomClusterClientNode(configuration: try .init(name: config.name, host: "localhost", port: config.port,
            tls: tls, threadPoolSize: 2), signer: signer, trust: trust,
            authenticationLimits: try .init(), runtimeConfiguration: try .init())
        _ = try await node.start()
        let inflightDrain = ProcessInfo.processInfo.environment["VA_REALTIME_INFLIGHT_DRAIN"] == "1"
        let ingress = Ingress(gateDirectory: receiver && (inflightDrain || config.outboxKind != nil) ? evidence : nil)
        let identity = V2GatewayRealtimeIdentity(nodeID: config.serviceID, serviceID: config.serviceID, incarnationID: UUID())
        let handle = try await node.makeRealtimeTransport(identity: identity, ingress: ingress,
            serviceOwnerAccess: [signer.serviceID: ["room-a", "user:callback"], try V2ActorServiceID(config.peerServiceID): ["room-a", "user:callback"]],
            limits: .init(maximumConcurrentCalls: inflightDrain ? 1 : 32))
        do {
            if ProcessInfo.processInfo.environment["VA_REALTIME_DUPLEX_PRESSURE"] == "1" {
                try await runDuplexPressure(receiver: receiver, handle: handle, ingress: ingress,
                    node: node, signer: signer, evidence: evidence, config: config)
                guard try await node.stop(deadline: .now + .seconds(10)) else { throw Failure.assertion("duplex Node did not drain") }
                return
            }
            if config.partitionHandoff == true {
                try await runPartitionHandoff(receiver: receiver, handle: handle, ingress: ingress, node: node, signer: signer, evidence: evidence, config: config)
                guard try await node.stop(deadline: .now + .seconds(10)) else { throw Failure.assertion("handoff Node did not drain") }
                return
            }
            if config.outboxKind != nil {
                try await runOutboxRelay(receiver: receiver, handle: handle, ingress: ingress, node: node, signer: signer, evidence: evidence, config: config)
                guard try await node.stop(deadline: .now + .seconds(10)) else { throw Failure.assertion("outbox caller-only Node did not drain") }
                return
            }
            if inflightDrain {
                try await runInflightDrain(receiver: receiver, handle: handle, ingress: ingress, evidence: evidence)
                guard try await node.stop(deadline: .now + .seconds(10)) else { throw Failure.assertion("inflight caller-only Node did not drain") }
                return
            }
            if receiver {
                try JSONEncoder().encode(handle.descriptor).write(to: marker("receiver.json"), options: .atomic)
                try await wait(marker("sender-delivered"))
                guard ingress.count.withLock({ $0 }) == 32 else { throw Failure.assertion("receiver expected 32 independent accepted deliveries") }
                guard await handle.stop(deadline: .now + .seconds(5)) else { throw Failure.assertion("receiver did not drain") }
                try Data("closed".utf8).write(to: marker("receiver-closed"), options: .atomic)
                try await wait(marker("sender-checked-closed"))
                try Data("{\"accepted\":32,\"callerOnly\":true,\"mtls\":true}".utf8).write(to: marker("receiver-result.json"), options: .atomic)
            } else {
                try await wait(marker("receiver.json"))
                let target = try JSONDecoder().decode(V2GatewayRealtimeDescriptor.self, from: Data(contentsOf: marker("receiver.json")))
                let room = RoomID(uuid: UUID())
                func batch(recipient: V2GatewayRealtimeIdentity, shard: String = "room-a") throws -> V2RealtimeBatch {
                    .init(recipient: recipient, deliveries: [.init(topic: .init(kind: .roomEvents, id: room.rawValue,
                        owner: try .init(shardID: shard, epoch: 0)),
                        partitionID: V2RealtimeTopicKey(kind: .roomEvents, id: room.rawValue).partitionID(),
                        partitionEpoch: 1, sessionID: UUID(), interestGeneration: 1, gatewayIncarnation: recipient.incarnationID,
                        payload: .roomWake(roomID: room, highWatermark: 1))])
                }
                for _ in 0..<16 {
                    let first = try batch(recipient: target.identity)
                    let second = try batch(recipient: target.identity)
                    async let a = handle.send(first, to: target)
                    async let b = handle.send(second, to: target)
                    let results = try await (a, b)
                    guard results.0 == .accepted, results.1 == .accepted else { throw Failure.assertion("callback did not accept") }
                }
                do { _ = try await handle.send(batch(recipient: target.identity, shard: "user:forbidden"), to: target); throw Failure.assertion("unauthorized owner accepted") }
                catch let failure as V2ActorAuthenticationError { guard failure == .forbidden else { throw failure } }
                let retired = V2GatewayRealtimeIdentity(nodeID: target.identity.nodeID, serviceID: target.identity.serviceID, incarnationID: UUID())
                let stale = V2GatewayRealtimeDescriptor(identity: retired, endpointReference: target.endpointReference, address: target.address, port: target.port)
                do { _ = try await handle.send(batch(recipient: retired), to: stale); throw Failure.assertion("retired identity accepted") }
                catch let failure as V2ActorAuthenticationError { guard failure == .wrongRecipient else { throw failure } }
                try Data("delivered".utf8).write(to: marker("sender-delivered"), options: .atomic)
                try await wait(marker("receiver-closed"))
                do { _ = try await handle.send(batch(recipient: target.identity), to: target); throw Failure.assertion("closed endpoint accepted") }
                catch let failure as V2ActorAuthenticationError { guard failure == .overloaded else { throw failure } }
                try Data("checked".utf8).write(to: marker("sender-checked-closed"), options: .atomic)
                try Data("{\"ownerRejected\":true,\"oldIncarnationRejected\":true,\"closedRejected\":true,\"concurrentCalls\":32}".utf8).write(to: marker("sender-result.json"), options: .atomic)
            }
            guard try await node.stop(deadline: .now + .seconds(10)) else { throw Failure.assertion("caller-only Node did not drain") }
        } catch {
            _ = try? await node.stop(deadline: .now + .seconds(10))
            throw error
        }
    }
    private static func runInflightDrain(receiver: Bool, handle: V2RealtimeTransportHandle,
                                         ingress: Ingress, evidence: URL) async throws {
        func marker(_ name: String) -> URL { evidence.appendingPathComponent(name) }
        if receiver {
            try JSONEncoder().encode(handle.descriptor).write(to: marker("receiver.json"), options: .atomic)
            try await wait(marker("sender-drained"))
            guard ingress.count.withLock({ $0 }) == 1 else { throw Failure.assertion("expected one held remote offer") }
            guard await handle.stop(deadline: .now + .seconds(5)) else { throw Failure.assertion("receiver drain failed") }
            try Data("{\"accepted\":1,\"callerOnly\":true,\"mtls\":true,\"controlledOfferCompleted\":true}".utf8)
                .write(to: marker("receiver-result.json"), options: .atomic)
        } else {
            try await wait(marker("receiver.json"))
            let target = try JSONDecoder().decode(V2GatewayRealtimeDescriptor.self, from: Data(contentsOf: marker("receiver.json")))
            let room = RoomID(uuid: UUID())
            let batch = V2RealtimeBatch(recipient: target.identity, deliveries: [.init(
                topic: .init(kind: .roomEvents, id: room.rawValue, owner: try .init(shardID: "room-a", epoch: 0)),
                partitionID: V2RealtimeTopicKey(kind: .roomEvents, id: room.rawValue).partitionID(),
                partitionEpoch: 1, sessionID: UUID(), interestGeneration: 1, gatewayIncarnation: target.identity.incarnationID,
                payload: .roomWake(roomID: room, highWatermark: 1))])
            let dispatched = Task { try await handle.send(batch, to: target) }
            // The barrier is written from the remote production ingress.offer:
            // dispatch has crossed the real TLS transport and cannot have completed.
            try await wait(marker("offer-held"))
            // A real remote generic offer occupies the single shared slot.
            // Room RPCs must fail locally even though the per-peer ceiling is two.
            let activation = V2RoomActivationToken(roomID: room,
                owner: try .init(shardID: "room-a", epoch: 0), activationEpoch: try .init(1),
                host: .init(hostID: .init(uuid: UUID()), incarnationID: UUID()))
            let fence = V2RoomSubscriptionFence(activation: activation, subscriptionID: UUID(),
                generation: 1, baselineSequence: 0)
            let roomDelivery = V2RoomSubscriptionDelivery(fence: fence, deliverySequence: 1,
                authorizationSequence: 1, payload: .baseline(members: []))
            do {
                _ = try await handle.sendRoomSubscription(roomDelivery, sourceShardID: "room-a", to: target)
                throw Failure.assertion("room call bypassed held generic callback admission")
            } catch let failure as V2ActorAuthenticationError {
                guard failure == .overloaded else { throw failure }
            }
            do {
                _ = try await handle.sendRoomSubscriptionBatch(.init(deliveries: [roomDelivery]),
                    sourceShardID: "room-a", to: target)
                throw Failure.assertion("room batch bypassed held generic callback admission")
            } catch let failure as V2ActorAuthenticationError {
                guard failure == .overloaded else { throw failure }
            }
            let journalSource = V2RealtimeJournalSource(sourceID: "room-a",
                incarnationID: UUID(), partitionID: 0)
            let journalFence = V2RealtimeJournalProjectionFence(publisherIncarnationID: UUID(),
                sourceLeaseEpoch: 1, sourceLeaseToken: UUID(), sourceLeaseExpiresAt: Date().addingTimeInterval(60),
                routingPartitionEpoch: 1, routingLeaseToken: UUID(), sessionID: UUID(),
                interestGeneration: 1, gatewayIncarnationID: target.identity.incarnationID)
            let journalBatch = V2RealtimeJournalProjectionBatch(source: journalSource,
                fence: journalFence, payload: .baseline(minimumCut: 0))
            do {
                _ = try await handle.sendJournalProjection(journalBatch, to: target)
                throw Failure.assertion("journal bypassed held generic callback admission")
            } catch let failure as V2ActorAuthenticationError {
                guard failure == .overloaded else { throw failure }
            }
            guard !(await handle.stop(deadline: .now + .milliseconds(200))) else {
                throw Failure.assertion("stop reported drained while remote offer was held")
            }
            do {
                _ = try await handle.send(batch, to: target)
                throw Failure.assertion("stopped sender admitted a new call")
            } catch let failure as V2ActorAuthenticationError {
                guard failure == .overloaded else { throw failure }
            }
            let drainReturned = Mutex(false)
            let finalDrain = Task {
                let result = await handle.stop(deadline: .now + .seconds(5))
                drainReturned.withLock { $0 = true }
                return result
            }
            try await Task.sleep(for: .milliseconds(100))
            guard !drainReturned.withLock({ $0 }) else { throw Failure.assertion("final drain returned before remote offer release") }
            try Data("release".utf8).write(to: marker("offer-release"), options: .atomic)
            guard try await dispatched.value == .accepted else { throw Failure.assertion("held remote dispatch did not complete") }
            guard await finalDrain.value else { throw Failure.assertion("sender failed actual dispatch drain") }
            try Data("{\"journalAdmissionRejected\":true,\"mixedCallbackAdmissionRejected\":true,\"inflightStopTimedOut\":true,\"newCallsRejected\":true,\"dispatchCompleted\":true,\"finalDrainCompleted\":true}".utf8)
                .write(to: marker("sender-result.json"), options: .atomic)
            try Data("drained".utf8).write(to: marker("sender-drained"), options: .atomic)
        }
    }

    // This proves the durable notification contract, not a full App/body write path.
    private static func runOutboxRelay(receiver: Bool, handle: V2RealtimeTransportHandle,
                                       ingress: Ingress, node: V2RoomClusterClientNode, signer: V2ActorSigningIdentity, evidence: URL, config: Configuration) async throws {
        guard let databaseURL = config.databaseURL, let kind = config.outboxKind,
              kind == "user", let topicID = config.topicID else { throw Failure.missingEnvironment }
        func marker(_ name: String) -> URL { evidence.appendingPathComponent(name) }
        let resources = V2DatabaseResources(eventLoopGroup: MultiThreadedEventLoopGroup(numberOfThreads: 1),
            logger: Logger(label: "imv2.callback.outbox"), ownsEventLoopGroup: true)
        do {
        resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
        let database = resources.database(.psql)
        let owner = try V2RoomDataOwner(shardID: "user:callback", epoch: 0)
        let canonicalID = try UserID(topicID).rawValue
        guard let canonicalUUID = UUID(uuidString: canonicalID) else { throw Failure.assertion("invalid durable topic identity") }
        let topic = V2RealtimeTopic(kind: .userSync, id: canonicalID, owner: owner)
        let service = V2RealtimeShardService { descriptor, batch in try await handle.send(batch, to: descriptor) }
        let shardHandle = try await node.makeRealtimeShardTransport(identity: handle.descriptor.identity, serving: service,
            serviceOwnerAccess: [signer.serviceID: ["room-a", "user:callback"], try V2ActorServiceID(config.peerServiceID): ["room-a", "user:callback"]],
            discoveryPeers: [
                .init(nodeID: config.serviceID, serviceID: config.serviceID, address: "localhost", port: config.port),
                .init(nodeID: config.peerServiceID, serviceID: config.peerServiceID, address: "localhost", port: config.peerPort)
            ])
        let partitionStore = try PostgresV2RealtimePartitionLeaseStore(database: database)
        var leases: [V2RealtimePartitionLease] = []
        if receiver {
            let started = ContinuousClock.now
            leases = try await partitionStore.claim(partitionIDs: [V2RealtimeTopicKey(topic).partitionID()],
                identity: handle.descriptor.identity, token: UUID(), leaseDuration: 120)
            guard leases.count == 1, let lease = leases.first else { throw Failure.assertion("partition claim failed") }
            let deadline = started + .milliseconds(Int64(lease.remainingLeaseSeconds * 1_000)) - .milliseconds(500)
            guard deadline > .now else { throw Failure.assertion("partition claim exhausted its real deadline") }
            let token = V2RealtimeShardToken(partitionID: lease.partitionID, host: lease.identity, epoch: lease.epoch, leaseToken: lease.token)
            await service.install(token: token, deadline: deadline)
            let remaining = ContinuousClock.now.duration(to: deadline).components
            try await shardHandle.installPartitions([.init(token: token, remainingLeaseMilliseconds:
                remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000)])
        }
        let coordinator = V2RealtimeInterestCoordinator(descriptor: handle.descriptor, transport: shardHandle,
            readHeads: { topics in
                guard let sql = database as? any SQLDatabase else { throw Failure.assertion("missing SQL database") }
                let rows = try await sql.raw("SELECT next_sequence FROM im_v2.user_sync_sequences WHERE user_id = \(bind: canonicalUUID)").all(decoding: SyncHead.self)
                guard rows.count == 1, rows[0].sequence >= 0 else { throw Failure.assertion("missing durable user head") }
                return Dictionary(uniqueKeysWithValues: topics.map { ($0, V2RealtimeRecoveryHeadOutcome.available(UInt64(rows[0].sequence))) })
            }, recovered: { heads in
                // This probe verifies durable notification relay, not App cursor application.
                guard heads.values.allSatisfy({ $0 >= 1 }) else { throw Failure.assertion("missing committed registration barrier") }
                return Set(heads.keys)
            }, coverageLost: { _, _ in })
        let fanout = V2RealtimeFanoutDispatcher(transport: shardHandle)
        let publisher = V2ActorRealtimePublisher(interests: coordinator, fanout: fanout, topic: { requestedKind, id in
            let requestedID = requestedKind == .roomEvents ? try RoomID(id).rawValue : try UserID(id).rawValue
            guard requestedKind == topic.kind, id == requestedID, requestedID == topic.id else { throw Failure.assertion("relay topic mismatch") }
            return topic
        })
        do {
            if receiver {
                ingress.fence.withLock { $0 = coordinator }
                try await coordinator.start()
                try await coordinator.activate(topic)
                try JSONEncoder().encode(handle.descriptor).write(to: marker("receiver.json"), options: .atomic)
                try await wait(marker("sender-recovered"))
                guard ingress.count.withLock({ $0 }) == 2 else { throw Failure.assertion("expected killed delivery and successor delivery") }
                try Data("{\"accepted\":2,\"callerOnly\":true,\"mtls\":true,\"fencedRegistration\":true}".utf8)
                    .write(to: marker("receiver-result.json"), options: .atomic)
            } else {
                try await wait(marker("receiver.json"))
                let discoveryDeadline = ContinuousClock.now + .seconds(10)
                while true {
                    do { _ = try await shardHandle.resolve(partitionID: V2RealtimeTopicKey(topic).partitionID()); break }
                    catch {
                        guard ContinuousClock.now < discoveryDeadline else { throw error }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
                let report = try await V2UserSyncWakeRelay(
                    store: PostgresV2UserSyncWakeStore(database: database), publisher: publisher).runOnce(limit: 1)
                let resultName = config.name.hasSuffix("successor") ? "successor-relay-report.json" : "source-relay-report.json"
                let diagnostic = report.claimed == 0 ? "NO_CLAIM" : (report.retryScheduled > 0 ? "PUBLISH_RETRY" : "COMPLETED")
                try JSONSerialization.data(withJSONObject: ["claimed": report.claimed, "published": report.published,
                    "retryScheduled": report.retryScheduled, "resultCode": diagnostic], options: [.sortedKeys])
                    .write(to: marker(resultName), options: .atomic)
                guard report.claimed == 1, report.published == 1, report.retryScheduled == 0 else {
                    throw Failure.assertion("committed wake relay result \(diagnostic) claimed=\(report.claimed) published=\(report.published) retryScheduled=\(report.retryScheduled)")
                }
                try Data("{\"claimed\":1,\"published\":1,\"retryScheduled\":0,\"productionRelay\":true}".utf8)
                    .write(to: marker("sender-result.json"), options: .atomic)
                try Data("recovered".utf8).write(to: marker("sender-recovered"), options: .atomic)
            }
            await fanout.shutdown()
            await coordinator.shutdown()
            try await shardHandle.installPartitions([])
            for lease in leases { await service.retire(token: .init(partitionID: lease.partitionID, host: lease.identity, epoch: lease.epoch, leaseToken: lease.token)) }
            await service.shutdown()
            guard await shardHandle.stop(deadline: .now + .seconds(5)) else { throw Failure.assertion("outbox shard handle did not drain") }
            try await partitionStore.release(leases)
            guard await handle.stop(deadline: .now + .seconds(5)) else { throw Failure.assertion("outbox handle did not drain") }
            try await resources.shutdown()
        } catch {
            await fanout.shutdown()
            await coordinator.shutdown()
            try? await shardHandle.installPartitions([])
            await service.shutdown()
            _ = await shardHandle.stop(deadline: .now + .seconds(5))
            try? await partitionStore.release(leases)
            throw error
        }
        } catch {
            try? await resources.shutdown()
            throw error
        }
    }

    /// These records contain fences only; never payloads or signing material.
    private struct CoverageRecord: Codable, Sendable {
        let token: V2RealtimeShardToken
        let sessionID: UUID
        let interestGeneration: Int64
        let highWatermark: UInt64
        init(_ value: V2RealtimeCoverageConfirmation) {
            token = value.token; sessionID = value.sessionID
            interestGeneration = value.interestGeneration; highWatermark = value.highWatermark
        }
    }
    private actor HandoffObservation {
        var initial: CoverageRecord?
        var rebuilt: CoverageRecord?
        var lost = 0
        var successfulHeadReads = 0
        func readCompleted() { successfulHeadReads += 1 }
        func coverageLost() { lost += 1 }
        func ready(_ values: [V2RealtimeTopic: V2RealtimeCoverageConfirmation]) {
            guard let value = values.values.first else { return }
            let record = CoverageRecord(value)
            if initial == nil { initial = record }
            else if record.token.epoch > initial!.token.epoch { rebuilt = record }
        }
        func confirmedInitial() throws -> CoverageRecord {
            guard let initial, initial.highWatermark >= 1 else { throw Failure.assertion("initial head barrier missing") }
            return initial
        }
        func confirmedReplacement() throws -> CoverageRecord? {
            guard let rebuilt else { return nil }
            guard let initial, lost > 0, successfulHeadReads >= 2,
                  rebuilt.token.host.incarnationID != initial.token.host.incarnationID,
                  rebuilt.sessionID != initial.sessionID,
                  rebuilt.interestGeneration > initial.interestGeneration,
                  rebuilt.highWatermark >= initial.highWatermark else {
                throw Failure.assertion("replacement Ready did not rebuild all exact fences and durable head barrier")
            }
            return rebuilt
        }
    }
    /// Fixture renewal owns its actual task through settlement. This deliberately
    /// does not impersonate the production roster/rendezvous lease controller.
    private actor HandoffLeaseOwner {
        let store: PostgresV2RealtimePartitionLeaseStore
        let service: V2RealtimeShardService
        let transport: V2RealtimeShardTransportHandle
        var lease: V2RealtimePartitionLease
        var renewal: Task<Void, Never>?
        var failed = false
        init(store: PostgresV2RealtimePartitionLeaseStore, service: V2RealtimeShardService,
             transport: V2RealtimeShardTransportHandle, lease: V2RealtimePartitionLease) {
            self.store = store; self.service = service; self.transport = transport; self.lease = lease
        }
        func install(started: ContinuousClock.Instant) async throws {
            let deadline = started + .milliseconds(Int64(lease.remainingLeaseSeconds * 1_000)) - .milliseconds(500)
            guard deadline > .now else { throw Failure.assertion("handoff lease exhausted request budget") }
            let token = V2RealtimeShardToken(partitionID: lease.partitionID, host: lease.identity, epoch: lease.epoch, leaseToken: lease.token)
            await service.install(token: token, deadline: deadline)
            let remaining = ContinuousClock.now.duration(to: deadline).components
            try await transport.installPartitions([.init(token: token, remainingLeaseMilliseconds:
                remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000)])
        }
        func start(started: ContinuousClock.Instant) async throws {
            try await install(started: started)
            renewal = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    if Task.isCancelled { return }
                    await self.renewOnce()
                }
            }
        }
        private func renewOnce() async {
            do {
                let started = ContinuousClock.now
                let renewed = try await store.renew([lease], leaseDuration: 30)
                guard renewed.count == 1, let value = renewed.first else { failed = true; return }
                lease = value
                try await install(started: started)
            } catch { failed = true }
        }
        func check() throws { guard !failed else { throw Failure.assertion("fixture actual lease renewal failed") } }
        func stop() async throws {
            let actual = renewal; renewal = nil; actual?.cancel(); await actual?.value
            try await transport.installPartitions([])
            await service.retire(token: .init(partitionID: lease.partitionID, host: lease.identity, epoch: lease.epoch, leaseToken: lease.token))
            await service.shutdown()
            try await store.release([lease])
        }
    }
    private static func runPartitionHandoff(receiver: Bool, handle: V2RealtimeTransportHandle,
        ingress: Ingress, node: V2RoomClusterClientNode, signer: V2ActorSigningIdentity,
        evidence: URL, config: Configuration) async throws {
        guard let databaseURL = config.databaseURL, let topicID = config.topicID else { throw Failure.missingEnvironment }
        func marker(_ name: String) -> URL { evidence.appendingPathComponent(name) }
        let resources = V2DatabaseResources(eventLoopGroup: MultiThreadedEventLoopGroup(numberOfThreads: 1),
            logger: Logger(label: "imv2.callback.handoff"), ownsEventLoopGroup: true)
        var shardHandle: V2RealtimeShardTransportHandle?
        var leaseOwner: HandoffLeaseOwner?
        var coordinator: V2RealtimeInterestCoordinator?
        var fanout: V2RealtimeFanoutDispatcher?
        var stage = "database_setup"
        func entered(_ value: String) throws {
            try Data(value.utf8).write(to: marker(receiver ? "handoff-host-stage" : "handoff-gateway-stage"), options: .atomic)
        }
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            let database = resources.database(.psql)
            let room = try RoomID(topicID)
            let topic = V2RealtimeTopic(kind: .roomEvents, id: room.rawValue, owner: try .init(shardID: "room-a", epoch: 0))
            let partitionID = V2RealtimeTopicKey(topic).partitionID()
            let service = V2RealtimeShardService { target, batch in try await handle.send(batch, to: target) }
            stage = "transport_factory"; try entered(stage)
            let transport = try await node.makeRealtimeShardTransport(identity: handle.descriptor.identity, serving: service,
                serviceOwnerAccess: [signer.serviceID: ["room-a"], try V2ActorServiceID(config.peerServiceID): ["room-a"]],
                discoveryPeers: [.init(nodeID: config.serviceID, serviceID: config.serviceID, address: "localhost", port: config.port),
                                 .init(nodeID: config.peerServiceID, serviceID: config.peerServiceID, address: "localhost", port: config.peerPort)])
            shardHandle = transport
            if receiver {
                let store = try PostgresV2RealtimePartitionLeaseStore(database: database)
                let started = ContinuousClock.now
                stage = "host_pg_claim"; try entered(stage)
                let leases = try await store.claim(partitionIDs: [partitionID], identity: handle.descriptor.identity, token: UUID(), leaseDuration: 30)
                guard leases.count == 1, let lease = leases.first else { throw Failure.assertion("real handoff claim failed") }
                let owner = HandoffLeaseOwner(store: store, service: service, transport: transport, lease: lease)
                leaseOwner = owner
                stage = "host_service_and_advertisement_install"; try entered(stage)
                try await owner.start(started: started)
                let token = V2RealtimeShardToken(partitionID: lease.partitionID, host: lease.identity, epoch: lease.epoch, leaseToken: lease.token)
                let successor = config.name.hasSuffix("successor")
                if successor {
                    let old = try JSONDecoder().decode(V2RealtimeShardToken.self, from: Data(contentsOf: marker("host-installed-initial.json")))
                    guard token.epoch > old.epoch, token.host.incarnationID != old.host.incarnationID,
                          token.leaseToken != old.leaseToken else { throw Failure.assertion("successor did not receive a higher real PG epoch") }
                    let oldLease = V2RealtimePartitionLease(partitionID: old.partitionID, identity: old.host, epoch: old.epoch, token: old.leaseToken, remainingLeaseSeconds: 0)
                    guard try await store.renew([oldLease], leaseDuration: 30).isEmpty else { throw Failure.assertion("old PG lease renewed successor") }
                    try JSONEncoder().encode(token).write(to: marker("host-installed-successor.json"), options: .atomic)
                    try await wait(marker("handoff-gateway-done"))
                    try await owner.check()
                    try await owner.stop(); leaseOwner = nil
                    try Data("{\"higherEpoch\":true,\"newIncarnation\":true,\"oldLeaseRenewRejected\":true,\"actualLeaseReleased\":true}".utf8)
                        .write(to: marker("receiver-result.json"), options: .atomic)
                } else {
                    try JSONEncoder().encode(token).write(to: marker("host-installed-initial.json"), options: .atomic)
                    // Driver SIGKILLs this process. No graceful release is expected.
                    try await wait(marker("handoff-gateway-done"))
                    throw Failure.assertion("initial host survived required SIGKILL")
                }
            } else {
                let observation = HandoffObservation()
                let desired = V2RealtimeInterestCoordinator(descriptor: handle.descriptor, transport: transport,
                    readHeads: { topics in
                        let heads = try await PostgresV2RealtimeRoomHeadReader(database: database).heads(topics: topics)
                        await observation.readCompleted(); return heads
                    }, recovered: { heads in
                        guard heads.values.allSatisfy({ $0 >= 1 }) else { throw Failure.assertion("committed handoff head missing") }
                        return Set(heads.keys)
                    }, coverageReady: { await observation.ready($0) }, coverageLost: { _, _ in await observation.coverageLost() })
                coordinator = desired; ingress.fence.withLock { $0 = desired }
                let publications = V2RealtimeFanoutDispatcher(transport: transport); fanout = publications
                try await wait(marker("host-installed-initial.json"))
                // Exactly one activation; subsequent recovery is the unchanged production coordinator.
                stage = "desired_start"; try entered(stage)
                try await desired.start()
                stage = "initial_desired_activate"; try entered(stage)
                try await desired.activate(topic)
                let initial = try await observation.confirmedInitial()
                stage = "initial_cached_resolve"; try entered(stage)
                let oldDescriptor = try await transport.resolve(partitionID: partitionID)
                stage = "initial_real_publish"; try entered(stage)
                try await publications.publish(topic: topic, payload: .roomWake(roomID: room, highWatermark: 1))
                guard ingress.count.withLock({ $0 }) == 1, let oldDelivery = ingress.lastAccepted.withLock({ $0 }) else {
                    throw Failure.assertion("initial real fenced callback missing")
                }
                try JSONEncoder().encode(initial).write(to: marker("gateway-before-kill.json"), options: .atomic)
                stage = "await_successor_install"; try entered(stage)
                try await wait(marker("host-installed-successor.json"))
                stage = "automatic_desired_recovery"; try entered(stage)
                let deadline = ContinuousClock.now + .seconds(40)
                var replacement: CoverageRecord?
                while replacement == nil {
                    replacement = try await observation.confirmedReplacement()
                    if replacement != nil { break }
                    guard ContinuousClock.now < deadline else { throw Failure.timeout }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard let replacement else { throw Failure.assertion("replacement Ready missing") }
                try JSONEncoder().encode(replacement).write(to: marker("gateway-rebuilt.json"), options: .atomic)
                stage = "replacement_hot_publish"; try entered(stage)
                let before = await transport.metricsSnapshot()
                let callbacksBefore = ingress.count.withLock { $0 }
                let hotStarted = ContinuousClock.now
                let hotPublishCount = 10_000
                for _ in 0..<hotPublishCount { try await publications.publish(topic: topic, payload: .roomWake(roomID: room, highWatermark: 1)) }
                let after = await transport.metricsSnapshot()
                let callbacksAfter = ingress.count.withLock { $0 }
                let hotDuration = hotStarted.duration(to: .now).components
                // Persist the actual independent counters before the combined
                // assertion. Background coordinator resolve/renew work shares
                // Handle metrics; it must not disappear into a generic failure.
                try JSONSerialization.data(withJSONObject: [
                    "expectedPublications": hotPublishCount,
                    "callbacksBefore": callbacksBefore, "callbacksAfter": callbacksAfter,
                    "cacheHitsBefore": before.cacheHits, "cacheHitsAfter": after.cacheHits,
                    "cacheMissesBefore": before.cacheMisses, "cacheMissesAfter": after.cacheMisses,
                    "cacheInvalidationsBefore": before.cacheInvalidations, "cacheInvalidationsAfter": after.cacheInvalidations,
                    "publishStartedBefore": before.publishStarted, "publishStartedAfter": after.publishStarted,
                    "publishSettledBefore": before.publishSettled, "publishSettledAfter": after.publishSettled,
                    "controlStartedBefore": before.controlStarted, "controlStartedAfter": after.controlStarted,
                    "discoveryPassesBefore": before.discoveryPasses, "discoveryPassesAfter": after.discoveryPasses,
                    "foregroundReceptionistLookupsBefore": before.foregroundReceptionistLookups, "foregroundReceptionistLookupsAfter": after.foregroundReceptionistLookups,
                    "backgroundReceptionistLookupsBefore": before.backgroundReceptionistLookups, "backgroundReceptionistLookupsAfter": after.backgroundReceptionistLookups,
                    "publishActiveAfter": after.publishActive, "controlActiveAfter": after.controlActive,
                    "pendingHandshakesAfter": after.pendingHandshakes,
                    "elapsedSeconds": Double(hotDuration.seconds) + Double(hotDuration.attoseconds) / 1e18,
                    "counterScope": "whole_handle_including_background_coordinator"
                ], options: [.sortedKeys]).write(to: marker("hot-publication-observation.json"), options: .atomic)
                // Cache hits cover the whole Handle, including concurrent
                // coordinator renew/resolve. Exact publication and callback
                // counts remain separate; background hits are not attributed
                // to these publications.
                guard callbacksAfter - callbacksBefore == hotPublishCount,
                      after.cacheMisses == before.cacheMisses,
                      after.cacheInvalidations == before.cacheInvalidations,
                      after.foregroundReceptionistLookups == before.foregroundReceptionistLookups,
                      after.cacheHits - before.cacheHits >= UInt64(hotPublishCount),
                      after.publishStarted - before.publishStarted == UInt64(hotPublishCount),
                      after.publishSettled - before.publishSettled == UInt64(hotPublishCount) else {
                    throw Failure.assertion("hot replacement callback/cache settlement contract failed")
                }
                // Replay an ACTUAL old delivery through the authenticated callback endpoint.
                stage = "old_delivery_fence"; try entered(stage)
                let oldAcceptance = try await handle.send(.init(recipient: handle.descriptor.identity, deliveries: [oldDelivery]), to: handle.descriptor)
                guard oldAcceptance == .stale, ingress.count.withLock({ $0 }) == callbacksAfter else { throw Failure.assertion("old delivery fence accepted") }
                do {
                    _ = try await transport.publish(oldDescriptor, request: .init(token: oldDescriptor.token, topic: topic, payload: .roomWake(roomID: room, highWatermark: 1)))
                    throw Failure.assertion("old reference entered replacement publication")
                } catch let error as V2ActorAuthenticationError {
                    guard error == .sessionExpired else { throw error }
                }
                guard await transport.metricsSnapshot().publishStarted == after.publishStarted else { throw Failure.assertion("old descriptor dispatched RPC") }
                stage = "actual_shutdown"; try entered(stage)
                await publications.shutdown(); fanout = nil
                await desired.shutdown(); coordinator = nil
                guard await transport.stop(deadline: .now + .seconds(10)) else { throw Failure.assertion("handoff transport did not actually drain") }
                let settled = await transport.metricsSnapshot()
                guard settled.controlActive == 0, settled.publishActive == 0, settled.discoveryActive == 0,
                      settled.pendingHandshakes == 0 else { throw Failure.assertion("handoff actual tasks retained") }
                try JSONSerialization.data(withJSONObject: ["singleDesiredActivation": true, "automaticDesiredRecovery": true,
                    "lostCoverageObserved": true, "freshHeadBarrier": true, "hotAcceptedCallbacks": callbacksAfter - callbacksBefore, "hotCacheMisses": after.cacheMisses - before.cacheMisses,
                    "hotCacheInvalidations": after.cacheInvalidations - before.cacheInvalidations,
                    "hotCacheHits": after.cacheHits - before.cacheHits,
                    "backgroundDiscoveryPassesDuringHotCalls": after.discoveryPasses - before.discoveryPasses,
                    "hotForegroundReceptionistLookups": after.foregroundReceptionistLookups - before.foregroundReceptionistLookups,
                    "backgroundReceptionistLookupsDuringHotCalls": after.backgroundReceptionistLookups - before.backgroundReceptionistLookups,
                    "perCallAddressSQLMeasured": false, "perCallReceptionistMeasured": true,
                    "receptionistMeasurementScope": "shard_transport_pass_invocations_by_creator",
                    "oldDeliveryRejected": true, "oldReferenceRejectedBeforeDispatch": true, "actualDrain": true,
                    "productionControllerUsed": false, "fixtureRenewalUsed": true, "fabricatedLateReply": false], options: [.sortedKeys])
                    .write(to: marker("sender-result.json"), options: .atomic)
                try Data("done".utf8).write(to: marker("handoff-gateway-done"), options: .atomic)
            }
            if let shardHandle { guard await shardHandle.stop(deadline: .now + .seconds(10)) else { throw Failure.assertion("handoff shard drain failed") } }
            guard await handle.stop(deadline: .now + .seconds(10)) else { throw Failure.assertion("handoff callback drain failed") }
            try await resources.shutdown()
        } catch {
            // Persist the ORIGINAL failing stage before cleanup can down/unbind
            // this node. Authentication cases are closed, low-cardinality codes.
            let code = (error as? V2ActorAuthenticationError).map { String(describing: $0) } ?? String(reflecting: type(of: error))
            try? JSONSerialization.data(withJSONObject: ["stage": stage, "errorCode": code, "beforeCleanup": true], options: [.sortedKeys])
                .write(to: marker(receiver ? "handoff-host-failure.json" : "handoff-gateway-failure.json"), options: .atomic)
            await fanout?.shutdown(); await coordinator?.shutdown()
            try? await leaseOwner?.stop()
            if let shardHandle { _ = await shardHandle.stop(deadline: .now + .seconds(10)) }
            try? await resources.shutdown()
            throw error
        }
    }

    /// A fixture wrapper around the actual production service. The real signed
    /// publication and reverse callback complete before its RPC reply is held.
    /// Unlike Ingress.offer's synchronous gate, this suspends without blocking
    /// either Node's event loops. It deliberately does not claim a PG lease test.
    private actor DuplexServing: V2RealtimeShardServing {
        let service: V2RealtimeShardService
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private(set) var entered = 0
        private(set) var settled = 0
        init(service: V2RealtimeShardService) { self.service = service }
        func control(_ request: V2RealtimeShardControlRequest) async throws -> V2RealtimeShardControlReply {
            try await service.control(request)
        }
        func publish(_ request: V2RealtimeShardPublishRequest) async throws -> V2RealtimeShardPublishReply {
            let result = try await service.publish(request)
            if result == .overloaded { return result }
            guard result == .accepted || result == .acceptedAsWatermark else {
                throw Failure.assertion("duplex production publication did not reach a subscriber")
            }
            entered += 1
            if !released { await withCheckedContinuation { continuations.append($0) } }
            settled += 1
            return result
        }
        func release() {
            released = true
            let held = continuations; continuations.removeAll()
            for continuation in held { continuation.resume() }
        }
    }
    private struct DuplexPeer: Codable, Sendable {
        let topic: V2RealtimeTopic
        let callback: V2GatewayRealtimeDescriptor
    }
    private static func runDuplexPressure(receiver: Bool, handle: V2RealtimeTransportHandle,
        ingress: Ingress, node: V2RoomClusterClientNode, signer: V2ActorSigningIdentity,
        evidence: URL, config: Configuration) async throws {
        let local = receiver ? "b" : "a", remote = receiver ? "a" : "b"
        func marker(_ phase: String, _ side: String) -> URL { evidence.appendingPathComponent("duplex-\(side)-\(phase)") }
        func mark(_ phase: String) throws { try Data("reached".utf8).write(to: marker(phase, local), options: .atomic) }
        func boundedCondition(_ condition: @Sendable () async throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(1)
            while !(try await condition()) {
                guard ContinuousClock.now < deadline else { throw Failure.timeout }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let qualification = try V2ActorServiceQualification(localNodeID: config.serviceID,
            roster: [config.serviceID, config.peerServiceID])
        let service = V2RealtimeShardService(qualification: qualification) { target, batch in
            // The real remote service/delivery path receives controlled errors;
            // only proven backpressure may become a signed overloaded reply.
            if let delivery = batch.deliveries.first, case .roomWake(_, let high) = delivery.payload {
                if high == 2 { throw V2RealtimePublicationBackpressure.peerRPCs }
                if high == 3 { throw V2ActorAuthenticationError.invalidRequest }
            }
            return try await handle.send(batch, to: target)
        }
        let serving = DuplexServing(service: service)
        let transport = try await node.makeRealtimeShardTransport(identity: handle.descriptor.identity, serving: serving,
            serviceOwnerAccess: [signer.serviceID: ["room-a"], try V2ActorServiceID(config.peerServiceID): ["room-a"]],
            discoveryPeers: [.init(nodeID: config.serviceID, serviceID: config.serviceID, address: "localhost", port: config.port),
                             .init(nodeID: config.peerServiceID, serviceID: config.peerServiceID, address: "localhost", port: config.peerPort)],
            serviceQualification: qualification)
        var publications: [Task<V2RealtimeShardPublishReply, any Error>] = []
        var stage = "authenticated_qualification"
        do {
            // Bootstrap the real two-voter signed probe; no implicit standalone
            // qualification or simulated membership is used by this fixture.
            let qualificationDeadline = ContinuousClock.now + .seconds(30)
            while qualification.snapshot() == nil {
                guard ContinuousClock.now < qualificationDeadline else { throw Failure.timeout }
                try await Task.sleep(for: .milliseconds(20))
            }
            let firstRoom = RoomID(uuid: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
            var secondRoom = RoomID(uuid: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)
            let firstPartition = V2RealtimeTopicKey(kind: .roomEvents, id: firstRoom.rawValue).partitionID()
            for suffix in 2...512 {
                secondRoom = RoomID(uuid: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", suffix))!)
                if V2RealtimeTopicKey(kind: .roomEvents, id: secondRoom.rawValue).partitionID() != firstPartition { break }
            }
            let room = receiver ? secondRoom : firstRoom
            let topic = V2RealtimeTopic(kind: .roomEvents, id: room.rawValue, owner: try .init(shardID: "room-a", epoch: 0))
            let partitionID = V2RealtimeTopicKey(topic).partitionID()
            guard V2RealtimeTopicKey(kind: .roomEvents, id: secondRoom.rawValue).partitionID() != firstPartition else {
                throw Failure.assertion("duplex topics must occupy disjoint partitions")
            }
            // This narrowly tests RPC ownership; synthetic fixture tokens are
            // explicitly installed, not advertised as PostgreSQL admission facts.
            let token = V2RealtimeShardToken(partitionID: partitionID, host: handle.descriptor.identity,
                epoch: 1, leaseToken: UUID())
            await service.install(token: token, deadline: .now + .seconds(30))
            try await transport.installPartitions([.init(token: token, remainingLeaseMilliseconds: 30_000)])
            try JSONEncoder().encode(DuplexPeer(topic: topic, callback: handle.descriptor))
                .write(to: marker("peer.json", local), options: .atomic)
            try await wait(marker("peer.json", remote))
            let peer = try JSONDecoder().decode(DuplexPeer.self, from: Data(contentsOf: marker("peer.json", remote)))
            stage = "resolve_and_subscribe"
            let descriptor = try await transport.resolve(partitionID: V2RealtimeTopicKey(peer.topic).partitionID())
            guard descriptor.token.host == peer.callback.identity else { throw Failure.assertion("duplex resolved wrong process") }
            let session = V2RealtimeShardSession(gateway: handle.descriptor, sessionID: UUID(), sessionGeneration: 1)
            func request(_ mutation: V2RealtimeShardMutation, base: Int64, next: Int64) throws -> V2RealtimeShardControlRequest {
                .init(token: descriptor.token, session: session, baseRevision: base, nextRevision: next, mutation: mutation,
                    payloadFingerprint: try V2RealtimeShardFingerprint.control(token: descriptor.token, session: session,
                        baseRevision: base, nextRevision: next, mutation: mutation))
            }
            let interest = V2RealtimeShardInterest(key: .init(peer.topic), interestGeneration: 1)
            let snapshot = V2RealtimeShardMutation.snapshotChunk(snapshotID: UUID(), index: 0, total: 1,
                digest: try V2RealtimeShardFingerprint.snapshot([interest]), interests: [interest])
            let subscribed = try await transport.control(descriptor, request: request(snapshot, base: 0, next: 1))
            guard subscribed.status == .applied, subscribed.appliedRevision == 1 else { throw Failure.assertion("duplex initial subscribe failed") }
            try mark("subscribed"); try await wait(marker("subscribed", remote))
            stage = "signed_remote_backpressure_classification"
            let capacityRequest = V2RealtimeShardPublishRequest(token: descriptor.token, topic: peer.topic,
                payload: .roomWake(roomID: try RoomID(peer.topic.id), highWatermark: 2))
            guard try await transport.publish(descriptor, request: capacityRequest) == .overloaded else {
                throw Failure.assertion("duplex remote capacity failure lost its signed reply classification")
            }
            let hardRequest = V2RealtimeShardPublishRequest(token: descriptor.token, topic: peer.topic,
                payload: .roomWake(roomID: try RoomID(peer.topic.id), highWatermark: 3))
            do {
                _ = try await transport.publish(descriptor, request: hardRequest)
                throw Failure.assertion("duplex non-capacity failure was converted into a reply")
            } catch let error as V2ActorAuthenticationError {
                guard error == .invalidRequest else { throw error }
            }
            stage = "two_publish_calls_each_direction"
            let publication = V2RealtimeShardPublishRequest(token: descriptor.token, topic: peer.topic,
                payload: .roomWake(roomID: try RoomID(peer.topic.id), highWatermark: 1))
            publications = (0..<2).map { _ in Task { try await transport.publish(descriptor, request: publication) } }
            // Observe actual remote methods through this process's reciprocal
            // serving gate, then require the other process's independent witness.
            try await boundedCondition { await serving.entered == 2 }
            try mark("held"); try await wait(marker("held", remote))
            let held = await transport.metricsSnapshot()
            guard held.publishActive == 2, held.publishStarted == 4, held.publishSettled == 2 else {
                throw Failure.assertion("duplex did not retain two actual outbound publications")
            }
            stage = "control_and_reverse_delivery_while_publish_held"
            let renewed = try await transport.control(descriptor, request: request(.renew, base: 0, next: 0))
            guard renewed.status == .applied, renewed.appliedRevision == 1, renewed.remainingSessionMilliseconds > 0 else {
                throw Failure.assertion("duplex renewal could not progress")
            }
            let replacement = V2RealtimeShardInterest(key: .init(peer.topic), interestGeneration: 2)
            let updated = try await transport.control(descriptor,
                request: request(.delta([.upsert(replacement)]), base: 1, next: 2))
            guard updated.status == .applied, updated.appliedRevision == 2 else { throw Failure.assertion("duplex subscription update could not progress") }
            let reverse = V2RealtimeBatch(recipient: peer.callback.identity, deliveries: [.init(topic: peer.topic,
                partitionID: descriptor.token.partitionID, partitionEpoch: descriptor.token.epoch,
                sessionID: session.sessionID, interestGeneration: 2, gatewayIncarnation: peer.callback.identity.incarnationID,
                payload: .roomWake(roomID: try RoomID(peer.topic.id), highWatermark: 1))])
            guard try await handle.send(reverse, to: peer.callback) == .accepted else { throw Failure.assertion("duplex independent reverse callback could not progress") }
            publications[0].cancel()
            guard await transport.metricsSnapshot().publishActive == 2 else { throw Failure.assertion("duplex caller cancellation released an invocation prematurely") }
            do {
                _ = try await transport.publish(descriptor, request: publication)
                throw Failure.assertion("duplex third peer publication exceeded its original ceiling")
            } catch let error as V2RealtimeLocalAdmissionBackpressure { guard error == .peerRPCs else { throw error } }
            let rejected = await transport.metricsSnapshot()
            guard rejected.capacityRejections[.publish]?[.peer] == (held.capacityRejections[.publish]?[.peer] ?? 0) + 1,
                  rejected.capacityRejections[.control, default: [:]] == held.capacityRejections[.control, default: [:]],
                  rejected.rpcRejected == held.rpcRejected + 1 else {
                throw Failure.assertion("duplex sender lane/reason rejection accounting mismatch")
            }
            try mark("control-progress"); try await wait(marker("control-progress", remote))
            stage = "bounded_stop_and_actual_remote_release"
            guard !(await transport.stop(deadline: .now + .milliseconds(50))) else {
                throw Failure.assertion("duplex stop reported drain before held remote calls settled")
            }
            try mark("stop-pending"); try await wait(marker("stop-pending", remote))
            await serving.release()
            for publication in publications {
                let result = try await publication.value
                guard result == .accepted || result == .acceptedAsWatermark else { throw Failure.assertion("duplex held reply did not complete") }
            }
            try await boundedCondition { await serving.settled == 2 }
            guard await transport.stop(deadline: .now + .seconds(5)),
                  await transport.stop(deadline: .now + .seconds(5)) else { throw Failure.assertion("duplex repeated drain failed") }
            let drained = await transport.metricsSnapshot()
            guard drained.controlActive == 0, drained.publishActive == 0, drained.pendingHandshakes == 0,
                  drained.publishSettled == 4, drained.controlSettled == 3,
                  ingress.count.withLock({ $0 }) == 3 else { throw Failure.assertion("duplex actual local/remote resources did not settle") }
            await service.shutdown()
            try JSONSerialization.data(withJSONObject: ["realTwoProcessRPC": true, "mutualSignedQualification": true,
                "publishPeerCeiling": 2, "controlPeerCeiling": 2, "heldPublicationsEachDirection": 2,
                "renewedDuringPressure": true, "subscriptionUpdatedDuringPressure": true,
                "reverseCallbackDuringPressure": true, "cancelRetainedLocalInvocation": true,
                "remoteMethodsActuallySettled": true, "repeatedDrain": true,
                "signedRemoteBackpressureReply": true, "nonCapacityFailureNotConverted": true,
                "localPredispatchPeerBackpressure": true,
                "localControlStarted": drained.controlStarted, "localControlSettled": drained.controlSettled,
                "localPublishStarted": drained.publishStarted, "localPublishSettled": drained.publishSettled,
                "remoteTimeoutIsNotRemoteCompletion": true, "postgresLeaseAdmissionTest": false], options: [.sortedKeys])
                .write(to: marker("result.json", local), options: .atomic)
        } catch {
            try? JSONSerialization.data(withJSONObject: ["stage": stage, "beforeCleanup": true,
                "errorCode": (error as? V2ActorAuthenticationError).map { String(describing: $0) } ?? String(reflecting: type(of: error))], options: [.sortedKeys])
                .write(to: marker("failure.json", local), options: .atomic)
            await serving.release()
            for publication in publications { publication.cancel(); _ = await publication.result }
            _ = await transport.stop(deadline: .now + .seconds(5))
            await service.shutdown()
            throw error
        }
    }

    private struct SyncHead: Decodable {
        let sequence: Int64
        enum CodingKeys: String, CodingKey { case sequence = "next_sequence" }
    }
}
