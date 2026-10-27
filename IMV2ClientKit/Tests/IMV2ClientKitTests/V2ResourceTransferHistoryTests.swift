import CryptoKit
import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Bounded resource transfer history and protected recovery facts")
struct V2ResourceTransferHistoryTests {
    @Test func recoveryDependencyLookupsUseTheirJobIndexes() async throws {
        let f = try await Fixture()
        let plans = try await f.store.databasePool.read { db -> [String] in
            try ["SELECT 1 FROM v2_profile_intents WHERE upload_job_id=?",
                 "SELECT 1 FROM v2_send_intent_import_dependencies WHERE job_id=?",
                 "SELECT 1 FROM v2_background_transfer_tasks WHERE job_id=?"].flatMap { sql in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: [UUID().uuidString]).map { $0["detail"] as String }
            }
        }
        #expect(plans.contains { $0.contains("v2_profile_intent_upload") })
        #expect(plans.contains { $0.contains("v2_send_intent_import_job") })
        #expect(plans.contains { $0.contains("v2_background_transfer_job") })
        let admissionPlan = try await f.store.databasePool.read {
            try Row.fetchAll($0, sql: "EXPLAIN QUERY PLAN " + GRDBV2LocalSyncStore.retainDownloadAdmissionHistorySQL).map { $0["detail"] as String }
        }
        #expect(admissionPlan.contains { $0.contains("SEARCH v2_resource_entries") && $0.contains("home_id=? AND media_id=?") })
        #expect(!admissionPlan.contains { $0.contains("CORRELATED SCALAR SUBQUERY") })
        try await f.close()
    }

    @Test func pruningCancelledManualDownloadDoesNotLetAutomaticProducerResurrectIt() async throws {
        let f = try await Fixture(), media = MediaID(uuid: UUID()), owner = UUID()
        let message = V2MediaMessageLocation(roomID: f.room, messageID: .init(uuid: UUID()))
        let descriptor = try V2ResourceDescriptor(key: .init(home: .room(f.room), mediaID: media), revision: 1,
            displayName: .init("cancelled.png"), contentType: "image/png", byteCount: 3, checksum: f.checksum, state: .ready)
        try await f.store.indexResource(descriptor, reference: .message(message, ordinal: 0), businessRevision: 1)
        let journal = await f.store.resourceFileJournal()
        let id = try journal.beginForegroundDownload(identity: f.checksum.value + ":3", mediaID: media,
            message: message, bytes: 3, checksum: f.checksum, owner: owner)
        _ = try journal.pauseForegroundDownload(id, owner: owner, issue: .network)
        try await f.center.cancelTransfer(.download(id))
        try await f.store.databasePool.write { try $0.execute(sql: "UPDATE v2_resource_download_jobs SET finished_at=? WHERE job_id=?", arguments: [Date().addingTimeInterval(-31*86400).timeIntervalSince1970,id.uuidString]) }
        try await f.store.pruneResourceTransferHistory()
        #expect(try await f.store.managedResourceTransfers(.init()).entries.isEmpty)
        try journal.enqueueAutomaticDownloads()
        #expect(try journal.requestedDownloads().isEmpty)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.isEmpty)
        try await f.close()
    }

    @Test func groupAvatarReferencePinsReleasedCancelledUpload() async throws {
        let f = try await Fixture(), id = UUID()
        let request = try f.uploadRequest(id, usage: .groupAvatar(f.room), type: "image/png")
        let asset = try await importTestResourceSource(center: f.center, source: f.source, id: .init(), request: request)
        _ = try await f.store.prepareResourceTransfer(id: id, request: request, localAssetID: asset.id)
        let command = try V2GroupAvatarCommand(operationID: .init(uuid: UUID()), roomID: f.room, expectedRevision: 0, mutation: .set(request.mediaID))
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.account, command: command, uploadJobID: id)
        try await f.store.cancelGroupAvatarIntent(command.operationID)
        _ = try await f.store.requestResourceCancellation(id: id)
        try await f.store.confirmResourceCancellation(id: id, session: f.session(request, cancelled: true))
        try await f.store.releaseResourceSource(id: id)
        try await f.age(upload: id)
        try await f.store.pruneResourceTransferHistory()
        #expect(try await f.store.managedResourceTransfers(.init(group: .finished)).entries.isEmpty)
        #expect(try await f.store.resourceTransfer(id: id) != nil)
        #expect(try await f.store.groupAvatarIntent(command.operationID)?.uploadJobID == id)
        try await f.close()
    }

    @Test func completedNativeMappingPinsItsOriginalFactAndLateReceiptCannotResurrectIt() async throws {
        let f = try await Fixture(), id = UUID(), owner = UUID()
        let request = try f.uploadRequest(id, usage: .messageAttachment(f.room))
        let asset = try await importTestResourceSource(center: f.center, source: f.source, id: .init(), request: request)
        _ = try await f.store.prepareResourceTransfer(id: id, request: request, localAssetID: asset.id)
        _ = try #require(try await f.store.claimResourceStep(id: id, owner: owner, now: Date()))
        let created = try V2ResourceUploadSession(locator: .init(home: .room(f.room), sessionID: .init(uuid: UUID())),
            mediaID: request.mediaID, generation: 1, state: .created, resourceState: .pending, expiresAt: .now.addingTimeInterval(600))
        try await f.store.saveResourceSession(created, for: id)
        let mapping = V2BackgroundTaskMapping(id: UUID(), sessionID: try await f.store.backgroundSessionID(), jobID: id,
            activationID: UUID(), sourceToken: UUID(), taskIdentifier: 1, partNumber: 1, expectedBytes: 3,
            expiresAt: .now.addingTimeInterval(600), originDigest: String(repeating: "a", count: 64))
        try await f.store.installBackgroundMapping(mapping, resourceOwner: owner)
        _ = try await f.store.requestResourceCancellation(id: id)
        let cancelled = try V2ResourceUploadSession(locator: created.locator, mediaID: request.mediaID,
            generation: 1, state: .cancelled, resourceState: .pending, expiresAt: created.expiresAt)
        try await f.store.confirmResourceCancellation(id: id, session: cancelled)
        try await f.age(upload: id)
        try await f.store.pruneResourceTransferHistory()
        let active = try await f.store.managedResourceTransfers(.init(group: .active))
        #expect(active.entries.map(\.id) == [.upload(id)])
        #expect(active.entries.first?.phase == .cancelling)
        #expect(try await f.store.completeBackgroundMapping(mapping, result: nil))
        try await f.store.releaseResourceSource(id: id)
        try await f.age(upload: id)
        try await f.store.pruneResourceTransferHistory()
        #expect(try await f.store.resourceTransfer(id: id)?.stage == .cancelled)
        #expect(try await f.store.managedResourceTransfers(.init(group: .finished)).entries.isEmpty)
        #expect(try await !f.store.completeBackgroundMapping(mapping, result: nil))
        #expect(try await f.store.resourceTransfer(id: id)?.stage == .cancelled)
        try await f.close()
    }

    @Test func oneCombinedHistoryLimitRetiresUploadWithoutDeletingItsBorrowedFile() async throws {
        let f = try await Fixture()
        let upload = try await f.upload(cancelled: true)
        try await f.store.releaseResourceSource(id: upload.id)
        let lease = try await f.center.files.borrow(try #require(upload.asset.fileID))
        let now = Date()
        try await f.store.databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_transfer_jobs SET finished_at=? WHERE job_id=?", arguments: [now.addingTimeInterval(-1000).timeIntervalSince1970,upload.id.uuidString])
            for index in 0..<250 {
                let item = try f.importValue(), stamp = now.addingTimeInterval(-Double(index))
                try db.execute(sql: "INSERT INTO v2_resource_import_jobs(job_id,request,status,stage,created_at,finished_at) VALUES(?,?,?,'ready',?,?)",
                    arguments: [item.id.uuidString,try JSONEncoder().encode(item.request),try JSONEncoder().encode(item.status),stamp.timeIntervalSince1970,stamp.timeIntervalSince1970])
                try db.execute(sql: "INSERT INTO v2_resource_download_jobs(job_id,media_id,transport,byte_count,sha256,state,created_at,finished_at) VALUES(?,?,'background',3,?,'completed',?,?)",
                    arguments: [UUID().uuidString,UUID().uuidString,f.checksum.value,stamp.timeIntervalSince1970,stamp.timeIntervalSince1970])
            }
            try GRDBV2LocalSyncStore.pruneResourceTransferHistory(db: db, now: now)
        }
        let count = try await f.store.databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT (SELECT COUNT(*) FROM v2_resource_transfer_jobs WHERE history_retired=0)+(SELECT COUNT(*) FROM v2_resource_import_jobs WHERE history_retired=0)+(SELECT COUNT(*) FROM v2_resource_download_jobs WHERE history_retired=0)")
        }
        #expect(count == 500)
        #expect(try await f.store.resourceTransfer(id: upload.id) == nil)
        #expect(try Data(contentsOf: lease.fileURL) == Fixture.bytes)
        await lease.release(); try await f.close()
    }

    @Test func retiredUploadAndImportStillHandOffTheirFrozenMessageDependencies() async throws {
        let f = try await Fixture()
        let upload = try await f.upload(pinned: true)
        let imported = try f.importValue()
        try await f.store.prepareResourceImport(id: imported.id, request: imported.request)
        let intent = try V2SendIntent(id: UUID(), roomID: f.room, clientMessageID: .init(uuid: UUID()), text: "pinned import", attachmentJobIDs: [imported.id])
        try await f.store.freezeMetadataSendIntent(intent)
        try await f.store.seedResourceImportStatus(imported.status, id: imported.id)
        try await f.age(upload: upload.id, imported: imported.id)
        try await f.store.pruneResourceTransferHistory()
        #expect(try await f.store.managedResourceTransfers(.init(group: .finished)).entries.isEmpty)
        #expect(try await f.store.resourceTransfer(id: upload.id)?.stage == .ready)
        #expect(try await f.store.resourceImport(id: imported.id)?.status?.state == .ready)
        _ = try await f.store.handOffSendIntent(try #require(upload.intent))
        _ = try await f.store.handOffSendIntent(intent.id)
        #expect(try await f.store.resourceSendPayloads().count == 2)
        try await f.close()
    }

    @Test func liveImportOwnerIsActiveAndPreventsRetirementUntilActualRelease() async throws {
        let f = try await Fixture(), item = try f.importValue(), owner = UUID()
        try await f.store.prepareResourceImport(id: item.id, request: item.request)
        #expect(try await f.store.claimResourceImport(item.id, owner: owner))
        try await f.store.saveResourceImport(item.status, id: item.id, owner: owner)
        try await f.age(imported: item.id)
        try await f.store.pruneResourceTransferHistory()
        let active = try await f.store.managedResourceTransfers(.init(group: .active))
        #expect(active.entries.map(\.id) == [.serverImport(item.id)])
        #expect(active.entries.first?.phase == .verifying)
        #expect(try await f.store.resourceImport(id: item.id) != nil)
        try await f.store.releaseResourceImportExecution(item.id, owner: owner)
        #expect(try await f.store.resourceImport(id: item.id) == nil)
        try await f.close()
    }

    @Test func ageStartsAtFirstTerminalProofAndReplayCannotExtendIt() async throws {
        let f = try await Fixture(), item = try f.importValue()
        try await f.store.prepareResourceImport(id: item.id, request: item.request)
        try await f.store.databasePool.write { try $0.execute(sql: "UPDATE v2_resource_import_jobs SET created_at=? WHERE job_id=?", arguments: [Date().addingTimeInterval(-60*86400).timeIntervalSince1970,item.id.uuidString]) }
        try await f.store.seedResourceImportStatus(item.status, id: item.id)
        try await f.store.pruneResourceTransferHistory()
        #expect(try await f.store.resourceImport(id: item.id) != nil)
        let first = try await f.store.databasePool.read { try Double.fetchOne($0, sql: "SELECT finished_at FROM v2_resource_import_jobs WHERE job_id=?", arguments: [item.id.uuidString]) }
        try await f.store.seedResourceImportStatus(item.status, id: item.id)
        #expect(try await f.store.databasePool.read { try Double.fetchOne($0, sql: "SELECT finished_at FROM v2_resource_import_jobs WHERE job_id=?", arguments: [item.id.uuidString]) } == first)
        try await f.age(imported: item.id)
        try await f.store.pruneResourceTransferHistory()
        #expect(try await f.store.resourceImport(id: item.id) == nil)
        try await f.close()
    }

    @Test func nonForeignKeyProfileReferencePinsReleasedUploadUntilDomainHistoryRetires() async throws {
        let f = try await Fixture(), id = UUID()
        let request = try f.uploadRequest(id, usage: .userAvatar, type: "image/png")
        let asset = try await importTestResourceSource(center: f.center, source: f.source, id: .init(), request: request)
        let intent = try await f.store.enqueueProfileIntent(accountID: f.account, expectedRevision: .init(rawValue: 1)!,
            patch: .init(avatar: .set(.init(mediaID: request.mediaID))),
            avatarUpload: .init(id: id, localAssetID: asset.id, displayName: request.displayName.value, contentType: request.contentType, byteCount: request.byteCount))
        _ = try await f.store.prepareResourceTransfer(id: id, request: request, localAssetID: asset.id)
        try await f.store.discardProfileIntentSource(id: intent.id)
        _ = try await f.store.requestResourceCancellation(id: id)
        try await f.store.confirmResourceCancellation(id: id, session: f.session(request, cancelled: true))
        try await f.store.releaseResourceSource(id: id)
        try await f.age(upload: id)
        try await f.store.pruneResourceTransferHistory()
        #expect(try await f.store.managedResourceTransfers(.init(group: .finished)).entries.isEmpty)
        #expect(try await f.store.resourceTransfer(id: id) != nil)
        #expect(try await f.store.profileIntent(id: intent.id)?.avatarUpload?.id == id)
        try await f.store.databasePool.write { try $0.execute(sql: "DELETE FROM v2_profile_intents WHERE intent_id=?", arguments: [intent.id.uuidString]) }
        try await f.store.pruneResourceTransferHistory()
        #expect(try await f.store.resourceTransfer(id: id) == nil)
        try await f.close()
    }

    @Test func historyRetirementAndMetadataDeletionRollBackTogetherOnFailure() async throws {
        let f = try await Fixture(), item = try f.importValue()
        try await f.store.prepareResourceImport(id: item.id, request: item.request)
        try await f.store.seedResourceImportStatus(item.status, id: item.id)
        try await f.age(imported: item.id)
        try await f.store.databasePool.write { try $0.execute(sql: "CREATE TRIGGER reject_import_history_delete BEFORE DELETE ON v2_resource_import_jobs BEGIN SELECT RAISE(ABORT,'injected history deletion failure'); END") }
        await #expect(throws: DatabaseError.self) { try await f.store.pruneResourceTransferHistory() }
        #expect(try await f.store.managedResourceTransfers(.init(group: .finished)).entries.map(\.id) == [.serverImport(item.id)])
        try await f.store.databasePool.write { try $0.execute(sql: "DROP TRIGGER reject_import_history_delete") }
        try await f.store.pruneResourceTransferHistory()
        #expect(try await f.store.resourceImport(id: item.id) == nil)
        try await f.close()
    }

    private struct Fixture: Sendable {
        static let bytes = Data("abc".utf8)
        let root: URL, source: URL, account: UserID, room: RoomID
        let checksum: V2ResourceChecksum
        let store: GRDBV2LocalSyncStore
        let center: V2ResourceCenter
        init() async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "resource-history-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            source = root.appending(path: "source"); try Self.bytes.write(to: source)
            account = .init(uuid: UUID()); room = .init(uuid: UUID())
            checksum = try .init(value: SHA256.hash(data: Self.bytes).map { String(format: "%02x", $0) }.joined())
            store = try .init(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: account)
            center = try await makeResourceTestCenter(store: store, root: root)
        }
        func close() async throws { await center.close(); try await store.close(); try FileManager.default.removeItem(at: root) }
        func uploadRequest(_ id: UUID, usage: V2ResourceUsage, type: String = "application/octet-stream") throws -> V2ResourceUploadRequest {
            try .init(operationID: .init(uuid: id), mediaID: .init(uuid: id), usage: usage, contentType: type, byteCount: 3, checksum: checksum)
        }
        func session(_ request: V2ResourceUploadRequest, cancelled: Bool = false) throws -> V2ResourceUploadSession {
            try .init(locator: .init(home: request.usage.home(actorUserID: account), sessionID: .init(uuid: UUID())), mediaID: request.mediaID, generation: 1,
                state: cancelled ? .cancelled : .completed, resourceState: cancelled ? .pending : .ready,
                expiresAt: .now.addingTimeInterval(3600), bindableUntil: cancelled ? nil : .now.addingTimeInterval(3600))
        }
        func upload(pinned: Bool = false, cancelled: Bool = false) async throws -> (id: UUID, asset: V2LocalResourceAsset, intent: UUID?) {
            let id = UUID(), request = try uploadRequest(id, usage: .messageAttachment(room))
            let asset = try await importTestResourceSource(center: center, source: source, id: .init(), request: request)
            var intentID: UUID?
            if pinned {
                let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()), text: "pinned upload", attachmentJobIDs: [id])
                try await store.freezeSendIntent(intent, resources: [.init(id: id, request: request, localAssetID: asset.id)])
                intentID = intent.id
            } else { _ = try await store.prepareResourceTransfer(id: id, request: request, localAssetID: asset.id) }
            if cancelled { _ = try await store.requestResourceCancellation(id: id); try await store.confirmResourceCancellation(id: id, session: session(request, cancelled: true)) }
            else { try await store.saveResourceSession(session(request), for: id) }
            return (id, asset, intentID)
        }
        func importValue() throws -> (id: UUID, request: V2ResourceImportRequest, status: V2ResourceImportStatus) {
            let request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()),
                source: .message(location: .init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil),
                targetUsage: .messageAttachment(room), targetMediaID: .init(uuid: UUID()))
            return (UUID(), request, try .init(locator: .init(home: .room(room), operationID: request.operationID), mediaID: request.targetMediaID, state: .ready, bindableUntil: .now.addingTimeInterval(3600)))
        }
        func age(upload: UUID? = nil, imported: UUID? = nil) async throws {
            try await store.databasePool.write { db in
                let stamp = Date().addingTimeInterval(-31 * 86400).timeIntervalSince1970
                if let upload { try db.execute(sql: "UPDATE v2_resource_transfer_jobs SET finished_at=? WHERE job_id=?", arguments: [stamp,upload.uuidString]) }
                if let imported { try db.execute(sql: "UPDATE v2_resource_import_jobs SET finished_at=? WHERE job_id=?", arguments: [stamp,imported.uuidString]) }
            }
        }
    }
}
