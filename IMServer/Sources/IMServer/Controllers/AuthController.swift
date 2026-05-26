import Vapor

// AuthController 只负责 HTTP 层：解码请求、挂载路由、把业务逻辑转交给 AuthService。
struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api")
        let auth = api.grouped("auth")

        auth.post("register", use: register)
        auth.post("login", use: login)
        auth.post("refresh", use: refresh)
        auth.post("email-verifications", "resend", use: resendEmailVerification)
        auth.post("email-verifications", "confirm", use: confirmEmailVerification)
        auth.post("password-resets", "request", use: requestPasswordReset)
        auth.post("password-resets", "confirm", use: confirmPasswordReset)

        // refresh 之外的会话管理接口都要求 access token 已经通过鉴权。
        let protected = auth.grouped(
            AccessTokenAuthenticator(),
            User.guardMiddleware(throwing: Abort(.unauthorized, reason: "用户未登录。"))
        )
        protected.get("sessions", use: sessions)
        protected.post("logout", use: logout)
        protected.delete("sessions", "current", use: logoutCurrent)
        protected.delete("sessions", "all", use: logoutAll)
        protected.delete("sessions", ":sessionID", use: logoutSession)
    }

    func register(req: Request) async throws -> RegisterResponse {
        let request = try req.content.decode(RegisterRequest.self)
        let clientIPAddress = req.application.authClientIPResolver.resolveClientIPAddress(for: req)
        return try await AuthService(app: req.application, db: req.db)
            .register(
                request: request,
                clientIPAddress: clientIPAddress,
                userAgent: req.headers.first(name: .userAgent)
            )
    }

    func login(req: Request) async throws -> AuthResponse {
        let request = try req.content.decode(LoginRequest.self)
        let clientIPAddress = req.application.authClientIPResolver.resolveClientIPAddress(for: req)
        return try await AuthService(app: req.application, db: req.db)
            .login(request: request, clientIPAddress: clientIPAddress)
    }

    func refresh(req: Request) async throws -> AuthResponse {
        let request = try req.content.decode(RefreshRequest.self)
        let clientIPAddress = req.application.authClientIPResolver.resolveClientIPAddress(for: req)
        return try await AuthService(app: req.application, db: req.db)
            .refresh(refreshToken: request.refreshToken, clientIPAddress: clientIPAddress)
    }

    func resendEmailVerification(req: Request) async throws -> AuthChallengeResponse {
        let request = try req.content.decode(EmailVerificationResendRequest.self)
        let clientIPAddress = req.application.authClientIPResolver.resolveClientIPAddress(for: req)
        return try await AuthService(app: req.application, db: req.db)
            .resendEmailVerification(
                request: request,
                clientIPAddress: clientIPAddress,
                userAgent: req.headers.first(name: .userAgent)
            )
    }

    func confirmEmailVerification(req: Request) async throws -> AuthGenericResponse {
        let request = try req.content.decode(EmailVerificationConfirmRequest.self)
        let clientIPAddress = req.application.authClientIPResolver.resolveClientIPAddress(for: req)
        return try await AuthService(app: req.application, db: req.db)
            .confirmEmailVerification(request: request, clientIPAddress: clientIPAddress)
    }

    func requestPasswordReset(req: Request) async throws -> AuthChallengeResponse {
        let request = try req.content.decode(PasswordResetRequest.self)
        let clientIPAddress = req.application.authClientIPResolver.resolveClientIPAddress(for: req)
        return try await AuthService(app: req.application, db: req.db)
            .requestPasswordReset(
                request: request,
                clientIPAddress: clientIPAddress,
                userAgent: req.headers.first(name: .userAgent)
            )
    }

    func confirmPasswordReset(req: Request) async throws -> AuthGenericResponse {
        let request = try req.content.decode(PasswordResetConfirmRequest.self)
        let clientIPAddress = req.application.authClientIPResolver.resolveClientIPAddress(for: req)
        return try await AuthService(app: req.application, db: req.db)
            .confirmPasswordReset(request: request, clientIPAddress: clientIPAddress)
    }

    func sessions(req: Request) async throws -> [AuthSessionResponse] {
        let user = try req.auth.require(User.self)
        let session = try req.auth.require(SessionContext.self)
        return try await AuthService(app: req.application, db: req.db)
            .sessions(for: try user.requireID(), currentSessionID: session.sessionID)
    }

    func logout(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionContext.self)
        try await AuthService(app: req.application, db: req.db).logout(sessionID: session.sessionID)
        return .ok
    }

    func logoutCurrent(req: Request) async throws -> HTTPStatus {
        try await logout(req: req)
    }

    func logoutAll(req: Request) async throws -> LogoutAllResponse {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        let response = try await AuthService(app: req.application, db: req.db)
            .logoutAll(userID: userID)
        return response
    }

    func logoutSession(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        guard let rawSessionID = req.parameters.get("sessionID"),
              let sessionID = UUID(uuidString: rawSessionID)
        else {
            throw Abort(.badRequest, reason: "设备会话 ID 无效。")
        }

        try await AuthService(app: req.application, db: req.db)
            .logout(sessionID: sessionID, for: try user.requireID())
        return .ok
    }
}

struct RegisterRequest: Content {
    let email: String
    let password: String
    let device: DeviceMetadata?
}

enum RegisterResponseState: String, Content {
    case signedIn
    case verificationRequired
}

struct RegisterResponse: Content {
    let state: RegisterResponseState
    let auth: AuthResponse?
    let email: String?
    let expiresIn: Int?
    let message: String?

    static func signedIn(_ auth: AuthResponse) -> RegisterResponse {
        RegisterResponse(state: .signedIn, auth: auth, email: nil, expiresIn: nil, message: nil)
    }

    static func verificationRequired(email: String, expiresIn: Int) -> RegisterResponse {
        RegisterResponse(
            state: .verificationRequired,
            auth: nil,
            email: email,
            expiresIn: expiresIn,
            message: "验证码已发送，请完成邮箱验证后登录。"
        )
    }
}

struct LoginRequest: Content {
    let email: String
    let password: String
    let device: DeviceMetadata?
}

struct DeviceMetadata: Content {
    let deviceID: String?
    let deviceName: String?
    let platform: String?
    let appVersion: String?
}

struct RefreshRequest: Content {
    let refreshToken: String
}

struct EmailVerificationResendRequest: Content {
    let email: String
}

struct EmailVerificationConfirmRequest: Content {
    let email: String
    let code: String
}

struct PasswordResetRequest: Content {
    let email: String
}

struct PasswordResetConfirmRequest: Content {
    let email: String
    let code: String
    let newPassword: String
}

struct AuthChallengeResponse: Content {
    let email: String
    let expiresIn: Int
    let message: String
}

struct AuthGenericResponse: Content {
    let message: String
}

struct AuthResponse: Content {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String
    let refreshExpiresIn: Int
    let user: UserResponse
}

struct AuthSessionResponse: Content, Equatable {
    let id: UUID
    let deviceID: String?
    let deviceName: String?
    let platform: String?
    let appVersion: String?
    let lastSeenAt: Date?
    let createdAt: Date?
    let refreshExpiresAt: Date
    let isCurrent: Bool
    let isOnline: Bool
    let activeConnectionCount: Int
}

struct LogoutAllResponse: Content, Equatable {
    let revokedSessions: Int
}
