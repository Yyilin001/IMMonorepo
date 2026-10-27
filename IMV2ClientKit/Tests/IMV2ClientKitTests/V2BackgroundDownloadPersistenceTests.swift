import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

struct V2BackgroundDownloadPersistenceTests {
    @Test func demandPromotionPersistsBudgetAndControlsAndCannotCrossAccountOrRevivePause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = V2LocalInstallationBinding(value: UUID()), account = UserID(uuid: UUID())
        let url = root.appending(path: "db.sqlite"), id = UUID()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: account)
        _ = try await store.beginBackgroundDownload(id: id, mediaID: .init(uuid: UUID()), message: nil, accountID: account, priority: .background)
        try await store.databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET attempt_count=3,retry_at_milliseconds=12345 WHERE job_id=?", arguments: [id.uuidString])
        }
        #expect(try await store.promoteBackgroundDownload(id: id, accountID: account, priority: .interactive) == .interactive)
        #expect(try await store.promoteBackgroundDownload(id: id, accountID: account, priority: .background) == .interactive)
        await #expect(throws: V2ClientLocalStorageError.installationBindingMismatch) {
            _ = try await store.promoteBackgroundDownload(id: id, accountID: .init(uuid: UUID()), priority: .critical)
        }
        try await store.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: account)
        let saved = try #require(try await reopened.backgroundDownloads(accountID: account).first)
        #expect(saved.id == id && saved.priority == .interactive && saved.attemptCount == 3 && saved.retryAtMilliseconds == 12345 && saved.state == .preparing)
        // An automatic policy pause is a domain outcome, not promotion's retry.
        try await reopened.restrictAutomaticBackgroundDownload(id: id, accountID: account)
        #expect(try await reopened.promoteBackgroundDownload(id: id, accountID: account, priority: .critical) == nil)
        #expect(try await reopened.backgroundDownloads(accountID: account).first?.state == .paused)
        try await reopened.cancelBackgroundDownload(id: id, accountID: account)
        #expect(try await reopened.promoteBackgroundDownload(id: id, accountID: account, priority: .critical) == nil)
        try await reopened.close()
    }

    @Test func restartPreservesOriginalIntentAndAttemptWhileOtherAccountsCannotReadIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("db.sqlite"), binding = V2LocalInstallationBinding(value: UUID())
        let account = UserID(uuid: UUID()), id = UUID(), media = MediaID(uuid: UUID())
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        let first = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: account)
        let task = try makeTask(identifier: 1)
        let original = try await first.beginBackgroundDownload(id: id, mediaID: media, message: message, accountID: account)
        #expect(original.state == .preparing)
        try await first.installBackgroundDownloadTask(id: id, task: task, accountID: account)
        try await first.close()
        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: account)
        let saved = try #require(try await restarted.backgroundDownloads(accountID: account).first)
        #expect(saved.id == id && saved.mediaID == media && saved.message == message && saved.state == .transferring(task))
        await #expect(throws: V2ClientLocalStorageError.installationBindingMismatch) {
            _ = try await restarted.backgroundDownloads(accountID: .init(uuid: UUID()))
        }
        await #expect(throws: V2BackgroundTransferError.mappingConflict) {
            _ = try await restarted.beginBackgroundDownload(id: id, mediaID: .init(uuid: UUID()), message: message, accountID: account)
        }
        // Repeating the same request adopts its persisted task, never a second download.
        #expect(try await restarted.beginBackgroundDownload(id: id, mediaID: media, message: message, accountID: account) == saved)
        try await restarted.close()
    }

    @Test func oldAttemptCannotFinishNewAttemptEvenWhenTheOSTaskNumberIsReused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = UserID(uuid: UUID()), id = UUID()
        let store = try GRDBV2LocalSyncStore(databaseURL: root.appendingPathComponent("db.sqlite"),
            installationBinding: .init(value: UUID()), userID: account)
        _ = try await store.beginBackgroundDownload(id: id, mediaID: .init(uuid: UUID()), message: nil, accountID: account)
        let first = try makeTask(identifier: 1)
        try await store.installBackgroundDownloadTask(id: id, task: first, accountID: account)
        #expect(try await store.finishBackgroundDownloadTask(id: id, mappingID: first.id, sessionID: first.sessionID,
            identifier: 1, success: false, accountID: account))
        let replacement = try makeTask(identifier: 1, sessionID: first.sessionID)
        try await store.installBackgroundDownloadTask(id: id, task: replacement, accountID: account)
        #expect(try await !store.finishBackgroundDownloadTask(id: id, mappingID: first.id, sessionID: first.sessionID,
            identifier: 1, success: true, accountID: account))
        #expect(try await store.backgroundDownloads(accountID: account).first?.state == .transferring(replacement))
        try await store.cancelBackgroundDownload(id: id, accountID: account)
        #expect(try await store.backgroundDownloads(accountID: account).first?.state == .cancelled(replacement))
        #expect(try await !store.finishBackgroundDownloadTask(id: id, mappingID: replacement.id, sessionID: replacement.sessionID,
            identifier: 1, success: true, accountID: account))
        try await store.close()
    }

    @Test func canonicalSchemaRequiresResolvedBytesBeforePhysicalTransfer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = UserID(uuid: UUID()), id = UUID()
        let store = try GRDBV2LocalSyncStore(databaseURL: root.appendingPathComponent("db.sqlite"), installationBinding: .init(value: UUID()), userID: account)
        try await store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_resource_download_jobs(job_id,media_id,room_id,message_id,transport,identity,resume_requested,state,created_at) VALUES(?,?,'room','message','foreground',?,1,'paused',0)",
                arguments: [id.uuidString,UUID().uuidString,"demand:" + id.uuidString])
        }
        await #expect(throws: DatabaseError.self) {
            try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_resource_download_jobs SET state='transferring' WHERE job_id=?", arguments: [id.uuidString]) }
        }
        await #expect(throws: DatabaseError.self) {
            try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_resource_download_jobs SET byte_count=4 WHERE job_id=?", arguments: [id.uuidString]) }
        }
        #expect(try await store.boundAccountID() == account)
        try await store.close()
    }

    @Test func automaticRetriesPauseButAnExplicitRequestPreservesAndRestartsTheIntent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = UserID(uuid: UUID()), id = UUID(), media = MediaID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: root.appendingPathComponent("db.sqlite"),
            installationBinding: .init(value: UUID()), userID: account)
        _ = try await store.beginBackgroundDownload(id: id, mediaID: media, message: nil, accountID: account)
        for _ in 0..<8 { try await store.failBackgroundDownloadPreparation(id: id, accountID: account) }
        let paused = try #require(try await store.backgroundDownloads(accountID: account).first)
        #expect(paused.state == .paused && paused.attemptCount == 5)
        #expect(try await store.beginBackgroundDownload(id: UUID(), mediaID: media, message: nil,
            accountID: account, adoptMatching: true) == paused)
        let restarted = try await store.beginBackgroundDownload(id: UUID(), mediaID: media, message: nil,
            accountID: account, adoptMatching: true, retryPaused: true)
        #expect(restarted.id == id && restarted.mediaID == media && restarted.state == .preparing)
        #expect(restarted.attemptCount == 0 && restarted.retryAtMilliseconds == 0)
        let task = try makeTask(identifier: 1)
        try await store.installBackgroundDownloadTask(id: id, task: task, accountID: account)
        let active = try await store.beginBackgroundDownload(id: UUID(), mediaID: media, message: nil,
            accountID: account, adoptMatching: true, retryPaused: true)
        #expect(active.id == id && active.state == .transferring(task))
        #expect(try await store.backgroundDownloads(accountID: account).count == 1)
        try await store.close()
    }

    private func makeTask(identifier: Int, sessionID: UUID = UUID()) throws -> V2BackgroundDownloadTask {
        try .init(id: UUID(), sessionID: sessionID, identifier: identifier, grantID: UUID(), expectedByteCount: 3,
            checksum: .init(value: String(repeating: "a", count: 64)), originDigest: String(repeating: "b", count: 64),
            expiresAtMilliseconds: Int64((Date().addingTimeInterval(60).timeIntervalSince1970 * 1_000).rounded(.down)))
    }
}
