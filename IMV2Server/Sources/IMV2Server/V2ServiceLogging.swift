import Foundation
import IMV2Core
import Logging

/// 服务端进程共用的日志配置。仅调整 `imv2.` 首方 logger，避免开启依赖库的调试输出。
public enum V2ServiceLogging {
    public enum ConfigurationError: Error, Equatable, Sendable {
        case invalidLevel
    }

    public static func applicationLevel(environment: [String: String]) throws -> Logger.Level {
        guard let value = environment["IM_V2_LOG_LEVEL"] else { return .info }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let level = Logger.Level(rawValue: normalized) else {
            throw ConfigurationError.invalidLevel
        }
        return level
    }

    public static func bootstrap(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let applicationLevel = try applicationLevel(environment: environment)
        LoggingSystem.bootstrap { label in
            handler(label: label, applicationLevel: applicationLevel)
        }
    }

    static func handler(label: String, applicationLevel: Logger.Level) -> StreamLogHandler {
        var handler = StreamLogHandler.standardError(label: label)
        if label.hasPrefix("imv2.") { handler.logLevel = applicationLevel }
        return handler
    }

    public static func logWorkerFailure(_ logger: Logger, worker: String, error: any Error) {
        logger.error("IM V2 background worker failed; retrying", metadata:
            V2SafeLogMetadata.workerFailure(error, worker: worker))
    }
}

/// 只保存可公开的阶段和错误分类，供进程入口在完成清理后记录故障。
public struct V2StagedOperationalError: Error, Sendable {
    public let stage: String
    public let errorCode: String
    public let errorType: String

    public init(stage: String, error: any Error) {
        if let staged = error as? Self {
            self = staged
        } else {
            self.stage = stage
            errorCode = v2SafeErrorCode(error)
            errorType = String(reflecting: type(of: error))
        }
    }
}

/// 日志只接收编译期错误类型和调用点的固定分类，不接收 `Error` 的描述文本。
public enum V2SafeLogMetadata {
    public static func drainTimeout(stage: String) -> Logger.Metadata {
        ["stage": "\(stage)", "error_code": "drain_timeout", "error_type": "deadline"]
    }

    public static func workerFailure(_ error: any Error, worker: String) -> Logger.Metadata {
        failure(error, stage: "background_worker", worker: worker)
    }

    public static func failure(
        _ error: any Error,
        stage: String,
        worker: String? = nil
    ) -> Logger.Metadata {
        let staged = error as? V2StagedOperationalError
        var metadata: Logger.Metadata = [
            "stage": "\(staged?.stage ?? stage)",
            "error_code": "\(staged?.errorCode ?? v2SafeErrorCode(error))",
            "error_type": "\(staged?.errorType ?? String(reflecting: type(of: error)))",
        ]
        if let worker { metadata["worker"] = "\(worker)" }
        return metadata
    }
}

private func v2SafeErrorCode(_ error: any Error) -> String {
    switch error {
    case is CancellationError:
        "cancelled"
    case V2GatewayRuntimeConfigurationError.missing:
        "missing_configuration"
    case V2GatewayRuntimeConfigurationError.invalid:
        "invalid_configuration"
    case is DecodingError:
        "decoding_failed"
    case is V2FrameCodecError:
        "invalid_frame"
    default:
        "operation_failed"
    }
}
