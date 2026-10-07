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
            let registry = V2DeviceConnectionRegistry()
            let stream = V2GatewayByteStream(frameLimits: try .init(maximumPayloadBytes: 4096,
                acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]),
                session: .init(limits: try .init(maximumInFlightRequests: 1),
                    authenticator: CatalogRecoveryAuthenticator(), capabilityProfile: "base",
                    commandAdmission: CatalogRecoveryAdmission()),
                handler: CatalogRecoveryCommandHandler(), connectionID: connection, registry: registry)
            let receiver = V2GatewayJournalProjectionReceiver(projection: V2RealtimeJournalSharedProjection())
            try #require(receiver.configureAuthenticationSources(["source"]))
            let source = try catalog.source(logicalAlias: "source", partitionID: partition)
            do {
                try #require(await registry.register(stream, connectionID: connection,
                    identity: .init(userID: user, deviceID: device, capabilityProfile: "base"), publicationSuppressed: true))
                try await sql.raw("INSERT INTO \(unsafeRaw: schema).realtime_control_versions(topic_kind,topic_id,version,session_control_version) VALUES('userSync',\(bind: user.rawValue)::uuid::text,1,1)").run()
                await #expect(throws: GatewayJournalAuthorityError.coverageChanged) {
                    try await GatewayJournalAuthorityAssembly.refresh(catalog: catalog, coordinator: coordinator,
                        registry: registry, receiver: receiver, source: source, gatewayIdentity: gateway)
                }
                try await coordinator.activate(topic)
                let coverage = try #require(coordinator.journalCoverage(partitionID: partition))
                #expect(coverage.token == token && coverage.revision > 0)
                let entry = try catalog.entry(logicalAlias: "source")
                let publisher = try #require(try await entry.store.claim(partitionIDs: [partition], identity: host,
                    token: UUID(), leaseDuration: 30).first)
                try await GatewayJournalAuthorityAssembly.refresh(catalog: catalog, coordinator: coordinator,
                    registry: registry, receiver: receiver, source: source, gatewayIdentity: gateway)
                let binding = try #require(receiver.bindingSnapshot(source: source))
                #expect(binding.fence.routingLeaseToken == routingLease.token)
                #expect(binding.fence.sourceLeaseToken == publisher.token)
                #expect(binding.fence.sessionID == coverage.sessionID)
                #expect(receiver.authenticationBinding(userID: user)?.controlVersion == 1)
                try await sql.raw("UPDATE \(unsafeRaw: schema).realtime_control_versions SET version=2,session_control_version=2 WHERE topic_kind='userSync' AND topic_id=\(bind: user.rawValue)::uuid::text").run()
                try await GatewayJournalAuthorityAssembly.refresh(catalog: catalog, coordinator: coordinator,
                    registry: registry, receiver: receiver, source: source, gatewayIdentity: gateway)
                #expect(receiver.authenticationBinding(userID: user)?.controlVersion == 2)
                #expect(await registry.journalUserControlInterests().count == 1)
                try await sql.raw("INSERT INTO \(unsafeRaw: schema).auth_devices(user_id,device_id,created_at,last_active_at) VALUES(\(bind: user.rawValue)::uuid,\(bind: device.rawValue)::uuid,clock_timestamp(),clock_timestamp())").run()
                let sessions = V2PostgresDeviceSessionService(database: database)
                let operation = UUID()
                #expect(try await sessions.revokeCurrentDevice(actorUserID: user, currentDeviceID: device, operationID: operation) == .applied)
                #expect(try await sessions.revokeCurrentDevice(actorUserID: user, currentDeviceID: device, operationID: operation) == .idempotent)
                try await GatewayJournalAuthorityAssembly.refresh(catalog: catalog, coordinator: coordinator,
                    registry: registry, receiver: receiver, source: source, gatewayIdentity: gateway)
                #expect(await registry.journalUserControlInterests().isEmpty)
                // A subsequent cold read forgets departed users from receiver floors.
                try await GatewayJournalAuthorityAssembly.refresh(catalog: catalog, coordinator: coordinator,
                    registry: registry, receiver: receiver, source: source, gatewayIdentity: gateway)
                #expect(receiver.authenticationBinding(userID: user) == nil)
                try await sql.raw("UPDATE \(unsafeRaw: schema).realtime_journal_publisher_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE partition_id=\(bind: partition)").run()
                await #expect(throws: GatewayJournalAuthorityError.sourceLeaseChanged) {
                    try await GatewayJournalAuthorityAssembly.refresh(catalog: catalog, coordinator: coordinator,
                        registry: registry, receiver: receiver, source: source, gatewayIdentity: gateway)
                }
                await coordinator.deactivate(topic)
                #expect(receiver.bindingSnapshot(source: source) == nil)
                await coordinator.shutdown(); await service.shutdown()
                await registry.unregister(connectionID: connection); try await stream.finish()
                receiver.shutdown(); await registry.shutdownRealtimeRecovery()
            } catch {
                await coordinator.shutdown(); await service.shutdown()
                await registry.unregister(connectionID: connection); try? await stream.finish()
                receiver.shutdown(); await registry.shutdownRealtimeRecovery()
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
            let source = try catalog.source(logicalAlias: "room-a", partitionID: 3)
            let began = ContinuousClock.now
            let proof = try await catalog.provedSnapshot(source: source) {
                // Renewal during a read cannot extend the old read's witness.
                _ = try await room.store.renew([lease], leaseDuration: 30)
                return 7
            }
            #expect(proof.value == 7 && proof.lease.epoch == lease.epoch)
            #expect(proof.validUntil > .now && proof.validUntil <= began + .seconds(15))
            let authoritative = try await catalog.userSnapshotProof(source: source, userIDs: [], deviceIDs: [])
            #expect(authoritative.value.snapshot.identity == room.identity && authoritative.value.snapshot.users.isEmpty)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func readCannotReturnProofAfterSourceLeaseExpiresOrChangesGeneration() async throws {
        try await withCatalogDatabase { database, sql, schema in
            let catalog = try await GatewayJournalSourceCatalog.load(registrations: [
                .init(logicalAliases: ["source"], database: database, schema: schema)
            ])
            let entry = try catalog.entry(logicalAlias: "source")
            let owner = V2GatewayRealtimeIdentity(nodeID: "first", serviceID: "publisher", incarnationID: UUID())
            _ = try await entry.store.claim(partitionIDs: [4], identity: owner, token: UUID(), leaseDuration: 30)
            let source = try catalog.source(logicalAlias: "source", partitionID: 4)
            await #expect(throws: GatewayJournalSourceCatalog.CatalogError.sourceNotReady) {
                _ = try await catalog.provedSnapshot(source: source) {
                    try await sql.raw("UPDATE \(unsafeRaw: schema).realtime_journal_publisher_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE partition_id=4").run()
                    return 1
                }
            }
            _ = try await entry.store.claim(partitionIDs: [4], identity: owner, token: UUID(), leaseDuration: 30)
            await #expect(throws: GatewayJournalSourceCatalog.CatalogError.sourceNotReady) {
                _ = try await catalog.provedSnapshot(source: source) {
                    try await sql.raw("UPDATE \(unsafeRaw: schema).realtime_journal_publisher_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE partition_id=4").run()
                    let successor = try await entry.store.claim(partitionIDs: [4],
                        identity: .init(nodeID: "successor", serviceID: "publisher", incarnationID: UUID()),
                        token: UUID(), leaseDuration: 30)
                    #expect(successor.count == 1)
                    return 2
                }
            }
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
