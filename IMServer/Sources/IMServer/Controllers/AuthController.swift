import Vapor

// AuthController 只负责 HTTP 层：解码请求、挂载路由、把业务逻辑转交给 AuthService。
struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api")
        let auth = api.grouped("auth")

        auth.post("register", use: register)
        auth.post("login", use: login)
        auth.post("refresh", use: refresh)

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

    func register(req: Request) async throws -> AuthResponse {
        let request = try req.content.decode(RegisterRequest.self)
        let clientIPAddress = req.application.authClientIPResolver.resolveClientIPAddress(for: req)
        return try await AuthService(app: req.application, db: req.db)
            .register(request: request, clientIPAddress: clientIPAddress)
    }

    func login(req: Request) async throws -> AuthResponse {
        let request = try req.content.decode(LoginRequest.self)
        let clientIPAddress = req.application.authClientIPResolver.resolveClientIPAddress(for: req)
        return try await AuthService(app: req.application, db: req.db)
            .login(request: request, clientIPAddress: clientIPAddress)
    }

    func refresh(req: Request) async throws -> AuthResponse {
        let request = try req.content.decode(RefreshRequest.self)
        return try await AuthService(app: req.application, db: req.db).refresh(refreshToken: request.refreshToken)
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
        await req.application.gatewaySessionService.kickConnections(
            forSessionID: session.sessionID,
            reason: .logoutCurrent,
            message: "You have signed out from this device."
        )
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
        await req.application.gatewaySessionService.kickConnections(
            forUserID: userID,
            reason: .logoutAll,
            message: "You have signed out from all devices."
        )
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
        await req.application.gatewaySessionService.kickConnections(
            forSessionID: sessionID,
            reason: .sessionRevoked,
            message: "This session has been revoked."
        )
        return .ok
    }
}

struct RegisterRequest: Content {
    let email: String
    let password: String
    let device: DeviceMetadata?
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
