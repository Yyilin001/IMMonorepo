import Crypto
import Foundation

/// 为延迟创建的转发计划分块生成确定性 UUID 操作身份，同一父计划与分块序号得到同一值，不作为排序键。
public enum V2ForwardChunkIdentity {
    /// 根据用途前缀、父计划 UUID 字节和大端分块序号计算 SHA256，取前 16 字节并设置 UUID 版本与变体位。
    ///
    /// - Parameters:
    ///   - planID: 原始值可解析为 UUID 的父转发计划身份。
    ///   - chunkIndex: 从零开始的分块序号，最大为 Int64.max。
    /// - Returns: 确定性的分块操作身份，重试必须复用同一父计划和序号。
    /// - Throws: 父身份不是 UUID 时抛出 invalidIdentifier，分块序号越界时抛出 invalidNonNegativeValue。
    ///
    /// 生成的是应用定义版本 8 UUID；不读取时钟、随机数或持久化状态。
    public static func operationID(planID: MessageForwardOperationID, chunkIndex: UInt64) throws -> MessageForwardOperationID {
        guard let plan = planID.uuidValue else { throw V2CoreError.invalidIdentifier }
        guard chunkIndex <= UInt64(Int64.max) else { throw V2CoreError.invalidNonNegativeValue }
        var input = Data("im-v2-forward-chunk-uuid-v1".utf8)
        var tuple = plan.uuid
        withUnsafeBytes(of: &tuple) { input.append(contentsOf: $0) }
        withUnsafeBytes(of: chunkIndex.bigEndian) { input.append(contentsOf: $0) }
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        // Application-defined UUID (version 8), standard UUID variant. All
        // remaining bits are a domain-separated digest of parent and index.
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return .init(uuid: UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )))
    }
}
