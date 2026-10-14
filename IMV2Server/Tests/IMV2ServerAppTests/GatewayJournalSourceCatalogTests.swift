import Foundation
import FluentKit
import FluentPostgresDriver
import SQLKit
import NIOPosix
import Logging
import Testing
import IMV2Server
import IMV2ServerContracts
import IMV2ServerInfrastructure
import IMV2ActorContracts
import IMV2ServerApplication
import IMV2ServerGateway
import IMV2Core
@testable import IMV2ServerApp

@Suite("Source catalog database proof", .serialized)
struct GatewayJournalSourceCatalogTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func batchedSourceProofsRejectExpiredReplacedAndForeignSources() async throws {
        try await withCatalogDatabase { database, sql, schema in
            let catalog = try await GatewayJournalSourceCatalog.load(registrations: [
                .init(logicalAliases: ["source"], database: database, schema: schema)
            ])
            let entry = try catalog.entry(logicalAlias: "source")
            let owner = V2GatewayRealtimeIdentity(nodeID: "owner", serviceID: "source", incarnationID: UUID())
            let leases = try await entry.store.claim(partitionIDs: [1, 2, 3], identity: owner, token: UUID(), leaseDuration: 30)
            let began = ContinuousClock.now
            let proofs = try await catalog.sourceProofs(logicalAlias: "source", partitionIDs: [1, 2, 3, 4, 1])
            #expect(Set(proofs.keys) == [1, 2, 3])
            for lease in leases {
                let proof = try #require(proofs[lease.partitionID])
                #expect(proof.lease.token == lease.token && proof.lease.identity == owner)
                #expect(proof.value.publishedThrough == 0 && proof.value.trimmedThrough == 0)
                #expect(proof.validUntil > .now && proof.validUntil <= began + .seconds(30))
            }
            try await sql.raw("UPDATE \(unsafeRaw: schema).realtime_journal_publisher_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE partition_id IN(1,2)").run()
            let live = try await catalog.sourceProofs(logicalAlias: "source", partitionIDs: [1, 2, 3])
            #expect(Set(live.keys) == [3])
            let successor = V2GatewayRealtimeIdentity(nodeID: "new", serviceID: "source", incarnationID: UUID())
            _ = try await entry.store.claim(partitionIDs: [1], identity: successor, token: UUID(), leaseDuration: 30)
            let replaced = try await catalog.sourceProofs(logicalAlias: "source", partitionIDs: [1])
            #expect(replaced[1]?.lease.identity == successor)
            #expect(replaced[1]?.lease.epoch == (proofs[1]?.lease.epoch ?? 0) + 1)
            try await sql.raw("UPDATE \(unsafeRaw: schema).realtime_journal_source_identity SET database_incarnation=\(bind: UUID()) WHERE singleton").run()
            await #expect(throws: GatewayJournalSourceCatalog.CatalogError.identityChanged) {
                _ = try await catalog.sourceProofs(logicalAlias: "source", partitionIDs: [1, 3])
            }
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func productionRecoveryRequiresAcknowledgedCoverageAndCurrentSourceLease() async throws {
        try await withCatalogDatabase(schema: "im_v2") { database, sql, schema in
            let catalog = try await GatewayJournalSourceCatalog.load(registrations: [
                .init(logicalAliases: ["source"], database: database, schema: schema, isAuthenticationSource: true)
            ])
            let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), connection = UUID()
            let topic = V2RealtimeTopic(kind: .userSync, id: user.rawValue,
                owner: try .init(shardID: "source", epoch: 1))
            let partition = V2RealtimeTopicKey(topic).partitionID()
            let host = V2GatewayRealtimeIdentity(nodeID: "owner", serviceID: "owner", incarnationID: UUID())
            let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "gateway", incarnationID: UUID())
            let store = try PostgresV2RealtimePartitionLeaseStore(database: database, schema: schema)
            let routingLease = try #require(try await store.claim(partitionIDs: [partition], identity: host,
                token: UUID(), leaseDuration: 30).first)
            let token = V2RealtimeShardToken(partitionID: partition, host: host,
                epoch: routingLease.epoch, leaseToken: routingLease.token)
            let service = V2RealtimeShardService(send: { _, _ in .accepted })
            await service.install(token: token, deadline: .now + .seconds(routingLease.remainingLeaseSeconds))
            let transport = CatalogRecoveryTransport(service: service,
                descriptor: .init(token: token, endpointReference: Data([1]), address: "127.0.0.1",
                    port: 9001, remainingLeaseMilliseconds: 30_000))
            let coordinator = V2RealtimeInterestCoordinator(descriptor: .init(identity: gateway,
                endpointReference: Data([1]), address: "127.0.0.1", port: 9000), transport: transport,
                readHeads: { Dictionary(uniqueKeysWithValues: $0.map { ($0, .available(0)) }) },
                recovered: { Set($0.keys) }, coverageLost: { _, _ in })
            let frameLimits = try V2FrameLimits(maximumPayloadBytes: 4096,
                acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
            let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: frameLimits)
            let stream = V2GatewayByteStream(frameLimits: frameLimits,
                session: .init(limits: try .init(maximumInFlightRequests: 1),
                    authenticator: CatalogRecoveryAuthenticator(), capabilityProfile: "base",
                    commandAdmission: CatalogRecoveryAdmission()),
                handler: CatalogRecoveryCommandHandler(), connectionID: connection, registry: registry)
            let receiver = V2GatewayJournalProjectionReceiver(projection: V2RealtimeJournalSharedProjection())
            try #require(receiver.configureAuthenticationSources(["source"]))
            let source = try catalog.source(logicalAlias: "source", partitionID: partition)
            let recovery = GatewayJournalAuthorityAssembly.recovery(catalog: catalog, coordinator: coordinator, registry: registry, receiver: receiver)
            var otherUser = UserID(uuid: UUID())
            while V2RealtimeTopicKey(kind: .userSync, id: otherUser.rawValue).partitionID() != partition { otherUser = UserID(uuid: UUID()) }
            let otherDevice = DeviceID(uuid: UUID()), otherConnection = UUID()
            let otherStream = V2GatewayByteStream(frameLimits: frameLimits,
                session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: CatalogRecoveryAuthenticator(),
                    capabilityProfile: "base", commandAdmission: CatalogRecoveryAdmission()),
                handler: CatalogRecoveryCommandHandler(), connectionID: otherConnection, registry: registry)
            do {
                try #require(await registry.register(stream, connectionID: connection,
                    identity: .init(userID: user, deviceID: device, capabilityProfile: "base"), publicationSuppressed: true))
                try #require(await registry.register(otherStream, connectionID: otherConnection,
                    identity: .init(userID: otherUser, deviceID: otherDevice, capabilityProfile: "base"), publicationSuppressed: true))
                try await sql.raw("INSERT INTO \(unsafeRaw: schema).realtime_control_versions(topic_kind,topic_id,version,session_control_version) VALUES('userSync',\(bind: otherUser.rawValue)::uuid::text,1,1)").run()
                try await sql.raw("INSERT INTO \(unsafeRaw: schema).realtime_control_versions(topic_kind,topic_id,version,session_control_version) VALUES('userSync',\(bind: user.rawValue)::uuid::text,1,1)").run()
                await #expect(throws: GatewayJournalAuthorityError.coverageChanged) {
                    try await GatewayJournalAuthorityAssembly.refresh(catalog: catalog, coordinator: coordinator,
                        registry: registry, receiver: receiver, source: source, gatewayIdentity: gateway, recovery: recovery)
                }
                try await coordinator.activate(topic)
                let coverage = try #require(coordinator.journalCoverage(partitionID: partition))
                #expect(coverage.token == token && coverage.revision > 0)
                let entry = try catalog.entry(logicalAlias: "source")
                let publisher = try #require(try await entry.store.claim(partitionIDs: [partition], identity: host,
                    token: UUID(), leaseDuration: 30).first)
                try await GatewayJournalAuthorityAssembly.refresh(catalog: catalog, coordinator: coordinator,
                    registry: registry, receiver: receiver, source: source, gatewayIdentity: gateway, recovery: recovery)
                let binding = try #require(receiver.bindingSnapshot(source: source))
                #expect(binding.fence.routingLeaseToken == routingLease.token)
                #expect(binding.fence.sourceLeaseToken == publisher.token)
                #expect(binding.fence.sessionID == coverage.sessionID)
                #expect(receiver.authenticationBinding(userID: user)?.controlVersion == 1)
                try await sql.raw("UPDATE \(unsafeRaw: schema).realtime_control_versions SET version=2,session_control_version=2 WHERE topic_kind='userSync' AND topic_id=\(bind: user.rawValue)::uuid::text").run()
                // Newer committed state not yet represented by a published control
                // must not make a selective repair read or advance an unrelated user.
                try await sql.raw("UPDATE \(unsafeRaw: schema).realtime_control_versions SET version=2,session_control_version=2 WHERE topic_kind='userSync' AND topic_id=\(bind: otherUser.rawValue)::uuid::text").run()
                try await sql.raw("INSERT INTO \(unsafeRaw: schema).realtime_control_publication_floors(topic_kind,topic_id,published_version) VALUES('userSync',\(bind: user.rawValue)::uuid::text,1)").run()
                try await sql.raw("INSERT INTO \(unsafeRaw: schema).realtime_change_outbox(partition_id,topic_kind,topic_id,change_kind,user_control_version) VALUES(\(bind: partition),'userSync',\(bind: user.rawValue)::uuid::text,'userControl',2)").run()
                let published = try await entry.store.publishPending(lease: publisher, limit: 128)
                #expect(published.publishedThrough == 1)
                #expect(receiver.applyJournalProjection(.init(source: source, fence: binding.fence,
                    payload: .changes(fromExclusive: 0, throughInclusive: 1, entries: [
                        .init(sequence: 1, change: .userControlInvalidation(userID: user, controlVersion: 2, deviceID: nil, membershipRoomID: nil))])),
                    authenticatedServiceID: host.serviceID) == .snapshotRequired)
                var changed = V2GatewayJournalRecoveryControls(); changed.versions[user] = 2
                // A device without a local socket has no revocation side effect;
                // its hint must settle rather than spin additional owner passes.
                changed.devices = [.init(userID: user.uuidValue!, deviceID: UUID())]
                try await GatewayJournalAuthorityAssembly.refresh(catalog: catalog, coordinator: coordinator,
                    registry: registry, receiver: receiver, source: source, gatewayIdentity: gateway, recovery: recovery,
                    minimumCut: 1, controls: changed)
                #expect(receiver.authenticationBinding(userID: user)?.controlVersion == 2)
                #expect(receiver.authenticationBinding(userID: otherUser)?.controlVersion == 1)
                #expect(await registry.journalUserControlInterests().count == 2)
                try await sql.raw("INSERT INTO \(unsafeRaw: schema).auth_devices(user_id,device_id,created_at,last_active_at) VALUES(\(bind: user.rawValue)::uuid,\(bind: device.rawValue)::uuid,clock_timestamp(),clock_timestamp())").run()
                let sessions = V2PostgresDeviceSessionService(database: database)
                let operation = UUID()
                #expect(try await sessions.revokeCurrentDevice(actorUserID: user, currentDeviceID: device, operationID: operation) == .applied)
                #expect(try await sessions.revokeCurrentDevice(actorUserID: user, currentDeviceID: device, operationID: operation) == .idempotent)
                changed.versions[user] = 3; changed.devices = [.init(userID: user.uuidValue!, deviceID: device.uuidValue!)]
                try await GatewayJournalAuthorityAssembly.refresh(catalog: catalog, coordinator: coordinator,
                    registry: registry, receiver: receiver, source: source, gatewayIdentity: gateway, recovery: recovery, controls: changed)
                #expect(await registry.journalUserControlInterests().count == 1)
                // A subsequent cold read forgets departed users from receiver floors.
                try await GatewayJournalAuthorityAssembly.refresh(catalog: catalog, coordinator: coordinator,
                    registry: registry, receiver: receiver, source: source, gatewayIdentity: gateway, recovery: recovery)
                #expect(receiver.authenticationBinding(userID: user) == nil)
                try await sql.raw("UPDATE \(unsafeRaw: schema).realtime_journal_publisher_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE partition_id=\(bind: partition)").run()
                let nextPublisher = try #require(try await entry.store.claim(partitionIDs: [partition], identity: host,
                    token: UUID(), leaseDuration: 30).first)
                let nextProof = try #require(try await catalog.sourceProofs(logicalAlias: "source", partitionIDs: [partition])[partition])
                try await GatewayJournalAuthorityAssembly.refresh(catalog: catalog, coordinator: coordinator,
                    registry: registry, receiver: receiver, source: source, gatewayIdentity: gateway,
                    recovery: recovery, sourceProof: nextProof)
                #expect(receiver.bindingSnapshot(source: source)?.fence.sourceLeaseEpoch == nextPublisher.epoch)
                #expect(nextPublisher.epoch > publisher.epoch)
                try await sql.raw("UPDATE \(unsafeRaw: schema).realtime_journal_publisher_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE partition_id=\(bind: partition)").run()
                await #expect(throws: GatewayJournalAuthorityError.sourceLeaseChanged) {
                    try await GatewayJournalAuthorityAssembly.refresh(catalog: catalog, coordinator: coordinator,
                        registry: registry, receiver: receiver, source: source, gatewayIdentity: gateway, recovery: recovery, minimumCut: 2)
                }
                await coordinator.deactivate(topic)
                #expect(receiver.bindingSnapshot(source: source) == nil)
                await coordinator.shutdown(); await service.shutdown()
                await registry.unregister(connectionID: otherConnection); try await otherStream.finish()
                await registry.unregister(connectionID: connection); try await stream.finish()
                await recovery.close(); receiver.shutdown(); await registry.shutdownRealtimeRecovery()
            } catch {
                await coordinator.shutdown(); await service.shutdown()
                await registry.unregister(connectionID: otherConnection); try? await otherStream.finish()
                await registry.unregister(connectionID: connection); try? await stream.finish()
                await recovery.close(); receiver.shutdown(); await registry.shutdownRealtimeRecovery()
                throw error
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func uuidTopicPartitionsMatchPersistentSQLForCanonicalAndWireCase() async throws {
        try await withCatalogDatabase { _, sql, schema in
            struct Partition: Decodable { let partition: Int }
            let samples = ["EED841A8-28BD-5C9D-8BDC-896DAEDCF9A3", "F1AC8EC2-EE9A-5147-8238-C7247D64C266",
                "FB97D94E-C7CD-5CFB-B89F-90F55D32299B"]
            for sample in samples {
                let uuid = try #require(UUID(uuidString: sample))
                for kind in [V2RealtimeTopicKind.userSync, .roomEvents] {
                    let row = try #require(try await sql.raw("""
                        SELECT \(unsafeRaw: schema).realtime_topic_partition(\(bind: kind.rawValue),\(bind: uuid)::uuid::text) AS partition
                        """).first(decoding: Partition.self))
                    let canonical = V2RealtimeTopicKey(kind: kind, id: uuid.uuidString)
                    let lower = V2RealtimeTopicKey(kind: kind, id: sample.lowercased())
                    #expect(canonical == lower && canonical.partitionID() == row.partition)
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func trustedAuthenticationRoleAggregatesPhysicalAliasesAndProofKeepsInitialDeadline() async throws {
        try await withCatalogDatabase { database, _, schema in
            let catalog = try await GatewayJournalSourceCatalog.load(registrations: [
                .init(logicalAliases: ["room-a"], database: database, schema: schema),
                .init(logicalAliases: ["control", "room-a"], database: database, schema: schema, isAuthenticationSource: true)
            ])
            let room = try catalog.entry(logicalAlias: "room-a")
            #expect(room.isAuthenticationSource)
            #expect(try catalog.entry(logicalAlias: "control").isAuthenticationSource)
            #expect(try catalog.canonicalAlias(for: room.identity) == "control")
            #expect(try catalog.authorizedAliases(for: "control") == ["control", "room-a"])
            let leases = try await room.store.claim(partitionIDs: [3],
                identity: .init(nodeID: "source", serviceID: "publisher", incarnationID: UUID()),
                token: UUID(), leaseDuration: 15)
            let lease = try #require(leases.first)
            let began = ContinuousClock.now
            let proof = try #require(try await catalog.sourceProofs(logicalAlias: "room-a", partitionIDs: [3])[3])
            _ = try await room.store.renew([lease], leaseDuration: 30)
            #expect(proof.lease.epoch == lease.epoch)
            #expect(proof.validUntil > .now && proof.validUntil <= began + .seconds(15))

        }
    }


}

/// Uses only the explicitly disposable test URL; no HTTP service or process
/// is started, and the URL is never logged by this helper.
private struct CatalogRecoveryAdmission: V2AuthenticatedGatewayCommandAdmitting {
    func admit(identity: V2AuthenticatedConnection, cost: Int, now: Date) -> Bool { true }
}

private struct CatalogRecoveryAuthenticator: V2GatewayAuthenticator {
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        throw V2RealtimeJournalError.invalidInput
    }
}
private struct CatalogRecoveryCommandHandler: V2GatewayCommandHandler {
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope { envelope }
}

private struct CatalogRecoveryTransport: V2RealtimeShardTransport {
    let service: V2RealtimeShardService
    let descriptor: V2RealtimeShardDescriptor
    func resolve(partitionID: Int) async throws -> V2RealtimeShardDescriptor { descriptor }
    func control(_ descriptor: V2RealtimeShardDescriptor, request: V2RealtimeShardControlRequest) async throws -> V2RealtimeShardControlReply {
        try await service.control(request)
    }
    func publish(_ descriptor: V2RealtimeShardDescriptor, request: V2RealtimeShardPublishRequest) async throws -> V2RealtimeShardPublishReply {
        try await service.publish(request)
    }
    func invalidate(_ descriptor: V2RealtimeShardDescriptor) async {}
}

private func withCatalogDatabase(schema: String = "catalog_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), _ operation: (any Database, any SQLDatabase, String) async throws -> Void) async throws {
    guard let url = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
          ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" else { return }
    let resources = V2DatabaseResources(eventLoopGroup: MultiThreadedEventLoopGroup(numberOfThreads: 1),
        logger: Logger(label: "imv2.catalog.tests"), ownsEventLoopGroup: true, threadPoolThreads: 1)
    var ownsSchema = false
    do {
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
        let database = resources.database(.psql)
        let sql = try #require(database as? any SQLDatabase)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for file in ["schema.sql", "realtime-change-journal.sql"] {
            let source = try String(contentsOf: root.appending(path: "IMV2/sql/" + file), encoding: .utf8)
                .replacingOccurrences(of: "im_v2", with: schema)
            for statement in catalogPostgresStatements(in: source) where statement != "BEGIN" && statement != "COMMIT" {
                try await sql.raw("\(unsafeRaw: statement)").run()
                if statement.contains("CREATE SCHEMA " + schema) { ownsSchema = true }
            }
        }
        try await operation(database, sql, schema)
        try await sql.raw("DROP SCHEMA \(unsafeRaw: schema) CASCADE").run()
        try await resources.shutdown()
    } catch {
        if ownsSchema, let sql = resources.database(.psql) as? any SQLDatabase {
            try? await sql.raw("DROP SCHEMA IF EXISTS \(unsafeRaw: schema) CASCADE").run()
        }
        try? await resources.shutdown()
        throw error
    }
}

private func catalogPostgresStatements(in source: String) -> [String] {
    var statements: [String] = []
    var buffer = ""
    var dollarQuote: String?
    var quote: Character?
    var index = source.startIndex
    while index < source.endIndex {
        let character = source[index]
        let next = source.index(after: index)
        if let active = quote {
            buffer.append(character)
            if character == active {
                if next < source.endIndex, source[next] == active {
                    buffer.append(active)
                    index = source.index(after: next)
                    continue
                }
                quote = nil
            }
            index = next
            continue
        }
        if dollarQuote == nil {
            if source[index...].hasPrefix("--") {
                index = source[index...].firstIndex(of: "\n") ?? source.endIndex
                buffer.append("\n")
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                buffer.append(character)
                index = next
                continue
            }
        }
        if character == "$" {
            let remainder = source[index...]
            if let closing = remainder.dropFirst().firstIndex(of: "$") {
                let tag = String(remainder[...closing])
                let isDollarTag = tag.dropFirst().dropLast().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
                if isDollarTag && (dollarQuote == nil || dollarQuote == tag) {
                    dollarQuote = dollarQuote == nil ? tag : nil
                    buffer.append(contentsOf: tag)
                    index = source.index(after: closing)
                    continue
                }
            }
        }
        if character == ";", dollarQuote == nil {
            let statement = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !statement.isEmpty { statements.append(statement) }
            buffer = ""
        } else {
            buffer.append(character)
        }
        index = next
    }
    let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty { statements.append(tail) }
    return statements
}
