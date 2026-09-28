import Crypto
import Foundation
import IMV2Core
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 仅在自有效用任务上使用的同步文件辅助方法。
///
/// 内存占用被限制在单块 64 KiB，传输流与落盘文件都会被计算摘要。
enum ForwardMediaFileIO {
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
