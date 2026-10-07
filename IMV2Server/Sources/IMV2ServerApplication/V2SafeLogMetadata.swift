import IMV2ServerContracts
import Foundation
import IMV2Core
import Logging

/// Closed vocabulary for lower layers to expose operational failure codes
/// without Application importing those layers or accepting error descriptions.
public enum V2SafeOperationalErrorCode: String, Sendable {
    case databaseLoanInvalidPolicy = "database_loan_invalid_policy"
    case databaseLoanQueueFull = "database_loan_queue_full"
    case databaseLoanTimedOut = "database_loan_timed_out"
    case databaseLoanCancelled = "database_loan_cancelled"
    case databaseLoanClosed = "database_loan_closed"
}
public protocol V2SafeOperationalErrorCodeProviding: Error {
    var safeOperationalErrorCode: V2SafeOperationalErrorCode { get }
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
    case let classified as any V2SafeOperationalErrorCodeProviding:
        classified.safeOperationalErrorCode.rawValue
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
