import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

struct V2BackgroundDownloadPersistenceTests {
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

    @Test func anExistingDatabaseGetsTheNewTableWithoutLosingItsInstallation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("db.sqlite"), binding = V2LocalInstallationBinding(value: UUID())
        let account = UserID(uuid: UUID())
        let original = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: account)
        try await original.close()
        // Construct the actual preceding schema state, keeping all prior tables/data.
        let old = try DatabaseQueue(path: url.path)
        try await old.write { db in
            try db.execute(sql: "DROP TABLE v2_background_download_jobs")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='addV2BackgroundDownloadJobs'")
        }
        try old.close()
        let upgraded = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: account)
        #expect(try await upgraded.boundAccountID() == account)
        #expect(try await upgraded.backgroundDownloads(accountID: account).isEmpty)
        try await upgraded.close()
    }

    private func makeTask(identifier: Int, sessionID: UUID = UUID()) throws -> V2BackgroundDownloadTask {
        try .init(id: UUID(), sessionID: sessionID, identifier: identifier, grantID: UUID(), expectedByteCount: 3,
            checksum: .init(value: String(repeating: "a", count: 64)), originDigest: String(repeating: "b", count: 64),
            expiresAtMilliseconds: Int64((Date().addingTimeInterval(60).timeIntervalSince1970 * 1_000).rounded(.down)))
    }
}
