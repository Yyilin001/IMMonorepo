import Foundation

public struct AuthAPI: Sendable {
    public let client: HTTPClient

    init(client: HTTPClient) {
        self.client = client
    }

    public func login(email: String, password: String, device: DeviceMetadataPayload?) async throws -> AuthResponseBody {
        try await client.execute(
            AuthRequest.login(
                CredentialsRequestBody(email: email, password: password, device: device)
            )
        )
    }

    public func register(email: String, password: String, device: DeviceMetadataPayload?) async throws -> RegisterResponseBody {
        try await client.execute(
            AuthRequest.register(
                CredentialsRequestBody(email: email, password: password, device: device)
            )
        )
    }

    public func refresh(refreshToken: String) async throws -> AuthResponseBody {
        try await client.execute(
            AuthRequest.refresh(RefreshRequestBody(refreshToken: refreshToken))
        )
    }

    public func resendEmailVerification(email: String) async throws -> AuthChallengeResponseBody {
        try await client.execute(AuthRequest.resendEmailVerification(EmailRequestBody(email: email)))
    }

    public func confirmEmailVerification(email: String, code: String) async throws -> AuthGenericResponseBody {
        try await client.execute(
            AuthRequest.confirmEmailVerification(
                EmailVerificationConfirmRequestBody(email: email, code: code)
            )
        )
    }

    public func requestPasswordReset(email: String) async throws -> AuthChallengeResponseBody {
        try await client.execute(AuthRequest.requestPasswordReset(EmailRequestBody(email: email)))
    }

    public func confirmPasswordReset(email: String, code: String, newPassword: String) async throws -> AuthGenericResponseBody {
        try await client.execute(
            AuthRequest.confirmPasswordReset(
                PasswordResetConfirmRequestBody(email: email, code: code, newPassword: newPassword)
            )
        )
    }
}

enum AuthRequest {
    public struct Login: Endpoint {
        public typealias Response = AuthResponseBody

        let body: CredentialsRequestBody
        let requestSpec = HTTPRequestSpec(path: "api/auth/login", method: .post)

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            do {
                return try encoder.encode(body)
            } catch {
                throw APIError.encodingFailed(error.localizedDescription)
            }
        }
    }

    public struct Register: Endpoint {
        public typealias Response = RegisterResponseBody

        let body: CredentialsRequestBody
        let requestSpec = HTTPRequestSpec(path: "api/auth/register", method: .post)

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            do {
                return try encoder.encode(body)
            } catch {
                throw APIError.encodingFailed(error.localizedDescription)
            }
        }
    }

    public struct Refresh: Endpoint {
        public typealias Response = AuthResponseBody

        let body: RefreshRequestBody
        let requestSpec = HTTPRequestSpec(path: "api/auth/refresh", method: .post)

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            do {
                return try encoder.encode(body)
            } catch {
                throw APIError.encodingFailed(error.localizedDescription)
            }
        }
    }

    public struct ResendEmailVerification: Endpoint {
        public typealias Response = AuthChallengeResponseBody

        let body: EmailRequestBody
        let requestSpec = HTTPRequestSpec(path: "api/auth/email-verifications/resend", method: .post)

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            do {
                return try encoder.encode(body)
            } catch {
                throw APIError.encodingFailed(error.localizedDescription)
            }
        }
    }

    public struct ConfirmEmailVerification: Endpoint {
        public typealias Response = AuthGenericResponseBody

        let body: EmailVerificationConfirmRequestBody
        let requestSpec = HTTPRequestSpec(path: "api/auth/email-verifications/confirm", method: .post)

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            do {
                return try encoder.encode(body)
            } catch {
                throw APIError.encodingFailed(error.localizedDescription)
            }
        }
    }

    public struct RequestPasswordReset: Endpoint {
        public typealias Response = AuthChallengeResponseBody

        let body: EmailRequestBody
        let requestSpec = HTTPRequestSpec(path: "api/auth/password-resets/request", method: .post)

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            do {
                return try encoder.encode(body)
            } catch {
                throw APIError.encodingFailed(error.localizedDescription)
            }
        }
    }

    public struct ConfirmPasswordReset: Endpoint {
        public typealias Response = AuthGenericResponseBody

        let body: PasswordResetConfirmRequestBody
        let requestSpec = HTTPRequestSpec(path: "api/auth/password-resets/confirm", method: .post)

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            do {
                return try encoder.encode(body)
            } catch {
                throw APIError.encodingFailed(error.localizedDescription)
            }
        }
    }

    public struct Sessions: AuthorizedEndpoint {
        public typealias Response = [SessionSnapshot]

        let baseRequestSpec = HTTPRequestSpec(path: "api/auth/sessions")
    }

    public struct LogoutCurrent: AuthorizedEndpoint {
        public typealias Response = EmptyResponse

        let baseRequestSpec = HTTPRequestSpec(
            path: "api/auth/sessions/current",
            method: .delete
        )
    }

    public struct LogoutAll: AuthorizedEndpoint {
        public typealias Response = LogoutAllResponseBody

        let baseRequestSpec = HTTPRequestSpec(
            path: "api/auth/sessions/all",
            method: .delete
        )
    }

    public struct Logout: AuthorizedEndpoint {
        public typealias Response = EmptyResponse

        let sessionID: UUID

        var baseRequestSpec: HTTPRequestSpec {
            .init(
                path: "api/auth/sessions/\(sessionID.uuidString)",
                method: .delete
            )
        }
    }

    public static func login(_ body: CredentialsRequestBody) -> Login {
        Login(body: body)
    }

    public static func register(_ body: CredentialsRequestBody) -> Register {
        Register(body: body)
    }

    public static func refresh(_ body: RefreshRequestBody) -> Refresh {
        Refresh(body: body)
    }

    public static func resendEmailVerification(_ body: EmailRequestBody) -> ResendEmailVerification {
        ResendEmailVerification(body: body)
    }

    public static func confirmEmailVerification(_ body: EmailVerificationConfirmRequestBody) -> ConfirmEmailVerification {
        ConfirmEmailVerification(body: body)
    }

    public static func requestPasswordReset(_ body: EmailRequestBody) -> RequestPasswordReset {
        RequestPasswordReset(body: body)
    }

    public static func confirmPasswordReset(_ body: PasswordResetConfirmRequestBody) -> ConfirmPasswordReset {
        ConfirmPasswordReset(body: body)
    }

    public static let sessions = Sessions()
    public static let logoutCurrent = LogoutCurrent()
    public static let logoutAll = LogoutAll()

    public static func logout(_ sessionID: UUID) -> Logout {
        Logout(sessionID: sessionID)
    }
}
