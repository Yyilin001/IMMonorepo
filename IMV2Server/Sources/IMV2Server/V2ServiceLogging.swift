import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import Logging

/// 服务端进程共用的日志配置。仅调整标签以 `imv2.` 开头的本项目日志，避免开启依赖库的调试输出。
public enum V2ServiceLogging {
    /// 日志配置无法从环境变量解析时抛出的错误。
    public enum ConfigurationError: Error, Equatable, Sendable {
        /// `IM_V2_LOG_LEVEL` 不是 swift-log 支持的日志级别。
        case invalidLevel
    }

    /// 从环境变量解析本项目服务端日志的级别。
    ///
    /// 未设置 `IM_V2_LOG_LEVEL` 时返回 `.info`；设置后先去掉首尾空白并转为小写。
    /// 无效值会抛错，避免服务在操作者误以为已启用某个级别时继续启动。
    ///
    /// - Parameter environment: 待读取的环境变量，通常为当前进程的环境。
    /// - Returns: 本项目服务端 logger 使用的日志级别。
    /// - Throws: `ConfigurationError.invalidLevel`，当变量值不是有效日志级别时。
    public static func applicationLevel(environment: [String: String]) throws -> Logger.Level {
        guard let value = environment["IM_V2_LOG_LEVEL"] else { return .info }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let level = Logger.Level(rawValue: normalized) else {
            throw ConfigurationError.invalidLevel
        }
        return level
    }

    /// 在进程入口初始化全局 swift-log 后端，供随后创建的 `Logger` 使用。
    ///
    /// 日志写入标准错误输出；只有标签以 `imv2.` 开头的 logger 使用
    /// `IM_V2_LOG_LEVEL`，依赖库的 logger 保持 `StreamLogHandler` 的默认级别。
    /// 必须在创建业务 logger 前调用，且每个进程只能调用一次。
    ///
    /// - Parameter environment: 用于读取 `IM_V2_LOG_LEVEL` 的环境变量；默认取当前进程环境。
    /// - Throws: `ConfigurationError.invalidLevel`，当日志级别配置无效时；此时尚未初始化后端。
    public static func bootstrap(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let applicationLevel = try applicationLevel(environment: environment)
        LoggingSystem.bootstrap { label in
            handler(label: label, applicationLevel: applicationLevel)
        }
    }

    /// 为日志标签创建写入标准错误输出的 handler，并只调整本项目服务端日志的级别。
    ///
    /// - Parameters:
    ///   - label: logger 标签；以 `imv2.` 开头时视为本项目服务端日志。
    ///   - applicationLevel: 本项目服务端日志使用的级别。
    /// - Returns: 按标签设置级别的 `StreamLogHandler`。
    static func handler(label: String, applicationLevel: Logger.Level) -> StreamLogHandler {
        var handler = StreamLogHandler.standardError(label: label)
        if label.hasPrefix("imv2.") { handler.logLevel = applicationLevel }
        return handler
    }

    /// 记录后台 worker 失败及其可安全输出的分类信息。
    ///
    /// 错误描述可能包含凭据或用户数据，因此只记录固定消息，以及
    /// `V2SafeLogMetadata` 生成的阶段、错误分类和 worker 标识。
    /// 此函数只写日志；重试或终止由调用方负责。
    ///
    /// - Parameters:
    ///   - logger: 负责输出该条错误日志的 logger。
    ///   - worker: 后台 worker 的固定标识，用于定位故障来源。
    ///   - error: 待归类的错误；不会把错误描述写入日志。
    public static func logWorkerFailure(_ logger: Logger, worker: String, error: any Error) {
        logger.error("IM V2 background worker failed; retrying", metadata:
            V2SafeLogMetadata.workerFailure(error, worker: worker))
    }
}
