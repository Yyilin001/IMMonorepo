import Foundation
import IMV2ClientKit
import IMV2Core

/// 一个本地的、可分享的媒体文件。
///
/// 它刻意不包含提供方 URL、凭据或服务端文件名；
/// 这些信息始终留在 ClientKit 的一次性授权与传输边界之内。
struct V2DownloadedConversationMedia: Hashable, Identifiable, Sendable {
    let mediaID: MediaID
    let fileURL: URL
    private let cached: V2ResourceCachedFile?

    init(mediaID: MediaID, fileURL: URL) {
        self.mediaID = mediaID; self.fileURL = fileURL; cached = nil
    }
    fileprivate init(_ cached: V2ResourceCachedFile) {
        mediaID = cached.mediaID; fileURL = cached.fileURL; self.cached = cached
    }
    /// A bare path never grants file access. The account cache issues a fresh
    /// borrow for every decoder, player or export operation.
    func borrowFile() async throws -> V2ConversationMediaFileLease {
        guard let cached else { throw V2MediaFileAccessError.unavailable }
        do { return .init(try await cached.borrowFile()) }
        catch V2ResourceStorageError.capacityExceeded { throw V2MediaFileAccessError.overloaded }
        catch is CancellationError { throw CancellationError() }
        catch { throw V2MediaFileAccessError.unavailable }
    }
    var id: MediaID { mediaID }
}

enum V2MediaFileAccessError: Error, Equatable { case unavailable, overloaded }

/// The ClientKit lease is the sole ownership claim. Dropping this wrapper
/// releases the same claim through the lease's deinit backstop.
nonisolated final class V2ConversationMediaFileLease: Sendable, Identifiable {
    let id = UUID()
    let fileURL: URL
    private let lease: V2ResourceFileLease
    fileprivate init(_ lease: V2ResourceFileLease) { self.lease = lease; fileURL = lease.fileURL }
    func release() async { await lease.release() }
    func forPresentation(fileExtension: String) async throws -> V2ConversationMediaFileLease {
        .init(try await lease.forPresentation(fileExtension: fileExtension))
    }
    func forExport(fileName: V2ResourceExportFileName) async throws -> V2ConversationMediaFileLease {
        .init(try await lease.forExport(fileName: fileName))
    }
}

protocol V2ConversationMediaDownloading: Sendable {
    func cachedFile(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2DownloadedConversationMedia?
    func imagePreview(_ media: V2MediaReference, message: V2MediaMessageLocation) async throws -> V2DownloadedConversationMedia
    func cachedImagePreview(_ media: V2MediaReference, message: V2MediaMessageLocation) async throws -> V2DownloadedConversationMedia?
    func borrowCached(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2ConversationMediaFileLease?
    /// 在返回可借用的本地文件之前，先重新授权并校验缓存或下载字节。
    ///
    /// 实现绝不能返回提供方目标地址。
    ///
    /// - Parameters:
    ///   - media: 待下载的媒体引用。
    ///   - message: 媒体所在消息的位置，可为空。
    /// - Returns: 可分享的本地媒体文件。
    /// - Throws: 授权失败或传输失败时抛出。
    func download(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2DownloadedConversationMedia
}

extension V2ConversationMediaDownloading {
    func cachedImagePreview(_ media: V2MediaReference, message: V2MediaMessageLocation) async throws -> V2DownloadedConversationMedia? { nil }
    func imagePreview(_ media: V2MediaReference, message: V2MediaMessageLocation) async throws -> V2DownloadedConversationMedia {
        throw V2MediaFileAccessError.unavailable
    }
}

/// 可选的本地缓存能力。
///
/// 它与下载能力分离，使既有的测试/远端实现不会因此获得文件系统权限。
protocol V2ConversationMediaCacheDiscarding: Sendable {
    func discard(_ media: V2MediaReference) async
}

enum V2DeviceLocalStorageError: Error, Equatable, Sendable {
    case fileSystemFailure
    case backupExclusionNotApplied
}

/// 把 V2 的设备本地存储策略应用到存放本地同步状态或已下载媒体的目录。
///
/// 此目录保存前台下载缓存，采用 `Complete` 保护级别。
/// 后台上传源文件和完成回调 inbox 由各自的文件所有者管理。
enum V2DeviceLocalStoragePolicy {
    static func prepareManagedDirectory(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        var managedDirectory = directory.standardizedFileURL
        do {
            try fileManager.createDirectory(at: managedDirectory, withIntermediateDirectories: true)
            try applyBackupExclusion(to: &managedDirectory)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: managedDirectory.path
            )
        } catch let error as V2DeviceLocalStorageError {
            throw error
        } catch {
            throw V2DeviceLocalStorageError.fileSystemFailure
        }
        return managedDirectory
    }

    static func applyToManagedFile(
        _ fileURL: URL,
        fileManager: FileManager = .default
    ) throws {
        var managedFile = fileURL.standardizedFileURL
        do {
            try applyBackupExclusion(to: &managedFile)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: managedFile.path
            )
        } catch let error as V2DeviceLocalStorageError {
            throw error
        } catch {
            throw V2DeviceLocalStorageError.fileSystemFailure
        }
    }

    private static func applyBackupExclusion(to url: inout URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        guard try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
            throw V2DeviceLocalStorageError.backupExclusionNotApplied
        }
    }
}

/// Presentation adapter for the account ResourceCenter. It owns no paths,
/// cache records or pin counters; ClientKit owns all byte lifetimes.
actor V2ForegroundConversationMediaDownloader: V2ConversationMediaDownloading, V2ConversationMediaCacheDiscarding {
    private let cache: V2ResourceDownloadCache
    private let center: V2ResourceCenter
    private var closed = false

    init(cache: V2ResourceDownloadCache, center: V2ResourceCenter) {
        self.cache = cache; self.center = center
    }

    func download(_ media: V2MediaReference, message: V2MediaMessageLocation? = nil) async throws -> V2DownloadedConversationMedia {
        try requireOpen()
        let file: V2ResourceCachedFile
        do {
            if let message {
                // Unknown versions persist as logical demands; the authenticated
                // leaf resolves their byte identity without creating another task.
                _ = try await center.prepareMessageDownload(mediaID: media.mediaID, message: message)
            }
            file = try await cache.download(media, message: message)
        }
        catch V2ResourceStorageError.closed { throw CancellationError() }
        try requireOpen()
        let use = try await file.borrowFile()
        do { try await performMaintenance(); await use.release() }
        catch { await use.release(); throw error }
        try requireOpen()
        return .init(file)
    }

    func borrowCached(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2ConversationMediaFileLease? {
        try requireOpen()
        guard let lease = try await cache.borrowCached(media, message: message) else { return nil }
        do { try requireOpen(); try Task.checkCancellation(); return .init(lease) }
        catch { await lease.release(); throw error }
    }

    func cachedFile(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2DownloadedConversationMedia? {
        try requireOpen()
        guard let file = try await cache.cachedFile(media, message: message) else { return nil }
        try requireOpen(); try Task.checkCancellation()
        return .init(file)
    }

    func cachedImagePreview(_ media: V2MediaReference, message: V2MediaMessageLocation) async throws -> V2DownloadedConversationMedia? {
        try requireOpen()
        guard let file = try await cache.cachedImagePreview(media, message: message, size: .large) else { return nil }
        try requireOpen(); try Task.checkCancellation()
        return .init(file)
    }

    func imagePreview(_ media: V2MediaReference, message: V2MediaMessageLocation) async throws -> V2DownloadedConversationMedia {
        try requireOpen()
        let file = try await cache.imagePreview(media, message: message, size: .large)
        try requireOpen()
        return .init(file)
    }

    func avatar(_ authorization: V2AvatarReadGrant) async throws -> V2ConversationMediaFileLease {
        try requireOpen()
        let use: V2ResourceFileLease
        do {
            let file = try await cache.avatar(authorization)
            use = try await file.borrowFile()
        } catch V2ResourceStorageError.closed { throw CancellationError() }
        do { try requireOpen() }
        catch { await use.release(); throw error }
        // The current borrow URL can differ from the handle's earlier cache
        // hint after promotion. The decoder owns this exact lease until done.
        return .init(use)
    }

    func discard(_ media: V2MediaReference) async { try? await cache.discard(media.mediaID) }

    func performMaintenance(now: Date = Date()) async throws {
        try requireOpen()
        try await center.maintainCache(now: now)
    }

    func attachBackgroundDownloads(_ coordinator: V2BackgroundDownloadCoordinator) async throws {
        try requireOpen()
        try await center.attachBackgroundDownloads(coordinator)
    }
    func runRecovery() async throws {
        try requireOpen()
        try await cache.runRecovery()
    }

    /// Normal account close preserves verified cache bytes. Account retirement
    /// removes the incarnation only after all real consumers and I/O drain.
    func close() async throws {
        closed = true
        await center.close()
    }

    private func requireOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
    }
}
