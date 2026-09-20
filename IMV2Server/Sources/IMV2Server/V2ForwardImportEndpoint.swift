import Foundation
import IMV2Core

/// 转发导入端点，直接复用目标房间归属已配置的写存储。
///
/// 复用写存储意味着准入、投影影子转发与提交后恢复适配器全部沿用目标归属的既有语义，
/// 而不是另起一条绕过准入的写入路径。
public struct V2ForwardImportEndpoint: V2ForwardExportDelivering {
    private let inbox: PostgresV2ForwardInboxStore
    private let write: PostgresV2RoomWriteStore
    private let media: V2ForwardMediaImportWorker?
    private let profile: V2CapacityProfile
    private let limits: V2MessageCommandLimits
    private let now: @Sendable () -> Date

    /// 组合目标归属的收件箱、写存储与可选媒体导入工作器。
    ///
    /// - Parameters:
    ///   - inbox: 目标归属的持久化收件箱。
    ///   - write: 目标归属的房间写存储。
    ///   - media: 媒体导入工作器；为 `nil` 时媒体类转发无法完成。
    ///   - capacityProfile: 目标归属的容量档位。
    ///   - limits: 消息命令限制。
    ///   - now: 可注入的当前时刻读取函数。
    public init(inbox: PostgresV2ForwardInboxStore, write: PostgresV2RoomWriteStore,
                media: V2ForwardMediaImportWorker? = nil, capacityProfile: V2CapacityProfile,
                limits: V2MessageCommandLimits, now: @escaping @Sendable () -> Date = Date.init) {
        self.inbox = inbox; self.write = write; self.media = media
        profile = capacityProfile; self.limits = limits; self.now = now
    }

    /// 投递一次转发导出，必要时先完成媒体导入再重试接受。
    ///
    /// 接受结果仍为待处理时返回 `nil`；只有收件箱中存在与本次导出完全一致的终态回执时
    /// 才返回回执，回执不匹配视为投递失败。
    ///
    /// - Parameter export: 本次投递的转发导出。
    /// - Returns: 终态回执；导出尚未进入终态时返回 `nil`。
    /// - Throws: 任务已取消时抛出 `CancellationError`；未配置媒体工作器时抛出
    ///   ``V2ForwardDeliveryError/targetUnavailable``；媒体导入被暂停时抛出
    ///   ``V2ForwardDeliveryError/mediaPaused``；回执与导出不一致时抛出
    ///   ``V2ForwardDeliveryError/receiptMismatch``。
    public func deliver(_ export: V2ForwardExport) async throws -> V2ForwardTerminalReceipt? {
        try Task.checkCancellation()
        var outcome = try await accept(export)
        if outcome == .pending(.media) {
            guard let media else { throw V2ForwardDeliveryError.targetUnavailable }
            switch try await media.runOnce(exportID: export.intent.exportID) {
            case .ready, .rejected: outcome = try await accept(export)
            case .paused: throw V2ForwardDeliveryError.mediaPaused
            case .idle, .retryScheduled, .superseded: return nil
            }
        }
        if case .pending = outcome { return nil }
        guard let receipt = try await inbox.terminalReceipt(exportID: export.intent.exportID), receipt.matches(export)
        else { throw V2ForwardDeliveryError.receiptMismatch }
        return receipt
    }

    /// 以同一授时与标识工厂执行一次转发接受。
    ///
    /// - Parameter export: 本次接受的转发导出。
    /// - Returns: 目标归属给出的导入结果。
    /// - Throws: 任务已取消或写存储拒绝时抛出。
    private func accept(_ export: V2ForwardExport) async throws -> V2ForwardImportOutcome {
        try Task.checkCancellation()
        let time = now()
        return try await write.importForwardExport(export, capacityProfile: profile, limits: limits,
                                                   identifiers: V2AcceptanceIDFactory().make(at: time), now: time)
    }
}

/// 按物理归属分发的投递注册表。
///
/// 只按导出记录的物理目标分片选择投递实现，不提供回退扫描，也不允许替换归属。
public struct V2ConfiguredForwardExportDelivery: V2ForwardExportDelivering {
    private let targets: [String: any V2ForwardExportDelivering]
    /// 组合各物理分片的投递实现。
    ///
    /// - Parameter targets: 物理分片标识到投递实现的映射。
    /// - Throws: 映射为空或含纯空白分片标识时抛出
    ///   ``V2ForwardDeliveryError/invalidConfiguration``。
    public init(targets: [String: any V2ForwardExportDelivering]) throws {
        guard !targets.isEmpty, targets.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw V2ForwardDeliveryError.invalidConfiguration }
        self.targets = targets
    }
    /// 按导出的目标分片投递。
    ///
    /// - Parameter export: 本次投递的转发导出。
    /// - Returns: 终态回执；尚未进入终态时返回 `nil`。
    /// - Throws: 目标分片未配置投递实现时抛出
    ///   ``V2ForwardDeliveryError/targetUnavailable``；其余错误来自投递实现。
    public func deliver(_ export: V2ForwardExport) async throws -> V2ForwardTerminalReceipt? {
        guard let target = targets[export.intent.targetShardID] else { throw V2ForwardDeliveryError.targetUnavailable }
        return try await target.deliver(export)
    }
}
