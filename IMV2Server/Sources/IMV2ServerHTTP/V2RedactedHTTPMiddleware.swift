import Foundation
import Logging
import Vapor
import HTTPTypes

/// HTTP 中间件安装入口。
///
/// 每个 V2 进程共享的基线 HTTP 中间件都在此安装。应在创建 `Application` 后立即调用，
/// 且要先于认证或限流中间件。这里刻意替换 Vapor 的默认中间件：
/// Vapor 默认的错误日志会记录完整 URL，其中包含已签名能力查询参数。
///
/// 按顺序安装 `V2RedactedRouteLoggingMiddleware` 与
/// `V2RedactedErrorMiddleware`，减少敏感字段日志与错误信息泄露。
public enum V2RedactedHTTPMiddlewareConfiguration {
    public static func install(on application: Application) {
        var middleware = Middlewares()
        middleware.use(V2RedactedRouteLoggingMiddleware())
        middleware.use(V2RedactedErrorMiddleware())
        application.middleware = middleware
    }
}

/// 路由级日志中间件，记录路由模板而非原始路径。
///
/// 只记录匹配到的路由模板，绝不记录调用方控制的路径或查询串。
/// 模板可让日志基数保持有界，并避免持久化标识符。
private struct V2RedactedRouteLoggingMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        // 成功请求的逐条日志用于诊断，并非运维事件。
        // 将其保持在生产环境 info 级别以下，可避免高 QPS 时的
        // 同步格式化与日志流水线压力。
        Logger.current.debug("HTTP request", metadata: request.v2RedactedHTTPMetadata)
        return try await next.respond(to: request)
    }
}

/// 错误响应中间件。
///
/// 产出稳定的、与 Vapor 兼容的 JSON 错误封装，同时刻意不在日志中保留原始错误描述。
/// 底层错误可能包含 SQL、提供方 URL、令牌或文件系统路径。
/// 使用稳定的错误 reason 并统一返回 JSON envelope，避免泄露底层异常细节。
private struct V2RedactedErrorMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            let status: HTTPResponse.Status
            let reason: String
            var headers: HTTPFields
            if let abort = error as? any AbortError {
                status = abort.status
                // 解码器与依赖错误可能符合 AbortError，
                // 并在 `reason` 中携带字段名或实现细节。
                // 公开契约只基于状态码，且有意保持稳定。
                reason = abort.status.reasonPhrase
                headers = abort.headers
            } else {
                status = .internalServerError
                reason = "Something went wrong."
                headers = [:]
            }

            var metadata = request.v2RedactedHTTPMetadata
            metadata["status"] = "\(status.code)"
            let level = (error as? any DebuggableError)?.logLevel
                ?? (status.code >= 500 ? .error : .warning)
            Logger.current.log(level: level, "HTTP request failed", metadata: metadata)

            headers[.cacheControl] = "no-store"
            headers[.v2Pragma] = "no-cache"
            headers.contentType = .json
            let envelope = V2HTTPErrorEnvelope(error: true, reason: reason)
            let body = try JSONEncoder().encode(envelope)
            return Response(status: status, headers: headers, body: .init(data: body))
        }
    }
}

/// 错误响应包体。
private struct V2HTTPErrorEnvelope: Encodable {
    let error: Bool
    let reason: String
}

private extension Request {
    var v2RedactedHTTPMetadata: Logger.Metadata {
        [
            "method": "\(method.rawValue)",
            "route": "\(route?.description ?? "<unmatched>")",
        ]
    }
}
