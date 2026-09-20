import Foundation
import IMV2Core
import IMV2Server
import Vapor

/// Public factor endpoints protected by the trusted edge proof and shared address budget.
/// Password-bearing operations additionally consume the canonical account's attempt budget.
public struct V2PasswordLifecycleRoutes: Sendable {
    private let service: any V2PasswordLifecycleManaging
    public init(service: any V2PasswordLifecycleManaging) { self.service = service }

    public func register(on routes: any RoutesBuilder) {
        for action in ["change", "recovery-code", "recover"] {
            routes.on(.POST, "v2", "account-auth", "password", PathComponent(stringLiteral: action), body: .collect(maxSize: "8kb")) { request async -> Response in
                do {
                    guard request.headers.contentType?.type == "application", request.headers.contentType?.subType == "json" else { return response(.badRequest) }
                    let input = try request.content.decode(Input.self)
                    guard let uuid = UUID(uuidString: input.deviceID) else { return response(.badRequest) }
                    let device = DeviceID(uuid: uuid)
                    switch action {
                    case "change":
                        guard let current = input.currentPassword, let next = input.newPassword else { return response(.badRequest) }
                        try await service.changePassword(accountHandle: input.accountHandle, currentPassword: current, newPassword: next, deviceID: device)
                    case "recovery-code":
                        guard let current = input.currentPassword, let code = input.recoveryCode else { return response(.badRequest) }
                        try await service.setRecoveryCode(accountHandle: input.accountHandle, password: current, recoveryCode: code, deviceID: device)
                    default:
                        guard let next = input.newPassword, let code = input.recoveryCode else { return response(.badRequest) }
                        try await service.resetPassword(accountHandle: input.accountHandle, recoveryCode: code, newPassword: next, deviceID: device)
                    }
                    return response(.noContent)
                } catch V2PasswordLifecycleError.rejected { return response(.unauthorized) }
                catch V2PasswordLifecycleError.invalidInput { return response(.badRequest) }
                catch V2PasswordAccountStoreError.invalidAccountHandle { return response(.badRequest) }
                catch V2PasswordLifecycleError.rateLimited(let seconds) { return response(.tooManyRequests, retry: seconds) }
                catch V2PasswordHashError.busy { return response(.serviceUnavailable, retry: 1) }
                catch is DecodingError { return response(.badRequest) }
                catch let abort as Abort where abort.status == .badRequest || abort.status == .unsupportedMediaType { return response(.badRequest) }
                catch { return response(.serviceUnavailable) }
            }
        }
    }

    private func response(_ status: HTTPStatus, retry: Int? = nil) -> Response {
        var headers: HTTPHeaders = ["Cache-Control": "no-store", "Pragma": "no-cache"]
        if let retry { headers.replaceOrAdd(name: "Retry-After", value: String(retry)) }
        return .init(status: status, headers: headers)
    }

    private struct Input: Content {
        let accountHandle: String
        let deviceID: String
        let currentPassword: String?
        let newPassword: String?
        let recoveryCode: String?
    }
}
