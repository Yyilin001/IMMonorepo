import Foundation
import IMV2ActorContracts

/// 持久化目标投递与前台协调器调用同一个 RoomRef 导入能力。
/// 媒体字节复制保有独立工作租约。
public struct V2ActorForwardImportEndpoint: V2ForwardExportDelivering {
    private let inbox: PostgresV2ForwardInboxStore
    private let media: V2ForwardMediaImportWorker?
    private let roomCommand: @Sendable (V2RoomForwardCommand, ContinuousClock.Instant) async throws -> V2RoomForwardResult
    private let deadline: @Sendable () -> ContinuousClock.Instant

    public init(inbox: PostgresV2ForwardInboxStore,
                media: V2ForwardMediaImportWorker? = nil,
                roomCommand: @escaping @Sendable (V2RoomForwardCommand, ContinuousClock.Instant) async throws -> V2RoomForwardResult,
                deadline: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.inbox = inbox; self.media = media
        self.roomCommand = roomCommand; self.deadline = deadline
    }

    public func deliver(_ export: V2ForwardExport) async throws -> V2ForwardTerminalReceipt? {
        try Task.checkCancellation()
        var outcome = try await importOnce(export)
        if outcome == .pending(.media) {
            guard let media else { throw V2ForwardDeliveryError.targetUnavailable }
            // 媒体复制是独立的租约工作流：其收件箱与媒体记录携带精确的
            // 导出、所有者纪元、认领、对象和上传身份。
            // 复制就绪不授予消息接受权限。复制后必须通过新的 RoomRef 导入轮次返回，
            // 以重新检查目标成员关系和激活。
            switch try await media.runOnce(exportID: export.intent.exportID) {
            case .ready, .rejected: outcome = try await importOnce(export)
            case .paused: throw V2ForwardDeliveryError.mediaPaused
            case .idle, .retryScheduled, .superseded: return nil
            }
        }
        if case .pending = outcome { return nil }
        guard let receipt = try await inbox.terminalReceipt(exportID: export.intent.exportID),
              receipt.matches(export) else { throw V2ForwardDeliveryError.receiptMismatch }
        return receipt
    }

    private func importOnce(_ export: V2ForwardExport) async throws -> V2ForwardImportOutcome {
        guard case .imported(let result) = try await roomCommand(
            .importExport(.init(domain: export)), deadline()) else {
            throw V2ForwardDeliveryError.receiptMismatch
        }
        return try result.toDomain()
    }
}
