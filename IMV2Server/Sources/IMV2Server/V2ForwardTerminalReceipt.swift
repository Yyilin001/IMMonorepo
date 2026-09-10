import Foundation
import IMV2Core

/// 转发终态回执，只能由读取持久化的目标终态收件箱产生。
///
/// 该能力通过受信归属通道传递；客户端上报的状态或校验和都不构成终态回执，
/// 也不能用于替代收件箱中的持久化记录。
public struct V2ForwardTerminalReceipt: Equatable, Sendable {
    /// 产生该回执的转发导出记录。
    public let export: V2ForwardExport
    /// 目标侧持久化的导入结果，仅允许终态取值。
    public let outcome: V2ForwardImportOutcome

    /// 校验导入结果为可用终态后构造回执。
    ///
    /// - Parameters:
    ///   - export: 对应的转发导出记录。
    ///   - outcome: 目标侧导入结果；`accepted` 要求消息标识可解码、序号为正且可写入 `Int64`，
    ///     `rejected` 要求错误码非空且不超过 128 字节。
    /// - Throws: 结果仍为 `pending`，或字段不满足上述约束时抛出
    ///   ``V2ForwardInboxError/corruptPersistenceState``。
    init(export: V2ForwardExport, outcome: V2ForwardImportOutcome) throws {
        switch outcome {
        case .accepted(let messageID, let sequence):
            guard messageID.uuidValue != nil, sequence > 0, sequence <= UInt64(Int64.max)
            else { throw V2ForwardInboxError.corruptPersistenceState }
        case .rejected(let code):
            guard !code.isEmpty, code.utf8.count <= 128
            else { throw V2ForwardInboxError.corruptPersistenceState }
        case .pending: throw V2ForwardInboxError.corruptPersistenceState
        }
        self.export = export
        self.outcome = outcome
    }
}
