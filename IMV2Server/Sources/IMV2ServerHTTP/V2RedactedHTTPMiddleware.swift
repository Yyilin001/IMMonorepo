import Foundation
import Vapor

/// Installs the baseline HTTP middleware shared by every V2 process. Call this
/// immediately after creating `Application`, before appending authentication or
/// rate-limit middleware. Replacing Vapor's defaults is intentional: its
/// default error logger records the complete URL, including signed capability
/// query values.
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
private struct V2RedactedRouteLoggingMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: any Responder) -> EventLoopFuture<Response> {
        request.logger.info("HTTP request", metadata: request.v2RedactedHTTPMetadata)
        return next.respond(to: request)
    }
}

/// Produces the stable Vapor-compatible JSON error envelope while deliberately
/// omitting the original error description from logs. Low-level errors can
/// contain SQL, provider URLs, tokens, or filesystem paths.
private struct V2RedactedErrorMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: any Responder) -> EventLoopFuture<Response> {
        next.respond(to: request).flatMapErrorThrowing { error in
            let status: HTTPResponseStatus
            let reason: String
            var headers: HTTPHeaders
            if let abort = error as? any AbortError {
                status = abort.status
                reason = abort.reason
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
