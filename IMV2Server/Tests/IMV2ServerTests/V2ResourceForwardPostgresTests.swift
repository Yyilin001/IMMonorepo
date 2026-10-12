@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Crypto
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2Core
import PostgresNIO
import SQLKit
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

@Suite(.serialized)
struct V2ResourceForwardPostgresTests {
    @Test("message download authorization requires a current resource in its message room",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil),
          arguments: ["catalog-missing", "wrong-room", "wrong-usage", "stale-generation", "retiring"])
    func downloadAdmission(scenario: String) async throws {
        try await exercise(owner: "same", scenario: "download-" + scenario)
    }

    #if canImport(ImageIO) && canImport(CoreGraphics)
    @Test("forwarded image generates previews without an upload session",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func imageVariants() async throws { try await exercise(owner: "same", scenario: "image") }
    #endif
    @Test("sealed resources copy between room homes on one database",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil),
          arguments: ["same", "logical"], ["copy", "ack-loss", "expired-lease", "delete-intent", "scan-retry", "expired-source"])
    func colocated(owner: String, scenario: String) async throws {
        try await exercise(owner: owner, scenario: scenario)
    }

    @Test("sealed resources copy between physical owner databases",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_FORWARD_TARGET_DATABASE_URL"] != nil),
          arguments: ["copy", "ack-loss", "expired-lease", "delete-intent", "scan-retry", "expired-source"])
    func physical(scenario: String) async throws {
        try await exercise(owner: "physical", scenario: scenario)
    }

    private func exercise(owner: String, scenario: String) async throws {
        let resources = makeV2DatabaseTestResources()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resource-forward-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"]),
                maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let sourceDB = resources.database(.psql)
            let targetDB: any Database
            if owner == "physical" {
                let targetID = DatabaseID(string: "resource-forward-target")
                resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_FORWARD_TARGET_DATABASE_URL"]),
                    maxConnectionsPerEventLoop: 4), as: targetID)
                targetDB = resources.database(targetID)
            } else { targetDB = sourceDB }
            let sourceSQL = try #require(sourceDB as? any SQLDatabase), targetSQL = try #require(targetDB as? any SQLDatabase)
            let actor = UserID(uuid: UUID()), sourceRoom = RoomID(uuid: UUID()), targetRoom = RoomID(uuid: UUID())
            let shard = "rf-" + UUID().uuidString.lowercased(), now = Date()
            let targetShard = owner == "same" ? shard : shard + "-target"
            try await seed(database: sourceDB, room: sourceRoom, actor: actor, shard: shard, now: now)
            try await seed(database: targetDB, room: targetRoom, actor: actor, shard: targetShard, now: now)
            try await withRoomActivationLifetime(database: sourceDB, roomID: sourceRoom,
                                                 shardID: shard) { sourceToken, sourceLifetime in
                try await withRoomActivation(database: targetDB, roomID: targetRoom,
                                             shardID: targetShard) { targetToken in
                    let sourceRoute = try V2RoomShardRoute(shardID: shard, epoch: 0)
                    let targetRoute = try V2RoomShardRoute(shardID: targetShard, epoch: 0)
                    let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 100, retryAfterSeconds: 1))
                    let limits = try V2MessageCommandLimits(maxUTF8Bytes: 1_024)
                    let sourceStore = try PostgresV2RoomWriteStore(database: sourceDB).usingActivationScope(.init(tokens: [sourceToken]))
                    let sourceWrite = V2PolicyAuthorizedTestWriteStore(database: sourceDB, controlDatabase: sourceDB,
                        store: sourceStore, shardID: shard, epoch: 0, activationToken: sourceToken)
                    let targetWrite = try PostgresV2RoomWriteStore(database: targetDB).usingActivationScope(.init(tokens: [targetToken]))
                    let a = try V2StorageBinding(id: "forward-a", configurationRevision: 1)
                    let b = try V2StorageBinding(id: "forward-b", configurationRevision: 2)
                    let storageA = try V2LocalResourceStorage(root: root.appendingPathComponent("a"), binding: a)
                    let storageB = try V2LocalResourceStorage(root: root.appendingPathComponent("b"), binding: b)
                    let registry = try V2ResourceStorageRegistry(storages: [storageA, storageB], defaultBinding: a)
                    let switched = try V2ResourceStorageRegistry(storages: [storageA, storageB], defaultBinding: b)
                    let bytes = scenario == "image"
                        ? try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
                        : Data("independent immutable forwarded object".utf8)
                    let contentType = scenario == "image" ? "image/png" : "text/plain"
                    let mediaID = MediaID(uuid: UUID())
                    let sourceFile = root.appendingPathComponent("source-input")
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try bytes.write(to: sourceFile)
                    let facts = try await storageA.write(storageA.allocate(), byteCount: Int64(bytes.count),
                        sha256: Data(SHA256.hash(data: bytes)), bytes: V2LocalResourceStorage.stream(file: sourceFile))
                    try FileManager.default.removeItem(at: sourceFile)
                    // A catalog resource has no dependency on upload staging or an upload session.
                    try await sourceSQL.raw("""
                        INSERT INTO im_v2.media_objects(media_id,owner_user_id,content_type,byte_count,state,upload_session_id,expires_at,state_updated_at,created_at)
                        VALUES(\(bind:mediaID.uuidValue!),\(bind:actor.uuidValue!),\(bind:contentType),\(bind:facts.byteCount),'available',\(bind:UUID()),\(bind:now.addingTimeInterval(600)),\(bind:now),\(bind:now))
                        """).run()
                    try await sourceSQL.raw("""
                        INSERT INTO im_v2.resource_catalog(media_id,home_kind,home_id,usage_kind,created_at)
                        VALUES(\(bind:mediaID.uuidValue!),'room',\(bind:sourceRoom.uuidValue!),'message_attachment',\(bind:now))
                        """).run()
                    let referenceJSON = String(decoding: try JSONEncoder().encode(facts.reference), as: UTF8.self)
                    try await sourceSQL.raw("""
                        INSERT INTO im_v2.resource_blob_placements(placement_id,media_id,generation,reference_json,byte_count,sha256,state,verified_at)
                        VALUES(\(bind:facts.reference.placementID),\(bind:mediaID.uuidValue!),1,\(bind:referenceJSON)::jsonb,\(bind:facts.byteCount),\(bind:facts.sha256),'active',\(bind:now))
                        """).run()
                    let sourceCommand = try V2SendMessageCommand(roomID: sourceRoom, senderUserID: actor,
                        clientMessageID: .init(uuid: UUID()), text: "resource forward", media: [.init(mediaID: mediaID)], limits: limits)
                    let accepted = try await sourceWrite.accept(command: sourceCommand, capacityProfile: profile, identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
                    let source = try V2ForwardMessageReference(roomID: sourceRoom, messageID: #require(accepted.acceptanceReceipt).messageID, revision: .init(1))
                    if scenario.hasPrefix("download-") {
                        let device = UUID()
                        try await sourceSQL.raw("INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at) VALUES(\(bind: actor.uuidValue!),\(bind: device),clock_timestamp(),clock_timestamp())").run()
                        let executor = try V2RoomMediaAuthorizationDomainExecutor(database: sourceDB, token: sourceToken, lifetime: sourceLifetime)
                        let query = V2RoomMediaAuthorizationQuery.messageVisibility(.init(roomID: sourceRoom,
                            messageID: source.messageID, mediaID: mediaID, actorUserID: actor))
                        guard case .visible = try await executor.execute(query) else { throw V2MediaStoreError.downloadNotAuthorized }
                        #expect(try await V2PostgresMediaVisibilityAuthorization.isAuthorized(mediaID: mediaID.uuidValue!,
                            requesterUserID: actor.uuidValue!, deviceID: device, on: sourceSQL))
                        switch scenario {
                        case "download-catalog-missing": try await sourceSQL.raw("DELETE FROM im_v2.resource_catalog WHERE media_id=\(bind: mediaID.uuidValue!)").run()
                        case "download-wrong-room": try await sourceSQL.raw("UPDATE im_v2.resource_catalog SET home_id=\(bind: targetRoom.uuidValue!) WHERE media_id=\(bind: mediaID.uuidValue!)").run()
                        case "download-wrong-usage": try await sourceSQL.raw("UPDATE im_v2.resource_catalog SET usage_kind='group_avatar' WHERE media_id=\(bind: mediaID.uuidValue!)").run()
                        case "download-stale-generation": try await sourceSQL.raw("UPDATE im_v2.resource_catalog SET generation=2 WHERE media_id=\(bind: mediaID.uuidValue!)").run()
                        case "download-retiring": try await sourceSQL.raw("UPDATE im_v2.resource_blob_placements SET state='retiring' WHERE media_id=\(bind: mediaID.uuidValue!)").run()
                        default: Issue.record("unknown download scenario")
                        }
                        #expect(try await executor.execute(query) == .notVisible)
                        #expect(try await !V2PostgresMediaVisibilityAuthorization.isAuthorized(mediaID: mediaID.uuidValue!,
                            requesterUserID: actor.uuidValue!, deviceID: device, on: sourceSQL))
                        return
                    }
                    if scenario == "expired-source" {
                        try await sourceSQL.raw("UPDATE im_v2.media_objects SET expires_at=\(bind:now.addingTimeInterval(-1)) WHERE media_id=\(bind:mediaID.uuidValue!)").run()
                        let result = try await withFixturePolicyOwners(database: sourceDB,
                            projectionDelivery: SuccessfulProjectionDelivery()) { owners in
                            let policies = V2RoomPolicyAuthorizationService(roomDatabase: sourceDB,
                                policyOwners: owners, endpoint: "resource-forward-test", maximumRooms: 1)
                            do {
                                let executor = V2ActorForwardPairDomainExecutor(database: sourceDB, write: sourceStore,
                                    capacityProfile: profile, limits: limits, now: { now }).usingPolicyAuthorizations(policies)
                                let result = try await executor.execute(.init(actorUserID: actor,
                                    operationID: .init(uuid: UUID()), source: source, targetRoomID: sourceRoom),
                                    activationTokens: [sourceToken])
                                await policies.shutdown()
                                return result
                            } catch {
                                await policies.shutdown()
                                throw error
                            }
                        }
                        #expect(result.messageID != nil && result.errorCode == nil)
                        let ordinary = try V2SendMessageCommand(roomID: sourceRoom, senderUserID: actor,
                            clientMessageID: .init(uuid: UUID()), text: "new unbound use", media: [.init(mediaID: mediaID)], limits: limits)
                        await #expect(throws: V2MediaStoreError.mediaUnavailable) {
                            _ = try await sourceWrite.accept(command: ordinary, capacityProfile: profile, identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
                        }
                    }
                    let operation = MessageForwardOperationID(uuid: UUID())
                    let routing = V2ResourceForwardImportRouting(sources: [shard: sourceDB])
                    #expect(try await routing.requiresImport(actor: actor, operation: operation, source: source, target: targetRoom, route: sourceRoute))
                    #expect(try await !routing.requiresImport(actor: actor, operation: operation, source: source, target: sourceRoom, route: sourceRoute))
                    var historicalOperation: MessageForwardOperationID?
                    if owner == "same" && scenario == "copy" {
                        // Historical pair operations may have a reservation, an accepted
                        // message with a lost result update, or a complete result pointer.
                        let oldOperation = MessageForwardOperationID(uuid: UUID()), oldClient = ClientMessageID(uuid: UUID())
                        historicalOperation = oldOperation
                        try await sourceSQL.raw("""
                            INSERT INTO im_v2.message_forward_operations(actor_user_id,operation_id,source_message_id,target_room_id,target_client_message_id,source_content_revision,source_room_id,created_at)
                            VALUES(\(bind:actor.uuidValue!),\(bind:oldOperation.uuidValue!),\(bind:source.messageID.uuidValue!),\(bind:targetRoom.uuidValue!),\(bind:oldClient.uuidValue!),1,\(bind:sourceRoom.uuidValue!),\(bind:now))
                            """).run()
                        #expect(try await routing.requiresImport(actor: actor, operation: oldOperation, source: source, target: targetRoom, route: sourceRoute))
                        let oldResult = try await V2PolicyAuthorizedTestWriteStore(database: targetDB, controlDatabase: targetDB,
                            store: targetWrite, shardID: targetShard, epoch: 0, activationToken: targetToken).accept(command: .init(roomID: targetRoom, senderUserID: actor,
                            clientMessageID: oldClient, text: "historic accepted result", limits: limits), capacityProfile: profile,
                            identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
                        #expect(try await !routing.requiresImport(actor: actor, operation: oldOperation, source: source, target: targetRoom, route: sourceRoute))
                        let oldMessage = try #require(oldResult.acceptanceReceipt).messageID
                        try await sourceSQL.raw("UPDATE im_v2.message_forward_operations SET result_message_id=\(bind:oldMessage.uuidValue!) WHERE actor_user_id=\(bind:actor.uuidValue!) AND operation_id=\(bind:oldOperation.uuidValue!)").run()
                        #expect(try await !routing.requiresImport(actor: actor, operation: oldOperation, source: source, target: targetRoom, route: sourceRoute))
                    }
                    let exporter = try PostgresV2ForwardExportStore(database: sourceDB).usingActivationToken(sourceToken)
                    let export = try await exporter.prepare(actorUserID: actor, operationID: operation, source: source,
                        sourceRoute: sourceRoute, targetRoomID: targetRoom, targetRoute: targetRoute, now: now)
                    let inbox = try PostgresV2ForwardInboxStore(database: targetDB).usingActivationToken(targetToken)
                    try await inbox.receive(export, now: now)
                    // Source withdrawal after export cannot reroute or remove the committed copy authorization.
                    try await sourceSQL.raw("UPDATE im_v2.messages SET withdrawn_at=\(bind:now),withdrawn_by_user_id=\(bind:actor.uuidValue!) WHERE message_id=\(bind:source.messageID.uuidValue!)").run()
                    #expect(try await routing.requiresImport(actor: actor, operation: operation, source: source, target: targetRoom, route: sourceRoute))
                    if let historicalOperation {
                        #expect(try await !routing.requiresImport(actor: actor, operation: historicalOperation, source: source, target: targetRoom, route: sourceRoute))
                    }
                    let importer = try PostgresV2ForwardMediaImportStore(database: targetDB)
                    let lease = try #require(try await importer.claim(exportID: export.intent.exportID, now: now, leaseDuration: 1))
                    let oldCopier = try V2ResourceForwardMediaCopier(sources: [shard: sourceDB], target: importer, registry: registry,
                        maximumBytes: 1_024, allocate: { _ in try storageA.allocate() }, now: { now })
                    #expect(try await importer.resourceCopyOutput(lease, now: now) == nil)
                    let reserved: V2StoredObjectFacts
                    if scenario == "copy" || scenario == "image" {
                        // Exercise the production first-call path as well as interrupted
                        // copies whose output identity was saved before any bytes arrived.
                        _ = try await oldCopier.copy(lease)
                        reserved = try #require(try await importer.resourceCopyOutput(lease, now: now))
                    } else {
                        reserved = try await importer.prepareResourceCopy(lease, source: facts, allocate: { try storageA.allocate() }, now: now)
                    }
                    #expect(reserved.reference.placementID != facts.reference.placementID)
                    #expect(reserved.reference.binding == a)
                    let purger = V2PlacementMediaPurger(database: targetDB, registry: registry, uploads: NoStagingPurge())
                    if scenario == "delete-intent" {
                        #expect(try await importer.reject(lease, now: now))
                        try await purger.purge(mediaID: lease.targetMediaID)
                        await #expect(throws: V2ResourceProviderError.preconditionFailed) {
                            _ = try await storageA.write(reserved.reference, byteCount: facts.byteCount, sha256: facts.sha256,
                                bytes: storageA.read(facts.reference))
                        }
                        #expect(try await !importer.recordCopied(lease, receipt: .init(byteCount: facts.byteCount, digest: facts.sha256), now: now))
                    } else {
                        var copyAt = now, currentLease = lease
                        if scenario == "ack-loss" || scenario == "scan-retry" {
                            let receipt = try await oldCopier.copy(lease)
                            #expect(receipt.digest == facts.sha256)
                            if scenario == "scan-retry" {
                                #expect(try await importer.recordCopied(lease, receipt: receipt, now: now))
                                #expect(try await importer.retry(lease, disposition: .retry(at: now), now: now))
                                currentLease = try #require(try await importer.claim(exportID: export.intent.exportID, now: now, leaseDuration: 60))
                            }
                            // Lost copy acknowledgment and a retry after scan failure use the saved
                            // output even when origin bytes have become unavailable.
                            try await storageA.delete(facts.reference)
                        } else if scenario == "expired-lease" {
                            copyAt = now.addingTimeInterval(2)
                            currentLease = try #require(try await importer.claim(exportID: export.intent.exportID, now: copyAt, leaseDuration: 60))
                            #expect(currentLease.claimToken != lease.claimToken)
                            #expect(try await !importer.recordCopied(lease, receipt: .init(byteCount: facts.byteCount, digest: facts.sha256), now: copyAt))
                            await #expect(throws: V2ResourceProviderError.preconditionFailed) {
                                _ = try await importer.resourceCopyOutput(lease, now: copyAt)
                            }
                        }
                        let fixedNow = copyAt
                        let copier = try V2ResourceForwardMediaCopier(sources: [shard: sourceDB], target: importer,
                            registry: switched, maximumBytes: 1_024, allocate: { _ in
                                Issue.record("A retry allocated a different target identity")
                                throw V2ResourceProviderError.configurationInvalid
                            }, now: { fixedNow })
                        let receipt = try await copier.copy(currentLease)
                        #expect(try await importer.resourceCopyOutput(currentLease, now: copyAt) == reserved)
                        #expect(try await importer.recordCopied(currentLease, receipt: receipt, now: copyAt))
                        let variants: V2ResourceVariantProcessor?
                        if scenario == "image" {
                            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                            let transformer = try V2LocalResourceTransformer(executable: package.appendingPathComponent(".build/debug/IMV2ResourceImageWorker"),
                                temporaryDirectory: root.appendingPathComponent("processing"))
                            variants = .init(database: targetDB, registry: switched, transformer: transformer, allocate: { binding in
                                #expect(binding == a)
                                return try storageA.allocate()
                            })
                        } else { variants = nil }
                        let scanner = V2PlacementMediaScanner(database: targetDB, registry: switched,
                            scanner: V2LocalResourceScanner(), variants: variants)
                        #expect(try await scanner.scan(mediaID: currentLease.targetMediaID) == .passed)
                        if scenario == "image" {
                            #expect(try await targetSQL.raw("SELECT count(*) AS value FROM im_v2.resource_variants WHERE media_id=\(bind:currentLease.targetMediaID.uuidValue!) AND recipe='preview' AND state='ready' AND size IN (320,1280)").first(decoding: ResourceForwardCount.self)?.value == 2)
                        }
                        #expect(try await importer.complete(currentLease, receipt: receipt, result: .passed, now: copyAt))
                        _ = try await withFixturePolicyOwners(database: targetDB,
                            projectionDelivery: SuccessfulProjectionDelivery()) { owners in
                            let policies = V2RoomPolicyAuthorizationService(roomDatabase: targetDB,
                                policyOwners: owners, endpoint: "resource-import-test", maximumRooms: 1)
                            let authorizedWrite = targetWrite.usingPolicyAuthorizations(policies)
                            do {
                                let accepted = try await authorizedWrite.importForwardExport(export, capacityProfile: profile,
                                    limits: limits, identifiers: V2AcceptanceIDFactory().make(at: copyAt), now: copyAt)
                                guard case .accepted = accepted else { throw V2ForwardInboxError.corruptPersistenceState }
                                #expect(try await authorizedWrite.importForwardExport(export, capacityProfile: profile,
                                    limits: limits, identifiers: V2AcceptanceIDFactory().make(at: copyAt), now: copyAt) == accepted)
                                await policies.shutdown()
                                return accepted
                            } catch {
                                await policies.shutdown()
                                throw error
                            }
                        }
                        let terminal = try #require(try await inbox.terminalReceipt(exportID: export.intent.exportID))
                        try await PostgresV2ForwardReceiptStore(database: sourceDB).usingActivationToken(sourceToken).record(terminal, now: copyAt)
                        try await storageA.delete(facts.reference)
                        #expect(try await storageA.inspect(reserved.reference) == reserved)
                        let row = try #require(try await targetSQL.raw("""
                            SELECT home_id AS value FROM im_v2.resource_catalog WHERE media_id=\(bind:currentLease.targetMediaID.uuidValue!)
                            """).first(decoding: ResourceForwardUUID.self))
                        #expect(row.value == targetRoom.uuidValue)
                        #expect(try await targetSQL.raw("SELECT count(*) AS value FROM im_v2.resource_upload_sessions WHERE media_id=\(bind:currentLease.targetMediaID.uuidValue!)").first(decoding: ResourceForwardCount.self)?.value == 0)
                        #expect(try await targetSQL.raw("SELECT count(*) AS value FROM im_v2.messages WHERE room_id=\(bind:targetRoom.uuidValue!) AND client_message_id=\(bind:export.intent.targetClientMessageID)").first(decoding: ResourceForwardCount.self)?.value == 1)
                        let delivery = try V2LocalResourceDelivery(registry: switched, baseURL: URL(string: "https://resource.test")!,
                            keyID: "test", keys: ["test": Data(repeating: 3, count: 32)])
                        let downloads = try V2BoundMediaProvider(database: targetDB, registry: switched, delivery: delivery, transports: [])
                        let plan = try await downloads.issueDownloadTarget(mediaID: currentLease.targetMediaID, expiresAt: Date().addingTimeInterval(60))
                        let capability = try #require(URLComponents(url: plan.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cap" })?.value)
                        #expect(try await delivery.bytes(placementID: reserved.reference.placementID, capability: capability) == bytes)
                        try await downloads.purge(mediaID: currentLease.targetMediaID) // no fabricated upload transport needed
                        #expect(try await storageA.inspect(reserved.reference) == reserved)
                    }
                }
            }
            try await resources.shutdown()
        } catch {
            try? await resources.shutdown()
            if let pg = error as? PSQLError {
                Issue.record("Resource forward SQL: state=\(pg.serverInfo?[.sqlState] ?? "unknown"), constraint=\(pg.serverInfo?[.constraintName] ?? "none"), message=\(pg.serverInfo?[.message] ?? "unknown")")
            } else { throw error }
        }
    }

    private func seed(database: any Database, room: RoomID, actor: UserID, shard: String, now: Date) async throws {
        let sql = try #require(database as? any SQLDatabase)
        let handle = "rf" + actor.rawValue.replacingOccurrences(of: "-", with: "").prefix(20).lowercased()
        try await sql.raw("""
            INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,revision,created_at,updated_at)
            VALUES(\(bind:actor.uuidValue!),\(bind:handle),'Resource forward',1,\(bind:now),\(bind:now)) ON CONFLICT DO NOTHING
            """).run()
        try await sql.raw("INSERT INTO im_v2.rooms(room_id,room_shard_id,capacity_profile_id,capacity_class) VALUES(\(bind:room.uuidValue!),\(bind:shard),'standard','large')").run()
        try await sql.raw("INSERT INTO im_v2.group_rooms(room_id,owner_user_id,title,created_at) VALUES(\(bind:room.uuidValue!),\(bind:actor.uuidValue!),'Resource forward',\(bind:now))").run()
        try await sql.raw("""
            INSERT INTO im_v2.shard_admission_pools(room_shard_id,capacity_profile_id,lease_id,generation,valid_until,command_window_limit)
            VALUES(\(bind:shard),'standard',\(bind:UUID()),1,\(bind:now.addingTimeInterval(3_600)),100) ON CONFLICT DO NOTHING
            """).run()
        let lease = try #require(try await sql.raw("SELECT lease_id AS value FROM im_v2.shard_admission_pools WHERE room_shard_id=\(bind:shard)").first(decoding: ResourceForwardUUID.self))
        try await sql.raw("""
            INSERT INTO im_v2.room_admission(room_id,eligible_member_count,command_window_limit,shard_lease_id,shard_lease_generation)
            VALUES(\(bind:room.uuidValue!),1,100,\(bind:lease.value),1)
            """).run()
        try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision) VALUES(\(bind:room.uuidValue!),\(bind:actor.uuidValue!),0)").run()

    }
}

private struct ResourceForwardUUID: Decodable { let value: UUID }
private struct ResourceForwardCount: Decodable { let value: Int64 }
private struct NoStagingPurge: V2MediaPurgeProvider { func purge(mediaID: MediaID) async throws {} }
