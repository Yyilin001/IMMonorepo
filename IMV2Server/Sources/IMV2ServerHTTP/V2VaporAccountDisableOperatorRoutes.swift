import Foundation
import IMV2Core
import IMV2Server
import Vapor

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

public struct V2AccountDisableHTTPResponse: Content, Equatable, Sendable {
    public let operationID: UUID
    public let outcome: String
    public let disabledAtMilliseconds: Int64
}

/// `POST /internal/v2/accounts/disable` is loopback-only and guarded with an
/// account-disable-specific operator credential. It processes exactly one
/// account and creates no general account-administration surface.
public struct V2VaporAccountDisableOperatorRoutes: Sendable {
    private let authenticator: V2OperatorReplayBearerAuthenticator
    private let service: any V2AccountDisabling

    public init(authenticator: V2OperatorReplayBearerAuthenticator, service: any V2AccountDisabling) {
        self.authenticator = authenticator
        self.service = service
    }

    public func register(on routes: RoutesBuilder) {
        routes.post("internal", "v2", "accounts", "disable") { request async throws -> Response in
            guard authenticator.isAuthorized(bearerToken: request.headers.bearerAuthorization?.token) else {
                throw Abort(.unauthorized)
            }
            let command: V2AccountDisableCommand
            do { command = try request.content.decode(V2AccountDisableHTTPRequest.self).command() }
            catch { throw Abort(.badRequest) }
            let result: V2AccountDisableOutcome
            do { result = try await service.disable(command) }
            catch V2AccountDisableError.operationConflict { throw Abort(.conflict) }
            catch V2AccountDisableError.invalidUserID { throw Abort(.badRequest) }
            catch { throw Abort(.serviceUnavailable) }
            return try noStoreJSON(.init(
                operationID: command.operationID,
                outcome: outcomeName(result),
                disabledAtMilliseconds: milliseconds(disabledAt: result)
            ))
        }
    }

    private func outcomeName(_ result: V2AccountDisableOutcome) -> String {
        switch result {
        case .disabled: "disabled"
        case .idempotent: "idempotent"
        case .alreadyDisabled: "already_disabled"
        }
    }

    private func milliseconds(disabledAt result: V2AccountDisableOutcome) -> Int64 {
        let date: Date
        switch result {
        case .disabled(let value), .idempotent(let value), .alreadyDisabled(let value): date = value
        }
        return Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }

    private func noStoreJSON(_ response: V2AccountDisableHTTPResponse) throws -> Response {
        let data = try JSONEncoder().encode(response)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }
}
