import Foundation
import IMV2ClientKit
import IMV2Core
import UniformTypeIdentifiers

/// Account-scoped composition of local facts, current message authority and
/// the existing transfer owner. Views never obtain provider URLs or paths to delete.
nonisolated struct V2ResourceManagementService: Sendable {
    let center: V2ResourceCenter
    let localStore: GRDBV2LocalSyncStore
    let downloader: any V2ConversationMediaDownloading
    let directory: any V2RoomResourceDirectoryReading

    func changes() async -> V2ProjectionChangeSubscription { await localStore.projectionChanges() }

    func thumbnail(_ key: V2ResourceKey, using cache: V2LocalMediaThumbnailCache) async throws -> V2SendableImage? {
        guard let detail = try await center.details(for: key),
              [.image, .animatedImage, .video].contains(detail.descriptor.kind),
              detail.variants.contains(where: { variant in
                  guard case .original = variant.descriptor.key.rendition, case .available = variant.localState else { return false }
                  return true
              }), let source = detail.sources.first else { return nil }
        guard let lease = try await downloader.borrowCached(.init(mediaID: key.mediaID), message: source.location) else { return nil }
        let image = await cache.thumbnail(fileURL: lease.fileURL, maximumPixelSize: 512,
            kind: detail.descriptor.kind == .video ? .video : .image)
        await lease.release()
        try Task.checkCancellation()
        guard try await center.containsSource(source, for: key) else { throw V2ResourceStorageError.unavailable }
        return image
    }

    func synchronize(room: RoomID, category: V2ResourceCategory, restart: Bool) async throws -> Bool {
        let page = try await center.synchronize(roomID: room, query: .init(category: category), using: directory, restart: restart)
        return page?.nextCursor != nil
    }

    func borrow(_ key: V2ResourceKey, source: V2ResourceMessageSource, contentType: String) async throws -> V2ConversationMediaFileLease {
        guard try await center.containsSource(source, for: key) else { throw V2ResourceStorageError.unavailable }
        // Persist the accepted read demand before the presentation's network
        // authorization or capacity wait. A disappearing page may detach its
        // waiter, but cannot erase this account-owned recovery intent.
        switch try await center.prepareMessageDownload(mediaID: key.mediaID, message: source.location) {
        case .local, .queued: break
        }
        try Task.checkCancellation()
        let downloaded = try await downloader.download(.init(mediaID: key.mediaID), message: source.location)
        let original = try await downloaded.borrowFile()
        let lease: V2ConversationMediaFileLease
        do {
            if let ext = UTType(mimeType: contentType)?.preferredFilenameExtension {
                lease = try await original.forPresentation(fileExtension: ext.lowercased())
                await original.release()
            } else { lease = original }
        } catch { await original.release(); throw error }
        do {
            try Task.checkCancellation()
            guard try await center.containsSource(source, for: key) else { throw V2ResourceStorageError.unavailable }
            return lease
        } catch { await lease.release(); throw error }
    }
}

nonisolated enum V2ResourceFailure {
    static func message(_ error: any Error) -> String {
        switch error {
        case V2ResourceAutomaticDownloadError.policyRestricted: "此文件不符合自动下载设置，可调整设置或主动下载。"
        case V2ResourceDownloadControlError.paused: "下载已暂停，请到传输任务中继续下载。"
        case V2ResourceTransferManagementError.actionUnavailable: "任务状态已变化，当前无法执行此操作。"
        case V2ResourceStorageError.expiredCleanupPlan: "清理预览已过期，请重新预览。"
        case V2ResourceStorageError.capacityExceeded: "资源任务繁忙或空间不足，请稍后重试。"
        case V2ResourceStorageError.integrityMismatch: "文件校验失败，请重新下载。"
        case V2ClientResourceDirectoryError.notVisible, V2ResourceStorageError.unavailable,
             V2ResourceStorageError.closed, V2ClientMediaTransferError.authorizationDenied,
             V2MediaFileAccessError.unavailable: "资源当前不可访问，请联网后重试。"
        default: "暂时无法完成，请稍后重试。"
        }
    }
}
