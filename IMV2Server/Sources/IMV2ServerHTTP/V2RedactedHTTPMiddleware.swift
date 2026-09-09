import Foundation
import Vapor

/// Installs the baseline HTTP middleware shared by every V2 process. Call this
/// immediately after creating `Application`, before appending authentication or
/// rate-limit middleware. Replacing Vapor's defaults is intentional: its
/// default error logger records the complete URL, including signed capability
/// query values.
/// HTTP 中间件安装入口。
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

/// Logs the matched route template, never the caller-controlled path or query.
/// Templates keep log cardinality bounded and avoid persisting identifiers.
/// 路由级日志中间件，记录路由模板而非原始路径。
private struct V2RedactedRouteLoggingMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: any Responder) -> EventLoopFuture<Response> {
        // Successful request-per-line logging is diagnostic, not an
        // operational event. Keeping it below the production info threshold
        // avoids synchronous formatting and log-pipeline pressure at high QPS.
        request.logger.debug("HTTP request", metadata: request.v2RedactedHTTPMetadata)
        return next.respond(to: request)
    }
}

/// Produces the stable Vapor-compatible JSON error envelope while deliberately
/// omitting the original error description from logs. Low-level errors can
/// contain SQL, provider URLs, tokens, or filesystem paths.
/// 错误响应中间件。
///
/// 使用稳定的错误 reason 并统一返回 JSON envelope，避免泄露底层异常细节。
private struct V2RedactedErrorMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: any Responder) -> EventLoopFuture<Response> {
        next.respond(to: request).flatMapErrorThrowing { error in
            let status: HTTPResponseStatus
            let reason: String
            var headers: HTTPHeaders
            if let abort = error as? any AbortError {
                status = abort.status
                // Decoder and dependency errors may conform to AbortError and
                // carry field names or implementation details in `reason`.
                // The public contract is status based and deliberately stable.
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
            request.logger.log(level: level, "HTTP request failed", metadata: metadata)

            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            headers.replaceOrAdd(name: "Pragma", value: "no-cache")
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
