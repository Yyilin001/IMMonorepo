import CZlib
import Foundation

/// 压缩配置、底层 zlib 或资源预算检查失败。
public enum V2FrameCompressionError: Error, Equatable, Sendable {
    /// 预算非正或压缩级别不受支持。
    case invalidConfiguration
    /// 输入或所需输出缓冲上界超出允许范围。
    case inputTooLarge
    /// 压缩失败；关联值为 zlib 状态码。
    case compressionFailed(Int32)
    /// 输入不是可解码的 zlib 数据；关联值为底层状态码。
    case invalidCompressedPayload(Int32)
    /// 解码输出超过调用者提供的容量上限。
    case outputLimitExceeded
    /// 解码膨胀比超限，或其上界计算不可安全表示。
    case expansionRatioExceeded
}

/// 已协商的帧压缩算法；protobuf 枚举转换由客户端与服务端边缘负责。
public enum V2NegotiatedFrameCompression: Equatable, Sendable {
    /// 每帧独立的 zlib 编码。
    case zlib
}

/// 每个 Gateway 帧独立压缩的无状态 zlib 工具。
///
/// 不跨帧或连接共享字典。丢帧后的恢复由请求／游标协议承担，
/// 不可变压缩页可以复用于多个已经授权的接收者。
/// 调用者仍需在协议边缘完成算法协商、帧长度与授权检查。
public enum V2ZlibFrameCompression {
    /// 默认使用 zlib 级别 1，优先降低压缩 CPU 开销。
    public static let defaultCompressionLevel: Int32 = 1
    /// 默认最多允许解码后字节数为压缩输入的 64 倍。
    public static let defaultMaximumExpansionRatio = 64

    /// 把一帧内容压缩为独立 zlib 数据。
    ///
    /// - Parameters:
    ///   - input: 完整的未压缩帧内容。
    ///   - maximumInputBytes: 允许的输入字节上限，必须为正。
    ///   - level: zlib 压缩级别，允许 0 到 9。
    /// - Returns: 不依赖其他帧解码状态的压缩数据。
    /// - Throws: ``V2FrameCompressionError``，表示配置错误、输入超限或底层压缩失败。
    public static func compress(
        _ input: Data,
        maximumInputBytes: Int,
        level: Int32 = defaultCompressionLevel
    ) throws -> Data {
        guard maximumInputBytes > 0,
              level >= Int32(Z_NO_COMPRESSION),
              level <= Int32(Z_BEST_COMPRESSION)
        else { throw V2FrameCompressionError.invalidConfiguration }
        guard input.count <= maximumInputBytes else {
            throw V2FrameCompressionError.inputTooLarge
        }

        let sourceCount = uLong(input.count)
        let bound = compressBound(sourceCount)
        guard bound <= uLong(Int.max) else {
            throw V2FrameCompressionError.inputTooLarge
        }
        var output = Data(count: max(1, Int(bound)))
        var outputCount = bound
        let status: Int32 = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                compress2(
                    destination.bindMemory(to: Bytef.self).baseAddress,
                    &outputCount,
                    source.bindMemory(to: Bytef.self).baseAddress,
                    sourceCount,
                    level
                )
            }
        }
        guard status == Z_OK else {
            throw V2FrameCompressionError.compressionFailed(status)
        }
        output.count = Int(outputCount)
        return output
    }

    /// 在固定输出容量与膨胀比限制下解压一帧。
    ///
    /// 输出缓冲按 `maximumOutputBytes` 分配，调用者应选用协议预算，
    /// 不能使用未经验证的远端数值作为内存容量。
    ///
    /// - Parameters:
    ///   - input: 非空 zlib 数据。
    ///   - maximumOutputBytes: 解压后最大字节数，必须为正。
    ///   - maximumExpansionRatio: 输出相对输入的最大倍数，必须为正。
    /// - Returns: 通过容量和膨胀比检查的原始帧内容。
    /// - Throws: ``V2FrameCompressionError``，表示非法数据、配置错误或资源预算超限。
    public static func decompress(
        _ input: Data,
        maximumOutputBytes: Int,
        maximumExpansionRatio: Int = defaultMaximumExpansionRatio
    ) throws -> Data {
        guard maximumOutputBytes > 0, maximumExpansionRatio > 0 else {
            throw V2FrameCompressionError.invalidConfiguration
        }
        guard !input.isEmpty else {
            throw V2FrameCompressionError.invalidCompressedPayload(Int32(Z_DATA_ERROR))
        }

        var output = Data(count: maximumOutputBytes)
        var outputCount = uLong(maximumOutputBytes)
        let status: Int32 = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                uncompress(
                    destination.bindMemory(to: Bytef.self).baseAddress,
                    &outputCount,
                    source.bindMemory(to: Bytef.self).baseAddress,
                    uLong(input.count)
                )
            }
        }
        if status == Z_BUF_ERROR {
            throw V2FrameCompressionError.outputLimitExceeded
        }
        guard status == Z_OK else {
            throw V2FrameCompressionError.invalidCompressedPayload(status)
        }
        guard outputCount <= uLong(Int.max) else {
            throw V2FrameCompressionError.outputLimitExceeded
        }
        let decodedCount = Int(outputCount)
        guard input.count <= Int.max / maximumExpansionRatio,
              decodedCount <= input.count * maximumExpansionRatio
        else { throw V2FrameCompressionError.expansionRatioExceeded }
        output.count = decodedCount
        return output
    }
}
