import IMV2ServerContracts
import Foundation
import IMV2Core

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
