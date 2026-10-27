import Crypto
import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Canonical foreground and background download facts", .timeLimit(.minutes(1)))
struct V2CanonicalDownloadJournalTests {
    @Test func startupShowsInterruptedForegroundWorkBeforeAnyNewDownload() async throws {
        let f = try await Fixture(), journal = await f.store.resourceFileJournal()
        let id = try journal.beginForegroundDownload(identity: f.identity, mediaID: .init(uuid: UUID()), message: nil,
            bytes: 4, checksum: f.checksum, owner: UUID())
        await f.center.close()
        let restored = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let stream = try await restored.transferSnapshots(for: .init(group: .attention))
        var iterator = stream.makeAsyncIterator()
        guard case .available(let page) = await iterator.next() else { Issue.record("Missing cold foreground task"); return }
        #expect(page.entries.map(\.id) == [.download(id)])
        #expect(page.entries.first?.phase == .requiresAttention(.needsAttention))
        #expect(page.entries.first?.actions == [.cancel])
        await restored.close(); try await f.remove()
    }

    @Test func coldCancellationDrainsOnlyInactiveOwnedBytesBeforeRecordingStopped() async throws {
        let f = try await Fixture(), owner = UUID()
        let journal = await f.store.resourceFileJournal()
        let id = try journal.beginForegroundDownload(identity: f.identity, mediaID: .init(uuid: UUID()), message: nil,
            bytes: 4, checksum: f.checksum, owner: owner)
        let staging = try await f.center.files.reserveTransient(identity: f.identity, bytes: 4)
        try Data([1,2]).write(to: staging.fileURL.appendingPathExtension("range-part"))
        try await f.center.files.releaseTransient(staging.id, discard: false)
        try journal.pauseForegroundDownload(id, owner: owner, issue: .interrupted)
        _ = try journal.requestForegroundDownloadCancellation(id)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.phase == .cancelling)
        await f.center.close()
        let restored = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        #expect(try await restored.files.snapshot().transferReservedBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: staging.fileURL.appendingPathExtension("range-part").path))
        #expect(try await f.store.managedResourceTransfers(.init(group: .finished)).entries.first?.phase == .cancelled)
        await restored.close(); try await f.remove()
    }

    @Test func adoptedForegroundIdentityFencesOldWriterAndRequiresVerifiedPublication() async throws {
        let f = try await Fixture(), first = UUID(), second = UUID()
        let journal = await f.store.resourceFileJournal()
        let id = try journal.beginForegroundDownload(identity: f.identity, mediaID: .init(uuid: UUID()), message: nil,
            bytes: 4, checksum: f.checksum, owner: first)
        try journal.recoverForegroundDownloads(owner: second)
        let adopted = try journal.beginForegroundDownload(identity: f.identity, mediaID: .init(uuid: UUID()), message: nil,
            bytes: 4, checksum: f.checksum, owner: second)
        #expect(adopted == id)
        #expect(throws: V2ResourceStorageError.conflict) { try journal.foregroundDownloadAwaitingVerification(id, owner: first) }
        try journal.pauseForegroundDownload(id, owner: first, issue: .network)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.phase == .transferring)
        #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try journal.requestForegroundDownloadCancellation(id) }
        try journal.foregroundDownloadAwaitingVerification(id, owner: second)
        #expect(throws: V2ResourceStorageError.conflict) { try journal.completeForegroundDownload(id, owner: second, fileID: .init()) }
        let source = f.root.appending(path: "source")
        try Fixture.bytes.write(to: source)
        let fileID = try await f.center.files.publishCopy(of: source, byteCount: 4, checksum: f.checksum, retention: .cache)
        #expect(throws: V2ResourceStorageError.conflict) { try journal.completeForegroundDownload(id, owner: first, fileID: fileID) }
        try journal.completeForegroundDownload(id, owner: second, fileID: fileID)
        #expect(try await f.store.managedResourceTransfers(.init(group: .finished)).entries.map(\.id) == [.download(id)])
        await f.center.close(); try await f.remove()
    }

    @Test func boundedHistoryNeverConsumesActiveAdmissionOrPrunesPendingWork() async throws {
        let f = try await Fixture(), now = Date(), active = UUID()
        _ = try await f.store.beginBackgroundDownload(id: active, mediaID: .init(uuid: UUID()), message: nil, accountID: f.scope.accountID)
        try await f.store.databasePool.write { db in
            for index in 0..<503 {
                let stamp = index == 502 ? now.addingTimeInterval(-31 * 24 * 60 * 60) : now.addingTimeInterval(-Double(index))
                try db.execute(sql: "INSERT INTO v2_resource_download_jobs(job_id,media_id,transport,byte_count,sha256,state,created_at,finished_at) VALUES(?,?,'background',4,?,'completed',?,?)",
                    arguments: [UUID().uuidString,UUID().uuidString,f.checksum.value,stamp.timeIntervalSince1970,stamp.timeIntervalSince1970])
            }
            try GRDBV2LocalSyncStore.pruneResourceTransferHistory(db: db, now: now)
        }
        let count = try await f.store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_resource_download_jobs WHERE finished_at IS NOT NULL") }
        #expect(count == 500)
        #expect(try await f.store.backgroundDownloads(accountID: f.scope.accountID).map(\.id) == [active])
        // History at its cap still admits another real pending request.
        _ = try await f.store.beginBackgroundDownload(id: UUID(), mediaID: .init(uuid: UUID()), message: nil, accountID: f.scope.accountID)
        #expect(try await f.store.backgroundDownloads(accountID: f.scope.accountID).count == 2)
        // A page opened much later also expires closed facts, without requiring
        // a new download or an account restart to trigger maintenance.
        try await f.store.databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET finished_at=? WHERE job_id=(SELECT job_id FROM v2_resource_download_jobs WHERE finished_at IS NOT NULL LIMIT 1)", arguments: [now.addingTimeInterval(-31 * 24 * 60 * 60).timeIntervalSince1970])
        }
        let stream = try await f.center.transferSnapshots(for: .init(group: .finished))
        var iterator = stream.makeAsyncIterator()
        guard case .available(let page) = await iterator.next() else { Issue.record("Missing bounded history snapshot"); return }
        #expect(page.entries.count == 50)
        let remaining = try await f.store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_resource_download_jobs WHERE finished_at IS NOT NULL") }
        #expect(remaining == 499)
        await f.center.close(); try await f.remove()
    }

    private struct Fixture {
        static let bytes = Data([1,2,3,4])
        let root: URL, store: GRDBV2LocalSyncStore, scope: V2AccountStorageScope, center: V2ResourceCenter
        let checksum: V2ResourceChecksum
        var identity: String { checksum.value + ":4" }
        init() async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "canonical-download-journal-\(UUID())")
            let user = UserID(uuid: UUID())
            store = try .init(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: user)
            scope = .init(incarnation: UUID(), accountID: user, directory: root.appending(path: "account"), cacheDirectory: root.appending(path: "cache"))
            checksum = try .init(value: SHA256.hash(data: Self.bytes).map { String(format: "%02x", $0) }.joined())
            center = try await .make(scope: scope, store: store)
        }
        func remove() async throws { try await store.close(); try FileManager.default.removeItem(at: root) }
    }
}
