import Crypto
import Foundation
import IMV2Core
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 本地文件系统的转发媒体复制适配器，仅用于本地开发。
///
/// 生产环境的原生复制、流式传输与扫描仍由部署侧适配器实现；
/// 任何文件路径或签名地址都不会进入持久化记录。
public struct V2LocalFilesystemForwardMediaCopier: V2ForwardMediaObjectCopying {
    private let sources: [String: V2LocalFilesystemMediaProvider]
    private let target: V2LocalFilesystemMediaProvider
    private let maximumBytes: Int64
    private let now: @Sendable () -> Date

    /// 组合来源分片提供方、目标提供方与体积上限。
    ///
    /// - Parameters:
    ///   - sources: 源分片标识到本地媒体提供方的映射。
    ///   - target: 目标侧本地媒体提供方。
    ///   - maximumBytes: 单对象允许的最大字节数，默认 64 MiB，需大于零。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 映射为空或体积上限非正时抛出
    ///   ``V2ForwardMediaCopyError/invalidReceipt``。
    public init(sources: [String: V2LocalFilesystemMediaProvider], target: V2LocalFilesystemMediaProvider,
                maximumBytes: Int64 = 64 * 1_024 * 1_024, now: @escaping @Sendable () -> Date = Date.init) throws {
        guard !sources.isEmpty, maximumBytes > 0 else { throw V2ForwardMediaCopyError.invalidReceipt }
        self.sources = sources; self.target = target; self.maximumBytes = maximumBytes; self.now = now
    }

    /// 执行一次本地文件复制。
    ///
    /// 已存在与持久化摘要一致的目标对象时直接返回该摘要，因为扫描前完成的复制
    /// 不应再受来源提供方可用性影响。复制发生在分离的效用任务中，若中途取消会丢弃暂存文件，
    /// 提交成功后同样会清理暂存对象。
    ///
    /// - Parameter lease: 本次导入租约。
    /// - Returns: 复制回执。
    /// - Throws: 超出体积上限抛出 ``V2ForwardMediaCopyError/sizeLimitExceeded``；
    ///   目标媒体与来源媒体相同时抛出 ``V2ForwardMediaCopyError/contentConflict``；
    ///   来源分片未配置或调用方目标授权不可用时抛出
    ///   ``V2ForwardMediaCopyError/sourceUnavailable``；字节数不符时抛出
    ///   ``V2ForwardMediaCopyError/byteCountMismatch``；任务取消时抛出 `CancellationError`。
    public func copy(_ lease: V2ForwardMediaImportLease) async throws -> V2ForwardMediaCopyReceipt {
        let manifest = lease.source
        guard manifest.byteCount <= maximumBytes else { throw V2ForwardMediaCopyError.sizeLimitExceeded }
        guard lease.targetMediaID.uuidValue != manifest.mediaID else { throw V2ForwardMediaCopyError.contentConflict }
        try Task.checkCancellation()
        if let digest = lease.copiedDigest,
           try await target.verifyForwardImportedObject(mediaID: lease.targetMediaID, byteCount: manifest.byteCount, digest: digest) {
            // 扫描器崩溃前已确认的复制结果，不依赖后续源提供方是否可用。
            return try .init(byteCount: manifest.byteCount, digest: digest)
        }
        guard let source = sources[lease.export.intent.sourceShardID] else { throw V2ForwardMediaCopyError.sourceUnavailable }
        let sourceID = MediaID(uuid: manifest.mediaID)
        guard let expiry = v2PostgresFutureTimestamp(now: now(), interval: 600) else {
            throw V2ForwardMediaCopyError.invalidReceipt
        }
        // 导出提交已授权此次独立复制。不要使用会重新检查
        // 可变成员关系的用户下载授权。
        let download = try await source.issueDownloadTarget(mediaID: sourceID, expiresAt: expiry)
        let object = try await source.downloadedObject(mediaID: sourceID, targetURL: download.url)
        guard object.byteCount == manifest.byteCount else { throw V2ForwardMediaCopyError.byteCountMismatch }
        let uploadTarget = try await target.issueUploadTarget(mediaID: lease.targetMediaID, contentType: manifest.contentType, byteCount: manifest.byteCount, expiresAt: expiry)
        let upload = try await target.beginUploadedObject(mediaID: lease.targetMediaID, targetURL: uploadTarget.url,
                                                        contentType: manifest.contentType, declaredByteCount: manifest.byteCount)
        do {
            // 所有路径都须持有并等待独立的文件 I/O 任务结束；
            // 写者停止后才可丢弃暂存文件。
            let transfer = Task.detached(priority: .utility) {
                try ForwardMediaFileIO.copy(from: object.fileURL, to: upload.fileURL, byteCount: manifest.byteCount)
            }
            let receipt = try await withTaskCancellationHandler {
                try await transfer.value
            } onCancel: { transfer.cancel() }
            try Task.checkCancellation()
            if let expected = lease.copiedDigest, expected != receipt.digest { throw V2ForwardMediaCopyError.contentConflict }
            try await target.commitForwardImportedObject(upload, receipt: receipt)
            try Task.checkCancellation()
            await target.discardUploadedObject(upload)
            return receipt
        } catch {
            await target.discardUploadedObject(upload)
            throw error
        }
    }
}

/// 仅在自有效用任务上使用的同步文件辅助方法。
///
/// 内存占用被限制在单块 64 KiB，传输流与落盘文件都会被计算摘要。
enum ForwardMediaFileIO {
    /// 以独占方式创建目标文件并逐块复制，边复制边计算摘要。
    ///
    /// - Parameters:
    ///   - source: 来源文件地址。
    ///   - target: 目标文件地址；已存在时失败而不覆盖。
    ///   - byteCount: 期望复制的字节数。
    /// - Returns: 复制回执。
    /// - Throws: 文件创建或写入失败时抛出；字节数与期望不符时抛出
    ///   ``V2ForwardMediaCopyError/byteCountMismatch``。
    static func copy(from source: URL, to target: URL, byteCount: Int64) throws -> V2ForwardMediaCopyReceipt {
        try Data().write(to: target, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        let digest = try read(input, byteCount: byteCount) { try output.write(contentsOf: $0) }
        try output.synchronize()
        return try .init(byteCount: byteCount, digest: digest)
    }

    /// 计算文件内容的摘要。
    ///
    /// - Parameters:
    ///   - url: 目标文件地址。
    ///   - byteCount: 期望读取的字节数。
    /// - Returns: SHA-256 摘要。
    /// - Throws: 读取失败或字节数与期望不符时抛出。
    static func digest(_ url: URL, byteCount: Int64) throws -> Data {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        return try read(input, byteCount: byteCount) { _ in }
    }

    /// 逐块读取输入并计算摘要，同时把每块交给消费闭包。
    ///
    /// - Parameters:
    ///   - input: 已打开的文件句柄。
    ///   - byteCount: 期望读取的字节数。
    ///   - consume: 对每块数据的处理闭包。
    /// - Returns: 内容摘要。
    /// - Throws: 任务取消时继续抛出取消错误；单块超出剩余字节数或最终字节数不足时抛出
    ///   ``V2ForwardMediaCopyError/byteCountMismatch``。
    private static func read(_ input: FileHandle, byteCount: Int64, consume: (Data) throws -> Void) throws -> Data {
        var remaining = byteCount
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty else { break }
            guard Int64(chunk.count) <= remaining else { throw V2ForwardMediaCopyError.byteCountMismatch }
            remaining -= Int64(chunk.count)
            hash.update(data: chunk)
            try consume(chunk)
        }
        guard remaining == 0 else { throw V2ForwardMediaCopyError.byteCountMismatch }
        return Data(hash.finalize())
    }

    /// 同步目录项，确保文件创建在掉电后仍然可见。
    ///
    /// - Parameter directory: 目标目录。
    /// - Throws: 打开目录或同步失败时抛出对应的 POSIX 错误。
    static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}
