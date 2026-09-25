import Foundation
import IMV2Server
import Logging

/// 命令遥测的生产日志适配器。
///
/// 这些是结构化运维事件，而不是高基数指标标签：
/// 其中不会包含房间、用户或消息标识，也不包含载荷、地址、令牌或凭据。
struct GatewayApplicationTelemetrySink: V2TelemetrySink {
    let logger: Logger
    let successSamplePermille: Int
    let slowCommandThresholdMilliseconds: Int
    let diagnosticLogLimiter: V2CommandDiagnosticLogLimiter

    func record(_ event: V2TelemetryEvent) async {
        switch event {
        case .gatewayCommand(let traceID, let command, let outcome, let rejection, let elapsedMilliseconds):
            guard shouldLogGatewayCommand(
                traceID: traceID,
                command: command,
                outcome: outcome,
                rejection: rejection,
                elapsedMilliseconds: elapsedMilliseconds
            ) else { return }
            logger.info("im_v2.gateway.command", metadata: [
                "trace_id": "\(traceID.uuidString)",
                "command": "\(command.rawValue)",
                "outcome": "\(outcome.rawValue)",
                "rejection": "\(rejection?.rawValue ?? "none")",
                "elapsed_ms": "\(elapsedMilliseconds)",
            ])
        }
    }

    private func shouldLogGatewayCommand(
        traceID: UUID,
        command: V2GatewayTelemetryCommand,
        outcome: V2GatewayTelemetryOutcome,
        rejection: V2GatewayTelemetryRejection?,
        elapsedMilliseconds: UInt64
    ) -> Bool {
        guard outcome == .accepted,
              elapsedMilliseconds < UInt64(slowCommandThresholdMilliseconds)
        else {
            return diagnosticLogLimiter.admit(
                command: command,
                outcome: outcome,
                rejection: rejection
            )
        }
        guard successSamplePermille > 0 else { return false }
        guard successSamplePermille < 1_000 else { return true }
        // 对 UUID 的 16 个原始字节计算 FNV，避免每次接受命令时
        // 都分配其 36 字符的字符串表示。
        var hash: UInt64 = 14_695_981_039_346_656_037
        withUnsafeBytes(of: traceID.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        return hash % 1_000 < UInt64(successSamplePermille)
    }
}
