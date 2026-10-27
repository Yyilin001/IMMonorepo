import Foundation
import ImageIO
import IMV2ClientKit
import IMV2Core
import UniformTypeIdentifiers

/// Presentation metadata for a durable, account-local selection. Paths are not
/// part of a draft or upload identity, and preview consumers borrow separately.
struct V2StagedConversationAttachment: Hashable, Identifiable, Sendable {
    let id: UUID
    let localAssetID: V2LocalResourceAssetID
    let displayName: String
    let contentType: String
    let byteCount: Int64
    let availability: V2LocalResourceAsset.Availability
    let imageDimensions: V2LocalResourceImageDimensions?
    init(asset: V2LocalResourceAsset) {
        id = asset.id.value; localAssetID = asset.id; displayName = asset.displayName.value
        contentType = asset.contentType.value; byteCount = asset.byteCount; availability = asset.availability
        imageDimensions = asset.imageDimensions
    }
    init(id: UUID, localAssetID: V2LocalResourceAssetID, displayName: String, contentType: String, byteCount: Int64,
         availability: V2LocalResourceAsset.Availability = .local, imageDimensions: V2LocalResourceImageDimensions? = nil) {
        self.id = id; self.localAssetID = localAssetID; self.displayName = displayName
        self.contentType = contentType; self.byteCount = byteCount; self.availability = availability
        self.imageDimensions = imageDimensions
    }
    init(id: UUID, displayName: String, contentType: String, byteCount: Int64) {
        self.init(id: id, localAssetID: .init(id), displayName: displayName, contentType: contentType, byteCount: byteCount)
    }
}

nonisolated struct V2NormalizedPhoto: Sendable {
    enum Format: Sendable { case jpeg, png }
    let data: Data
    let format: Format
    var imageDimensions: V2LocalResourceImageDimensions? = nil
    var displayName: String { format == .png ? "照片.png" : "照片.jpg" }
    var contentType: String { format == .png ? "image/png" : "image/jpeg" }
}

protocol V2ConversationAttachmentStaging: Sendable {
    func stageImportedFile(at sourceURL: URL, purpose: V2LocalResourceAssetPurpose) async throws -> V2StagedConversationAttachment
    func stageNormalizedPhoto(_ photo: V2NormalizedPhoto, purpose: V2LocalResourceAssetPurpose) async throws -> V2StagedConversationAttachment
    func selectedAttachments(purpose: V2LocalResourceAssetPurpose) async throws -> [V2StagedConversationAttachment]
    func borrow(_ context: V2LocalResourceReadContext) async throws -> V2ResourceFileLease
    func discard(_ attachment: V2StagedConversationAttachment) async
}

protocol V2ConversationAttachmentUploading: Sendable {
    /// 仅在边缘报告扫描器已批准可用之后才返回。
    ///
    /// - Parameter attachment: 已暂存、待上传的会话附件。
    /// - Returns: 扫描器批准后可写入消息的安全媒体引用。
    /// - Throws: 上传失败或扫描器拒绝时抛出。
    func upload(_ attachment: V2StagedConversationAttachment) async throws -> V2MediaReference
}

enum V2ConversationAttachmentStagingError: Error, Equatable, Sendable {
    case notRegularFile
    case invalidByteCount
    case fileTooLarge
    case stagingQuotaExceeded
    case fileSystemFailure
}

struct V2ConversationAttachmentStagingPolicy: Equatable, Sendable {
    let maximumFileBytes: Int64
    let maximumFileCount: Int
    init(maximumFileBytes: Int64, maximumFileCount: Int) {
        precondition(maximumFileBytes > 0 && (1...256).contains(maximumFileCount))
        self.maximumFileBytes = maximumFileBytes; self.maximumFileCount = maximumFileCount
    }
    static let standard = Self(maximumFileBytes: 50 * 1_024 * 1_024, maximumFileCount: 64)
}

/// iOS selection boundary. ResourceCenter is the sole byte owner; this adapter
/// owns the security-scoped input access and drains it before account teardown.
actor V2FileConversationAttachmentStager: V2ConversationAttachmentStaging {
    private let resources: V2ResourceCenter
    private let policy: V2ConversationAttachmentStagingPolicy
    private let operations = V2ResourceOperationScope(limit: 4)
    private var closed = false
    init(resources: V2ResourceCenter, policy: V2ConversationAttachmentStagingPolicy = .standard) {
        self.resources = resources; self.policy = policy
    }

    func stageImportedFile(at sourceURL: URL, purpose: V2LocalResourceAssetPurpose) async throws -> V2StagedConversationAttachment {
        try requireOpen()
        return try await operations.run(onCancelledValue: { asset in
            try? await self.resources.discardLocalSelection(asset.localAssetID)
        }) { try await self.importFile(sourceURL, purpose: purpose) }
    }
    func stageNormalizedPhoto(_ photo: V2NormalizedPhoto, purpose: V2LocalResourceAssetPurpose) async throws -> V2StagedConversationAttachment {
        try requireOpen()
        return try await operations.run(onCancelledValue: { asset in
            try? await self.resources.discardLocalSelection(asset.localAssetID)
        }) {
            guard !photo.data.isEmpty else { throw V2ConversationAttachmentStagingError.invalidByteCount }
            guard photo.data.count <= self.policy.maximumFileBytes else { throw V2ConversationAttachmentStagingError.fileTooLarge }
            let asset: V2LocalResourceAsset
            do {
                asset = try await self.resources.importLocal(data: photo.data, displayName: .init(photo.displayName),
                    contentType: .init(photo.contentType), purpose: purpose, imageDimensions: photo.imageDimensions,
                    maximumBytes: self.policy.maximumFileBytes, maximumSelections: self.policy.maximumFileCount)
            } catch V2ResourceStorageError.capacityExceeded { throw V2ConversationAttachmentStagingError.stagingQuotaExceeded }
            do { try await self.requireOpen() }
            catch { try? await self.resources.discardLocalSelection(asset.id); throw error }
            return .init(asset: asset)
        }
    }
    private func importFile(_ source: URL, purpose: V2LocalResourceAssetPurpose) async throws -> V2StagedConversationAttachment {
        try requireOpen()
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.nameKey,.contentTypeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw V2ConversationAttachmentStagingError.notRegularFile }
        guard let size = values.fileSize, size > 0 else { throw V2ConversationAttachmentStagingError.invalidByteCount }
        guard Int64(size) <= policy.maximumFileBytes else { throw V2ConversationAttachmentStagingError.fileTooLarge }
        let type = values.contentType ?? UTType(filenameExtension: source.pathExtension.lowercased()) ?? .data
        let dimensions: V2LocalResourceImageDimensions?
        if type.conforms(to: .image),
           let source = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            dimensions = try .init(width: (5...8).contains(orientation) ? height : width,
                                   height: (5...8).contains(orientation) ? width : height)
        } else { dimensions = nil }
        let asset: V2LocalResourceAsset
        do {
            asset = try await resources.importLocal(at: source, displayName: .init(values.name ?? source.lastPathComponent),
                contentType: .init(type.preferredMIMEType ?? "application/octet-stream"), purpose: purpose, imageDimensions: dimensions,
                maximumBytes: policy.maximumFileBytes, maximumSelections: policy.maximumFileCount)
        } catch V2ResourceStorageError.capacityExceeded { throw V2ConversationAttachmentStagingError.stagingQuotaExceeded }
        do { try requireOpen() }
        catch { try? await resources.discardLocalSelection(asset.id); throw error }
        return .init(asset: asset)
    }
    func selectedAttachments(purpose: V2LocalResourceAssetPurpose) async throws -> [V2StagedConversationAttachment] {
        try requireOpen()
        return try await resources.selectedLocalAssets(purpose: purpose).map(V2StagedConversationAttachment.init(asset:))
    }
    func borrow(_ context: V2LocalResourceReadContext) async throws -> V2ResourceFileLease {
        try requireOpen()
        return try await resources.borrowLocalOriginal(for: context)
    }
    func discard(_ attachment: V2StagedConversationAttachment) async {
        guard !closed else { return }
        try? await resources.discardLocalSelection(attachment.localAssetID)
    }
    func close() async {
        closed = true
        await operations.close()
    }
    private func requireOpen() throws {
        try Task.checkCancellation(); guard !closed else { throw CancellationError() }
    }
}

/// 账号范围的前台上传任务所有者。
///
/// 上传意图先持久化；调用者取消只结束观察，账号活动继续执行。
/// 关闭时停止新上传，取消并等待已接收任务，随后 App 才能清理暂存。
actor V2ForegroundConversationAttachmentUploader: V2ConversationAttachmentUploading {
    private var isClosed = false
    private var transfers: [UUID: Task<V2MediaReference, Error>] = [:]
    let durable: any V2DurableConversationSending

    init(durable: any V2DurableConversationSending) {
        self.durable = durable
    }

    /// 上传暂存附件并等待媒体达到可用状态。
    ///
    /// - Parameter attachment: 当前账号拥有、在上传期间保持可读的暂存附件。
    /// - Returns: 可提交到消息命令的媒体引用，不包含 provider URL。
    /// - Throws: 取消、上传器已关闭或 ClientKit 的传输／扫描错误。
    ///   返回引用不表示消息本身已被服务端接受。
    func upload(_ attachment: V2StagedConversationAttachment) async throws -> V2MediaReference {
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        let id = UUID()
        // Cancelling the task ends its database observation. Durable transfer
        // work is independently owned and drained by the account runtime.
        let task = Task { try await self.performUpload(attachment) }
        transfers[id] = task
        defer { transfers.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            guard !isClosed else { throw CancellationError() }
            return result
        } onCancel: { task.cancel() }
    }

    /// 终止上传器，取消并等待全部已接收上传。
    ///
    /// 底层任务忽略取消时仍等待其返回，避免先删除它正在读取的暂存文件。
    func close() async {
        isClosed = true
        await durable.close()
        let pending = Array(transfers.values)
        for task in pending { task.cancel() }
        for task in pending { _ = await task.result }
    }

    private func performUpload(_ attachment: V2StagedConversationAttachment) async throws -> V2MediaReference {
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        return try await durable.upload(attachment, usage: .userAvatar)
    }
}


/// Bridges the account-owned durable uploader to profile intent preparation.
/// The staged UUID is also the upload/job/media identity across restarts.
struct V2ProfileAvatarUploadAdapter: V2ProfileAvatarPreparing {
    let uploader: any V2ConversationAttachmentUploading
    func ensureReady(_ source: V2ProfileAvatarUpload) async throws -> V2AvatarReference {
        let media = try await uploader.upload(.init(id: source.id, localAssetID: source.localAssetID,
            displayName: source.displayName, contentType: source.contentType, byteCount: source.byteCount))
        return .init(mediaID: media.mediaID)
    }
}
