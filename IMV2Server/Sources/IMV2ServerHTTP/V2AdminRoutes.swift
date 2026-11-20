import Foundation
import HTTPTypes
import IMV2ServerApplication
import IMV2ServerContracts
import Vapor

/// 仅由管理进程挂载。Cookie、Origin 与自定义请求头共同限定浏览器访问边界。
public struct V2AdminRoutes: Sendable {
    private let service: V2AdminService
    private let monitoring: (any V2AdminMonitoring)?
    private let origin: String
    private let secureCookies: Bool
    public init(service: V2AdminService, origin: String, monitoring: (any V2AdminMonitoring)? = nil) throws {
        guard let url = URL(string: origin), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)) else {
            throw V2AdminError.invalidInput
        }
        self.service = service; self.monitoring = monitoring; self.origin = origin; secureCookies = url.scheme == "https"
    }
    public var cookieName: String { secureCookies ? "__Host-imv2_admin" : "imv2_admin_local" }

    public func register(on routes: RoutesBuilder) {
        let api = routes.grouped("admin", "api")
        api.on(.post, "login", maxBodySize: "4kb") { request async throws -> Response in
            try await handle(request, write: true) {
                let input = try await request.content.decode(Login.self)
                let result = try await service.login(username: input.username, password: input.password, replacing: token(request))
                var response = try json(result.identity)
                response.headers[.setCookie] = cookie(result.token, maxAge: Int(service.sessionLifetime))
                return response
            }
        }
        api.get("monitoring") { request async throws -> Response in
            try await handle(request) {
                _ = try await service.identity(token: token(request))
                guard let monitoring else { throw V2AdminError.unavailable }
                return try await json(monitoring.snapshot())
            }
        }
        api.get("session") { request async throws -> Response in
            try await handle(request) { try await json(service.identity(token: token(request))) }
        }
        api.on(.post, "logout", maxBodySize: "1kb") { request async throws -> Response in
            try await handle(request, write: true) {
                try await service.logout(token: token(request))
                var response = Response(status: .noContent)
                response.headers[.setCookie] = cookie("", maxAge: 0)
                return response
            }
        }
        api.get("users") { request async throws -> Response in
            try await handle(request) {
                let query = try request.query.decode(UserQuery.self)
                let after = try uuid(query.after)
                return try await json(service.users(token: token(request), query: query.q ?? "", after: after, limit: query.limit ?? 25))
            }
        }
        api.get("users", ":userID") { request async throws -> Response in
            try await handle(request) {
                guard let id = try uuid(request.parameters.get("userID")) else { throw V2AdminError.invalidInput }
                return try await json(service.user(token: token(request), id: id))
            }
        }
        api.on(.post, "users", ":userID", "disable", maxBodySize: "2kb") { request async throws -> Response in
            try await handle(request, write: true) {
                guard let id = try uuid(request.parameters.get("userID")) else { throw V2AdminError.invalidInput }
                let input = try await request.content.decode(Disable.self)
                return try await json(service.disable(token: token(request), id: input.operationID, userID: id, reason: input.reason))
            }
        }
        api.get("audit") { request async throws -> Response in
            try await handle(request) {
                let query = try request.query.decode(AuditQuery.self)
                let before: Int64?
                if let value = query.before {
                    guard let parsed = Int64(value), parsed > 0 else { throw V2AdminError.invalidInput }; before = parsed
                } else { before = nil }
                return try await json(service.audits(token: token(request), before: before, target: uuid(query.userID), limit: query.limit ?? 25))
            }
        }
        api.get("audit", ":operationID") { request async throws -> Response in
            try await handle(request) {
                guard let id = try uuid(request.parameters.get("operationID")) else { throw V2AdminError.invalidInput }
                return try await json(service.audit(token: token(request), id: id))
            }
        }
    }

    private func handle(_ request: Request, write: Bool = false, operation: () async throws -> Response) async throws -> Response {
        var response: Response
        do {
            guard request.headers[HTTPField.Name("X-IMV2-Admin")!] == "1" else { throw V2AdminError.forbidden }
            if write {
                guard request.headers[.origin] == origin else { throw V2AdminError.forbidden }
            }
            response = try await operation()
        } catch {
            let status: HTTPResponse.Status
            let code: String
            switch error {
            case V2AdminError.unauthorized: status = .unauthorized; code = "unauthorized"
            case V2AdminError.forbidden: status = .forbidden; code = "forbidden"
            case V2AdminError.invalidInput, is DecodingError: status = .badRequest; code = "invalid_input"
            case V2AdminError.notFound: status = .notFound; code = "not_found"
            case V2AdminError.conflict, V2AccountDisableError.operationConflict: status = .conflict; code = "operation_conflict"
            case V2AdminError.rateLimited: status = .tooManyRequests; code = "rate_limited"
            default:
                if let abort = error as? any AbortError, abort.status.code < 500 { status = abort.status; code = "invalid_input" }
                else { status = .serviceUnavailable; code = "unavailable" }
            }
            response = try json(ErrorBody(code: code), status: status)
            if status == .tooManyRequests || status == .serviceUnavailable { response.headers[.retryAfter] = "60" }
        }
        response.headers[.cacheControl] = "no-store"
        response.headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        return response
    }
    private func token(_ request: Request) -> String? { request.cookies[cookieName]?.string }
    private func cookie(_ token: String, maxAge: Int) -> String {
        "\(cookieName)=\(token); Path=/; Max-Age=\(maxAge); HttpOnly; SameSite=Strict" + (secureCookies ? "; Secure" : "")
    }
    private func uuid(_ value: String?) throws -> UUID? {
        guard let value else { return nil }; guard let id = UUID(uuidString: value) else { throw V2AdminError.invalidInput }; return id
    }
    private func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return Response(status: status, headers: [.contentType: "application/json; charset=utf-8"], body: .init(data: try encoder.encode(value)))
    }
}
private struct Login: Content { let username: String; let password: String }
private struct Disable: Content { let operationID: UUID; let reason: V2AccountDisableReason }
private struct UserQuery: Decodable { let q: String?; let after: String?; let limit: Int? }
private struct AuditQuery: Decodable { let before: String?; let userID: String?; let limit: Int? }
private struct ErrorBody: Encodable { let code: String }
