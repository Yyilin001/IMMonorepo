import IMV2ServerContracts
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
        let input = try V2PinnedLocalMediaFile(file: url)
        guard input.byteCount == byteCount else { throw V2ForwardMediaCopyError.byteCountMismatch }
        return try input.digest()
    }

    /// 同步目录项，确保文件创建在掉电后仍然可见。
    ///
    /// - Parameter directory: 目标目录。
    /// - Throws: 打开目录或同步失败时抛出对应的 POSIX 错误。
    static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}
