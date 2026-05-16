import Fluent
import JWTKit
import SQLKit
import Vapor

// 认证服务统一封装账号登录、refresh rotation、会话查询和登出逻辑。
struct AuthService {
    let app: Application
    let db: any Database

    private static let credentialMaskingHash = try! Bcrypt.hash("credential-mask-placeholder")

    private var config: AuthConfiguration {
        app.authConfiguration
    }

    private var now: Date {
        Date()
    }

    func register(request: RegisterRequest, clientIPAddress: String?) async throws -> AuthResponse {
        let normalizedEmail = User.normalize(request.email)
        let attempt = try await app.authLoginRateLimiter.beginRegistrationAttempt(
            ipAddress: clientIPAddress,
            account: normalizedEmail,
            now: now
        )

        do {
            guard request.password.count >= 8 else {
                throw AuthError.weakPassword
            }

            // 先完成密码哈希，再写库，避免重复邮箱和新邮箱在耗时上过于可区分。
            let passwordHash = try Bcrypt.hash(request.password)

            let user = User(
                email: normalizedEmail,
                passwordHash: passwordHash,
                status: .active
            )

            do {
                try await user.create(on: db)
            } catch {
                guard let databaseError = error as? any DatabaseError,
                      databaseError.isConstraintFailure
                else {
                    throw error
                }

                throw AuthError.invalidRegistration
            }

            let response = try await createSessionAndResponse(for: user, device: request.device)
            await app.authLoginRateLimiter.completeRegistrationAttempt(attempt, succeeded: true, now: now)
            return response
        } catch {
            await app.authLoginRateLimiter.completeRegistrationAttempt(attempt, succeeded: false, now: now)
            throw error
        }
    }

    func login(request: LoginRequest, clientIPAddress: String?) async throws -> AuthResponse {
        let normalizedEmail = User.normalize(request.email)
        let attempt = try await app.authLoginRateLimiter.beginLoginAttempt(
            ipAddress: clientIPAddress,
            account: normalizedEmail,
            now: now
        )

        do {
            guard let user = try await User.query(on: db)
                .filter(\.$email == normalizedEmail)
                .first()
            else {
                // 使用固定 bcrypt 校验掩盖“账号不存在”的更快失败路径。
                _ = try? Bcrypt.verify(request.password, created: Self.credentialMaskingHash)
                throw AuthError.invalidCredentials
            }

            guard try Bcrypt.verify(request.password, created: user.passwordHash) else {
                throw AuthError.invalidCredentials
            }

            guard user.statusEnum == .active else {
                throw AuthError.invalidCredentials
            }

            let response = try await createSessionAndResponse(for: user, device: request.device)
            await app.authLoginRateLimiter.completeLoginAttempt(attempt, succeeded: true, now: now)
            return response
        } catch {
            await app.authLoginRateLimiter.completeLoginAttempt(attempt, succeeded: false, now: now)
            throw error
        }
    }

    func refresh(refreshToken: String) async throws -> AuthResponse {
        let payload = try await app.jwtKeys.verify(refreshToken, as: RefreshTokenPayload.self)
        try validate(payload: payload, tokenKind: .refresh)
        let now = now
        let user = try await requireActiveUser(id: payload.sub)

        if let session = try await rotateRefreshToken(
            sessionID: payload.sid,
            userID: payload.sub,
            nonce: payload.nonce,
            now: now
        ) {
            return try await makeAuthResponse(for: user, session: session, now: now)
        }

        guard let session = try await AuthSession.find(payload.sid, on: db) else {
            throw AuthError.invalidToken
        }

        guard session.$user.id == payload.sub else {
            throw AuthError.invalidToken
        }

        guard session.revokedAt == nil else {
            throw AuthError.sessionRevoked
        }

        guard session.refreshExpiresAt > now else {
            session.revokedAt = now
            try await session.update(on: db)
            throw AuthError.expiredToken
        }

        if payload.nonce == session.previousNonce,
           let previousValidUntil = session.previousValidUntil,
           previousValidUntil >= now
        {
            session.lastSeenAt = now
            try await session.update(on: db)

            return try await makeAuthResponse(for: user, session: session, now: now)
        }

        // 旧 token 超出 grace period 仍被使用，视为 reuse/replay，直接吊销该 session。
        session.revokedAt = now
        try await session.update(on: db)
        throw AuthError.refreshTokenReuseDetected
    }

    func authenticateAccessToken(_ token: String) async throws -> (User, SessionContext) {
        let payload = try await app.jwtKeys.verify(token, as: AccessTokenPayload.self)
        try validate(payload: payload, tokenKind: .access)

        let session = try await requireActiveSession(id: payload.sid, userID: payload.sub, shouldRevokeExpired: true)
        let user = try await requireActiveUser(id: payload.sub)

        return (
            user,
            SessionContext(
                userID: payload.sub,
                sessionID: try session.requireID(),
                deviceID: session.deviceID
            )
        )
    }

    func logout(sessionID: UUID) async throws {
        guard let session = try await AuthSession.find(sessionID, on: db) else {
            return
        }

        session.revokedAt = now
        try await session.update(on: db)
    }

    func logout(sessionID: UUID, for userID: UUID) async throws {
        guard let session = try await AuthSession.find(sessionID, on: db),
              session.$user.id == userID
        else {
            throw AuthError.sessionNotFound
        }

        session.revokedAt = now
        try await session.update(on: db)
    }

    func sessions(for userID: UUID, currentSessionID: UUID) async throws -> [AuthSessionResponse] {
        let now = now
        let sessions = try await AuthSession.query(on: db)
            .filter(\.$user.$id == userID)
            .group(.and) { group in
                group.filter(\.$revokedAt == nil)
                group.filter(\.$refreshExpiresAt > now)
            }
            .all()

        let sessionIDs = sessions.compactMap(\.id)
        let activeConnectionCounts = await app.gatewaySessionService.activeConnectionCounts(forSessionIDs: sessionIDs)

        return sessions
            .map { session in
                let sessionID = session.id ?? currentSessionID
                let activeConnectionCount = activeConnectionCounts[sessionID] ?? 0
                return AuthSessionResponse(
                    id: sessionID,
                    deviceID: session.deviceID,
                    deviceName: session.deviceName,
                    platform: session.platform,
                    appVersion: session.appVersion,
                    lastSeenAt: session.lastSeenAt,
                    createdAt: session.createdAt,
                    refreshExpiresAt: session.refreshExpiresAt,
                    isCurrent: session.id == currentSessionID,
                    isOnline: activeConnectionCount > 0,
                    activeConnectionCount: activeConnectionCount
                )
            }
            .sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent {
                    return lhs.isCurrent
                }

                return (lhs.lastSeenAt ?? lhs.createdAt ?? .distantPast) > (rhs.lastSeenAt ?? rhs.createdAt ?? .distantPast)
            }
    }

    func logoutAll(userID: UUID) async throws -> LogoutAllResponse {
        let activeSessions = try await AuthSession.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$revokedAt == nil)
            .all()
        guard !activeSessions.isEmpty else {
            return LogoutAllResponse(revokedSessions: 0)
        }

        let revokedAt = now
        try await AuthSession.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$revokedAt == nil)
            .set(\.$revokedAt, to: revokedAt)
            .update()

        return LogoutAllResponse(revokedSessions: activeSessions.count)
    }

    private func createSessionAndResponse(for user: User, device: DeviceMetadata?) async throws -> AuthResponse {
        let normalizedDevice = normalize(device: device)
        let userID = try user.requireID()

        do {
            let (session, issuedAt, revokedSessionIDs) = try await db.transaction { transaction in
                let now = Date()
                var revokedSessionIDs: [UUID] = []

                // 同一用户 + 同一设备只保留一条活跃 session，撤销旧 session 与创建新 session 在同一事务中完成。
                if let deviceID = normalizedDevice?.deviceID {
                    revokedSessionIDs = try await AuthService(app: app, db: transaction).revokeActiveSessions(
                        for: userID,
                        deviceID: deviceID,
                        at: now
                    )
                }

                let session = AuthSession(
                    userID: userID,
                    currentNonce: TokenValueGenerator.make(),
                    refreshExpiresAt: now.addingTimeInterval(config.refreshTokenTTL),
                    deviceID: normalizedDevice?.deviceID,
                    deviceName: normalizedDevice?.deviceName,
                    platform: normalizedDevice?.platform,
                    appVersion: normalizedDevice?.appVersion,
                    lastSeenAt: now
                )
                try await session.create(on: transaction)
                return (session, now, revokedSessionIDs)
            }

            let response = try await makeAuthResponse(for: user, session: session, now: issuedAt)
            for revokedSessionID in revokedSessionIDs {
                await app.gatewaySessionService.kickConnections(
                    forSessionID: revokedSessionID,
                    reason: .sessionRevoked,
                    message: "This device signed in again, so the previous session was revoked."
                )
            }
            return response
        } catch {
            guard let databaseError = error as? any DatabaseError,
                  databaseError.isConstraintFailure,
                  let deviceID = normalizedDevice?.deviceID,
                  let existingSession = try await activeSession(for: userID, deviceID: deviceID)
            else {
                throw error
            }

            return try await makeAuthResponse(for: user, session: existingSession, now: now)
        }
    }

    private func revokeActiveSessions(for userID: UUID, deviceID: String, at revokedAt: Date) async throws -> [UUID] {
        let activeSessions = try await AuthSession.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$deviceID == deviceID)
            .filter(\.$revokedAt == nil)
            .all()
        let revokedSessionIDs = activeSessions.compactMap(\.id)
        guard !revokedSessionIDs.isEmpty else {
            return []
        }

        try await AuthSession.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$deviceID == deviceID)
            .filter(\.$revokedAt == nil)
            .set(\.$revokedAt, to: revokedAt)
            .update()
        return revokedSessionIDs
    }

    private func normalize(device: DeviceMetadata?) -> DeviceMetadata? {
        guard let device else {
            return nil
        }

        // 设备元数据只保留有值字段，避免把一堆空字符串写进数据库。
        let normalized = DeviceMetadata(
            deviceID: device.deviceID?.nilIfBlank,
            deviceName: device.deviceName?.nilIfBlank,
            platform: device.platform?.nilIfBlank,
            appVersion: device.appVersion?.nilIfBlank
        )

        if normalized.deviceID == nil,
           normalized.deviceName == nil,
           normalized.platform == nil,
           normalized.appVersion == nil
        {
            return nil
        }

        return normalized
    }

    private func makeAuthResponse(for user: User, session: AuthSession, now: Date) async throws -> AuthResponse {
        // access token 短期有效，refresh token 则绑定到 session + nonce 上，交给 rotation 管理。
        let accessToken = try await app.jwtKeys.sign(
            AccessTokenPayload(
                sub: try user.requireID(),
                sid: try session.requireID(),
                email: user.email,
                iss: config.issuer,
                exp: now.addingTimeInterval(config.accessTokenTTL).unixTimestamp,
                typ: .access
            )
        )

        let refreshToken = try await app.jwtKeys.sign(
            RefreshTokenPayload(
                sub: try user.requireID(),
                sid: try session.requireID(),
                nonce: session.currentNonce,
                iss: config.issuer,
                exp: session.refreshExpiresAt.unixTimestamp,
                typ: .refresh
            )
        )

        return try AuthResponse(
            accessToken: accessToken,
            expiresIn: Int(config.accessTokenTTL),
            refreshToken: refreshToken,
            refreshExpiresIn: max(0, Int(session.refreshExpiresAt.timeIntervalSince(now))),
            user: user.asResponse()
        )
    }

    func validate(payload: AccessTokenPayload, tokenKind: TokenKind) throws {
        guard payload.iss == config.issuer else {
            throw AuthError.invalidToken
        }

        guard payload.typ == tokenKind else {
            throw AuthError.invalidTokenType
        }
    }

    func validate(payload: RefreshTokenPayload, tokenKind: TokenKind) throws {
        guard payload.iss == config.issuer else {
            throw AuthError.invalidToken
        }

        guard payload.typ == tokenKind else {
            throw AuthError.invalidTokenType
        }
    }

    private func requireActiveSession(id sessionID: UUID, userID: UUID, shouldRevokeExpired: Bool) async throws -> AuthSession {
        guard let session = try await AuthSession.find(sessionID, on: db),
              session.$user.id == userID
        else {
            throw AuthError.invalidToken
        }

        if session.revokedAt != nil {
            throw AuthError.sessionRevoked
        }

        if session.refreshExpiresAt <= now {
            if shouldRevokeExpired {
                session.revokedAt = now
                try await session.update(on: db)
            }
            throw AuthError.sessionExpired
        }

        return session
    }

    private func requireActiveUser(id userID: UUID) async throws -> User {
        guard let user = try await User.find(userID, on: db) else {
            throw AuthError.invalidToken
        }

        guard user.statusEnum == .active else {
            throw AuthError.userDisabled
        }

        return user
    }

    private func rotateRefreshToken(
        sessionID: UUID,
        userID: UUID,
        nonce: String,
        now: Date
    ) async throws -> AuthSession? {
        guard let sql = db as? any SQLDatabase else {
            return nil
        }

        let refreshExpiry = now.addingTimeInterval(config.refreshTokenTTL)
        let previousValidUntil = now.addingTimeInterval(config.refreshGracePeriod)

        if let rotatedSession = try await sql.update(AuthSession.schema)
            .set("previous_nonce", to: nonce)
            .set("previous_valid_until", to: previousValidUntil)
            .set("current_nonce", to: TokenValueGenerator.make())
            .set("refresh_expires_at", to: refreshExpiry)
            .set("last_seen_at", to: now)
            .where("id", .equal, sessionID)
            .where("user_id", .equal, userID)
            .where("revoked_at", .is, SQLLiteral.null)
            .where("refresh_expires_at", .greaterThan, SQLBind(now))
            .where("current_nonce", .equal, nonce)
            .returning("*")
            .first(decodingFluent: AuthSession.self)
        {
            return rotatedSession
        }

        if let retriedSession = try await sql.update(AuthSession.schema)
            .set("last_seen_at", to: now)
            .where("id", .equal, sessionID)
            .where("user_id", .equal, userID)
            .where("revoked_at", .is, SQLLiteral.null)
            .where("refresh_expires_at", .greaterThan, SQLBind(now))
            .where("previous_nonce", .equal, nonce)
            .where("previous_valid_until", .greaterThanOrEqual, SQLBind(now))
            .returning("*")
            .first(decodingFluent: AuthSession.self)
        {
            return retriedSession
        }

        return nil
    }

    private func activeSession(for userID: UUID, deviceID: String) async throws -> AuthSession? {
        try await AuthSession.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$deviceID == deviceID)
            .filter(\.$revokedAt == nil)
            .filter(\.$refreshExpiresAt > now)
            .sort(\.$createdAt, .descending)
            .first()
    }
}

enum TokenValueGenerator {
    static func make(byteCount: Int = 32) -> String {
        // refresh nonce 只需要高熵、不可预测，不需要可读性。
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Date {
    var unixTimestamp: Int {
        Int(timeIntervalSince1970)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
