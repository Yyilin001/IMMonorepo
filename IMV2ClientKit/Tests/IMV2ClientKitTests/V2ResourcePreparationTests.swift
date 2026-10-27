import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Resource preparation due scheduling")
struct V2ResourcePreparationTests {
    @Test(arguments: [false, true], [false, true])
    func expiredUnsubmittedPreparationRenewsResourcesAndSurvivesRepeatedRetry(imported: Bool, messageExpired: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = V2LocalInstallationBinding(value: UUID()), user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let url = root.appendingPathComponent("db.sqlite"), now = Date(), id = UUID()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user)
        let until = now.addingTimeInterval(messageExpired ? 600 : -60)
        if imported {
            let request = try importRequest(room: room)
            try await store.prepareResourceImport(id: id, request: request)
            try await store.seedResourceImportStatus(.init(locator: .init(home: .room(room), operationID: request.operationID),
                mediaID: request.targetMediaID, state: .ready, bindableUntil: until), id: id)
        } else {
            let request = try V2ResourceUploadRequest(operationID: .init(uuid: id), mediaID: .init(uuid: id),
                usage: .messageAttachment(room), contentType: "image/png", byteCount: 3,
                checksum: .init(value: String(repeating: "a", count: 64)))
            _ = try await store.prepareMetadataResourceTransfer(id: id, request: request, localAssetID: .init(id))
            try await store.saveResourceSession(.init(locator: .init(home: .room(room), sessionID: .init(uuid: UUID())),
                mediaID: request.mediaID, generation: 1, state: .completed, resourceState: .ready,
                expiresAt: .distantFuture, bindableUntil: until), for: id)
        }
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()),
            text: "Keep this draft", attachmentJobIDs: [id])
        try await store.freezeSendIntent(intent, now: now.addingTimeInterval(messageExpired ? -2 * 86400 : -20))
        let before = try #require(try await store.pendingResourceSendSnapshot(in: room, page: 0, now: now).preparing.first)
        #expect(before.isExpired)
        let reserved = try await store.databasePool.read { db in
            try Int64.fetchOne(db, sql: "SELECT payload_bytes FROM v2_send_intents WHERE intent_id=?", arguments: [intent.id.uuidString])!
        }
        let blocker = UUID()
        let identity = try V2OperationIdentity(accountID: user, scope: .account(user), operation: .profileUpdate(.init(uuid: blocker)))
        let fingerprint = try V2OperationFingerprint(kind: .profileUpdate, fields: [.init("fixture", .text("full-quota"))])
        try await store.databasePool.write { db in
            _ = try GRDBV2LocalSyncStore.insertOperationWork(.init(id: blocker, intentID: blocker, identity: identity,
                fingerprint: fingerprint, orderingKey: "quota", payloadBytes: V2OperationWorkLimits().maximumPayloadBytes - reserved,
                admissionDeadline: nil), now: now, db: db)
            try db.execute(sql: "CREATE TRIGGER fail_reprepare BEFORE UPDATE OF payload_bytes ON v2_send_intents WHEN NEW.replacement_of IS NOT NULL BEGIN SELECT RAISE(ABORT,'injected commit failure'); END")
        }
        await #expect(throws: DatabaseError.self) { try await store.retryPreparedSendIntent(intent.id) }
        #expect(try await store.preparingSendIntent(id: intent.id) == intent)
        #expect(try await store.preparingSendIntents().count == 1)
        #expect(try await store.databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT (SELECT COUNT(*) FROM v2_resource_transfer_jobs)+(SELECT COUNT(*) FROM v2_resource_import_jobs)")
        } == 1)
        try await store.databasePool.write { try $0.execute(sql: "DROP TRIGGER fail_reprepare") }
        try await store.retryPreparedSendIntent(intent.id)
        let next = try #require(try await store.preparingSendIntents().first)
        #expect(next.id != intent.id && next.clientMessageID != intent.clientMessageID)
        #expect(next.text == intent.text)
        #expect(next.attachmentJobIDs != intent.attachmentJobIDs)
        #expect(try await store.preparingSendIntent(id: intent.id) == nil)
        let after = try #require(try await store.pendingResourceSendSnapshot(in: room, page: 0).preparing.first)
        #expect(after.createdAt == before.createdAt && !after.isExpired)
        let dependency = try #require(next.attachmentJobIDs.first)
        if imported {
            #expect(try await store.resourceImport(id: dependency)?.request.source == store.resourceImport(id: id)?.request.source)
        } else {
            #expect(try await store.resourceTransfer(id: dependency)?.localAssetID == .init(id))
            #expect(try await store.testHeldAssetIDs().contains(.init(id)))
        }
        try await store.close()
        let restored = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user)
        try await restored.retryPreparedSendIntent(intent.id)
        #expect(try await restored.preparingSendIntents().map(\.id) == [next.id])
        let media: MediaID
        if imported {
            let job = try #require(try await restored.resourceImport(id: dependency))
            media = job.request.targetMediaID
            try await restored.seedResourceImportStatus(.init(locator: .init(home: .room(room), operationID: job.request.operationID),
                mediaID: media, state: .ready, bindableUntil: .distantFuture), id: dependency)
        } else {
            let job = try #require(try await restored.resourceTransfer(id: dependency))
            media = job.request.mediaID
            try await restored.saveResourceSession(.init(locator: .init(home: .room(room), sessionID: .init(uuid: UUID())),
                mediaID: media, generation: 1, state: .completed, resourceState: .ready,
                expiresAt: .distantFuture, bindableUntil: .distantFuture), for: dependency)
        }
        _ = try await restored.handOffSendIntent(next.id)
        #expect(try await restored.resourceSendPayloads().first?.media == [.init(mediaID: media)])
        await #expect(throws: V2ResourceJournalError.conflict) {
            try await restored.retryPreparedSendIntent(next.id, now: .distantFuture)
        }
        try await restored.close()
    }

    @Test(.timeLimit(.minutes(1))) func messageAcceptanceWakesIdleSourceReleaseWithoutAnotherSend() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "source-release-wake-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GRDBV2LocalSyncStore(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: .init(uuid: UUID()))
        let room = RoomID(uuid: UUID()), jobID = UUID()
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: jobID), mediaID: .init(uuid: jobID), usage: .messageAttachment(room),
            contentType: "text/plain", byteCount: 3, checksum: .init(value: String(repeating: "a", count: 64)))
        _ = try await store.prepareMetadataResourceTransfer(id: jobID, request: request, localAssetID: .init(jobID))
        try await store.saveResourceSession(.init(locator: .init(home: .room(room), sessionID: .init(uuid: UUID())), mediaID: request.mediaID,
            generation: 1, state: .completed, resourceState: .ready, expiresAt: Date().addingTimeInterval(300), bindableUntil: Date().addingTimeInterval(300)), for: jobID)
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()), text: "release on ACK", attachmentJobIDs: [jobID])
        try await store.freezeMetadataSendIntent(intent)
        _ = try await store.handOffSendIntent(intent.id)
        let schedule = await store.resourcePreparationSchedule()
        let changes = await schedule.updates()
        var iterator = changes.makeAsyncIterator()
        _ = try await iterator.next() // The actual SQL observation is installed and idle.
        #expect(try await schedule.nextAttemptAt() == nil)
        #expect(try await store.testHeldAssetIDs().contains(.init(jobID)))
        let released = AsyncStream<Void>.makeStream()
        let activity = Task {
            try await store.runResourcePreparation {
                for id in try await store.releasableResourceJobs() { try await store.releaseResourceSource(id: id); released.continuation.yield(()) }
            }
        }
        try await store.completeResourceSendFixture(intent.clientMessageID, result: .accepted(.init(messageID: .init(uuid: UUID()), roomSequence: 1)))
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in released.stream { return true }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return false }
            #expect(await group.next() == true)
            group.cancelAll()
        }
        #expect(try await store.testHeldAssetIDs().isEmpty)
        #expect(try await schedule.nextAttemptAt() == nil)
        activity.cancel(); _ = await activity.result
        released.continuation.finish()
        try await store.close()
    }

    @Test func importCrashBudgetSurvivesRestartAndProcessingHasBoundedPolls() async throws {
        let owner = UUID(), restartedOwner = UUID()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-due-\(UUID()).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: .init(uuid:UUID(uuidString:"12345678-1234-1234-1234-123456789012")!))
        let id = UUID(), room = try RoomID(UUID().uuidString)
        let request = try importRequest(room: room)
        try await store.prepareResourceImport(id: id, request: request)
        let time = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        #expect(try await store.claimResourceImport(id, owner: owner, now: time))
        let deadline = try await store.resourceImportDeadline(id)
        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: .init(uuid:UUID(uuidString:"12345678-1234-1234-1234-123456789012")!))
        #expect(try await restarted.resourceImport(id: id)?.attempts == 1)
        #expect(try await restarted.resourceImportDeadline(id) == deadline)
        try await restarted.recoverResourceImportExecutions(owner: restartedOwner)
        for attempt in 2...5 {
            #expect(try await restarted.claimResourceImport(id, owner: restartedOwner, now: time.addingTimeInterval(Double(attempt)*10)))
            try await restarted.releaseResourceImportExecution(id, owner: restartedOwner)
        }
        #expect(try await restarted.dueResourceImports(now: time.addingTimeInterval(100)).isEmpty)
        try await restarted.retryResourceImport(id: id)
        let status = try V2ResourceImportStatus(locator: .init(home: .room(room), operationID: request.operationID), mediaID: request.targetMediaID, state: .processing, bindableUntil: nil)
        for _ in 0..<60 { try await restarted.seedResourceImportStatus(status, id: id) }
        #expect(try await restarted.resourceImport(id: id)?.attempts == 5)
        #expect(try await restarted.dueResourceImports(now: time.addingTimeInterval(10000)).isEmpty)
        try await restarted.close(); try await store.close()
    }
    @Test func databaseWakeHandsOffReadyDependencyAndCancellingScheduleDoesNotCancelIntent() async throws {
        let owner = UUID()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("send-due-\(UUID()).sqlite")
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: .init(value: UUID()), userID: .init(uuid:UUID()))
        let id = UUID(), room = try RoomID(UUID().uuidString), request = try importRequest(room: room)
        try await store.prepareResourceImport(id: id, request: request)
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(UUID().uuidString), text: "durable", attachmentJobIDs: [id])
        try await store.freezeMetadataSendIntent(intent)
        #expect(try await store.duePreparedSendIntents().isEmpty)
        // Exhaust import I/O admission, leaving the preparation owner idle until readiness changes.
        let time = Date()
        for attempt in 0..<5 {
            _ = try await store.claimResourceImport(id, owner: owner, now: time.addingTimeInterval(Double(attempt)*10))
            try await store.releaseResourceImportExecution(id, owner: owner)
        }
        let signal = AsyncStream<Void>.makeStream()
        let activity = Task {
            try await store.runResourcePreparation {
                for value in try await store.duePreparedSendIntents() {
                    _ = try await store.handOffSendIntent(value.id)
                    signal.continuation.yield(())
                }
            }
        }
        let status = try V2ResourceImportStatus(locator: .init(home: .room(room), operationID: request.operationID), mediaID: request.targetMediaID, state: .ready, bindableUntil: Date().addingTimeInterval(120))
        try await store.seedResourceImportStatus(status, id: id)
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in signal.stream { return true }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
            let awakened = await group.next() ?? false
            #expect(awakened)
            group.cancelAll()
        }
        activity.cancel(); _ = await activity.result
        #expect(try await store.resourceSendPayloads().count == 1)
        #expect(try await store.resourceImport(id: id)?.cancellationRequested == false)
        try await store.close()
    }
    @Test func handoffFailureBudgetSurvivesRestartUntilExplicitUserRetry() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-due-\(UUID()).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: .init(uuid:UUID(uuidString:"12345678-1234-1234-1234-123456789012")!))
        let intent = try V2SendIntent(id: UUID(), roomID: .init(UUID().uuidString), clientMessageID: .init(UUID().uuidString), text: "kept", attachmentJobIDs: [])
        try await store.freezeMetadataSendIntent(intent)
        for _ in 0..<5 { try await store.deferPreparedSendIntent(intent.id) }
        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: .init(uuid:UUID(uuidString:"12345678-1234-1234-1234-123456789012")!))
        #expect(try await restarted.preparedSendRequiresAttention(intent.id))
        #expect(try await restarted.duePreparedSendIntents(now: Date().addingTimeInterval(3600)).isEmpty)
        #expect(try await restarted.preparingSendIntents() == [intent])
        try await restarted.retryPreparedSendIntent(intent.id)
        #expect(try await restarted.duePreparedSendIntents() == [intent])
        try await restarted.close(); try await store.close()
    }

    @Test func userRetryAfterColdStartPreservesServerCooldownForImportAndUpload() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cooldown-due-\(UUID()).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID()), now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let cooldown = now.addingTimeInterval(10000)
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: .init(uuid:UUID(uuidString:"12345678-1234-1234-1234-123456789012")!))
        let id = UUID(), room = try RoomID(UUID().uuidString), importOwner = UUID()
        try await store.prepareResourceImport(id: id, request: importRequest(room: room))
        _ = try await store.claimResourceImport(id, owner: importOwner, now: now)
        try await store.pauseResourceImport(id: id, owner: importOwner, retryNotBefore: cooldown)
        try await store.releaseResourceImportExecution(id, owner: importOwner)
        let uploadID = UUID(), owner = UUID()
        let request = try V2ResourceUploadRequest(operationID: .init(uploadID.uuidString), mediaID: .init(uploadID.uuidString), usage: .userAvatar, contentType: "image/png", byteCount: 3, checksum: .init(value: String(repeating: "a", count: 64)))
        _ = try await store.prepareMetadataResourceTransfer(id: uploadID, request: request, localAssetID: .init(uploadID))
        _ = try await store.claimResourceStep(id: uploadID, owner: owner, now: now)
        try await store.failResourceStep(id: uploadID, owner: owner, code: "transport", retryAt: nil, serverRetryNotBefore: cooldown)
        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: .init(uuid:UUID(uuidString:"12345678-1234-1234-1234-123456789012")!))
        try await restarted.retryResourceImport(id: id)
        try await restarted.retryResourceTransfer(id: uploadID)
        #expect(try await restarted.resourceImport(id: id)?.retryAt == cooldown)
        #expect(try await restarted.resourceTransfer(id: uploadID)?.retryAt == cooldown)
        #expect(try await restarted.dueResourceImports(now: now.addingTimeInterval(100)).isEmpty)
        #expect(try await restarted.dueResourceTransfers(now: now.addingTimeInterval(100)).isEmpty)
        try await restarted.close(); try await store.close()
    }

    private func importRequest(room: RoomID) throws -> V2ResourceImportRequest {
        try .init(operationID: .init(UUID().uuidString), source: .message(location: .init(roomID: room, messageID: .init(UUID().uuidString)), mediaID: .init(UUID().uuidString), variantID: nil), targetUsage: .messageAttachment(room), targetMediaID: .init(UUID().uuidString))
    }
}
