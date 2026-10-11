@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Crypto
import FluentKit
import FluentPostgresDriver
import Foundation
import HTTPTypes
#if os(macOS)
import Darwin
#endif
import IMV2ActorContracts
import IMV2Core
import IMV2ServerHTTP
import PostgresNIO
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Synchronization
import Testing
import Vapor
import VaporTesting

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("durable forward delivery recovers owner transport and commit boundaries", arguments: ["text", "media", "media-paused-response-loss", "media-paused-revoked", "target-ack-loss", "source-ack-loss", "lease", "concurrent", "cancel", "pending", "paused", "source-owner", "target-owner", "accepted-target-owner", "enqueue-rollback", "batch", "max-attempt", "deadline"])
    func forwardDeliveryWorkerRecovery(scenario: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { sourceDB, targetDB, sourceSQL, targetSQL, targetRoom in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile(), limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let root = FileManager.default.temporaryDirectory.appending(path: "forward-delivery-\(UUID())", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: root) }
            let binding = try V2StorageBinding(id: "forward-delivery", configurationRevision: 1)
            let storage = try V2LocalResourceStorage(root: root.appending(path: "objects"), binding: binding)
            let registry = try V2ResourceStorageRegistry(storages: [storage], defaultBinding: binding)
            let byteDelivery = try V2LocalResourceDelivery(registry: registry,
                baseURL: URL(string: "https://resource.invalid")!, keyID: "fixture",
                keys: ["fixture": Data(repeating: 2, count: 32)], now: { now })
            let sourceProvider = try V2BoundMediaProvider(database: sourceDB, registry: registry,
                delivery: byteDelivery, transports: [], now: { now })
            let targetProvider = try V2BoundMediaProvider(database: targetDB, registry: registry,
                delivery: byteDelivery, transports: [], now: { now })
            func deliveredBytes(at url: URL) async throws -> Data {
                let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
                let capability = try #require(components.queryItems?.first { $0.name == "cap" }?.value)
                let placementID = try #require(UUID(uuidString: url.lastPathComponent))
                return try await byteDelivery.bytes(placementID: placementID, capability: capability)
            }
            var media: [V2MediaReference] = []
            if scenario == "media" || scenario.hasPrefix("media-paused-") {
                for value in ["first attachment", "second attachment"] {
                    let id = MediaID(uuid: UUID()), bytes = Data(value.utf8)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let input = root.appending(path: "source-input")
                    try bytes.write(to: input)
                    let facts = try await storage.write(storage.allocate(), byteCount: Int64(bytes.count),
                        sha256: Data(SHA256.hash(data: bytes)), bytes: V2LocalResourceStorage.stream(file: input))
                    try FileManager.default.removeItem(at: input)
                    try await sourceSQL.raw("""
                        INSERT INTO im_v2.media_objects (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at)
                        VALUES (\(bind: id.uuidValue!), \(bind: senderUUID), 'text/plain', \(bind: Int64(bytes.count)), 'available', \(bind: UUID()), \(bind: now.addingTimeInterval(600)), \(bind: now), \(bind: now))
                        """).run()
                    try await sourceSQL.raw("INSERT INTO im_v2.resource_catalog(media_id,home_kind,home_id,usage_kind,created_at) VALUES(\(bind:id.uuidValue!),'room',\(bind:roomID.uuidValue!),'message_attachment',\(bind:now))").run()
                    let referenceJSON = String(decoding: try JSONEncoder().encode(facts.reference), as: UTF8.self)
                    try await sourceSQL.raw("""
                        INSERT INTO im_v2.resource_blob_placements(placement_id,media_id,generation,reference_json,byte_count,sha256,state,verified_at)
                        VALUES(\(bind:facts.reference.placementID),\(bind:id.uuidValue!),1,\(bind:referenceJSON)::jsonb,\(bind:facts.byteCount),\(bind:facts.sha256),'active',\(bind:now))
                        """).run()
                    media.append(.init(mediaID: id))
                }
            }
            let send = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: sourceDB, controlDatabase: sourceDB,
                store: PostgresV2RoomWriteStore(database: sourceDB), shardID: "room-a", epoch: 0), capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "durable delivery", media: media)) else { throw V2ForwardInboxError.corruptPersistenceState }
            let exporter = PostgresV2ForwardExportStore(database: sourceDB)
            let reference = try V2ForwardMessageReference(roomID: roomID, messageID: message.messageID, revision: .init(1))
            let operation = MessageForwardOperationID(uuid: UUID())
            if scenario == "enqueue-rollback" {
                try await sourceSQL.raw("CREATE FUNCTION im_v2.zz_abort_enqueue() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'enqueue rollback'; END; $$").run()
                try await sourceSQL.raw("CREATE TRIGGER zz_abort_enqueue AFTER INSERT ON im_v2.message_forward_delivery_jobs FOR EACH ROW EXECUTE FUNCTION im_v2.zz_abort_enqueue()").run()
                await #expect(throws: (any Error).self) {
                    try await exporter.prepare(actorUserID: .init(uuid: memberTwoUUID), operationID: operation, source: reference, sourceRoute: .init(shardID: "room-a", epoch: 0), targetRoomID: targetRoom, targetRoute: .init(shardID: "room-b", epoch: 0), now: now)
                }
                #expect(try await count("im_v2.message_forward_exports", on: sourceSQL) == 0)
                #expect(try await count("im_v2.message_forward_delivery_jobs", on: sourceSQL) == 0)
                try await sourceSQL.raw("DROP TRIGGER zz_abort_enqueue ON im_v2.message_forward_delivery_jobs").run()
                try await sourceSQL.raw("DROP FUNCTION im_v2.zz_abort_enqueue()").run()
            }
            let export = try await exporter.prepare(actorUserID: .init(uuid: memberTwoUUID), operationID: operation, source: reference, sourceRoute: .init(shardID: "room-a", epoch: 0), targetRoomID: targetRoom, targetRoute: .init(shardID: "room-b", epoch: 0), now: now)
            #expect(try await count("im_v2.message_forward_delivery_jobs", on: sourceSQL) == 1)
            let inbox = PostgresV2ForwardInboxStore(database: targetDB)
            let importer = try PostgresV2ForwardMediaImportStore(database: targetDB)
            let copier = try V2ResourceForwardMediaCopier(sources: ["room-a": sourceDB], target: importer,
                registry: registry, maximumBytes: 1024, allocate: { _ in try storage.allocate() }, now: { now })
            let scanner = V2PlacementMediaScanner(database: targetDB, registry: registry, scanner: V2LocalResourceScanner())
            let mediaWorker = try V2ForwardMediaImportWorker(store: importer, copier: copier, scanner: scanner, now: { now })
            let endpoint = V2ForwardImportEndpoint(inbox: inbox, write: V2PolicyAuthorizedTestWriteStore(database: targetDB, controlDatabase: sourceDB,
                store: PostgresV2RoomWriteStore(database: targetDB), shardID: "room-b", epoch: 0), media: mediaWorker, capacityProfile: profile, limits: limits, now: { now })
            let probe = ForwardDeliveryTestTarget(target: endpoint, mode: scenario)
            let transport = try V2ConfiguredForwardExportDelivery(targets: ["room-b": probe])
            let jobs = PostgresV2ForwardDeliveryStore(database: sourceDB), receipts = PostgresV2ForwardReceiptStore(database: sourceDB)
            func worker(at time: Date, target: any V2ForwardExportDelivering) throws -> V2ForwardDeliveryWorker {
                try .init(store: jobs, receipts: receipts, target: target,
                          sourceCommand: forwardSourceCommand(database: sourceDB, now: { time }), deadline: { .now + .seconds(10) }, leaseDuration: 10, deliveryTimeout: scenario == "deadline" ? 0.1 : 8, maximumConcurrency: 2,
                          retryPolicy: .init(initialDelay: 1, maximumDelay: 1, maximumAttempts: 2, jitterFraction: 0), now: { time })
            }
            if scenario == "accepted-target-owner" {
                try await targetSQL.raw("CREATE FUNCTION im_v2.zz_hold_forward_finalization() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'hold finalization'; END; $$").run()
                try await targetSQL.raw("CREATE TRIGGER zz_hold_forward_finalization BEFORE UPDATE OF state ON im_v2.message_forward_inbox FOR EACH ROW WHEN (NEW.state='completed') EXECUTE FUNCTION im_v2.zz_hold_forward_finalization()").run()
                await #expect(throws: (any Error).self) { _ = try await endpoint.deliver(export) }
                #expect(try await inbox.status(exportID: export.intent.exportID) == .pending(.finalization))
                try await targetSQL.raw("DROP TRIGGER zz_hold_forward_finalization ON im_v2.message_forward_inbox").run()
                try await targetSQL.raw("DROP FUNCTION im_v2.zz_hold_forward_finalization()").run()
                try await targetSQL.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: targetRoom.uuidValue!)").run()
                let held = try await worker(at: now, target: transport).runOnce(sourceShardID: "room-a", limit: 10)
                #expect(held.claimed == 1 && held.retried == 1 && held.completed == 0)
                #expect(try await inbox.status(exportID: export.intent.exportID) == .pending(.finalization))
                #expect(try await inbox.terminalReceipt(exportID: export.intent.exportID) == nil)
                #expect(try await receipts.status(exportID: export.intent.exportID) == nil)
                #expect(try await sourceSQL.raw("SELECT COUNT(*) AS value FROM im_v2.message_forward_exports e WHERE NOT EXISTS (SELECT 1 FROM im_v2.message_forward_export_receipts r WHERE r.export_id=e.export_id)").first(decoding: CountRow.self)?.value == 1)
                #expect(try await count("im_v2.messages", on: targetSQL) == 1)
                // Disposable fixture restoration, not a migration protocol.
                try await targetSQL.raw("UPDATE im_v2.rooms SET owner_epoch=0 WHERE room_id=\(bind: targetRoom.uuidValue!)").run()
                let recovered = try await worker(at: now.addingTimeInterval(2), target: endpoint).runOnce(sourceShardID: "room-a", limit: 10)
                #expect(recovered.completed == 1)
                #expect(try await receipts.status(exportID: export.intent.exportID) != nil)
                #expect(try await count("im_v2.messages", on: targetSQL) == 1)
                return
            }
            if scenario.hasPrefix("media-paused-") {
                // The target commits a paused attachment and loses that reply.
                // A fresh target worker must recover the persisted disposition.
                _ = try await inbox.receive(export, now: now)
                let firstWorker = try V2ForwardMediaImportWorker(store: .init(database: targetDB),
                    copier: copier,
                    scanner: ForwardMediaFailOnceScanner(
                        scanner: scanner,
                        deterministicFailure: true
                    ),
                    retryPolicy: .init(maximumAttempts: 1), now: { now })
                #expect(try await firstWorker.runOnce(exportID: export.intent.exportID) == .paused)
                #expect(try await mediaWorker.runOnce(exportID: export.intent.exportID) == .paused)
                await #expect(throws: V2ForwardDeliveryError.mediaPaused) { try await endpoint.deliver(export) }
                let report = try await worker(at: now, target: transport).runOnce(sourceShardID: "room-a", limit: 10)
                #expect(report.paused == 1 && report.deferred == 0)
                #expect(try await jobs.isPaused(exportID: export.intent.exportID))
                #expect(try await receipts.status(exportID: export.intent.exportID) == nil)
                #expect(try await count("im_v2.messages", on: targetSQL) == 0)
                #expect(try await worker(at: now.addingTimeInterval(60), target: endpoint).runOnce(sourceShardID: "room-a", limit: 10).claimed == 0)
                let replay = try V2ForwardWorkOperatorReplayService(stores: [
                    "room-a": PostgresV2ForwardWorkReplayStore(database: sourceDB),
                    "room-b": PostgresV2ForwardWorkReplayStore(database: targetDB)
                ], operatorPrincipal: "oncall-test", now: { now })
                let mediaReplay = try V2ForwardWorkReplayCommand(operationID: UUID(), shardID: "room-b", kind: .media,
                    exportID: export.intent.exportID, ordinal: 0, reason: .dependencyRecovered)
                let sourceReplay = try V2ForwardWorkReplayCommand(operationID: UUID(), shardID: "room-a", kind: .delivery,
                    exportID: export.intent.exportID, reason: .dependencyRecovered)
                #expect(try await replay.replay(mediaReplay).outcome == .requeued)
                #expect(try await replay.replay(sourceReplay).outcome == .requeued)
                if scenario == "media-paused-revoked" {
                    try await targetSQL.raw("INSERT INTO im_v2.room_member_mutes (room_id, user_id, mute_until, actor_user_id, operation_id, created_at) VALUES (\(bind: targetRoom.uuidValue!), \(bind: memberTwoUUID), \(bind: now.addingTimeInterval(600)), \(bind: senderUUID), \(bind: UUID()), \(bind: now))").run()
                    #expect(try await worker(at: now, target: endpoint).runOnce(sourceShardID: "room-a", limit: 10).deferred == 1)
                    #expect(try await targetSQL.raw("SELECT error_code AS value FROM im_v2.message_forward_inbox WHERE export_id = \(bind: export.intent.exportID)").first(decoding: ForwardImportDigestAssertion.self)?.value == "ACTOR_MUTED")
                    #expect(try await receipts.status(exportID: export.intent.exportID) == nil)
                    #expect(try await worker(at: now.addingTimeInterval(2), target: endpoint).runOnce(sourceShardID: "room-a", limit: 10).completed == 1)
                    #expect(try await receipts.status(exportID: export.intent.exportID) == .rejected(code: "ACTOR_MUTED"))
                    #expect(try await count("im_v2.messages", on: targetSQL) == 0)
                    return
                }
                #expect(try await worker(at: now, target: endpoint).runOnce(sourceShardID: "room-a", limit: 10).deferred == 1)
                #expect(try await worker(at: now.addingTimeInterval(2), target: endpoint).runOnce(sourceShardID: "room-a", limit: 10).completed == 1)
                #expect(try await replay.replay(mediaReplay).wasIdempotent)
                #expect(try await replay.replay(sourceReplay).wasIdempotent)
                #expect(try await count("im_v2.messages", on: targetSQL) == 1)
                #expect(try await count("im_v2.message_forward_export_receipts", on: sourceSQL) == 1)
                let mapped = try await targetSQL.raw("SELECT target_media_id AS value FROM im_v2.message_forward_inbox_media ORDER BY ordinal").all(decoding: ForwardInboxUUIDAssertion.self)
                #expect(mapped.count == 2)
                for (row, value) in zip(mapped, ["first attachment", "second attachment"]) {
                    let id = MediaID(uuid: row.value)
                    let grant = try await targetProvider.issueDownloadTarget(mediaID: id, expiresAt: now.addingTimeInterval(60))
                    #expect(try await deliveredBytes(at: grant.url) == Data(value.utf8))
                }
                return
            }
            if scenario == "deadline" {
                #expect(try await worker(at: now, target: probe).runOnce(sourceShardID: "room-a", limit: 10).retried == 1)
                #expect(await probe.waiting)
                #expect(await probe.drained)
                #expect(try await receipts.status(exportID: export.intent.exportID) == nil)
                #expect(try await worker(at: now.addingTimeInterval(2), target: endpoint).runOnce(sourceShardID: "room-a", limit: 10).completed == 1)
                #expect(try await count("im_v2.messages", on: targetSQL) == 1)
                return
            }
            if scenario == "max-attempt" {
                try await sourceSQL.raw("UPDATE im_v2.message_forward_delivery_jobs SET retry_count = 9223372036854775807").run()
                let unavailable = ForwardDeliveryTestTarget(target: endpoint, mode: "paused")
                // 瞬时失败在计数饱和时同样只释放重试；要保护的不变量是计数不再增长
                // （不会溢出或回绕），而不是进入暂停。
                let report = try await worker(at: now, target: unavailable).runOnce(sourceShardID: "room-a", limit: 10)
                #expect(report.retried == 1)
                #expect(try await sourceSQL.raw("""
                    SELECT retry_count AS value FROM im_v2.message_forward_delivery_jobs
                    WHERE export_id = \(bind: export.intent.exportID)
                    """).first(decoding: CountRow.self)?.value == Int64.max)
                #expect(try await receipts.status(exportID: export.intent.exportID) == nil)
                return
            }
            if scenario == "batch" {
                for _ in 0..<4 {
                    _ = try await exporter.prepare(actorUserID: .init(uuid: memberTwoUUID), operationID: .init(uuid: UUID()), source: reference, sourceRoute: .init(shardID: "room-a", epoch: 0), targetRoomID: targetRoom, targetRoute: .init(shardID: "room-b", epoch: 0), now: now)
                }
                for expected in [2, 2, 1] {
                    let report = try await worker(at: now, target: transport).runOnce(sourceShardID: "room-a", limit: 100)
                    #expect(report.claimed == expected && report.completed == expected)
                }
                #expect(try await worker(at: now, target: transport).runOnce(sourceShardID: "room-a", limit: 100).claimed == 0)
                #expect(try await count("im_v2.messages", on: targetSQL) == 5)
                #expect(try await count("im_v2.message_forward_export_receipts", on: sourceSQL) == 5)
                #expect(await probe.calls == 5)
                return
            }
            if scenario == "source-owner" {
                try await sourceSQL.raw("UPDATE im_v2.rooms SET owner_epoch = 1 WHERE room_id = \(bind: roomUUID)").run()
                #expect(try await worker(at: now, target: transport).runOnce(sourceShardID: "room-a", limit: 10).claimed == 0)
                #expect(await probe.calls == 0)
                #expect(try await receipts.status(exportID: export.intent.exportID) == nil)
                return
            }
            if scenario == "target-owner" {
                try await targetSQL.raw("UPDATE im_v2.rooms SET owner_epoch = 1 WHERE room_id = \(bind: targetRoom.uuidValue!)").run()
            }
            if scenario == "pending" {
                for tick in 0..<12 {
                    let report = try await worker(at: now.addingTimeInterval(Double(tick)), target: transport).runOnce(sourceShardID: "room-a", limit: 10)
                    #expect(report.deferred == 1 && report.paused == 0)
                    #expect(try await receipts.status(exportID: export.intent.exportID) == nil)
                }
                #expect(try await count("im_v2.messages", on: targetSQL) == 0)
                #expect(await probe.calls == 12)
            }
            if scenario == "source-ack-loss" {
                try await sourceSQL.raw("CREATE FUNCTION im_v2.zz_abort_job_complete() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'lost completion'; END; $$").run()
                try await sourceSQL.raw("CREATE TRIGGER zz_abort_job_complete BEFORE UPDATE ON im_v2.message_forward_delivery_jobs FOR EACH ROW WHEN (NEW.state = 'completed') EXECUTE FUNCTION im_v2.zz_abort_job_complete()").run()
            }
            if scenario == "lease" {
                let old = try #require(try await jobs.claim(sourceShardID: "room-a", now: now, leaseDuration: 1, limit: 1).first)
                #expect(try await jobs.complete(old, now: now) == false)
                #expect(try await endpoint.deliver(export) != nil)
                #expect(try await jobs.claim(sourceShardID: "room-a", now: now, leaseDuration: 1, limit: 1).isEmpty)
                #expect(try await worker(at: now.addingTimeInterval(2), target: transport).runOnce(sourceShardID: "room-a", limit: 10).completed == 1)
                #expect(try await jobs.reschedule(old, disposition: .pause, now: now.addingTimeInterval(2)) == false)
                #expect(try await jobs.complete(old, now: now.addingTimeInterval(2)) == false)
            } else if scenario == "concurrent" {
                let active = try worker(at: now, target: transport)
                let completed = try await withThrowingTaskGroup(of: Int.self) { group in
                    for _ in 0..<16 { group.addTask { try await active.runOnce(sourceShardID: "room-a", limit: 10).completed } }
                    var total = 0; for try await n in group { total += n }; return total
                }
                #expect(completed == 1)
                #expect(await probe.calls == 1)
            } else if scenario == "cancel" {
                let active = try worker(at: now, target: transport)
                let task = Task { try await active.runOnce(sourceShardID: "room-a", limit: 10) }
                do {
                    for _ in 0..<500 { if await probe.waiting { break }; try await Task.sleep(for: .milliseconds(10)) }
                    #expect(await probe.waiting)
                    task.cancel()
                    await #expect(throws: CancellationError.self) { try await task.value }
                } catch { task.cancel(); _ = try? await task.value; throw error }
                #expect(try await receipts.status(exportID: export.intent.exportID) == nil)
                #expect(try await worker(at: now, target: endpoint).runOnce(sourceShardID: "room-a", limit: 10).completed == 1)
            } else {
                let firstAt = scenario == "pending" ? now.addingTimeInterval(12) : now
                let report = try await worker(at: firstAt, target: transport).runOnce(sourceShardID: "room-a", limit: 10)
                if scenario == "target-ack-loss" || scenario == "source-ack-loss" || scenario == "media" || scenario == "paused" || scenario == "target-owner" {
                    if scenario == "media" { #expect(report.deferred == 1); #expect(try await count("im_v2.messages", on: targetSQL) == 0) }
                    else { #expect(report.retried == 1) }
                    if scenario == "source-ack-loss" {
                        #expect(try await receipts.status(exportID: export.intent.exportID) != nil)
                        try await sourceSQL.raw("DROP TRIGGER zz_abort_job_complete ON im_v2.message_forward_delivery_jobs").run()
                        try await sourceSQL.raw("DROP FUNCTION im_v2.zz_abort_job_complete()").run()
                    }
                    let next = try await worker(at: now.addingTimeInterval(2), target: transport).runOnce(sourceShardID: "room-a", limit: 10)
                    if scenario == "paused" || scenario == "target-owner" {
                        // 目标不可用与 owner 变化都是瞬时失败：第二次尝试同样只释放
                        // 重试，不产生暂停行，也不产生终态回执。暂停边界的覆盖由
                        // media-paused-* 场景承担——那是唯一被 store 允许写入暂停的路径
                        // （该表的 immutable 触发器拒绝任何直接 UPDATE）。
                        #expect(next.retried == 1)
                        #expect(try await jobs.isPaused(exportID: export.intent.exportID) == false)
                        #expect(try await receipts.status(exportID: export.intent.exportID) == nil)
                        #expect(try await count("im_v2.messages", on: targetSQL) == 0)
                        return
                    }
                    #expect(next.completed == 1)
                    if scenario == "source-ack-loss" { #expect(await probe.calls == 1) }
                } else { #expect(report.completed == 1) }
            }
            guard case .accepted = try await receipts.status(exportID: export.intent.exportID) else { throw V2ForwardInboxError.corruptPersistenceState }
            #expect(try await count("im_v2.messages", on: targetSQL) == 1)
            #expect(try await sourceSQL.raw("SELECT count(*) AS value FROM im_v2.message_forward_delivery_jobs WHERE state = 'completed'").first(decoding: CountRow.self)?.value == 1)
            #expect(try await worker(at: now.addingTimeInterval(100), target: transport).runOnce(sourceShardID: "room-a", limit: 10).claimed == 0)
            if scenario == "media" {
                let mapped = try await targetSQL.raw("SELECT target_media_id AS value FROM im_v2.message_forward_inbox_media ORDER BY ordinal").all(decoding: ForwardInboxUUIDAssertion.self)
                #expect(mapped.count == 2)
                let device = DeviceID(uuid: UUID())
                try await sourceSQL.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: memberTwoUUID), \(bind: device.uuidValue!), \(bind: now), \(bind: now))").run()
                try await sourceSQL.raw("INSERT INTO im_v2.room_owner_routes (room_id, room_shard_id, route_epoch, created_at, updated_at) VALUES (\(bind: targetRoom.uuidValue!), 'room-b', 0, \(bind: now), \(bind: now)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id = EXCLUDED.room_shard_id, route_epoch = EXCLUDED.route_epoch, updated_at = EXCLUDED.updated_at").run()
                let copiedMessage = try #require(try await targetSQL.raw("SELECT message_id AS value FROM im_v2.messages").first(decoding: ForwardInboxUUIDAssertion.self))
                let downloads = V2MediaEdgeHTTPHandler(resolver: V2RoomRefMediaDownloadClient(
                    local: .init(media: .init(store: PostgresV2MediaStore(database: sourceDB)), providerSessions: try .init(store: PostgresV2MediaDownloadSessionStore(database: sourceDB), provider: sourceProvider)),
                    rooms: V2PostgresRoomShardRouter(database: sourceDB), owners: ["room-b": .init(database: targetDB, provider: targetProvider)],
                    controlDatabase: sourceDB, authorization: roomMediaAuthorizationPort(database: targetDB), now: { now }))
                for (row, value) in zip(mapped, ["first attachment", "second attachment"]) {
                    let id = MediaID(uuid: row.value)
                    let download = try await downloads.downloadTarget(actorUserID: .init(uuid: memberTwoUUID), deviceID: device, rawMediaID: id.rawValue, rawRoomID: targetRoom.rawValue, rawMessageID: copiedMessage.value.uuidString)
                    #expect(try await deliveredBytes(at: download.plan.url) == Data(value.utf8))
                }
            }
        }
    }

    @Test("message media downloads validate room ownership and control-plane device authority", arguments: ["standard", "room-log", "withdrawn", "removed", "late-join", "device", "owner", "wrong-message", "provider-revoke", "provider-device-expiry", "provider-withdraw", "provider-reference", "cancel", "clock-bounds"])
    func messageScopedMediaDownloads(scenario: String) async throws {
        try await withForwardOwnerDatabases(mode: scenario.hasPrefix("room-log") ? .large : .standard) { controlDB, ownerDB, controlSQL, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let clock = TestSequenceClock([now])
            let profile = try forwardImportTestProfile(), limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let user = UserID(uuid: memberTwoUUID), device = DeviceID(uuid: UUID()), media = MediaID(uuid: UUID())
            let root = FileManager.default.temporaryDirectory.appending(path: "message-media-\(UUID())", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: root) }
            let resource = try ConcurrentMediaResourceFixture(root: root, now: { now })
            let provider = try resource.provider(database: ownerDB)
            let bytes = Data("scoped attachment".utf8)
            try await ownerSQL.raw("""
                INSERT INTO im_v2.media_objects (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at)
                VALUES (\(bind: media.uuidValue!), \(bind: senderUUID), 'text/plain', \(bind: Int64(bytes.count)), 'available', \(bind: UUID()), \(bind: now.addingTimeInterval(600)), \(bind: now), \(bind: now))
                """).run()
            try await resource.seedPlacement(mediaID: media.uuidValue!, roomID: room, bytes: bytes, sql: ownerSQL, now: now)
            if scenario == "late-join" { try await ownerSQL.raw("DELETE FROM im_v2.room_memberships WHERE room_id = \(bind: room.uuidValue!) AND user_id = \(bind: memberTwoUUID)").run() }
            let sender = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: ownerDB, controlDatabase: controlDB,
                store: PostgresV2RoomWriteStore(database: ownerDB), shardID: "room-b", epoch: 0), capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let message) = try await sender.send(.init(roomID: room, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "download", media: [.init(mediaID: media)])) else { throw V2ForwardInboxError.corruptPersistenceState }
            try await controlSQL.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at) VALUES (\(bind: memberTwoUUID), \(bind: device.uuidValue!), \(bind: now), \(bind: now))").run()
            #expect(try await count("im_v2.auth_devices", on: ownerSQL) == 0)
            try await controlSQL.raw("INSERT INTO im_v2.room_owner_routes (room_id, room_shard_id, route_epoch, created_at, updated_at) VALUES (\(bind: room.uuidValue!), 'room-b', 0, \(bind: now), \(bind: now)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id = EXCLUDED.room_shard_id, route_epoch = EXCLUDED.route_epoch, updated_at = EXCLUDED.updated_at").run()
            #expect(try await count("im_v2.user_projection_versions", on: ownerSQL) == 0)
            #expect(try await count("im_v2.user_projection_versions", on: controlSQL) == 0)
            if scenario == "withdrawn" {
                let withdrawal = V2MessageWithdrawalService(store: PostgresV2MessageWithdrawalStore(database: ownerDB), capacityProfile: profile, now: { now })
                _ = try await withdrawal.withdraw(.init(roomID: room, actorUserID: senderID, operationID: .init(uuid: UUID()), messageID: message.messageID, expectedMessageRevision: 1))
            } else if scenario == "removed" {
                try await ownerSQL.raw("UPDATE im_v2.room_memberships SET left_revision = joined_revision WHERE room_id = \(bind: room.uuidValue!) AND user_id = \(bind: memberTwoUUID)").run()
            } else if scenario == "late-join" {
                try await ownerSQL.raw("UPDATE im_v2.rooms SET membership_revision = membership_revision + 1 WHERE room_id = \(bind: room.uuidValue!)").run()
                try await ownerSQL.raw("INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision) SELECT room_id, \(bind: memberTwoUUID), 'member', membership_revision FROM im_v2.rooms WHERE room_id = \(bind: room.uuidValue!)").run()
            } else if scenario == "device" {
                try await controlSQL.raw("UPDATE im_v2.auth_devices SET revoked_at = \(bind: now) WHERE user_id = \(bind: memberTwoUUID)").run()
            } else if scenario == "owner" {
                try await ownerSQL.raw("UPDATE im_v2.rooms SET owner_epoch = 1 WHERE room_id = \(bind: room.uuidValue!)").run()
            }
            let signing = MessageMediaTestProvider(provider: provider) {
                if scenario == "provider-device-expiry" { try await controlSQL.raw("UPDATE im_v2.auth_devices SET session_expires_at=clock_timestamp()-interval '1 second' WHERE user_id=\(bind: memberTwoUUID)").run() }
                if scenario == "provider-revoke" { try await controlSQL.raw("UPDATE im_v2.auth_devices SET revoked_at = \(bind: now) WHERE user_id = \(bind: memberTwoUUID)").run() }
                if scenario == "provider-reference" { try await ownerSQL.raw("UPDATE im_v2.message_media_references SET revoked_at = \(bind: now) WHERE message_id = \(bind: message.messageID.uuidValue!)").run() }
                if scenario == "provider-withdraw" {
                    let withdrawal = V2MessageWithdrawalService(store: PostgresV2MessageWithdrawalStore(database: ownerDB), capacityProfile: profile, now: { now })
                    _ = try await withdrawal.withdraw(.init(roomID: room, actorUserID: senderID, operationID: .init(uuid: UUID()), messageID: message.messageID, expectedMessageRevision: 1))
                }
                if scenario == "cancel" { try await Task.sleep(for: .seconds(3_600)) }
            }
            let service = V2RoomRefMediaDownloadClient(
                local: .init(media: .init(store: PostgresV2MediaStore(database: controlDB)), providerSessions: try .init(store: PostgresV2MediaDownloadSessionStore(database: controlDB), provider: provider)),
                rooms: V2PostgresRoomShardRouter(database: controlDB), owners: ["room-b": .init(database: ownerDB, provider: signing)],
                controlDatabase: controlDB, authorization: roomMediaAuthorizationPort(database: ownerDB), now: { clock.now() })
            let handler = V2MediaEdgeHTTPHandler(resolver: service)
            let rawMessage = scenario == "wrong-message" ? UUID().uuidString : message.messageID.rawValue
            @Sendable func download() async throws -> V2MediaDownloadTargetEnvelope {
                try await handler.downloadTarget(actorUserID: user, deviceID: device, rawMediaID: media.rawValue, rawRoomID: room.rawValue, rawMessageID: rawMessage)
            }
            if scenario == "clock-bounds" {
                let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
                for invalid in badDates {
                    clock.set([invalid])
                    await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await download() }
                    #expect(try await count("im_v2.media_download_grants", on: ownerSQL) == 0)
                }
                let upper = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)
                clock.set([upper])
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await download() }
                #expect(try await count("im_v2.media_download_grants", on: ownerSQL) == 0)
                // The grant fits, but a later claim clock cannot represent its lease.
                clock.set([upper.addingTimeInterval(-120), upper])
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await download() }
                #expect(try await ownerSQL.raw("SELECT state = 'pending' AND retry_count = 0 AND claim_token IS NULL AND lease_expires_at IS NULL AS exists FROM im_v2.media_download_grants").first(decoding: ExistsRow.self)?.exists == true)
                #expect(await signing.calls == 0)
                for (index, invalid) in badDates.enumerated() {
                    clock.set([now, now, now, invalid])
                    await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await download() }
                    #expect(try await count("im_v2.media_download_grants WHERE state = 'pending' AND retry_count = 1 AND claim_token IS NULL AND lease_expires_at IS NULL AND redeemed_at IS NULL", on: ownerSQL) == Int64(index + 1))
                    // A final router clock failure cannot return a target or reopen
                    // the session already consumed by the provider exchange.
                    clock.set([now, now, now, now, now, invalid])
                    await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await download() }
                    #expect(try await count("im_v2.media_download_grants WHERE state = 'consumed' AND redeemed_at IS NOT NULL AND claim_token IS NULL", on: ownerSQL) == Int64(index + 1))
                }
                clock.set([now])
                let result = try await download()
                #expect(try await resource.bytes(at: result.plan.url) == bytes)
                #expect(try await count("im_v2.media_download_grants WHERE state = 'consumed'", on: ownerSQL) == 9)
                #expect(try await count("im_v2.media_download_grants WHERE state = 'claimed'", on: ownerSQL) == 0)
                #expect(try await count("im_v2.media_download_grants", on: controlSQL) == 0)
                #expect(await signing.calls == 17)
                return
            }
            if scenario == "standard" || scenario == "room-log" {
                let result = try await download()
                #expect(try await resource.bytes(at: result.plan.url) == bytes)
                #expect(try await ownerSQL.raw("SELECT count(*) AS value FROM im_v2.media_download_grants WHERE state = 'consumed' AND message_room_id = \(bind: room.uuidValue!) AND message_id = \(bind: message.messageID.uuidValue!)").first(decoding: CountRow.self)?.value == 1)
                #expect(try await count("im_v2.media_download_grants", on: controlSQL) == 0)
                #expect(await signing.calls == 1)
                // A consumed URL grant cannot be redirected or reopened, even
                // by a caller with database write access to the row.
                await #expect(throws: (any Error).self) {
                    try await ownerSQL.raw("UPDATE im_v2.media_download_grants SET message_id = \(bind: UUID())").run()
                }
                await #expect(throws: (any Error).self) {
                    try await ownerSQL.raw("UPDATE im_v2.media_download_grants SET state = 'pending', redeemed_at = NULL").run()
                }
                await #expect(throws: (any Error).self) {
                    try await ownerSQL.raw("""
                        INSERT INTO im_v2.media_download_grants
                            (download_session_id, media_id, user_id, device_id, expires_at, created_at, message_room_id)
                        VALUES (\(bind: UUID()), \(bind: media.uuidValue!), \(bind: memberTwoUUID), \(bind: device.uuidValue!),
                                \(bind: now.addingTimeInterval(60)), \(bind: now), \(bind: room.uuidValue!))
                        """).run()
                }
            } else if scenario == "cancel" {
                let task = Task { try await download() }
                do {
                    for _ in 0..<500 { if await signing.calls == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
                    #expect(await signing.calls == 1)
                    task.cancel()
                    await #expect(throws: CancellationError.self) { try await task.value }
                    #expect(await signing.drained)
                } catch { task.cancel(); _ = try? await task.value; throw error }
            } else if scenario == "owner" {
                await #expect(throws: V2RoomActivationLeaseError.ownerChanged) { try await download() }
                #expect(await signing.calls == 0)
                #expect(try await count("im_v2.media_download_grants", on: ownerSQL) == 0)
            } else {
                await #expect(throws: V2MediaStoreError.downloadNotAuthorized) { try await download() }
                #expect(await signing.calls == (scenario.hasPrefix("provider-") ? 1 : 0))
            }
            if scenario.hasPrefix("provider-") || scenario == "cancel" {
                #expect(try await ownerSQL.raw("SELECT count(*) AS value FROM im_v2.media_download_grants WHERE state = 'pending'").first(decoding: CountRow.self)?.value == 1)
                #expect(try await ownerSQL.raw("SELECT count(*) AS value FROM im_v2.media_download_grants WHERE state = 'consumed'").first(decoding: CountRow.self)?.value == 0)
            }
        }
    }

    @Test("forward operator replay is atomic, idempotent, owner fenced and preserves media identity", arguments: [V2ForwardWorkReplayKind.delivery, .media])
    func forwardOperatorReplay(kind: V2ForwardWorkReplayKind) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { sourceDB, targetDB, sourceSQL, targetSQL, targetRoom in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile(), limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let root = FileManager.default.temporaryDirectory.appending(path: "forward-replay-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let resource = try ConcurrentMediaResourceFixture(root: root, now: { now })
            let copiedBytes = Data("copy".utf8)
            var media: [V2MediaReference] = []
            if kind == .media {
                let id = UUID()
                try await sourceSQL.raw("""
                    INSERT INTO im_v2.media_objects (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at)
                    VALUES (\(bind: id), \(bind: senderUUID), 'text/plain', 4, 'available', \(bind: UUID()), \(bind: now.addingTimeInterval(600)), \(bind: now), \(bind: now))
                    """).run()
                try await resource.seedPlacement(mediaID: id, roomID: roomID, bytes: copiedBytes, sql: sourceSQL, now: now)
                media = [.init(mediaID: .init(uuid: id))]
            }
            let send = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: sourceDB, controlDatabase: sourceDB,
                store: PostgresV2RoomWriteStore(database: sourceDB), shardID: "room-a", epoch: 0), capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "operator replay", media: media)) else { throw V2ForwardInboxError.corruptPersistenceState }
            let export = try await PostgresV2ForwardExportStore(database: sourceDB).prepare(actorUserID: .init(uuid: memberTwoUUID), operationID: .init(uuid: UUID()),
                source: .init(roomID: roomID, messageID: message.messageID, revision: .init(1)), sourceRoute: .init(shardID: "room-a", epoch: 0),
                targetRoomID: targetRoom, targetRoute: .init(shardID: "room-b", epoch: 0), now: now)
            let delivery = PostgresV2ForwardDeliveryStore(database: sourceDB)
            let importer = try PostgresV2ForwardMediaImportStore(database: targetDB)
            var oldDelivery: V2ForwardDeliveryLease?, oldMedia: V2ForwardMediaImportLease?
            let sql = kind == .delivery ? sourceSQL : targetSQL
            let ownerDB = kind == .delivery ? sourceDB : targetDB
            let shard = kind == .delivery ? "room-a" : "room-b"
            let ownerRoom = kind == .delivery ? roomUUID : targetRoom.uuidValue!
            let table = kind == .delivery ? "message_forward_delivery_jobs" : "message_forward_media_imports"
            if kind == .delivery {
                let lease = try #require(try await delivery.claim(sourceShardID: shard, now: now, leaseDuration: 30, limit: 1).first)
                #expect(try await delivery.reschedule(lease, disposition: .pause, now: now))
                oldDelivery = lease
            } else {
                try await PostgresV2ForwardInboxStore(database: targetDB).receive(export, now: now)
                let lease = try #require(try await importer.claim(exportID: export.intent.exportID, now: now, leaseDuration: 30))
                let copier = try V2ResourceForwardMediaCopier(sources: ["room-a": sourceDB], target: importer,
                    registry: resource.registry, maximumBytes: 1024, allocate: { _ in try resource.storage.allocate() }, now: { now })
                let copied = try await copier.copy(lease)
                #expect(try await importer.recordCopied(lease, receipt: copied, now: now))
                #expect(try await importer.retry(lease, disposition: .pause, now: now))
                oldMedia = lease
            }
            let store = PostgresV2ForwardWorkReplayStore(database: ownerDB)
            let service = try V2ForwardWorkOperatorReplayService(stores: [shard: store, "wrong-owner": store], operatorPrincipal: "oncall-test", now: { now })
            func command(_ id: UUID = UUID(), shardID: String? = nil, reason: V2DurableWorkReplayReason = .dependencyRecovered) throws -> V2ForwardWorkReplayCommand {
                try .init(operationID: id, shardID: shardID ?? shard, kind: kind, exportID: export.intent.exportID, ordinal: kind == .media ? 0 : nil, reason: reason)
            }
            let badClocks = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12].map { Date(timeIntervalSince1970: $0) }
            func replaySnapshot() async throws -> String {
                try #require(try await sql.raw("""
                    SELECT jsonb_build_object(
                        'audit', (SELECT jsonb_agg(to_jsonb(r) ORDER BY operation_id) FROM im_v2.forward_work_replay_audit r),
                        'jobs', (SELECT jsonb_agg(to_jsonb(r) ORDER BY export_id) FROM im_v2.\(unsafeRaw: table) r),
                        'media', (SELECT jsonb_agg(to_jsonb(r) ORDER BY media_id) FROM im_v2.media_objects r)
                    )::text AS value
                    """).first(decoding: StringValueRow.self)).value
            }
            let clockOperation = try command()
            let beforeInvalidClock = try await replaySnapshot()
            for bad in badClocks {
                await #expect(throws: V2ForwardWorkReplayError.corruptPersistenceState) {
                    _ = try await store.replay(clockOperation, operatorPrincipal: "oncall-test", now: bad)
                }
                #expect(try await replaySnapshot() == beforeInvalidClock)
            }
            await #expect(throws: V2ForwardWorkReplayError.unknownShard) { try await service.replay(command(shardID: "unknown")) }
            await #expect(throws: V2ForwardWorkReplayError.ownerChanged) { try await service.replay(command(shardID: "wrong-owner")) }
            try await sql.raw("UPDATE im_v2.rooms SET owner_epoch = 1 WHERE room_id = \(bind: ownerRoom)").run()
            await #expect(throws: V2ForwardWorkReplayError.ownerChanged) { try await service.replay(command()) }
            #expect(try await count("im_v2.forward_work_replay_audit", on: sql) == 0)
            try await sql.raw("UPDATE im_v2.rooms SET owner_epoch = 0 WHERE room_id = \(bind: ownerRoom)").run()
            try await sql.raw("CREATE FUNCTION im_v2.zz_abort_replay() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'audit rollback'; END; $$").run()
            try await sql.raw("CREATE TRIGGER zz_abort_replay BEFORE UPDATE ON im_v2.forward_work_replay_audit FOR EACH ROW EXECUTE FUNCTION im_v2.zz_abort_replay()").run()
            let operation = try command()
            await #expect(throws: (any Error).self) { try await service.replay(operation) }
            #expect(try await count("im_v2.forward_work_replay_audit", on: sql) == 0)
            #expect(try await sql.raw("SELECT state AS value FROM im_v2.\(unsafeRaw: table)").first(decoding: ForwardImportDigestAssertion.self)?.value == "paused")
            try await sql.raw("DROP TRIGGER zz_abort_replay ON im_v2.forward_work_replay_audit").run()
            try await sql.raw("DROP FUNCTION im_v2.zz_abort_replay()").run()
            let results = try await withThrowingTaskGroup(of: V2DurableWorkReplayResult.self) { group in
                for _ in 0..<16 { group.addTask { try await service.replay(operation) } }
                var results: [V2DurableWorkReplayResult] = []; for try await result in group { results.append(result) }; return results
            }
            #expect(results.allSatisfy { $0.outcome == .requeued })
            #expect(results.filter { !$0.wasIdempotent }.count == 1)
            #expect(try await count("im_v2.forward_work_replay_audit", on: sql) == 1)
            let afterReplay = try await replaySnapshot()
            for bad in badClocks {
                #expect(try await store.replay(operation, operatorPrincipal: "oncall-test", now: bad) == .init(operationID: operation.operationID, outcome: .requeued, wasIdempotent: true))
                await #expect(throws: V2ForwardWorkReplayError.idempotencyConflict) {
                    _ = try await store.replay(command(operation.operationID, reason: .dataRepaired), operatorPrincipal: "oncall-test", now: bad)
                }
                #expect(try await replaySnapshot() == afterReplay)
            }
            await #expect(throws: V2ForwardWorkReplayError.idempotencyConflict) { try await service.replay(command(operation.operationID, reason: .dataRepaired)) }
            if let oldDelivery { #expect(try await delivery.reschedule(oldDelivery, disposition: .pause, now: now) == false) }
            if let oldMedia {
                #expect(try await importer.retry(oldMedia, disposition: .pause, now: now) == false)
                #expect(try await sql.raw("SELECT encode(copied_digest, 'hex') AS value FROM im_v2.message_forward_media_imports").first(decoding: ForwardImportDigestAssertion.self)?.value == SHA256.hash(data: copiedBytes).map { String(format: "%02x", $0) }.joined())
                #expect(try await sql.raw("SELECT target_media_id AS value FROM im_v2.message_forward_media_imports").first(decoding: ForwardInboxUUIDAssertion.self)?.value == oldMedia.targetMediaID.uuidValue)
            }
            if kind == .delivery {
                let lease = try #require(try await delivery.claim(sourceShardID: shard, now: now, leaseDuration: 30, limit: 1).first)
                #expect(try await delivery.reschedule(lease, disposition: .pause, now: now))
            } else {
                let lease = try #require(try await importer.claim(exportID: export.intent.exportID, now: now, leaseDuration: 30))
                #expect(try await importer.retry(lease, disposition: .pause, now: now))
            }
            let distinct = try (0..<8).map { _ in try command() }
            let outcomes = try await withThrowingTaskGroup(of: V2DurableWorkReplayOutcome.self) { group in
                for action in distinct { group.addTask { try await service.replay(action).outcome } }
                var results: [V2DurableWorkReplayOutcome] = []; for try await result in group { results.append(result) }; return results
            }
            #expect(outcomes.filter { $0 == .requeued }.count == 1)
            #expect(outcomes.filter { $0 == .notPaused }.count == 7)
            #expect(try await count("im_v2.forward_work_replay_audit", on: sql) == 9)
            #expect(try await service.replay(command()).outcome == .notPaused)
            let notPausedCommand = try command()
            let beforeNotPaused = try await replaySnapshot()
            for bad in badClocks {
                await #expect(throws: V2ForwardWorkReplayError.corruptPersistenceState) {
                    _ = try await store.replay(notPausedCommand, operatorPrincipal: "oncall-test", now: bad)
                }
                #expect(try await replaySnapshot() == beforeNotPaused)
            }
            #expect(try await service.replay(notPausedCommand).outcome == .notPaused)
            let afterNotPaused = try await replaySnapshot()
            for bad in badClocks {
                #expect(try await store.replay(notPausedCommand, operatorPrincipal: "oncall-test", now: bad) == .init(operationID: notPausedCommand.operationID, outcome: .notPaused, wasIdempotent: true))
                #expect(try await replaySnapshot() == afterNotPaused)
            }
            if kind == .media {
                // Immutable metadata survives the terminal transition. A late
                // operator command must not revive the leftover import job.
                await #expect(throws: (any Error).self) {
                    try await sql.raw("UPDATE im_v2.message_forward_inbox SET target_epoch = 1").run()
                }
                await #expect(throws: (any Error).self) {
                    try await sql.raw("UPDATE im_v2.message_forward_inbox SET target_shard_id = 'wrong-owner'").run()
                }
                try await sql.raw("""
                    UPDATE im_v2.message_forward_inbox SET state = 'rejected', error_code = 'FORBIDDEN',
                        completed_at = \(bind: now) WHERE export_id = \(bind: export.intent.exportID)
                    """).run()
                #expect(try await PostgresV2ForwardInboxCompactor(database: targetDB).runOnce(
                    now: now.addingTimeInterval(PostgresV2ForwardInboxCompactor.retentionSeconds), limit: 1) == 1)
                let late = try command()
                #expect(try await service.replay(late).outcome == .notPaused)
                #expect(try await service.replay(late).wasIdempotent)
                await #expect(throws: V2ForwardWorkReplayError.targetUnavailable) {
                    try await service.replay(.init(operationID: UUID(), shardID: shard, kind: .media,
                        exportID: export.intent.exportID, ordinal: 1, reason: .dependencyRecovered))
                }
                await #expect(throws: V2ForwardWorkReplayError.ownerChanged) {
                    try await service.replay(command(shardID: "wrong-owner"))
                }
            }
            // An old audited operation remains stable after topology changes.
            try await sql.raw("UPDATE im_v2.rooms SET owner_epoch = 1 WHERE room_id = \(bind: ownerRoom)").run()
            #expect(try await service.replay(operation).outcome == .requeued)
            await #expect(throws: V2ForwardWorkReplayError.ownerChanged) { try await service.replay(command()) }
            await #expect(throws: (any Error).self) { try await sql.raw("UPDATE im_v2.forward_work_replay_audit SET outcome = 'not_paused' WHERE operation_id = \(bind: operation.operationID)").run() }
            await #expect(throws: (any Error).self) { try await sql.raw("DELETE FROM im_v2.forward_work_replay_audit WHERE operation_id = \(bind: operation.operationID)").run() }
            #expect(try await count("im_v2.messages", on: targetSQL) == 0)
            #expect(try await count("im_v2.message_forward_export_receipts", on: sourceSQL) == 0)
        }
    }

    @Test("routed cross-owner requests complete through an owned runtime and survive restart", arguments: [V2GroupCapacityClass.standard, .large])
    func forwardRoutedRuntimeLifecycle(mode: V2GroupCapacityClass) async throws {
        try await withForwardOwnerDatabases(mode: mode) { sourceDB, targetDB, sourceSQL, targetSQL, targetRoom in
            let now = Date()
            for sql in [sourceSQL, targetSQL] {
                try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes'").run()
            }
            let profile = try forwardImportTestProfile(), limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let actor = UserID(uuid: memberTwoUUID)
            try await sourceSQL.raw("""
                INSERT INTO im_v2.room_owner_routes (room_id, room_shard_id, route_epoch, created_at, updated_at)
                VALUES (\(bind: roomUUID), 'room-a', 0, \(bind: now), \(bind: now)),
                       (\(bind: targetRoom.uuidValue!), 'room-b', 0, \(bind: now), \(bind: now)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id = EXCLUDED.room_shard_id, route_epoch = EXCLUDED.route_epoch, updated_at = EXCLUDED.updated_at
                """).run()
            try await withFixturePolicyOwners(database: sourceDB, projectionDelivery: SuccessfulProjectionDelivery()) { owners in
            let policies = V2RoomPolicyAuthorizationService(roomDatabase: sourceDB,
                policyOwners: owners, endpoint: "routed-forward-source", maximumRooms: 1)
            do {
            let writeA = PostgresV2RoomWriteStore(database: sourceDB).usingPolicyAuthorizations(policies)
            let writeB = PostgresV2RoomWriteStore(database: targetDB)
            let send = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: sourceDB, controlDatabase: sourceDB,
                store: writeA, shardID: "room-a", epoch: 0, policyOwners: owners), capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let source) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "routed runtime")) else { throw V2ForwardInboxError.corruptPersistenceState }
            let sourceCommand = forwardSourceCommand(database: sourceDB, now: { now })
            let cross = try V2ActorCrossOwnerForwardService(sources: [
                "room-a": .init(receipts: PostgresV2ForwardReceiptStore(database: sourceDB),
                    jobs: PostgresV2ForwardDeliveryStore(database: sourceDB))
            ], sourceCommand: sourceCommand, deadline: { .now + .seconds(30) })
            let pairExecutor = V2ActorForwardPairDomainExecutor(database: sourceDB, write: writeA,
                capacityProfile: profile, limits: limits, now: { now })
            let router = try V2ActorForwardingCoordinator(router: V2PostgresRoomShardRouter(database: sourceDB),
                physicalStoreKeyByShard: ["room-a": "source-database", "room-b": "target-database"],
                pair: .init { pair, deadline in
                    #expect(pair.source.roomID == roomID && pair.targetRoomID == roomID)
                    return try await withRoomActivation(database: sourceDB, roomID: roomID) { token in
                        do {
                            let result = try await pairExecutor.execute(pair, activationTokens: [token], deadline: deadline)
                            await policies.retire(token: token)
                            return result
                        } catch {
                            await policies.retire(token: token)
                            throw error
                        }
                    }
                }, crossOwner: cross, deadline: { .now + .seconds(30) })
            let target = V2ForwardImportEndpoint(inbox: PostgresV2ForwardInboxStore(database: targetDB), write: V2PolicyAuthorizedTestWriteStore(database: targetDB, controlDatabase: sourceDB,
                store: writeB.usingWorkloadDatabase(targetDB), shardID: "room-b", epoch: 0, policyOwners: owners), capacityProfile: profile, limits: limits, now: { now })
            let transport = try V2ConfiguredForwardExportDelivery(targets: ["room-b": target])
            let worker = try V2ForwardDeliveryWorker(store: .init(database: sourceDB), receipts: PostgresV2ForwardReceiptStore(database: sourceDB), target: transport, sourceCommand: sourceCommand, deadline: { .now + .seconds(10) }, now: { now })
            let runtime = try V2ForwardDeliveryRuntime(workers: ["room-a": worker], minimumPollMilliseconds: 10)
            let reference = try V2ForwardMessageReference(roomID: roomID, messageID: source.messageID, revision: .init(1))
            let commands = try (0..<3).map { _ in try V2ForwardMessagesCommand(operationID: .init(uuid: UUID()), sources: [reference], targetRoomIDs: [roomID, targetRoom]) }
            await #expect(throws: V2ForwardPendingError.pending) { try await router.forward(actorUserID: actor, command: commands[0]) }
            // The local pair already committed, while the cross pair is only
            // durably queued. No partial completion escapes to the caller.
            #expect(try await count("im_v2.messages", on: sourceSQL) == 2)
            #expect(try await count("im_v2.messages", on: targetSQL) == 0)
            #expect(try await count("im_v2.message_forward_exports", on: sourceSQL) == 1)
            #expect(try await count("im_v2.message_forward_delivery_jobs", on: sourceSQL) == 1)
            var task: Task<Void, Never>? = Task { await runtime.run() }
            do {
                var firstResults: [V2ForwardMessageResult] = []
                for index in 0..<3 {
                    if index > 0 {
                        if index == 2 { task?.cancel(); await task?.value; task = nil }
                        if index == 2 {
                            await #expect(throws: V2ForwardPendingError.pending) { try await router.forward(actorUserID: actor, command: commands[index]) }
                        } else {
                            // An active worker may commit before the foreground
                            // receipt read; both responses are valid here.
                            do {
                                let result = try await router.forward(actorUserID: actor, command: commands[index])
                                #expect(result.count == 2 && result.allSatisfy { $0.errorCode == nil })
                            } catch V2ForwardPendingError.pending { }
                        }
                        if index == 2 {
                            try await Task.sleep(for: .milliseconds(50))
                            #expect(try await count("im_v2.messages", on: targetSQL) == 2)
                            task = Task { await runtime.run() }
                        }
                    }
                    for _ in 0..<1_000 {
                        if try await count("im_v2.message_forward_export_receipts", on: sourceSQL) == Int64(index + 1) { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    #expect(try await count("im_v2.message_forward_export_receipts", on: sourceSQL) == Int64(index + 1))
                    let result = try await router.forward(actorUserID: actor, command: commands[index])
                    #expect(result.count == 2 && result.allSatisfy { $0.errorCode == nil })
                    #expect(result.map(\.targetRoomID) == [roomID, targetRoom])
                    #expect(try await count("im_v2.messages", on: sourceSQL) == Int64(index + 2))
                    #expect(try await count("im_v2.messages", on: targetSQL) == Int64(index + 1))
                    if index == 0 { firstResults = result }
                }
                task?.cancel(); await task?.value; task = nil
                let withdrawal = V2MessageWithdrawalService(store: PostgresV2MessageWithdrawalStore(database: sourceDB), capacityProfile: profile, now: { now.addingTimeInterval(1) })
                guard case .withdrawn = try await withdrawal.withdraw(.init(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), messageID: source.messageID, expectedMessageRevision: 1)) else { throw V2ForwardInboxError.corruptPersistenceState }
                #expect(try await router.forward(actorUserID: actor, command: commands[0]) == firstResults)
                let changed = try V2ForwardMessagesCommand(operationID: commands[0].operationID, sources: [.init(roomID: roomID, messageID: source.messageID, revision: .init(2))], targetRoomIDs: [targetRoom])
                #expect(try await router.forward(actorUserID: actor, command: changed).first?.errorCode == "IDEMPOTENCY_CONFLICT")
                #expect(try await count("im_v2.message_forward_exports", on: sourceSQL) == 3)
                #expect(try await count("im_v2.messages", on: targetSQL) == 3)
            } catch { task?.cancel(); await task?.value; throw error }
            try await policies.shutdown()
            } catch { try? await policies.shutdown(); throw error }
            }
        }
    }

    @Test("multi-hop media forwards use exact active source references and reject late revocation", arguments: [V2GroupCapacityClass.standard, .large])
    func forwardedMediaUsesSourceReferences(capacityClass: V2GroupCapacityClass) async throws {
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        let root = FileManager.default.temporaryDirectory.appending(path: "forward-references-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(capacityClass: capacityClass, on: sql)
            let now = Date()
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=\(bind: now.addingTimeInterval(600))").run()
            let resource = try ConcurrentMediaResourceFixture(root: root, now: { now })
            let bytes = Data(repeating: 42, count: 42)
            let mediaIDs = [UUID(uuidString: "00000000-0000-0000-0000-00000000a202")!, UUID(uuidString: "00000000-0000-0000-0000-00000000a201")!]
            let unrelated = UUID()
            for asset in mediaIDs + [unrelated] {
                try await sql.raw("""
                    INSERT INTO im_v2.media_objects (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at)
                    VALUES (\(bind: asset), \(bind: asset == unrelated ? memberTwoUUID : senderUUID), 'image/png', 42, 'available', \(bind: UUID()), \(bind: now.addingTimeInterval(600)), \(bind: now), \(bind: now))
                    """).run()
                try await resource.seedPlacement(mediaID: asset, roomID: roomID, bytes: bytes, sql: sql, now: now)
            }
            let media = try mediaIDs.map { try V2MediaReference(mediaID: .init($0.uuidString)) }
            let limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10,
                  retryAfterSeconds: 3
            ))
            let store = CurrentSameRoomForwardTestWriteStore(database: resources.database(.psql),
                store: PostgresV2RoomWriteStore(database: resources.database(.psql)))
            let sender = V2SendMessageService(store: store, capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let original) = try await sender.send(.init(
                roomID: roomID, actorUserID: senderID, clientMessageID: .init(UUID().uuidString), text: "two shared assets", media: media
            )) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            func forward(actorUserID: UserID, command: V2ForwardMessagesCommand) async throws -> V2ActorForwardMessageResultWire {
                try await executeSameRoomForwardPairFixture(database: resources.database(.psql),
                    store: PostgresV2RoomWriteStore(database: resources.database(.psql)), actor: actorUserID,
                    source: try #require(command.sources.first), capacityProfile: profile, limits: limits,
                    now: now, operationID: command.operationID)
            }
            let actorB = try UserID(memberTwoUUID.uuidString)
            let actorC = try UserID(memberThreeUUID.uuidString)
            let firstOperation = try V2ForwardMessagesCommand(operationID: .init(UUID().uuidString), sources: [.init(roomID: roomID, messageID: original.messageID, revision: .init(1))], targetRoomIDs: [roomID])
            let first = try await forward(actorUserID: actorB, command: firstOperation)
            let messageB = try #require(first.messageID)
            let secondOperation = try V2ForwardMessagesCommand(operationID: .init(UUID().uuidString), sources: [.init(roomID: roomID, messageID: messageB, revision: .init(1))], targetRoomIDs: [roomID])
            let second = try await forward(actorUserID: actorC, command: secondOperation)
            let messageC = try #require(second.messageID)
            for message in [original.messageID, messageB, messageC] {
                let references = try await sql.raw("SELECT message_id, media_id, ordinal FROM im_v2.message_media_references WHERE message_id = \(bind: message.uuidValue!) ORDER BY ordinal").all(decoding: MediaReferenceAssertionRow.self)
                #expect(references.map(\.mediaID) == mediaIDs)
            }
            #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.media_objects WHERE owner_user_id = \(bind: senderUUID)").first(decoding: CountRow.self)?.value == 2)
            // Presentation attribution is not a way to attach unrelated media,
            // even when that unrelated asset belongs to the forwarding actor.
            for altered in [[], [media[0]], media.reversed().map { $0 }, [try V2MediaReference(mediaID: .init(unrelated.uuidString))]] {
                let request = try V2SendMessageCommand(
                    roomID: roomID, senderUserID: actorB, clientMessageID: .init(UUID().uuidString), text: original.text,
                    media: altered, forwardedFrom: .init(messageID: original.messageID, senderUserID: senderID, sourceRevision: .init(1)), limits: limits
                )
                await #expect(throws: V2RoomWriteStoreError.actorNotEligible) {
                    _ = try await store.accept(command: request, capacityProfile: profile, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
                }
            }
            let ordinary = try V2SendMessageCommand(roomID: roomID, senderUserID: actorB, clientMessageID: .init(UUID().uuidString), text: original.text, media: media, limits: limits)
            await #expect(throws: V2MediaStoreError.mediaUnavailable) {
                _ = try await store.accept(command: ordinary, capacityProfile: profile, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
            }
            #expect(try await count("im_v2.messages", on: sql) == 3)
            // Ordinary withdrawal affects its message. Copies independently
            // authorized before withdrawal still hold their own references.
            let withdrawal = V2MessageWithdrawalService(store: PostgresV2MessageWithdrawalStore(database: resources.database(.psql)), capacityProfile: profile, now: { now.addingTimeInterval(1) })
            guard case .withdrawn = try await withdrawal.withdraw(.init(
                roomID: roomID, actorUserID: senderID, operationID: .init(UUID().uuidString), messageID: original.messageID, expectedMessageRevision: 1
            )) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let third = try await forward(actorUserID: senderID, command: .init(operationID: .init(UUID().uuidString), sources: [.init(roomID: roomID, messageID: messageC, revision: .init(1))], targetRoomIDs: [roomID]))
            #expect(third.messageID != nil)
            let originalDenied = try await forward(actorUserID: actorB, command: .init(operationID: .init(UUID().uuidString), sources: [.init(roomID: roomID, messageID: original.messageID, revision: .init(1))], targetRoomIDs: [roomID]))
            #expect(originalDenied.errorCode == "NOT_FOUND")
            // Capture both references, then revoke one before final SQL acceptance.
            let capturedRevoked = try V2SendMessageCommand(roomID: roomID, senderUserID: actorC,
                clientMessageID: .init(uuid: UUID()), text: original.text, media: media,
                forwardedFrom: .init(messageID: messageB, senderUserID: actorB, sourceRevision: .init(1)), limits: limits)
            try await sql.raw("UPDATE im_v2.message_media_references SET revoked_at=\(bind: now) WHERE message_id=\(bind: messageB.uuidValue!) AND media_id=\(bind: mediaIDs[0])").run()
            await #expect(throws: V2RoomWriteStoreError.actorNotEligible) {
                _ = try await store.accept(command: capturedRevoked, capacityProfile: profile,
                    identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
            }
            let alreadyRevoked = try await forward(actorUserID: actorC, command: .init(operationID: .init(UUID().uuidString), sources: [.init(roomID: roomID, messageID: messageB, revision: .init(1))], targetRoomIDs: [roomID]))
            #expect(alreadyRevoked.errorCode == "NOT_FOUND")
            // Never silently strip the revoked image and forward the caption
            // with the remaining image. No message, reference, or receipt leaks.
            #expect(try await count("im_v2.messages", on: sql) == 4)
            #expect(try await count("im_v2.message_media_references", on: sql) == 8)
            #expect(try await count("im_v2.message_send_completions", on: sql) == 4)
            let capturedRetired = try V2SendMessageCommand(roomID: roomID, senderUserID: actorB,
                clientMessageID: .init(uuid: UUID()), text: original.text, media: media,
                forwardedFrom: .init(messageID: messageC, senderUserID: actorC, sourceRevision: .init(1)), limits: limits)
            // Binding expiry alone does not revoke a bound reference; retiring its placement does.
            try await sql.raw("UPDATE im_v2.media_objects SET expires_at=\(bind: now.addingTimeInterval(-1)) WHERE media_id=\(bind: mediaIDs[0])").run()
            try await sql.raw("UPDATE im_v2.resource_blob_placements SET state='retiring' WHERE media_id=\(bind: mediaIDs[0])").run()
            await #expect(throws: V2MediaStoreError.mediaUnavailable) {
                _ = try await store.accept(command: capturedRetired, capacityProfile: profile,
                    identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
            }
            #expect(try await count("im_v2.messages", on: sql) == 4)
            #expect(try await count("im_v2.message_media_references", on: sql) == 8)
            #expect(try await count("im_v2.message_send_completions", on: sql) == 4)
            try await sql.raw("UPDATE im_v2.resource_blob_placements SET state = 'active' WHERE media_id = \(bind: mediaIDs[0])").run()
            try await sql.raw("UPDATE im_v2.media_objects SET state = 'failed', expires_at = \(bind: now.addingTimeInterval(600)) WHERE media_id = \(bind: mediaIDs[0])").run()
            await #expect(throws: V2MediaStoreError.mediaUnavailable) {
                _ = try await forward(actorUserID: actorB, command: .init(operationID: .init(UUID().uuidString),
                    sources: [.init(roomID: roomID, messageID: messageC, revision: .init(1))], targetRoomIDs: [roomID]))
            }
            #expect(try await count("im_v2.messages", on: sql) == 4)
            #expect(try await count("im_v2.message_media_references", on: sql) == 8)
            #expect(try await count("im_v2.message_send_completions", on: sql) == 4)
            #expect(try await forward(actorUserID: actorC, command: secondOperation) == second)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("forward requires the current content version audience after rejoin", arguments: [V2GroupCapacityClass.standard, .large])
    func forwardChecksEditedVersionAudience(capacityClass: V2GroupCapacityClass) async throws {
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(capacityClass: capacityClass, on: sql)
            try await sql.raw("DELETE FROM im_v2.room_memberships WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: memberThreeUUID)").run()
            try await sql.raw("UPDATE im_v2.room_admission SET eligible_member_count = 2 WHERE room_id = \(bind: roomUUID)").run()
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10,
                  retryAfterSeconds: 3
            ))
            let store = PostgresV2RoomWriteStore(database: resources.database(.psql))
            let send = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: resources.database(.psql),
                controlDatabase: resources.database(.psql), store: store, shardID: "room-a", epoch: 0),
                capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let source) = try await send.send(.init(
                roomID: roomID, actorUserID: senderID, clientMessageID: .init(UUID().uuidString), text: "before leaving"
            )) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            func check(_ allowed: Bool, revision: UInt64, body: String, actor: UUID = memberTwoUUID, messageID: MessageID? = nil) async throws {
                let sourceID = messageID ?? source.messageID
                let actorID = try UserID(actor.uuidString)
                let beforeRead = try await count("im_v2.messages", on: sql)
                let result = try await executeSameRoomForwardPairFixture(database: resources.database(.psql), store: store,
                    actor: actorID, source: .init(roomID: roomID, messageID: sourceID, revision: .init(revision)),
                    capacityProfile: profile, limits: limits, now: now)
                #expect(result.errorCode == (allowed ? nil : "NOT_FOUND"))
                #expect(try await count("im_v2.messages", on: sql) == beforeRead + (allowed ? 1 : 0))
                if allowed {
                    let forwardedID = try #require(result.messageID?.uuidValue)
                    let text = try await sql.raw("SELECT text_body AS value FROM im_v2.messages WHERE message_id=\(bind: forwardedID)")
                        .first(decoding: StringValueRow.self)?.value
                    #expect(text == body)
                }
                do {
                    let exported = try await PostgresV2ForwardExportStore(database: resources.database(.psql)).prepare(
                        actorUserID: actorID, operationID: .init(uuid: UUID()),
                        source: .init(roomID: roomID, messageID: sourceID, revision: .init(revision)),
                        sourceRoute: .init(shardID: "room-a", epoch: 0), targetRoomID: .init(uuid: UUID()),
                        targetRoute: .init(shardID: "remote-owner", epoch: 0), now: now)
                    #expect(allowed && exported.intent.text == body)
                } catch V2ForwardExportError.sourceUnavailable { #expect(!allowed) }
                let countBefore = try await count("im_v2.messages", on: sql)
                let request = try V2SendMessageCommand(
                    roomID: roomID, senderUserID: actorID, clientMessageID: .init(UUID().uuidString), text: body,
                    forwardedFrom: .init(messageID: sourceID, senderUserID: senderID, sourceRevision: .init(revision)), limits: limits
                )
                do {
                    let outcome = try await acceptSameRoomForwardFixture(database: resources.database(.psql), store: store, command: request, capacityProfile: profile, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
                    #expect(allowed)
                    #expect(outcome.acceptanceReceipt != nil)
                } catch V2RoomWriteStoreError.actorNotEligible { #expect(!allowed) }
                #expect(try await count("im_v2.messages", on: sql) == countBefore + (allowed ? 1 : 0))
            }
            try await check(true, revision: 1, body: "before leaving")
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = 1 WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: memberTwoUUID)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1 WHERE room_id = \(bind: roomUUID)").run()
            try await sql.raw("UPDATE im_v2.room_admission SET eligible_member_count = 1 WHERE room_id = \(bind: roomUUID)").run()
            let edit = V2MessageEditService(store: PostgresV2MessageEditStore(database: resources.database(.psql)), capacityProfile: profile, maximumTextUTF8Bytes: 64, now: { now.addingTimeInterval(1) })
            guard case .edited = try await edit.edit(.init(
                roomID: roomID, actorUserID: senderID, operationID: .init(UUID().uuidString), messageID: source.messageID,
                expectedMessageRevision: 1, text: "private during absence"
            )) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision) VALUES (\(bind: roomUUID), \(bind: memberTwoUUID), 3), (\(bind: roomUUID), \(bind: memberThreeUUID), 3)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 3 WHERE room_id = \(bind: roomUUID)").run()
            try await sql.raw("UPDATE im_v2.room_admission SET eligible_member_count = 3 WHERE room_id = \(bind: roomUUID)").run()
            // Accepted rev1 is visible and the actor is active again, but rev2
            // was committed at exactly the old interval's exclusive end.
            try await check(false, revision: 2, body: "private during absence")
            guard case .edited = try await edit.edit(.init(
                roomID: roomID, actorUserID: senderID, operationID: .init(UUID().uuidString), messageID: source.messageID,
                expectedMessageRevision: 2, text: "visible after rejoin"
            )) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await check(true, revision: 3, body: "visible after rejoin")
            // A new member sees the current edit's membership interval, but
            // still lacks the original accepted audience.
            try await check(false, revision: 3, body: "visible after rejoin", actor: memberThreeUUID)
            try await V2SchemaReadiness.verify(database: resources.database(.psql))
            try await assertSQLSchemaGate(true, on: sql)
            await #expect(throws: (any Error).self) {
                try await sql.raw("""
                    INSERT INTO im_v2.room_events (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                    SELECT \(bind: UUID()), room_id, 900, event_type, actor_user_id, payload, 3, created_at
                    FROM im_v2.room_events WHERE event_type = 'message.edited' AND payload->>'message_revision' = '3'
                    """).run()
            }
            // A current revision without projection state is readable only through its exact immutable edit event.
            func installSyntheticAcceptance(_ messageID: UUID) async throws {
                // These synthetic content fixtures must include the same
                // immutable acceptance fact that real writes always commit.
                try await sql.raw("""
                    INSERT INTO im_v2.message_send_completions
                        (room_id,sender_user_id,client_message_id,fingerprint_version,request_fingerprint,message_id,event_id,room_sequence,timeline_sequence,accepted_membership_revision,group_capacity_class,created_at)
                    SELECT message.room_id,message.sender_user_id,message.client_message_id,3,decode(repeat('00',32),'hex'),message.message_id,accepted.event_id,message.room_sequence,message.timeline_sequence,accepted.committed_membership_revision,
                           room.capacity_class,message.created_at
                    FROM im_v2.messages message JOIN im_v2.rooms room ON room.room_id=message.room_id
                    JOIN im_v2.room_events accepted ON accepted.room_id=message.room_id AND accepted.room_sequence=message.room_sequence AND accepted.event_type='message.accepted'
                    WHERE message.message_id=\(bind: messageID)
                    """).run()
            }
            let legacy = UUID()
            try await sql.raw("""
                INSERT INTO im_v2.messages (message_id, room_id, room_sequence, timeline_sequence, sender_user_id, client_message_id, text_body, content_revision, created_at)
                VALUES (\(bind: legacy), \(bind: roomUUID), 100, 100, \(bind: senderUUID), \(bind: UUID()), 'legacy current', 2, \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_events (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                VALUES (\(bind: UUID()), \(bind: roomUUID), 100, 'message.accepted', \(bind: senderUUID),
                        jsonb_build_object('message_id', \(bind: legacy.uuidString)), 0, \(bind: now)),
                       (\(bind: UUID()), \(bind: roomUUID), 101, 'message.edited', \(bind: senderUUID),
                        jsonb_build_object('message_id', \(bind: legacy.uuidString), 'room_id', \(bind: roomUUID.uuidString), 'message_revision', 2), 3, \(bind: now))
                """).run()
            try await sql.raw("UPDATE im_v2.rooms SET room_sequence = 101, timeline_sequence = 100 WHERE room_id = \(bind: roomUUID)").run()
            try await check(false, revision: 2, body: "legacy current", messageID: .init(legacy.uuidString))
            try await installSyntheticAcceptance(legacy)
            try await check(true, revision: 2, body: "legacy current", messageID: .init(legacy.uuidString))
            // Missing and mismatched current-version evidence fail closed,
            // even though the original accepted interval is authorized.
            let missing = UUID()
            try await sql.raw("""
                INSERT INTO im_v2.messages (message_id, room_id, room_sequence, timeline_sequence, sender_user_id, client_message_id, text_body, content_revision, created_at)
                VALUES (\(bind: missing), \(bind: roomUUID), 110, 110, \(bind: senderUUID), \(bind: UUID()), 'unproven body', 2, \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_events (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                VALUES (\(bind: UUID()), \(bind: roomUUID), 110, 'message.accepted', \(bind: senderUUID), jsonb_build_object('message_id', \(bind: missing.uuidString)), 0, \(bind: now))
                """).run()
            try await installSyntheticAcceptance(missing)
            try await check(false, revision: 2, body: "unproven body", messageID: .init(missing.uuidString))
            await #expect(throws: PSQLError.self) {
                try await sql.raw("""
                    INSERT INTO im_v2.room_events (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                    VALUES (\(bind: UUID()), \(bind: roomUUID), 111, 'message.edited', \(bind: senderUUID),
                            jsonb_build_object('message_id', \(bind: missing.uuidString), 'room_id', \(bind: UUID().uuidString), 'message_revision', 2), 3, \(bind: now))
                    """).run()
            }
            try await check(false, revision: 2, body: "unproven body", messageID: .init(missing.uuidString))
            // The predicate must remain a point lookup as room history grows.
            try await sql.raw("""
                INSERT INTO im_v2.room_events (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                SELECT md5('audience-event-' || n)::uuid, \(bind: roomUUID), 1000 + n, 'message.edited', \(bind: senderUUID),
                       jsonb_build_object('message_id', md5('audience-message-' || n)::uuid::text, 'room_id', \(bind: roomUUID.uuidString), 'message_revision', 2), 3, \(bind: now)
                FROM generate_series(1, 2000) AS input(n)
                """).run()
            try await sql.raw("UPDATE im_v2.rooms SET room_sequence = 3000 WHERE room_id = \(bind: roomUUID)").run()
            try await sql.raw("ANALYZE im_v2.room_events").run()
            try await sql.raw("""
                INSERT INTO im_v2.message_send_completions
                    (room_id,sender_user_id,client_message_id,fingerprint_version,request_fingerprint,message_id,event_id,room_sequence,timeline_sequence,accepted_membership_revision,group_capacity_class,created_at)
                SELECT room_id,sender_user_id,md5('audience-client-'||n)::uuid,fingerprint_version,request_fingerprint,md5('audience-message-'||n)::uuid,md5('audience-accepted-'||n)::uuid,1000+n,1000+n,accepted_membership_revision,group_capacity_class,created_at
                FROM im_v2.message_send_completions CROSS JOIN generate_series(1,2000) AS input(n)
                WHERE message_id=\(bind: legacy)
                """).run()
            try await sql.raw("ANALYZE im_v2.message_send_completions").run()

            let plan = try await sql.raw("""
                EXPLAIN (COSTS OFF) SELECT message.message_id FROM im_v2.messages AS message
                JOIN im_v2.rooms AS room ON room.room_id = message.room_id
                WHERE message.message_id = \(bind: legacy)
                  AND (\(v2ForwardSourceVisibility(actorID: memberTwoUUID)))
                """).all().map { try $0.decode(column: "QUERY PLAN", as: String.self) }.joined(separator: "\n")
            #expect(plan.contains("room_events_message_edit_revision_idx"))
            #expect(plan.contains("message_send_completions_pkey"))
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("forward source revision survives ABA, retry, and completion")
    func forwardSourceRevisionFencesABAAndRetry() async throws {
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists")
                .first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            let now = Date()
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until = \(bind: now.addingTimeInterval(600))").run()
            let limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10,
                  retryAfterSeconds: 3
            ))
            let store = CurrentSameRoomForwardTestWriteStore(database: resources.database(.psql),
                store: PostgresV2RoomWriteStore(database: resources.database(.psql)))
            let send = V2SendMessageService(store: store, capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let source) = try await send.send(.init(
                roomID: roomID, actorUserID: senderID, clientMessageID: .init(UUID().uuidString), text: "original"
            )) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await V2SchemaReadiness.verify(database: resources.database(.psql))
            #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.message_send_completions WHERE fingerprint_version = 3").first(decoding: CountRow.self)?.value == 1)
            let rawStore = PostgresV2RoomWriteStore(database: resources.database(.psql))
            func forward(_ command: V2ForwardMessagesCommand, at timestamp: Date) async throws -> V2ActorForwardMessageResultWire {
                try await executeSameRoomForwardPairFixture(database: resources.database(.psql), store: rawStore,
                    actor: senderID, source: try #require(command.sources.first), capacityProfile: profile,
                    limits: limits, now: timestamp, operationID: command.operationID)
            }
            let edit = V2MessageEditService(store: PostgresV2MessageEditStore(database: resources.database(.psql)), capacityProfile: profile, maximumTextUTF8Bytes: 64, now: { now.addingTimeInterval(1) })
            let captured = try V2SendMessageCommand(roomID: roomID, senderUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "original",
                forwardedFrom: .init(messageID: source.messageID, senderUserID: senderID, sourceRevision: .init(1)), limits: limits)
            do {
                for (revision, body) in [(UInt64(1), "changed"), (UInt64(2), "original")] {
                    let outcome = try await edit.edit(.init(
                        roomID: roomID, actorUserID: senderID, operationID: .init(UUID().uuidString),
                        messageID: source.messageID, expectedMessageRevision: revision, text: body
                    ))
                    guard case .edited = outcome else { throw V2RoomWriteStoreError.corruptPersistenceState }
                }
            }
            // The SQL acceptance boundary must also reject a payload captured before the ABA edits.
            await #expect(throws: (any Error).self) {
                _ = try await store.accept(command: captured, capacityProfile: profile,
                    identifiers: V2AcceptanceIDFactory().make(at: now), now: now)
            }
            let operation = try V2ForwardMessagesCommand(operationID: .init(UUID().uuidString), sources: [.init(roomID: roomID, messageID: source.messageID, revision: .init(1))], targetRoomIDs: [roomID])
            let first = try await forward(operation, at: now)
            #expect(first.errorCode == "SOURCE_CHANGED")
            #expect(try await count("im_v2.messages", on: sql) == 1)
            let state = try #require(try await sql.raw("SELECT text_body, content_revision FROM im_v2.messages WHERE message_id = \(bind: source.messageID.uuidValue!)").first(decoding: EditMessageStateRow.self))
            #expect(state.text == "original")
            #expect(state.revision == 3)
            // New service instance, same durable operation: do not silently
            // rebind revision 1 to revision 3, even though the bytes match.
            let retry = try await forward(operation, at: now)
            #expect(retry.errorCode == "SOURCE_CHANGED")
            #expect(try await count("im_v2.message_forward_operations", on: sql) == 0)
            let freshOperation = try V2ForwardMessagesCommand(operationID: .init(UUID().uuidString), sources: [.init(roomID: roomID, messageID: source.messageID, revision: .init(3))], targetRoomIDs: [roomID])
            let fresh = try await forward(freshOperation, at: now)
            #expect(fresh.errorCode == nil && fresh.messageID != nil)
            struct ForwardClientRow: Decodable { let value: UUID }
            let freshClient = try #require(try await sql.raw("SELECT target_client_message_id AS value FROM im_v2.message_forward_operations WHERE operation_id=\(bind: freshOperation.operationID.uuidValue!)").first(decoding: ForwardClientRow.self)).value
            // The mapping to a target client ID is an acceptance fence, not
            // an expiring cache. A late replay must not generate a second send.
            let later = now.addingTimeInterval(V2IdempotencyPolicy.minimumServerRetention + 86_400)
            // Keep admission available at the late retry, so a lost mapping
            // exposes duplicate acceptance instead of an expired fixture lease.
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until = \(bind: later.addingTimeInterval(3_600))").run()
            let housekeeping = PostgresV2ControlPlaneHousekeepingStore(database: resources.database(.psql))
            _ = try await housekeeping.purgeTerminal(now: later, retention: 60,
                idempotencyRetention: V2IdempotencyPolicy.minimumServerRetention, limit: 1_024)
            #expect(try await count("im_v2.message_forward_operations", on: sql) == 1)
            let lateReplay = try await forward(freshOperation, at: later)
            try #require(lateReplay == fresh)
            #expect(try await count("im_v2.messages", on: sql) == 2)
            #expect(try await forward(operation, at: later).errorCode == "SOURCE_CHANGED")
            let changed = try V2ForwardMessageReference(roomID: roomID, messageID: source.messageID, revision: .init(1))
            let changedReplay = try V2ForwardMessagesCommand(operationID: freshOperation.operationID,
                sources: [changed], targetRoomIDs: [roomID])
            #expect(try await forward(changedReplay, at: now).errorCode == "IDEMPOTENCY_CONFLICT")
            let newIntent = try V2ForwardMessagesCommand(operationID: .init(uuid: UUID()),
                sources: [changed], targetRoomIDs: [roomID])
            #expect(try await forward(newIntent, at: now).errorCode == "SOURCE_CHANGED")
            // An unowned source room cannot enter the current pair execution boundary.
            let wrongSource = try V2ForwardMessagesCommand(operationID: freshOperation.operationID,
                sources: [.init(roomID: .init(uuid: UUID()), messageID: source.messageID, revision: .init(3))],
                targetRoomIDs: [roomID])
            await #expect(throws: (any Error).self) { _ = try await forward(wrongSource, at: now) }
            await #expect(throws: (any Error).self) {
                try await sql.raw("UPDATE im_v2.message_forward_operations SET source_content_revision=1 WHERE operation_id=\(bind: freshOperation.operationID.uuidValue!)").run()
            }
            await #expect(throws: (any Error).self) {
                try await sql.raw("UPDATE im_v2.message_forward_operations SET source_room_id = \(bind: UUID()) WHERE operation_id = \(bind: freshOperation.operationID.uuidValue!)").run()
            }
            #expect(try await count("im_v2.messages", on: sql) == 2)
            #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.message_send_completions WHERE fingerprint_version = 3").first(decoding: CountRow.self)?.value == 2)
            // Exact accepted version is part of durable replay identity, while
            // a later source mutation cannot invalidate the accepted result.
            guard case .edited = try await edit.edit(.init(
                roomID: roomID, actorUserID: senderID, operationID: .init(UUID().uuidString),
                messageID: source.messageID, expectedMessageRevision: 3, text: "later"
            )) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            for revision: UInt64 in [3, 4] {
                let request = try V2SendMessageCommand(
                    roomID: roomID, senderUserID: senderID, clientMessageID: .init(freshClient.uuidString), text: "original",
                    forwardedFrom: .init(messageID: source.messageID, senderUserID: senderID, sourceRevision: .init(revision)), limits: limits
                )
                let replay = try await store.accept(command: request, capacityProfile: profile, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
                if revision == 3 {
                    #expect(replay.acceptanceReceipt?.messageID == fresh.messageID)
                } else { #expect(replay == .idempotencyConflict) }
            }
            #expect(try await forward(freshOperation, at: now) == fresh)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("forward reads and acceptance intersect original and current membership intervals", arguments: ["room_event", "message_row"])
    func forwardRequiresHistoricalAndCurrentMembership(storage: String) async throws {
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists")
                .first(decoding: ExistsRow.self))?.exists == false
            else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 10,

                 retryAfterSeconds: 3
            ))
            let limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let writeStore = PostgresV2RoomWriteStore(database: resources.database(.psql))
            let sender = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: resources.database(.psql),
                controlDatabase: resources.database(.psql), store: writeStore, shardID: "room-a", epoch: 0),
                capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let source) = try await sender.send(.init(
                roomID: roomID, actorUserID: senderID,
                clientMessageID: .init(UUID().uuidString), text: "historical body"
            )) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let sourceID = try #require(UUID(uuidString: source.messageID.rawValue))
            if storage == "message_row" {
                // Exercise the second canonical accepted representation. The
                // current body remains mutable in both storage generations.
                try await sql.raw("""
                    UPDATE im_v2.messages SET accepted_event_storage = 'message_row',
                        accepted_event_id = \(bind: UUID()), accepted_membership_revision = 0
                    WHERE message_id = \(bind: sourceID)
                    """).run()
            }
            let actorID = try UserID(memberTwoUUID.uuidString)
            func check(_ allowed: Bool, messageID: MessageID? = nil) async throws {
                let checkedMessageID = messageID ?? source.messageID
                let beforeRead = try await count("im_v2.messages", on: sql)
                let result = try await executeSameRoomForwardPairFixture(database: resources.database(.psql), store: writeStore,
                    actor: actorID, source: .init(roomID: roomID, messageID: checkedMessageID, revision: .init(1)),
                    capacityProfile: profile, limits: limits, now: now)
                #expect(result.errorCode == (allowed ? nil : "NOT_FOUND"))
                #expect((result.messageID != nil) == allowed)
                #expect(try await count("im_v2.messages", on: sql) == beforeRead + (allowed ? 1 : 0))
                // Bypass the initial reader with a previously captured source.
                // The final database boundary must independently enforce it.
                let request = try V2SendMessageCommand(
                    roomID: roomID, senderUserID: actorID, clientMessageID: .init(UUID().uuidString),
                    text: source.text, forwardedFrom: .init(messageID: checkedMessageID, senderUserID: senderID, sourceRevision: .init(1)), limits: limits
                )
                let before = try await count("im_v2.messages", on: sql)
                do {
                    let outcome = try await acceptSameRoomForwardFixture(database: resources.database(.psql), store: writeStore,
                        command: request, capacityProfile: profile,
                        identifiers: try V2AcceptanceIDFactory().make(at: now), now: now
                    )
                    #expect(allowed)
                    #expect(outcome.acceptanceReceipt != nil)
                } catch V2RoomWriteStoreError.actorNotEligible {
                    #expect(!allowed)
                }
                #expect(try await count("im_v2.messages", on: sql) == before + (allowed ? 1 : 0))
                if allowed {
                    let alteredEntities = try V2SendMessageCommand(
                        roomID: roomID, senderUserID: actorID, clientMessageID: .init(UUID().uuidString),
                        text: source.text, entities: [.init(offsetUTF16: 0, lengthUTF16: 1, kind: .bold)],
                        forwardedFrom: .init(messageID: checkedMessageID, senderUserID: senderID, sourceRevision: .init(1)), limits: limits
                    )
                    await #expect(throws: V2RoomWriteStoreError.actorNotEligible) {
                        _ = try await acceptSameRoomForwardFixture(database: resources.database(.psql), store: writeStore,
                            command: alteredEntities, capacityProfile: profile,
                            identifiers: try V2AcceptanceIDFactory().make(at: now), now: now
                        )
                    }
                    #expect(try await count("im_v2.messages", on: sql) == before + 1)
                }
            }
            try await check(true)
            // Removed users retain a historical interval, but no current one.
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = 1 WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: memberTwoUUID)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1 WHERE room_id = \(bind: roomUUID)").run()
            try await check(false)
            // Accept a real second source while this member is absent. Keep
            // the append-only event intact; authorization must use its revision.
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 2 WHERE room_id = \(bind: roomUUID)").run()
            guard case .accepted(let gapSource) = try await sender.send(.init(
                roomID: roomID, actorUserID: senderID,
                clientMessageID: .init(UUID().uuidString), text: source.text
            )) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            if storage == "message_row" {
                try await sql.raw("""
                    UPDATE im_v2.messages SET accepted_event_storage = 'message_row',
                        accepted_event_id = \(bind: UUID()), accepted_membership_revision = 2
                    WHERE message_id = \(bind: gapSource.messageID.uuidValue!)
                    """).run()
            }
            // Rejoining restores access to messages from the first interval.
            try await sql.raw("INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision) VALUES (\(bind: roomUUID), \(bind: memberTwoUUID), 3)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 3 WHERE room_id = \(bind: roomUUID)").run()
            try await check(true)
            // A message accepted in the gap stays invisible after rejoining.
            try await check(false, messageID: gapSource.messageID)
            // Brand-new membership cannot authorize any earlier accepted body.
            try await sql.raw("DELETE FROM im_v2.room_memberships WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: memberTwoUUID) AND joined_revision = 0").run()
            try await check(false)
            if storage == "room_event" {
                // Deliberately incomplete legacy data: a message without its
                // accepted event cannot borrow today's membership revision.
                let orphan = UUID()
                try await sql.raw("""
                    INSERT INTO im_v2.messages
                        (message_id, room_id, room_sequence, timeline_sequence,
                         sender_user_id, client_message_id, text_body, created_at)
                    VALUES (\(bind: orphan), \(bind: roomUUID), 100, 100,
                            \(bind: senderUUID), \(bind: UUID()), \(bind: source.text), \(bind: now))
                    """).run()
                try await check(false, messageID: .init(orphan.uuidString))
                // A same-sequence accepted event for another identity is also
                // insufficient. No append-only trigger is disabled or altered.
                try await sql.raw("""
                    INSERT INTO im_v2.room_events
                        (event_id, room_id, room_sequence, event_type, actor_user_id,
                         payload, committed_membership_revision, created_at)
                    VALUES (\(bind: UUID()), \(bind: roomUUID), 100, 'message.accepted',
                            \(bind: senderUUID), jsonb_build_object('message_id', \(bind: UUID().uuidString)::text),
                            3, \(bind: now))
                    """).run()
                try await check(false, messageID: .init(orphan.uuidString))
            }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("Current Actor pair forwards serialize opposite room lock sets and recheck source membership", arguments: [false, true])
    func oppositeForwardsUseCanonicalRoomLocks(reverseArrival: Bool) async throws {
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            // The 16 independent replica tasks must reach PostgreSQL together;
            // a one-connection fixture would serialize them before room locks.
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 16), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists")
                .first(decoding: ExistsRow.self))?.exists == false
            else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            let otherRoom = UUID()
            let otherRoomID = try RoomID(otherRoom.uuidString)
            let now = Date()
            try await sql.raw("""
                INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id)
                VALUES (\(bind: otherRoom), 'room-a', 'standard')
                """).run()
            try await sql.raw("INSERT INTO im_v2.room_owner_routes (room_id, room_shard_id, route_epoch, created_at, updated_at) VALUES (\(bind: otherRoom), 'room-a', 0, \(bind: now), \(bind: now))").run()
            try await sql.raw("INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at) VALUES (\(bind: otherRoom), \(bind: senderUUID), 'other', \(bind: now))").run()
            try await sql.raw("""
                INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision)
                SELECT \(bind: otherRoom), user_id, joined_revision FROM im_v2.room_memberships WHERE room_id = \(bind: roomUUID)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_admission
                    (room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation)
                VALUES (\(bind: otherRoom), 3, 10, \(bind: leaseUUID), 1)
                """).run()
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET command_window_limit = 100, valid_until=clock_timestamp()+interval '10 minutes'").run()
            try await sql.raw("UPDATE im_v2.room_admission SET command_window_limit = 100").run()
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 10, maxCommandsPerWindow: 100,

                 retryAfterSeconds: 3
            ))
            let limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let store = PostgresV2RoomWriteStore(database: resources.database(.psql))
            let sender = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(database: resources.database(.psql),
                controlDatabase: resources.database(.psql), store: store, shardID: "room-a", epoch: 0), capacityProfile: profile, limits: limits, now: { now })
            var sources: [V2AcceptedMessage] = []
            for destination in [roomID, otherRoomID] {
                guard case .accepted(let source) = try await sender.send(.init(
                    roomID: destination, actorUserID: senderID,
                    clientMessageID: .init(UUID().uuidString), text: "opposite source"
                )) else { throw V2RoomWriteStoreError.corruptPersistenceState }
                sources.append(source)
            }
            let fixedSources = sources
            try await withRoomActivation(database: resources.database(.psql), roomID: roomID) { firstToken in
            try await withRoomActivation(database: resources.database(.psql), roomID: otherRoomID) { secondToken in
            try await withFixturePolicyOwners(database: resources.database(.psql),
                projectionDelivery: SuccessfulProjectionDelivery()) { owners in
                let policies = V2RoomPolicyAuthorizationService(roomDatabase: resources.database(.psql),
                    policyOwners: owners, endpoint: "opposite-pair-test", maximumRooms: 2)
                do {
                    let tokens = [firstToken, secondToken]
                    let pairs = try (0..<16).map { index in
                        let source = fixedSources[(index + (reverseArrival ? 1 : 0)) % 2]
                        return V2ActorForwardPairWire(actorUserID: senderID,
                            operationID: .init(uuid: UUID()), source: try .init(roomID: source.roomID,
                                messageID: source.messageID, revision: .init(1)),
                            targetRoomID: fixedSources.first(where: { $0.roomID != source.roomID })!.roomID)
                    }
                    let results = try await withThrowingTaskGroup(of: V2ActorForwardMessageResultWire.self) { group in
                        for pair in pairs {
                            group.addTask {
                                // Separate executor/store instances exercise the real SQL room-lock order.
                                let executor = V2ActorForwardPairDomainExecutor(database: resources.database(.psql),
                                    write: PostgresV2RoomWriteStore(database: resources.database(.psql)),
                                    capacityProfile: profile, limits: limits, now: { now }).usingPolicyAuthorizations(policies)
                                return try await executor.execute(pair, activationTokens: tokens)
                            }
                        }
                        var results: [V2ActorForwardMessageResultWire] = []
                        for try await result in group { results.append(result) }
                        return results
                    }
                    #expect(results.count == 16)
                    #expect(results.allSatisfy { $0.errorCode == nil && $0.messageID != nil })
                    #expect(Set(results.compactMap(\.messageID)).count == 16)
                    #expect(try await count("im_v2.messages", on: sql) == 18)
                    #expect(try await count("im_v2.message_send_completions", on: sql) == 18)
                    #expect(try await count("im_v2.message_forward_operations WHERE result_message_id IS NOT NULL", on: sql) == 16)
                    let executor = V2ActorForwardPairDomainExecutor(database: resources.database(.psql),
                        write: store, capacityProfile: profile, limits: limits, now: { now }).usingPolicyAuthorizations(policies)
                    let replay = try await executor.execute(pairs[0], activationTokens: tokens)
                    #expect(results.contains(replay))
                    #expect(try await count("im_v2.messages", on: sql) == 18)
                    // The source is visible before removal. A new pair after removal must
                    // reject the source even though the actor still belongs to the target.
                    let actor = UserID(uuid: memberTwoUUID)
                    let visible = try await sql.raw("""
                        SELECT count(*) AS value FROM im_v2.messages AS message
                        JOIN im_v2.rooms AS room ON room.room_id=message.room_id
                        WHERE message.message_id=\(bind: fixedSources[0].messageID.uuidValue!)
                          AND (\(v2ForwardSourceVisibility(actorID: memberTwoUUID)))
                        """).first(decoding: CountRow.self)?.value
                    #expect(visible == 1)
                    try await resources.database(.psql).transaction { transaction in
                        let transactionSQL = try #require(transaction as? any SQLDatabase)
                        try await transactionSQL.raw("SELECT room_id FROM im_v2.rooms WHERE room_id = \(bind: roomUUID) FOR UPDATE").run()
                        try await transactionSQL.raw("UPDATE im_v2.room_memberships SET left_revision = 1 WHERE room_id = \(bind: roomUUID) AND user_id = \(bind: memberTwoUUID) AND left_revision IS NULL").run()
                        try await transactionSQL.raw("UPDATE im_v2.rooms SET membership_revision = 1 WHERE room_id = \(bind: roomUUID)").run()
                    }
                    let revokedPair = V2ActorForwardPairWire(actorUserID: actor,
                        operationID: .init(uuid: UUID()), source: try .init(roomID: roomID,
                            messageID: fixedSources[0].messageID, revision: .init(1)), targetRoomID: otherRoomID)
                    let revoked = try await executor.execute(revokedPair, activationTokens: tokens)
                    #expect(revoked.errorCode == "NOT_FOUND" && revoked.messageID == nil)
                    #expect(try await count("im_v2.messages", on: sql) == 18)
                    #expect(try await count("im_v2.message_send_completions", on: sql) == 18)
                    #expect(try await count("im_v2.message_forward_operations", on: sql) == 16)
                    try await assertAllAcceptedMessagesHaveCompletions(sql: sql)
                    await policies.shutdown()
                } catch {
                    await policies.shutdown()
                    throw error
                }
            }
            }
            }

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("a 100k hybrid group creation commits one atomic membership and personal discovery events")
    func createsOneHundredThousandMemberHybridRoomAtomically() async throws {
        guard ProcessInfo.processInfo.environment["IMV2_RUN_HYBRID_100K_GROUP_CREATE"] == "1",
              let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
        else { return }

        let startedAt = Date()
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            guard let sql = resources.database(.psql) as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else {
                throw TestConfigurationError.schemaAlreadyExists
            }
            try await installSchema(on: sql)
            let schemaElapsed = v2LocalElapsedMilliseconds(since: startedAt)

            let owner = try UserID("00000000-0000-0000-0000-000000000001")
            let operationID = try GroupRoomOperationID("00000000-0000-0000-0000-00000000c001")
            let lease = UUID(uuidString: "00000000-0000-0000-0000-00000000c002")!
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
                VALUES ('hybrid-create-100k', 'hybrid-create-100k', \(bind: lease), 1, \(bind: now.addingTimeInterval(600)), 100_000)
                """).run()
            let profileLimits = try RoomCapacityProfile(
                maxEligibleMembers: 100_000,
                maxCommandsPerWindow: 100_000,

                retryAfterSeconds: 1
            )
            let ownerUUID = try #require(UUID(uuidString: owner.rawValue))
            let operationUUID = try #require(UUID(uuidString: operationID.rawValue))
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, created_at, updated_at)
                SELECT ('00000000-0000-0000-0000-' || lpad(to_hex(value), 12, '0'))::uuid,
                       'member' || lpad(value::text, 6, '0'),
                       '成员 ' || value::text,
                       1, \(bind: now), \(bind: now)
                FROM generate_series(1, 100000) AS value
                """).run()
            let canonical = try V2GroupCreationAudience.canonical((2...100_000).map { value in
                UserID(uuid: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!)
            }, actorUserID: owner)
            let intent = try V2GroupCreationIntent(identity: .init(accountID: owner, scope: .account(owner), operation: .groupRoom(operationID)),
                title: "十万人混合群创建回归", capacityClass: .large, initialMemberCount: canonical.count,
                audienceDigest: V2GroupCreationAudience.digest(canonical), firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))
            let service = try V2GroupCreationOperationTestFixture(control: resources.database(.psql), owner: resources.database(.psql),
                shardID: "hybrid-create-100k", capacityProfile: .init(id: "hybrid-create-100k", limits: profileLimits), now: { now })
            let creationStartedAt = Date()
            let group = try await service.create(intent: intent, canonicalMembers: canonical, now: now)
            let creationElapsed = v2LocalElapsedMilliseconds(since: creationStartedAt)
            let room = UUID(uuidString: group.roomID.rawValue)!
            let accounting = try #require(try await sql.raw("""
                SELECT
                    (SELECT COUNT(*) FROM im_v2.room_memberships WHERE room_id = \(bind: room)) AS member_count,
                    (SELECT COUNT(*) FROM im_v2.user_state_event_outbox AS target
                     JOIN im_v2.room_events AS event ON event.event_id = target.source_event_id
                     WHERE event.room_id = \(bind: room)) AS target_count,
                    (SELECT capacity_class FROM im_v2.rooms WHERE room_id = \(bind: room)) AS capacity_class,
                    (SELECT COUNT(*) FROM im_v2.group_creation_owner_receipts WHERE actor_user_id = \(bind: ownerUUID) AND operation_id = \(bind: operationUUID)) AS operation_count,
                    (SELECT (receipt->'outcome'->'created'->>'memberCount')::bigint FROM im_v2.group_creation_owner_receipts WHERE actor_user_id = \(bind: ownerUUID) AND operation_id = \(bind: operationUUID)) AS operation_member_count,
                    (SELECT cardinality(initial_member_user_ids) FROM im_v2.group_room_operations WHERE actor_user_id = \(bind: ownerUUID) AND operation_id = \(bind: operationUUID)) AS materialized_operation_member_count
                """).first(decoding: GroupCreateScaleAccountingRow.self))

            #expect(group.capacityClass == .large)
            #expect(group.memberCount == 100_000)
            #expect(accounting.memberCount == 100_000)
            #expect(accounting.targetCount == 100_000)
            #expect(accounting.capacityClass == V2GroupCapacityClass.large.rawValue)
            #expect(accounting.operationCount == 1)
            #expect(group.receipt.validates(intent: intent))
            #expect(accounting.operationMemberCount == 100_000)
            #expect(accounting.materializedOperationMemberCount == 0)
            print("V2_LOCAL_HYBRID_100K_GROUP_CREATE_TIMING total_wall_ms=\(v2LocalElapsedMilliseconds(since: startedAt)) schema_ms=\(schemaElapsed) create_ms=\(creationElapsed) members=\(accounting.memberCount) personal_discovery_events=\(accounting.targetCount)")

            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("reciprocal sends preserve stranger limits, activation fencing and active policy changes", arguments: [false, true])
    func reciprocalSendsRespectCurrentPolicy(_ actorScoped: Bool) async throws {
        guard let databaseURL = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
        else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(
                try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2),
                as: .psql,
                isDefault: true
            )
            guard let sql = resources.database(.psql) as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists")
                .first(decoding: ExistsRow.self))?.exists == false
            else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)

            let now = Date()
            let profile = try V2CapacityProfile(id: "reciprocal-fast", limits: .init(
                maxEligibleMembers: 10,
                maxCommandsPerWindow: 100,

                retryAfterSeconds: 1
            ))
            let lease = UUID(uuidString: "00000000-0000-0000-0002-000000000001")!
            let firstUUID = UUID(uuidString: "00000000-0000-0000-0002-000000000002")!
            let secondUUID = UUID(uuidString: "00000000-0000-0000-0002-000000000003")!
            let first = try UserID(firstUUID.uuidString)
            let second = try UserID(secondUUID.uuidString)
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools
                    (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
                VALUES ('reciprocal-shard', \(bind: profile.id), \(bind: lease), 1, \(bind: now.addingTimeInterval(600)), 100)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles
                    (user_id, public_handle, display_name, revision, created_at, updated_at)
                VALUES
                    (\(bind: firstUUID), 'reciprocal01', '双向一', 1, \(bind: now), \(bind: now)),
                    (\(bind: secondUUID), 'reciprocal02', '双向二', 1, \(bind: now), \(bind: now))
                """).run()
            let direct = try V2DirectRoomOperationTestFixture(
                store: PostgresV2DirectMessagingStore(database: resources.database(.psql), identityReader: PostgresV2DirectRoomIdentityReader(database: resources.database(.psql)), projectionDelivery: SuccessfulProjectionDelivery()),
                capacityProfile: profile,
                roomShardID: "reciprocal-shard",
                now: { now }
            )
            let room = try await direct.openedIdentity(
                actorUserID: first,
                operationID: try .init("00000000-0000-0000-0002-000000000004"),
                targetUserID: second
            , firstSubmissionDeadlineMilliseconds: V2DirectRoomOperationTestFixture.deadline(now))

            try await withFixturePolicyOwners(database: resources.database(.psql), projectionDelivery: SuccessfulProjectionDelivery()) { owners in
            let writer = PostgresV2RoomWriteStore(
                database: resources.database(.psql),
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 2, window: 86_400),
                contentReviewMode: .disabled)
            var selectedWriter = V2PolicyAuthorizedTestWriteStore(database: resources.database(.psql),
                controlDatabase: resources.database(.psql), store: writer,
                shardID: "reciprocal-shard", epoch: 0, policyOwners: owners)
            if actorScoped {
                let owner = try V2RoomDataOwner(shardID: "reciprocal-shard", epoch: 0)
                let host = V2ActorHostIdentity(
                    hostID: try .init("reciprocal-fast-test"), incarnationID: UUID()
                )
                let activations = PostgresV2RoomActivationStore(database: resources.database(.psql))
                guard case .acquired(let lease) = try await activations.acquire(
                    roomID: room.roomID, owner: owner, host: host, duration: .init(30_000)
                ) else { throw V2RoomActivationLeaseError.activationChanged }
                selectedWriter.activationToken = lease.token
            }
            let messages = V2SendMessageService(
                store: selectedWriter,
                capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64),
                now: { now }
            )
            guard case .accepted = try await messages.send(.init(
                roomID: room.roomID,
                actorUserID: first,
                clientMessageID: try .init("00000000-0000-0000-0002-000000000011"),
                text: "一方首次发送"
            )) else {
                Issue.record("expected first-send acceptance")
                return
            }

            guard case .accepted = try await messages.send(.init(
                roomID: room.roomID,
                actorUserID: first,
                clientMessageID: try .init("00000000-0000-0000-0002-000000000012"),
                text: "一方额度内快速发送"
            )) else {
                Issue.record("expected quota-bearing fast append")
                return
            }
            let quota = try #require(try await sql.raw("""
                SELECT message_count::bigint AS value
                FROM im_v2.stranger_message_windows
                WHERE sender_user_id = \(bind: firstUUID)
                  AND recipient_user_id = \(bind: secondUUID)
                """).first(decoding: CountRow.self))
            #expect(quota.value == 2)

            do {
                _ = try await messages.send(.init(
                    roomID: room.roomID,
                    actorUserID: first,
                    clientMessageID: try .init("00000000-0000-0000-0002-000000000013"),
                    text: "超出陌生人额度"
                ))
                Issue.record("expected exact stranger quota denial")
                return
            } catch V2RoomWriteStoreError.strangerMessageLimitReached {
                // The gateway maps this domain error to RATE_LIMITED. Keeping
                // it as an error at the service boundary is the existing API.
            }

            // A reply changes the business rule: this pair is no longer a
            // one-sided stranger conversation, so later messages correctly
            // stop consuming the exhausted stranger window.
            guard case .accepted = try await messages.send(.init(
                roomID: room.roomID,
                actorUserID: second,
                clientMessageID: try .init("00000000-0000-0000-0002-000000000014"),
                text: "另一方首次发送"
            )) else {
                Issue.record("expected reciprocal first-send acceptance")
                return
            }

            guard case .accepted = try await messages.send(.init(
                roomID: room.roomID,
                actorUserID: first,
                clientMessageID: try .init("00000000-0000-0000-0002-000000000015"),
                text: "回复后重新装载缓存"
            )) else {
                Issue.record("expected post-reply cache reload")
                return
            }

            for (actor, clientID, text) in [
                (first, "00000000-0000-0000-0002-000000000016", "一方稳定发送"),
                (second, "00000000-0000-0000-0002-000000000017", "另一方稳定发送"),
            ] {
                guard case .accepted = try await messages.send(.init(
                    roomID: room.roomID,
                    actorUserID: actor,
                    clientMessageID: try .init(clientID),
                    text: text
                )) else {
                    Issue.record("expected steady-state acceptance")
                    return
                }
            }

            if actorScoped {
                let roomUUID = try #require(room.roomID.uuidValue)
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: roomUUID)").run()
                let stale = V2AuthenticatedSendMessage(roomID: room.roomID, actorUserID: first, clientMessageID: .init(uuid: UUID()), text: "stale warm append")
                await #expect(throws: V2RoomActivationLeaseError.ownerChanged) { _ = try await messages.send(stale) }
                // Restore epoch only in this disposable fixture, then verify
                // the failed message can be retried.
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=0 WHERE room_id=\(bind: roomUUID)").run()
                guard case .accepted = try await messages.send(stale) else { throw V2RoomWriteStoreError.corruptPersistenceState }
                let replay = try await messages.send(stale)
                guard case .idempotent = replay else { throw V2RoomWriteStoreError.corruptPersistenceState }
                guard case .accepted = try await messages.send(.init(roomID: room.roomID, actorUserID: first, clientMessageID: .init(uuid: UUID()), text: "warm after replay")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            }

            let social = PostgresV2SocialRelationshipStore(database: resources.database(.psql),
                projectionDelivery: SuccessfulProjectionDelivery(), policyOwners: owners)
            _ = try await social.executeSocialFixture(actorUserID: second, targetUserID: first,
                operation: .userBlock(.init(uuid: UUID())), action: .userBlock(.block), now: now)
            await #expect(throws: V2SendOperationResponseError.directPolicyDenied) {
                try await messages.send(.init(roomID: room.roomID, actorUserID: first,
                    clientMessageID: .init("00000000-0000-0000-0002-000000000018"), text: "封禁后拒绝发送"))
            }

            try await assertAllAcceptedMessagesHaveCompletions(sql: sql)
            }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await resources.shutdown()
            throw error
        }
    }

}

/// Test schema installation must handle PostgreSQL function bodies as a
/// single statement. A plain `split(separator: ";")` breaks `$$` blocks and
/// can mask bootstrap failures before a database-backed regression starts.

/// 会话摘要夹具使用的接受形态。
private struct GroupCreateScaleAccountingRow: Decodable {
    let memberCount: Int64
    let targetCount: Int64
    let capacityClass: String
    let operationCount: Int64
    let operationMemberCount: Int
    let materializedOperationMemberCount: Int
    enum CodingKeys: String, CodingKey {
        case memberCount = "member_count"
        case targetCount = "target_count"
        case capacityClass = "capacity_class"
        case operationCount = "operation_count"
        case operationMemberCount = "operation_member_count"
        case materializedOperationMemberCount = "materialized_operation_member_count"
    }
}

private actor ForwardDeliveryTestTarget: V2ForwardExportDelivering {
    let target: any V2ForwardExportDelivering
    let mode: String
    private(set) var calls = 0
    private(set) var waiting = false
    private(set) var drained = false
    init(target: any V2ForwardExportDelivering, mode: String) { self.target = target; self.mode = mode }
    func deliver(_ export: V2ForwardExport) async throws -> V2ForwardTerminalReceipt? {
        calls += 1
        // Exercise target pending directly; retired room credits no longer gate delivery.
        if mode == "pending", calls <= 12 { return nil }
        if mode == "paused" { throw V2ForwardDeliveryError.targetUnavailable }
        if mode == "deadline" {
            waiting = true
            defer { drained = true }
            try await Task.sleep(for: .seconds(60))
        }
        let receipt = try await target.deliver(export)
        if mode == "target-ack-loss" && calls == 1 { throw V2ForwardDeliveryError.targetUnavailable }
        if mode == "cancel" {
            waiting = true
            try await Task.sleep(for: .seconds(60))
        }
        return receipt
    }
}

private actor MessageMediaTestProvider: V2MediaObjectProvider {
    let provider: any V2MediaObjectProvider
    let beforeReturn: @Sendable () async throws -> Void
    private(set) var calls = 0
    private(set) var drained = false
    init(provider: any V2MediaObjectProvider, beforeReturn: @escaping @Sendable () async throws -> Void) {
        self.provider = provider; self.beforeReturn = beforeReturn
    }
    func issueDownloadTarget(mediaID: MediaID, expiresAt: Date) async throws -> V2ResourceTransferPlan {
        calls += 1
        defer { drained = true }
        let result = try await provider.issueDownloadTarget(mediaID: mediaID, expiresAt: expiresAt)
        try await beforeReturn()
        return result
    }
}

/// Exact resource placements for these message/forward fixtures; media metadata is seeded by each test.
struct ConcurrentMediaResourceFixture: Sendable {
    let root: URL
    let storage: V2LocalResourceStorage
    let registry: V2ResourceStorageRegistry
    let delivery: V2LocalResourceDelivery
    private let now: @Sendable () -> Date
    init(root: URL, now: @escaping @Sendable () -> Date) throws {
        self.root = root; self.now = now
        let binding = try V2StorageBinding(id: "concurrent-media", configurationRevision: 1)
        storage = try V2LocalResourceStorage(root: root.appending(path: "objects"), binding: binding)
        registry = try V2ResourceStorageRegistry(storages: [storage], defaultBinding: binding)
        delivery = try V2LocalResourceDelivery(registry: registry, baseURL: URL(string: "https://resource.invalid")!,
            keyID: "fixture", keys: ["fixture": Data(repeating: 3, count: 32)], now: now)
    }
    func seedPlacement(mediaID: UUID, roomID: RoomID, bytes: Data, sql: any SQLDatabase, now: Date) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "input-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try bytes.write(to: file)
        let facts = try await storage.write(storage.allocate(), byteCount: Int64(bytes.count),
            sha256: Data(SHA256.hash(data: bytes)), bytes: V2LocalResourceStorage.stream(file: file))
        try await sql.raw("INSERT INTO im_v2.resource_catalog(media_id,home_kind,home_id,usage_kind,created_at) VALUES(\(bind:mediaID),'room',\(bind:roomID.uuidValue!),'message_attachment',\(bind:now))").run()
        let reference = String(decoding: try JSONEncoder().encode(facts.reference), as: UTF8.self)
        try await sql.raw("""
            INSERT INTO im_v2.resource_blob_placements(placement_id,media_id,generation,reference_json,byte_count,sha256,state,verified_at)
            VALUES(\(bind:facts.reference.placementID),\(bind:mediaID),1,\(bind:reference)::jsonb,\(bind:facts.byteCount),\(bind:facts.sha256),'active',\(bind:now))
            """).run()
    }
    func provider(database: any Database) throws -> V2BoundMediaProvider {
        try .init(database: database, registry: registry, delivery: delivery, transports: [], now: now)
    }
    func bytes(at url: URL) async throws -> Data {
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let capability = try #require(parts.queryItems?.first { $0.name == "cap" }?.value)
        let placement = try #require(UUID(uuidString: url.lastPathComponent))
        let stream = try await delivery.stream(placementID: placement, capability: capability)
        do {
            let result = try await collect(stream.bytes)
            await stream.close()
            return result
        } catch { await stream.close(); throw error }
    }
    func facts(mediaID: UUID, sql: any SQLDatabase) async throws -> V2StoredObjectFacts {
        struct Row: Decodable { let reference: String; let byte_count: Int64; let sha256: Data }
        let row = try #require(try await sql.raw("""
            SELECT reference_json::text AS reference,byte_count,sha256 FROM im_v2.resource_blob_placements
            WHERE media_id=\(bind:mediaID) AND state='active'
            """).first(decoding: Row.self))
        return try .init(reference: JSONDecoder().decode(V2StoredObjectReference.self, from: Data(row.reference.utf8)),
                         byteCount: row.byte_count, sha256: row.sha256)
    }
    func rawBytes(reference: V2StoredObjectReference) async throws -> Data {
        try await collect(storage.read(reference))
    }
    private func collect(_ stream: V2ResourceByteStream) async throws -> Data {
        var result = Data()
        while let chunk = try await stream.next() {
            guard chunk.count <= 64 * 1024 * 1024 - result.count else { throw V2ResourceProviderError.integrityMismatch }
            result.append(chunk)
        }
        return result
    }
    /// Inject only loss of an unacknowledged file, preserving the durable placement and GC fence.
    func removeObjectForFixtureRecovery(_ reference: V2StoredObjectReference) throws {
        guard reference.binding == storage.binding,
              String(data: reference.handle, encoding: .utf8) == reference.placementID.uuidString.lowercased()
        else { throw V2ResourceProviderError.configurationInvalid }
        try FileManager.default.removeItem(at: root.appending(path: "objects").appending(path: reference.placementID.uuidString.lowercased()))
    }
}

/// The current production media executor runs each authorization query in a fresh room turn.
private func roomMediaAuthorizationPort(database: any Database) -> V2ActorRoomMediaAuthorizationPort {
    .init(query: { query, deadline in
        guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        return try await withRoomActivation(database: database, roomID: query.roomID, shardID: "room-b") { token in
            try await V2RoomMediaAuthorizationDomainExecutor(database: database, token: token).execute(query)
        }
    })
}

/// Runs the production source reader, ledger and write boundary for one exact room pair.
private func executeSameRoomForwardPairFixture(database: any Database, store: PostgresV2RoomWriteStore,
    actor: UserID, source: V2ForwardMessageReference, capacityProfile: V2CapacityProfile,
    limits: V2MessageCommandLimits, now: Date,
    operationID: MessageForwardOperationID = .init(uuid: UUID())) async throws -> V2ActorForwardMessageResultWire {
    try await withFixturePolicyOwners(database: database,
        projectionDelivery: SuccessfulProjectionDelivery()) { owners in
        let policies = V2RoomPolicyAuthorizationService(roomDatabase: database,
            policyOwners: owners, endpoint: "source-reader-test", maximumRooms: 1)
        do {
            let result = try await withRoomActivation(database: database, roomID: source.roomID) { token in
                let executor = V2ActorForwardPairDomainExecutor(database: database, write: store,
                    capacityProfile: capacityProfile, limits: limits, now: { now }).usingPolicyAuthorizations(policies)
                return try await executor.execute(.init(actorUserID: actor, operationID: operationID,
                    source: source, targetRoomID: source.roomID), activationTokens: [token])
            }
            await policies.shutdown()
            return result
        } catch {
            await policies.shutdown()
            throw error
        }
    }
}

private func acceptSameRoomForwardFixture(database: any Database, store: PostgresV2RoomWriteStore,
    command: V2SendMessageCommand, capacityProfile: V2CapacityProfile,
    identifiers: V2AcceptanceIdentifiers, now: Date) async throws -> V2SendMessageOutcome {
    try await withFixturePolicyOwners(database: database,
        projectionDelivery: SuccessfulProjectionDelivery()) { owners in
        let policies = V2RoomPolicyAuthorizationService(roomDatabase: database,
            policyOwners: owners, endpoint: "captured-forward-test", maximumRooms: 1)
        do {
            let result = try await withRoomActivation(database: database, roomID: command.roomID) { token in
                try await store.usingPolicyAuthorizations(policies).acceptActorForwardPair(
                    request: .init(command: command, capacityProfile: capacityProfile,
                        identifiers: identifiers, now: now), sourceRoomID: command.roomID,
                    activationTokens: [token], prepareLedger: { _ in }, recordLedger: { _, _ in })
            }
            await policies.shutdown()
            return result
        } catch {
            await policies.shutdown()
            throw error
        }
    }
}

/// Explicit current write composition for same-room captured-source regressions.
/// Ordinary sends and trusted forwards enter their distinct policy boundaries.
private struct CurrentSameRoomForwardTestWriteStore: V2RoomWriteStore {
    let database: any Database
    let store: PostgresV2RoomWriteStore

    func accept(command: consuming V2SendMessageCommand, capacityProfile: V2CapacityProfile,
                identifiers: V2AcceptanceIdentifiers, now: Date) async throws -> V2SendMessageOutcome {
        let command = command
        if command.forwardedFrom != nil {
            return try await acceptSameRoomForwardFixture(database: database, store: store,
                command: command, capacityProfile: capacityProfile, identifiers: identifiers, now: now)
        }
        return try await V2PolicyAuthorizedTestWriteStore(database: database, controlDatabase: database,
            store: store, shardID: "room-a", epoch: 0).accept(command: command,
                capacityProfile: capacityProfile, identifiers: identifiers, now: now)
    }


}
