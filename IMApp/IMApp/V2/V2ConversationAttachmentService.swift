import Foundation
import IMV2ClientKit
import IMV2Core
import UniformTypeIdentifiers

/// 设备本地的导入副本及非持久化元数据。
///
/// 消息 outbox 只保存上传后的媒体引用，不保存此路径或显示名。
struct V2StagedConversationAttachment: Hashable, Identifiable, Sendable {
    let id: UUID
    let fileURL: URL
    let displayName: String
    let contentType: String
    let byteCount: Int64
}

protocol V2ConversationAttachmentStaging: Sendable {
    func stageImportedFile(at sourceURL: URL) async throws -> V2StagedConversationAttachment
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
    let maximumDirectoryBytes: Int64
    let maximumFileCount: Int

    init(maximumFileBytes: Int64, maximumDirectoryBytes: Int64, maximumFileCount: Int) {
        precondition(
            maximumFileBytes > 0
                && maximumDirectoryBytes >= maximumFileBytes
                && maximumFileCount > 0
        )
        self.maximumFileBytes = maximumFileBytes
        self.maximumDirectoryBytes = maximumDirectoryBytes
        self.maximumFileCount = maximumFileCount
    }

    /// 默认的本机安全上限。
    ///
    /// 该设备本地安全边界刻意独立于提供方的权威限制。
    /// 提供方可能拒绝更小的文件，但任何已配置的提供方都不能让 App 暂存无上限的文件。
    static let standard = Self(
        maximumFileBytes: 50 * 1_024 * 1_024,
        maximumDirectoryBytes: 512 * 1_024 * 1_024,
        maximumFileCount: 64
    )
}

/// 账号暂存目录的所有者，执行受配额限制的文件导入。
///
/// 复制期间临时访问 security-scoped 源文件，按块检查容量与取消。
/// 目录关闭是终态：等待 actor 中同步复制结束后删除副本，后续导入被拒绝。
actor V2FileConversationAttachmentStager: V2ConversationAttachmentStaging {
    private var isClosed = false
    private let directory: URL
    private let fileManager: FileManager
    private let policy: V2ConversationAttachmentStagingPolicy
    private let makeUUID: @Sendable () -> UUID
    private let protectionWriter:any V2ResourceFileProtectionWriting

    init(
        directory: URL,
        fileManager: FileManager = .default,
        policy: V2ConversationAttachmentStagingPolicy = .standard,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        protectionWriter:any V2ResourceFileProtectionWriting = V2SystemResourceFileProtectionWriter()
    ) throws {
        self.directory = try V2DeviceLocalStoragePolicy.prepareManagedDirectory(
            directory,
            fileManager: fileManager
        )
        self.fileManager = fileManager
        self.policy = policy
        self.makeUUID = makeUUID
        self.protectionWriter=protectionWriter
        try V2ResourceStagingBudget.register(directory:self.directory)
    }

    /// 把用户选择的文件复制到受保护的账号暂存目录。
    ///
    /// - Parameter sourceURL: 本地普通文件，可为 security-scoped 导入 URL。
    /// - Returns: 随机暂存身份、路径、内容类型、显示名和实际复制字节数。
    /// - Throws: 取消、关闭后的请求、文件类型／大小／配额错误或文件系统错误。
    ///   复制失败会尝试清理目标副本，原始文件保持不变。
    func stageImportedFile(at sourceURL: URL) throws -> V2StagedConversationAttachment {
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        let accessGranted = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let values: URLResourceValues
        do {
            values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .nameKey, .contentTypeKey])
        } catch {
            throw V2ConversationAttachmentStagingError.fileSystemFailure
        }
        guard values.isRegularFile == true else { throw V2ConversationAttachmentStagingError.notRegularFile }
        guard let fileSize = values.fileSize, fileSize > 0 else { throw V2ConversationAttachmentStagingError.invalidByteCount }
        guard Int64(fileSize) <= policy.maximumFileBytes else {
            throw V2ConversationAttachmentStagingError.fileTooLarge
        }
        let usage = try stagingUsage()
        guard usage.fileCount < policy.maximumFileCount,
              usage.byteCount <= policy.maximumDirectoryBytes - Int64(fileSize)
        else { throw V2ConversationAttachmentStagingError.stagingQuotaExceeded }
        let id = makeUUID()
        let destination = directory.appendingPathComponent(id.uuidString, isDirectory: false)
        let partial = directory.appendingPathComponent(".partial-" + id.uuidString, isDirectory: false)
        var copiedByteCount: Int64 = 0
        do {
            copiedByteCount = try V2ResourceStagingBudget.withCopy(directory:directory,additionalBytes:Int64(fileSize)) {
                try copyWithinLimits(
                sourceURL: sourceURL,
                destination: partial,
                maximumDirectoryAddition: min(policy.maximumDirectoryBytes - usage.byteCount, Int64(fileSize))
                )
            }
            try Task.checkCancellation()
            try fileManager.moveItem(at: partial, to: destination)
            try V2DeviceLocalStoragePolicy.applyToManagedFile(destination, fileManager: fileManager)
            try protectionWriter.apply(.complete,to:destination)
        } catch is CancellationError {
            try? fileManager.removeItem(at: partial)
            try? fileManager.removeItem(at: destination)
            throw CancellationError()
        } catch let error as V2ConversationAttachmentStagingError {
            try? fileManager.removeItem(at: partial)
            try? fileManager.removeItem(at: destination)
            throw error
        } catch let error as V2DeviceLocalStorageError {
            try? fileManager.removeItem(at: partial)
            try? fileManager.removeItem(at: destination)
            throw error
        } catch {
            try? fileManager.removeItem(at: partial)
            try? fileManager.removeItem(at: destination)
            throw V2ConversationAttachmentStagingError.fileSystemFailure
        }
        let contentType = values.contentType
            ?? UTType(filenameExtension: sourceURL.pathExtension.lowercased())
            ?? .data
        let mimeType = contentType.preferredMIMEType ?? "application/octet-stream"
        return .init(
            id: id,
            fileURL: destination,
            displayName: values.name ?? sourceURL.lastPathComponent,
            contentType: mimeType,
            byteCount: copiedByteCount
        )
    }

    private func copyWithinLimits(
        sourceURL: URL,
        destination: URL,
        maximumDirectoryAddition: Int64
    ) throws -> Int64 {
        guard !fileManager.fileExists(atPath: destination.path),
              fileManager.createFile(atPath: destination.path, contents: nil)
        else { throw V2ConversationAttachmentStagingError.fileSystemFailure }
        try V2DeviceLocalStoragePolicy.applyToManagedFile(destination, fileManager: fileManager)
        let source: FileHandle
        do {
            source = try FileHandle(forReadingFrom: sourceURL)
        } catch {
            throw V2ConversationAttachmentStagingError.fileSystemFailure
        }
        defer { try? source.close() }
        let target: FileHandle
        do {
            target = try FileHandle(forWritingTo: destination)
        } catch {
            throw V2ConversationAttachmentStagingError.fileSystemFailure
        }
        defer {
            try? target.close()
        }
        var total: Int64 = 0
        do {
            while let bytes = try source.read(upToCount: 64 * 1_024), !bytes.isEmpty {
                try Task.checkCancellation()
                let count = Int64(bytes.count)
                guard total <= policy.maximumFileBytes - count else {
                    throw V2ConversationAttachmentStagingError.fileTooLarge
                }
                guard total <= maximumDirectoryAddition - count else {
                    throw V2ConversationAttachmentStagingError.stagingQuotaExceeded
                }
                try target.write(contentsOf: bytes)
                total += count
            }
            try Task.checkCancellation()
            try target.synchronize()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2ConversationAttachmentStagingError {
            throw error
        } catch {
            throw V2ConversationAttachmentStagingError.fileSystemFailure
        }
        guard total > 0 else { throw V2ConversationAttachmentStagingError.invalidByteCount }
        return total
    }

    private func stagingUsage() throws -> (fileCount: Int, byteCount: Int64) {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: []
            )
        } catch {
            throw V2ConversationAttachmentStagingError.fileSystemFailure
        }
        var byteCount: Int64 = 0
        for entry in entries {
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            } catch {
                throw V2ConversationAttachmentStagingError.fileSystemFailure
            }
            guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize >= 0 else {
                throw V2ConversationAttachmentStagingError.fileSystemFailure
            }
            let size = Int64(fileSize)
            guard byteCount <= Int64.max - size else {
                throw V2ConversationAttachmentStagingError.stagingQuotaExceeded
            }
            byteCount += size
        }
        return (entries.count, byteCount)
    }

    /// 终止暂存器并删除其受管目录，可重复调用。
    ///
    /// actor 串行化保证同步复制已结束；调用者必须先等待上传者结束文件读取。
    ///
    /// - Throws: 无法删除目录时抛出文件系统错误，不能把清理失败当成退出成功。
    func close(preservingDurableFiles: Bool = false) throws {
        isClosed = true
        if preservingDurableFiles { return }
        if fileManager.fileExists(atPath: directory.path) {
            do { try fileManager.removeItem(at: directory) }
            catch { throw V2ConversationAttachmentStagingError.fileSystemFailure }
        }
    }

    func discard(_ attachment: V2StagedConversationAttachment) {
        let candidate = attachment.fileURL.standardizedFileURL
        guard candidate.deletingLastPathComponent() == directory else { return }
        try? fileManager.removeItem(at: candidate)
    }

    /// Startup only, after draining the previous account owner and before any
    /// foreground activity starts. These incomplete copies never have durable tokens.
    func discardInterruptedCopies() throws {
        guard !isClosed else { throw CancellationError() }
        guard let entries = fileManager.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants]) else { throw V2ConversationAttachmentStagingError.fileSystemFailure }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        for case let entry as URL in entries {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw V2ConversationAttachmentStagingError.fileSystemFailure }
            let name = entry.lastPathComponent
            let prefix = name.hasPrefix(".part-") ? ".part-" : (name.hasPrefix(".partial-") ? ".partial-" : nil)
            guard let prefix, UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
                entry.standardizedFileURL.deletingLastPathComponent() == directory else { continue }
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try fileManager.removeItem(at: entry)
        }
    }

    /// 清理残留的暂存文件。
    ///
    /// 调用方从账号 journal 提供仍受引用的文件 token；只清理超过宽限期的孤儿。
    /// 恢复中的上传与冻结发送意图不能被当成缓存淘汰，且绝不遍历目录之外。
    func discardOrphanedStagedFiles(retaining tokens: Set<String> = [], olderThan cutoff: Date? = nil) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: []
        ) else { return }
        for entry in entries {
            let candidate = entry.standardizedFileURL
            guard candidate.deletingLastPathComponent() == directory,
                  !tokens.contains(candidate.lastPathComponent),
                  let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  cutoff.map({ (values.contentModificationDate ?? .distantFuture) < $0 }) ?? true
            else { continue }
            try? fileManager.removeItem(at: candidate)
        }
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
        let media = try await uploader.upload(.init(id: source.id, fileURL: source.fileURL,
            displayName: source.displayName, contentType: source.contentType, byteCount: source.byteCount))
        return .init(mediaID: media.mediaID)
    }
}
