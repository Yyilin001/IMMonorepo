import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import Vapor
import HTTPTypes

/// 账户封禁请求体。
public struct V2AccountDisableHTTPRequest: Content, Sendable {
    public let operationID: UUID
    public let userID: String
    public let reason: V2AccountDisableReason

    public init(operationID: UUID, userID: String, reason: V2AccountDisableReason) {
        self.operationID = operationID
        self.userID = userID
        self.reason = reason
    }

    func command() throws -> V2AccountDisableCommand {
        try .init(userID: .init(userID), operationID: operationID, reason: reason)
    }
}

/// 账户封禁响应体。
public struct V2AccountDisableHTTPResponse: Content, Equatable, Sendable {
    public let operationID: UUID
    public let outcome: String
    public let disabledAtMilliseconds: Int64
}

/// 账户禁用操作员路由。
///
/// 仅环回调用，且经过专用 operator bearer 验证。
/// 单次请求仅处理一个用户，避免暴露通用账号管理能力。
public struct V2VaporAccountDisableOperatorRoutes: Sendable {
    private let authenticator: V2OperatorReplayBearerAuthenticator
    private let service: any V2AccountDisabling

    /// 初始化。
    ///
    /// - Parameters:
    ///   - authenticator: 操作员鉴权器。
    ///   - service: 封禁服务。
    public init(authenticator: V2OperatorReplayBearerAuthenticator, service: any V2AccountDisabling) {
        self.authenticator = authenticator
        self.service = service
    }

    /// 挂载 `POST /internal/v2/accounts/disable`。
    public func register(on routes: RoutesBuilder) {
        routes.post("internal", "v2", "accounts", "disable") { request async throws -> Response in
            guard authenticator.isAuthorized(bearerToken: request.headers.bearerAuthorization?.token) else {
                throw Abort(.unauthorized)
            }
            let command: V2AccountDisableCommand
            do { command = try await request.content.decode(V2AccountDisableHTTPRequest.self).command() }
            catch { throw Abort(.badRequest) }
            let result: V2AccountDisableOutcome
            do { result = try await service.disable(command) }
            catch V2AccountDisableError.operationConflict { throw Abort(.conflict) }
            catch V2AccountDisableError.invalidUserID { throw Abort(.badRequest) }
            catch V2AccountDisableError.unavailable { return unavailableResponse() }
            catch { return unavailableResponse() }
            guard let disabledAtMilliseconds = milliseconds(disabledAt: result) else {
                return unavailableResponse()
            }
            return try noStoreJSON(.init(
                operationID: command.operationID,
                outcome: outcomeName(result),
                disabledAtMilliseconds: disabledAtMilliseconds
            ))
        }
    }

    /// 输出可序列化的结果名。
    private func outcomeName(_ result: V2AccountDisableOutcome) -> String {
        switch result {
        case .disabled: "disabled"
        case .idempotent: "idempotent"
        case .alreadyDisabled: "already_disabled"
        }
    }

    /// 将禁用时间转为毫秒时间戳。
    private func milliseconds(disabledAt result: V2AccountDisableOutcome) -> Int64? {
        let date: Date
        switch result {
        case .disabled(let value), .idempotent(let value), .alreadyDisabled(let value): date = value
        }
        return Int64(exactly: (date.timeIntervalSince1970 * 1_000).rounded(.down))
    }

    /// 服务不可用响应（no-store）。
    private func unavailableResponse() -> Response {
        .init(status: .serviceUnavailable, headers: [.cacheControl: "no-store", .v2Pragma: "no-cache"])
    }

    /// 返回禁用结果 JSON（no-store）。
    private func noStoreJSON(_ response: V2AccountDisableHTTPResponse) throws -> Response {
        let data = try JSONEncoder().encode(response)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.cacheControl] = "no-store"
        headers[.v2Pragma] = "no-cache"
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }
}
