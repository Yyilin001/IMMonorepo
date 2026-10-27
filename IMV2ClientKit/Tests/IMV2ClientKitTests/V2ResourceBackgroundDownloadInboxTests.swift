import CryptoKit
import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Admitted background download byte ownership", .timeLimit(.minutes(1)))
struct V2ResourceBackgroundDownloadInboxTests {
    @Test func callbackRequiresAnInstalledTaskAndExactOriginAndSize() async throws {
        let f = try await Fixture()
        let source = try f.source()
        #expect(throws: (any Error).self) { try f.inbox.receive(source, mapping: f.mapping, identifier: 7, origin: f.origin) }
        let reservation = try await f.reserve()
        #expect(throws: (any Error).self) { try f.inbox.receive(source, mapping: f.mapping, identifier: 7, origin: f.origin) }
        try await f.files.installBackgroundDownload(reservation, task: f.task)
        #expect(throws: V2BackgroundTransferError.mappingConflict) { try f.inbox.receive(source, mapping: f.mapping, identifier: 8, origin: f.origin) }
        #expect(throws: V2BackgroundTransferError.mappingConflict) { try f.inbox.receive(source, mapping: f.mapping, identifier: 7, origin: String(repeating: "a", count: 64)) }
        let short = try f.source(Data([1]))
        #expect(throws: V2ClientMediaTransferError.byteCountMismatch) { try f.inbox.receive(short, mapping: f.mapping, identifier: 7, origin: f.origin) }
        try f.inbox.receive(source, mapping: f.mapping, identifier: 7, origin: f.origin)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try f.inbox.permit(f.mapping).state == .received(7))
        let duplicate = try f.source()
        #expect(throws: V2BackgroundTransferError.mappingConflict) { try f.inbox.receive(duplicate, mapping: f.mapping, identifier: 7, origin: f.origin) }
        try await f.files.verifyBackgroundDownload(f.task, reservation: reservation)
        try await f.files.releaseTransient(reservation.id, discard: true)
        try await f.remove()
    }

    @Test func receiptCannotPublishWrongBytesEvenWithTheRightLength() async throws {
        let f = try await Fixture(), reservation = try await f.reserve()
        try await f.files.installBackgroundDownload(reservation, task: f.task)
        let corrupted = try f.source(Data(repeating: 9, count: Fixture.body.count))
        try f.inbox.receive(corrupted, mapping: f.mapping, identifier: 7, origin: f.origin)
        await #expect(throws: V2ResourceStorageError.integrityMismatch) {
            try await f.files.verifyBackgroundDownload(f.task, reservation: reservation)
        }
        await #expect(throws: V2ResourceStorageError.integrityMismatch) {
            try await f.files.publishDownload(of: reservation.fileURL, reservation: reservation,
                byteCount: Int64(Fixture.body.count), checksum: f.target.checksum)
        }
        #expect(try await f.files.snapshot().files.isEmpty)
        try await f.files.releaseTransient(reservation.id, discard: true)
        try await f.remove()
    }

    @Test func receiptDoesNotNeedTheBusinessDatabaseAndColdOwnerVerifiesBeforePublishing() async throws {
        let f = try await Fixture(), reservation = try await f.reserve()
        try await f.files.installBackgroundDownload(reservation, task: f.task)
        try await f.files.releaseTransient(reservation.id, discard: false)
        await f.files.close(); try await f.store.close()
        // Equivalent to a locked Complete database: callback cannot query it.
        try f.inbox.receive(f.source(), mapping: f.mapping, identifier: 7, origin: f.origin)
        let restoredStore = try GRDBV2LocalSyncStore(databaseURL: f.database, installationBinding: f.binding, userID: f.account)
        let restored = try V2ResourceFileStore(scope: f.scope, journal: await restoredStore.resourceFileJournal())
        let adopted = try await restored.adoptBackgroundDownload(f.task)
        #expect(adopted.id == reservation.id && adopted.fileURL == reservation.fileURL)
        try await restored.verifyBackgroundDownload(f.task, reservation: adopted)
        let published = try await restored.publishDownload(of: adopted.fileURL, reservation: adopted,
            byteCount: f.task.expectedByteCount, checksum: f.task.checksum)
        #expect(try Data(contentsOf: published.lease.fileURL) == Fixture.body)
        try await restored.releaseTransient(adopted.id, discard: true)
        await published.lease.release(); await restored.close(); try await restoredStore.close()
        try FileManager.default.removeItem(at: f.root)
    }

    @Test func coldCleanupCannotReclaimUndrainedBackgroundReservations() async throws {
        let f = try await Fixture(), reservation = try await f.reserve()
        try await f.files.installBackgroundDownload(reservation, task: f.task)
        try await f.files.releaseTransient(reservation.id, discard: false)
        await f.files.close()
        let restored = try V2ResourceFileStore(scope: f.scope, journal: f.journal)
        #expect(try await restored.planCleanup().transferStagingIDs.isEmpty)
        #expect(try await restored.snapshot().backgroundReservedBytes == 8192)
        #expect(try await restored.snapshot().transferReservedBytes == 0)
        try await restored.reconcileBackgroundDownloads(session: f.session, retained: [f.mapping])
        #expect(try f.journal.stagingReservations().count == 1)
        // Only the coordinator, after OS task adoption/drain, supplies this set.
        try await restored.reconcileBackgroundDownloads(session: f.session, retained: [])
        #expect(try f.journal.stagingReservations().isEmpty)
        #expect(try f.inbox.permits().isEmpty)
        await restored.close(); try await f.remove()
    }

    @Test func oneReservationCoversBothRawAndPublicationAndRejectsAnotherPeak() async throws {
        let f = try await Fixture(temporaryLimit: 8192), reservation = try await f.reserve()
        #expect(try await f.files.snapshot().quota.temporaryReservedBytes == 8192)
        await #expect(throws: V2ResourceStorageError.capacityExceeded) {
            try await f.files.reserveBackgroundDownload(mapping: UUID(), session: f.session, target: f.target)
        }
        #expect(try f.inbox.permits().count == 1)
        try await f.files.installBackgroundDownload(reservation, task: f.task)
        try f.inbox.receive(f.source(), mapping: f.mapping, identifier: 7, origin: f.origin)
        let publication = try await f.files.publishDownload(of: reservation.fileURL, reservation: reservation,
            byteCount: f.task.expectedByteCount, checksum: f.task.checksum)
        #expect(try await f.files.snapshot().quota.temporaryReservedBytes == 4096)
        #expect(try await f.files.backgroundDownloadWasPublished(f.task))
        try await f.files.releaseTransient(reservation.id, discard: true)
        #expect(try await f.files.snapshot().quota.temporaryReservedBytes == 0)
        #expect(try f.inbox.permits().isEmpty)
        await publication.lease.release(); try await f.remove()
    }

    @Test func reusingAnotherVerifiedBlobSettlesThePublicationCredit() async throws {
        let f = try await Fixture(), reservation = try await f.reserve()
        try await f.files.installBackgroundDownload(reservation, task: f.task)
        try f.inbox.receive(f.source(), mapping: f.mapping, identifier: 7, origin: f.origin)
        let existing = try await f.files.publishCopy(of: f.source(), byteCount: f.task.expectedByteCount,
            checksum: f.task.checksum, retention: .cache)
        let publication = try await f.files.publishDownload(of: reservation.fileURL, reservation: reservation,
            byteCount: f.task.expectedByteCount, checksum: f.task.checksum)
        #expect(publication.id == existing)
        #expect(try await f.files.backgroundDownloadWasPublished(f.task))
        #expect(try await f.files.snapshot().quota.temporaryReservedBytes == 4096)
        try await f.files.releaseTransient(reservation.id, discard: true)
        await publication.lease.release(); try await f.remove()
    }

    @Test("failed publication rearms while raw source stays owned; committed copies survive cold recovery",
          arguments: V2ResourceFileStore.PublicationCheckpoint.allCases)
    func interruptedPublication(stage: V2ResourceFileStore.PublicationCheckpoint) async throws {
        let f = try await Fixture(temporaryLimit: 8192, failure: stage), reservation = try await f.reserve()
        try await f.files.installBackgroundDownload(reservation, task: f.task)
        try f.inbox.receive(f.source(), mapping: f.mapping, identifier: 7, origin: f.origin)
        await #expect(throws: Interrupted.self) {
            try await f.files.publishDownload(of: reservation.fileURL, reservation: reservation,
                byteCount: f.task.expectedByteCount, checksum: f.task.checksum)
        }
        if stage == .partialWritten {
            #expect(try await !f.files.backgroundDownloadWasPublished(f.task))
            try await f.files.rearmBackgroundDownload(f.task, reservation: reservation)
            #expect(try await f.files.snapshot().quota.temporaryReservedBytes == 8192)
            #expect(try await f.files.planCleanup().transferStagingIDs.isEmpty)
        } else {
            #expect(try await f.files.backgroundDownloadWasPublished(f.task))
            #expect(try await f.files.snapshot().quota.temporaryReservedBytes == 4096)
        }
        try await f.files.releaseTransient(reservation.id, discard: false)
        await f.files.close()
        let restored = try V2ResourceFileStore(scope: f.scope, journal: f.journal)
        if stage == .partialWritten {
            let adopted = try await restored.adoptBackgroundDownload(f.task)
            let publication = try await restored.publishDownload(of: adopted.fileURL, reservation: adopted,
                byteCount: f.task.expectedByteCount, checksum: f.task.checksum)
            #expect(try Data(contentsOf: publication.lease.fileURL) == Fixture.body)
            try await restored.releaseTransient(adopted.id, discard: true)
            await publication.lease.release()
        } else {
            #expect(try await restored.backgroundDownloadWasPublished(f.task))
            try await restored.reconcileBackgroundDownloads(session: f.session, retained: [])
            #expect(try await restored.snapshot().files.count == 1)
        }
        await restored.close(); try await f.remove()
    }

    @Test func revokedOrRetiredInboxNeverRecreatesDirectoriesForLateCallback() async throws {
        let f = try await Fixture(), reservation = try await f.reserve()
        try await f.files.installBackgroundDownload(reservation, task: f.task)
        let source = try f.source()
        try await f.files.releaseTransient(reservation.id, discard: true)
        #expect(throws: (any Error).self) { try f.inbox.receive(source, mapping: f.mapping, identifier: 7, origin: f.origin) }
        try FileManager.default.removeItem(at: f.scope.backgroundDirectory)
        #expect(throws: (any Error).self) { try f.inbox.receive(source, mapping: f.mapping, identifier: 7, origin: f.origin) }
        #expect(!FileManager.default.fileExists(atPath: f.scope.backgroundDirectory.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        try await f.remove()
    }

    @Test func callbackRejectsSymlinkedProviderBytes() async throws {
        let f = try await Fixture(), reservation = try await f.reserve()
        try await f.files.installBackgroundDownload(reservation, task: f.task)
        let source = try f.source(), link = f.root.appending(path: "provider-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: (any Error).self) { try f.inbox.receive(link, mapping: f.mapping, identifier: 7, origin: f.origin) }
        #expect(FileManager.default.fileExists(atPath: source.path))
        try await f.files.releaseTransient(reservation.id, discard: true)
        try await f.remove()
    }

    private struct Interrupted: Error {}
    private struct Fixture {
        static let body = Data(repeating: 5, count: 4096)
        let root: URL, database: URL, scope: V2AccountStorageScope
        let account: UserID, binding: V2LocalInstallationBinding
        let session = UUID(), mapping = UUID()
        let store: GRDBV2LocalSyncStore, journal: V2ResourceFileJournal, files: V2ResourceFileStore
        let target: V2ClientMediaTransferTarget, task: V2BackgroundDownloadTask
        let inbox: V2ResourceBackgroundDownloadInbox, origin: String
        init(temporaryLimit: Int64 = 65536, failure: V2ResourceFileStore.PublicationCheckpoint? = nil) async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "background-inbox-\(UUID())")
            database = root.appending(path: "V2.sqlite")
            account = .init(uuid: UUID()); binding = .init(value: UUID())
            store = try .init(databaseURL: database, installationBinding: binding, userID: account)
            journal = await store.resourceFileJournal()
            scope = .init(incarnation: UUID(), accountID: account, directory: root.appending(path: "account"), cacheDirectory: root.appending(path: "cache"))
            files = try .init(root: scope.resourceFilesDirectory, cacheRoot: scope.resourceCacheDirectory,
                backgroundRoot: scope.backgroundDirectory, journal: journal,
                policy: .init(maximumCacheBytes: 65536, maximumTemporaryBytes: temporaryLimit)) { stage in
                if stage == failure { throw Interrupted() }
            }
            let now = Date(), checksum = try V2ResourceChecksum(value: SHA256.hash(data: Self.body).map { String(format: "%02x", $0) }.joined())
            target = try .init(downloadPlan: .init(mode: .httpGet, url: URL(string: "https://objects.invalid/bytes")!,
                expiresAt: now.addingTimeInterval(60), expectedByteCount: Int64(Self.body.count), checksum: checksum,
                backgroundDownloadAuthorization: .init(id: UUID(), expectedByteCount: Int64(Self.body.count), checksum: checksum, issuedAt: now, expiresAt: now.addingTimeInterval(60))))
            let grant = try #require(target.backgroundDownloadAuthorization)
            origin = try #require(V2BackgroundResultInbox.originDigest(target.url))
            task = try .init(id: mapping, sessionID: session, identifier: 7, grantID: grant.id, expectedByteCount: grant.expectedByteCount,
                checksum: checksum, originDigest: origin, expiresAtMilliseconds: grant.expiresAtMilliseconds)
            inbox = .init(root: scope.backgroundDirectory, sessionID: session)
        }
        func reserve() async throws -> V2ResourceTransferStaging { try await files.reserveBackgroundDownload(mapping: mapping, session: session, target: target) }
        func source(_ bytes: Data = Self.body) throws -> URL {
            let url = root.appending(path: "provider-\(UUID())"); try bytes.write(to: url); return url
        }
        func remove() async throws { await files.close(); try await store.close(); try FileManager.default.removeItem(at: root) }
    }
}
