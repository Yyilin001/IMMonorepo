import Foundation
import IMV2Core
@testable import IMV2ClientKit
@testable import IMApp

struct V2ResourceMediaTestCachePolicy: Sendable {
    let maximumByteCount: Int64
    let maximumEntryCount: Int
    let maximumAge: TimeInterval
    init(maximumByteCount: Int64 = 512 * 1_024 * 1_024, maximumEntryCount: Int = 256,
         maximumAge: TimeInterval = 7 * 24 * 60 * 60) {
        precondition(maximumByteCount > 0 && maximumEntryCount > 0 && maximumAge.isFinite && maximumAge > 0)
        self.maximumByteCount = maximumByteCount; self.maximumEntryCount = maximumEntryCount; self.maximumAge = maximumAge
    }
}

/// Every file-lifetime test uses the account journal and the real byte owner.
/// There is no second downloader-specific file layout in test fixtures.
@MainActor
func makeResourceMediaTestDownloader(
    downloader: V2ClientMediaDownloadService, directory: URL,
    cachePolicy: V2ResourceMediaTestCachePolicy = .init()
) async throws -> V2ResourceMediaTestOwner {
    let user = try UserID("resource-media-test-account")
    let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "V2.sqlite"),
        installationBinding: .init(value: UUID(uuidString: "B6B2F8F9-EBD7-471D-B997-E38239B99F00")!), userID: user)
    let scope = V2AccountStorageScope(incarnation: UUID(), accountID: user, directory: directory, cacheDirectory: directory.appending(path: "cache-scope"))
    let center = try await V2ResourceCenter.make(scope: scope, store: store, policy: .testBounded(cachePolicy.maximumByteCount))
    return .init(downloader: .init(cache: try await center.downloadCache(using: downloader), center: center), store: store,
                 center: center, cachePolicy: cachePolicy)
}

/// The production center shares the account database and must not close it.
/// This standalone test owner supplies that account teardown after I/O drains.
struct V2ResourceMediaTestOwner: V2ConversationMediaDownloading, V2ConversationMediaCacheDiscarding {
    func cachedFile(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2DownloadedConversationMedia? { try await downloader.cachedFile(media, message: message) }
    func borrowCached(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2ConversationMediaFileLease? { try await downloader.borrowCached(media, message: message) }
    let downloader: V2ForegroundConversationMediaDownloader
    let store: GRDBV2LocalSyncStore
    let center: V2ResourceCenter
    let cachePolicy: V2ResourceMediaTestCachePolicy
    func download(_ media: V2MediaReference, message: V2MediaMessageLocation? = nil) async throws -> V2DownloadedConversationMedia {
        try await downloader.download(media, message: message)
    }
    func avatar(_ access: V2ResourceAvatarAccess, home: V2ResourceHome) async throws -> V2ConversationMediaFileLease {
        let remaining = access.plan?.expiresAt.timeIntervalSinceNow ?? 0
        let deadline = ContinuousClock.now + .seconds(max(0, remaining))
        return try await downloader.avatar(.init(avatar: access, home: home, deadline: deadline,
            downloadDeadline: deadline, validate: { true }))
    }
    func discard(_ media: V2MediaReference) async { await downloader.discard(media) }
    func performMaintenance(now: Date = Date()) async throws {
        try await center.maintainCache(maximumEntryCount: cachePolicy.maximumEntryCount, maximumAge: cachePolicy.maximumAge, now: now)
    }
    func close() async throws {
        try await downloader.close()
        try await store.close()
    }
}

/// Seeds through the real publication path, then forbids unexpected network I/O.
actor ResourceMediaSeedBytes: V2ClientMediaByteTransfer {
    private var bytes: Data?
    init(_ bytes: Data) { self.bytes = bytes }
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) throws {
        guard let bytes else { throw CancellationError() }
        self.bytes = nil
        try bytes.write(to: destinationURL)
    }
}
