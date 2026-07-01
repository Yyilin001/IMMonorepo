import Fluent
import Crypto
import JWTKit
import SQLKit
import Vapor

// 认证服务统一封装账号登录、refresh rotation、会话查询和登出逻辑。
struct AuthService {
    let app: Application
    let db: any Database

    private static let credentialMaskingHashResult: Result<String, any Error> = Result {
        try Bcrypt.hash("credential-mask-placeholder")
    }

    private var config: AuthConfiguration {
        app.authConfiguration
    }

    private var securityConfig: AuthSecurityConfiguration {
        app.authSecurityConfiguration
    }

    private var now: Date {
        Date()
    }

    func register(request: RegisterRequest, clientIPAddress: String?, userAgent: String?) async throws -> RegisterResponse {
        let normalizedEmail = User.normalize(request.email)
        let attempt = try await app.authLoginRateLimiter.beginRegistrationAttempt(
            ipAddress: clientIPAddress,
            account: normalizedEmail,
            now: now
        )

        do {
            try PasswordPolicy.validate(password: request.password, email: normalizedEmail)

            // 先完成密码哈希，再写库，避免重复邮箱和新邮箱在耗时上过于可区分。
            let passwordHash = try Bcrypt.hash(request.password)
            let now = now

            let user = User(
                email: normalizedEmail,
                passwordHash: passwordHash,
                status: .active,
                emailVerifiedAt: securityConfig.emailVerificationRequired ? nil : now
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

            if securityConfig.emailVerificationRequired {
                let expiresIn = try await issueEmailVerificationChallenge(
                    for: user,
                    email: normalizedEmail,
                    clientIPAddress: clientIPAddress,
                    userAgent: userAgent
                )
                await audit(
                    eventType: "register",
                    user: user,
                    email: normalizedEmail,
                    sessionID: nil,
                    deviceID: request.device?.deviceID,
                    ipAddress: clientIPAddress,
                    succeeded: true,
                    failureReason: nil
                )
                await app.authLoginRateLimiter.completeRegistrationAttempt(attempt, succeeded: true, now: now)
                return .verificationRequired(email: normalizedEmail, expiresIn: expiresIn)
            }

            let response = try await createSessionAndResponse(for: user, device: request.device)
            await audit(
                eventType: "register",
                user: user,
                email: normalizedEmail,
                sessionID: nil,
                deviceID: request.device?.deviceID,
                ipAddress: clientIPAddress,
                succeeded: true,
                failureReason: nil
            )
            await app.authLoginRateLimiter.completeRegistrationAttempt(attempt, succeeded: true, now: now)
            return .signedIn(response)
        } catch {
            await audit(
                eventType: "register",
                user: nil,
                email: normalizedEmail,
                sessionID: nil,
                deviceID: request.device?.deviceID,
                ipAddress: clientIPAddress,
                succeeded: false,
                failureReason: String(describing: error)
            )
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
                Self.performCredentialMaskingCheck(password: request.password, logger: app.logger)
                throw AuthError.invalidCredentials
            }

            guard try Bcrypt.verify(request.password, created: user.passwordHash) else {
                throw AuthError.invalidCredentials
            }

            guard user.statusEnum == .active else {
                throw AuthError.invalidCredentials
            }

            guard !securityConfig.emailVerificationRequired || user.emailVerifiedAt != nil else {
                throw AuthError.emailVerificationRequired
            }

            let response = try await createSessionAndResponse(for: user, device: request.device)
            await audit(
                eventType: "login",
                user: user,
                email: normalizedEmail,
                sessionID: nil,
                deviceID: request.device?.deviceID,
                ipAddress: clientIPAddress,
                succeeded: true,
                failureReason: nil
            )
            await app.authLoginRateLimiter.completeLoginAttempt(attempt, succeeded: true, now: now)
            return response
        } catch {
            await audit(
                eventType: "login",
                user: nil,
                email: normalizedEmail,
                sessionID: nil,
                deviceID: request.device?.deviceID,
                ipAddress: clientIPAddress,
                succeeded: false,
                failureReason: String(describing: error)
            )
            await app.authLoginRateLimiter.completeLoginAttempt(attempt, succeeded: false, now: now)
            throw error
        }
    }

    private static func performCredentialMaskingCheck(password: String, logger: Logger) {
        switch credentialMaskingHashResult {
        case .success(let hash):
            do {
                _ = try Bcrypt.verify(password, created: hash)
            } catch {
                logger.warning("auth credential masking bcrypt verify failed", metadata: ["error": "\(error)"])
            }
        case .failure(let error):
            logger.error("auth credential masking hash unavailable", metadata: ["error": "\(error)"])
            _ = try? Bcrypt.hash(password)
        }
    }

    func refresh(refreshToken: String, clientIPAddress: String? = nil) async throws -> AuthResponse {
        try await app.authLoginRateLimiter.checkRefreshAttempt(ipAddress: clientIPAddress, account: nil, now: now)
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
            session.revokedReason = AuthSessionRevocationReason.sessionRevoked.rawValue
            try await session.update(on: db)
            await kickRevokedSession(
                sessionID: payload.sid,
                reason: .sessionRevoked,
                message: "Current login is invalid. Please sign in again."
            )
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
        session.revokedReason = AuthSessionRevocationReason.refreshTokenReuse.rawValue
        try await session.update(on: db)
        await app.authSessionValidationCache.invalidate(sessionID: payload.sid)
        await audit(
            eventType: "refresh_reuse_detected",
            user: user,
            email: user.email,
            sessionID: payload.sid,
            deviceID: session.deviceID,
            ipAddress: clientIPAddress,
            succeeded: false,
            failureReason: AuthError.refreshTokenReuseDetected.reason
        )
        await kickRevokedSession(
            sessionID: payload.sid,
            reason: .sessionRevoked,
            message: "Current login is invalid. Please sign in again."
        )
        throw AuthError.refreshTokenReuseDetected
    }

    func resendEmailVerification(
        request: EmailVerificationResendRequest,
        clientIPAddress: String?,
        userAgent: String?
    ) async throws -> AuthChallengeResponse {
        let normalizedEmail = User.normalize(request.email)
        try await app.authLoginRateLimiter.checkVerificationResendAttempt(
            ipAddress: clientIPAddress,
            account: normalizedEmail,
            now: now
        )

        if let user = try await User.query(on: db).filter(\.$email == normalizedEmail).first(),
           user.emailVerifiedAt == nil
        {
            let expiresIn = try await issueEmailVerificationChallenge(
                for: user,
                email: normalizedEmail,
                clientIPAddress: clientIPAddress,
                userAgent: userAgent
            )
            await audit(
                eventType: "email_verification_sent",
                user: user,
                email: normalizedEmail,
                sessionID: nil,
                deviceID: nil,
                ipAddress: clientIPAddress,
                succeeded: true,
                failureReason: nil
            )
            return AuthChallengeResponse(
                email: normalizedEmail,
                expiresIn: expiresIn,
                message: "验证码已发送。"
            )
        }

        return AuthChallengeResponse(
            email: normalizedEmail,
            expiresIn: Int(securityConfig.verificationCodeTTL),
            message: "如果账号需要验证，验证码会发送到该邮箱。"
        )
    }

    func confirmEmailVerification(
        request: EmailVerificationConfirmRequest,
        clientIPAddress: String?
    ) async throws -> AuthGenericResponse {
        let normalizedEmail = User.normalize(request.email)
        try await app.authLoginRateLimiter.checkVerificationConfirmAttempt(
            ipAddress: clientIPAddress,
            account: normalizedEmail,
            now: now
        )

        guard let challenge = try await AuthEmailVerificationChallenge.query(on: db)
            .filter(\.$email == normalizedEmail)
            .filter(\.$consumedAt == nil)
            .sort(\.$createdAt, .descending)
            .first(),
            let user = try await User.find(challenge.$user.id, on: db)
        else {
            throw AuthError.invalidVerificationCode
        }

        try await validate(challenge: challenge, code: request.code)

        challenge.consumedAt = now
        user.emailVerifiedAt = now
        try await db.transaction { transaction in
            try await challenge.update(on: transaction)
            try await user.update(on: transaction)
        }
        await audit(
            eventType: "email_verification_completed",
            user: user,
            email: normalizedEmail,
            sessionID: nil,
            deviceID: nil,
            ipAddress: clientIPAddress,
            succeeded: true,
            failureReason: nil
        )
        return AuthGenericResponse(message: "邮箱验证已完成，请登录。")
    }

    func requestPasswordReset(
        request: PasswordResetRequest,
        clientIPAddress: String?,
        userAgent: String?
    ) async throws -> AuthChallengeResponse {
        let normalizedEmail = User.normalize(request.email)
        try await app.authLoginRateLimiter.checkPasswordResetAttempt(
            ipAddress: clientIPAddress,
            account: normalizedEmail,
            now: now
        )

        if let user = try await User.query(on: db)
            .filter(\.$email == normalizedEmail)
            .first(),
           user.statusEnum == .active
        {
            let expiresIn = try await issuePasswordResetChallenge(
                for: user,
                email: normalizedEmail,
                clientIPAddress: clientIPAddress,
                userAgent: userAgent
            )
            await audit(
                eventType: "password_reset_requested",
                user: user,
                email: normalizedEmail,
                sessionID: nil,
                deviceID: nil,
                ipAddress: clientIPAddress,
                succeeded: true,
                failureReason: nil
            )
            return AuthChallengeResponse(
                email: normalizedEmail,
                expiresIn: expiresIn,
                message: "如果账号存在，重置验证码会发送到该邮箱。"
            )
        }

        return AuthChallengeResponse(
            email: normalizedEmail,
            expiresIn: Int(securityConfig.passwordResetCodeTTL),
            message: "如果账号存在，重置验证码会发送到该邮箱。"
        )
    }

    func confirmPasswordReset(
        request: PasswordResetConfirmRequest,
        clientIPAddress: String?
    ) async throws -> AuthGenericResponse {
        let normalizedEmail = User.normalize(request.email)
        try await app.authLoginRateLimiter.checkVerificationConfirmAttempt(
            ipAddress: clientIPAddress,
            account: normalizedEmail,
            now: now
        )
        try PasswordPolicy.validate(password: request.newPassword, email: normalizedEmail)

        guard let challenge = try await AuthPasswordResetChallenge.query(on: db)
            .filter(\.$email == normalizedEmail)
            .filter(\.$consumedAt == nil)
            .sort(\.$createdAt, .descending)
            .first(),
            let user = try await User.find(challenge.$user.id, on: db)
        else {
            throw AuthError.passwordResetFailed
        }

        try await validate(challenge: challenge, code: request.code)
        let newPasswordHash = try Bcrypt.hash(request.newPassword)
        let revokedSessionIDs = try await db.transaction { transaction in
            challenge.consumedAt = now
            user.passwordHash = newPasswordHash
            try await challenge.update(on: transaction)
            try await user.update(on: transaction)
            return try await AuthService(app: app, db: transaction)
                .revokeAllActiveSessions(
                    for: try user.requireID(),
                    at: now,
                    reason: .passwordReset
                )
        }

        await app.authSessionValidationCache.invalidate(userID: try user.requireID())
        for sessionID in revokedSessionIDs {
            await kickRevokedSession(
                sessionID: sessionID,
                reason: .sessionRevoked,
                message: "Your password was reset. Please sign in again."
            )
        }
        await audit(
            eventType: "password_reset_completed",
            user: user,
            email: normalizedEmail,
            sessionID: nil,
            deviceID: nil,
            ipAddress: clientIPAddress,
            succeeded: true,
            failureReason: nil
        )
        return AuthGenericResponse(message: "密码已重置，请使用新密码登录。")
    }

    func authenticateAccessToken(_ token: String) async throws -> (User, SessionContext) {
        let payload = try await app.jwtKeys.verify(token, as: AccessTokenPayload.self)
        try validate(payload: payload, tokenKind: .access)

        let principal = try await app.authSessionValidationCache.principal(
            sessionID: payload.sid,
            userID: payload.sub,
            loadFromDatabase: {
                try await loadAuthenticatedPrincipal(
                    sessionID: payload.sid,
                    userID: payload.sub,
                    shouldRevokeExpired: true
                )
            }
        )

        return (
            principal.makeUserSnapshot(),
            principal.sessionContext
        )
    }

    func validateActiveSession(id sessionID: UUID, userID: UUID) async throws {
        _ = try await app.authSessionValidationCache.principal(
            sessionID: sessionID,
            userID: userID,
            loadFromDatabase: {
                try await loadAuthenticatedPrincipal(
                    sessionID: sessionID,
                    userID: userID,
                    shouldRevokeExpired: true
                )
            }
        )
    }

    func logout(sessionID: UUID) async throws {
        guard let session = try await AuthSession.find(sessionID, on: db) else {
            return
        }

        session.revokedAt = now
        session.revokedReason = AuthSessionRevocationReason.logoutCurrent.rawValue
        try await session.update(on: db)
        await app.authSessionValidationCache.invalidate(sessionID: sessionID)
        await app.gatewaySessionService.kickConnections(
            forSessionID: sessionID,
            reason: .logoutCurrent,
            message: "You have signed out from this device."
        )
    }

    func logout(sessionID: UUID, for userID: UUID) async throws {
        guard let session = try await AuthSession.find(sessionID, on: db),
              session.$user.id == userID
        else {
            throw AuthError.sessionNotFound
        }

        session.revokedAt = now
        session.revokedReason = AuthSessionRevocationReason.sessionRevoked.rawValue
        try await session.update(on: db)
        await app.authSessionValidationCache.invalidate(sessionID: sessionID)
        await app.gatewaySessionService.kickConnections(
            forSessionID: sessionID,
            reason: .sessionRevoked,
            message: "This session has been revoked."
        )
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
            .set(\.$revokedReason, to: AuthSessionRevocationReason.logoutAll.rawValue)
            .update()

        await app.authSessionValidationCache.invalidate(userID: userID)
        await app.gatewaySessionService.kickConnections(
            forUserID: userID,
            reason: .logoutAll,
            message: "You have signed out from all devices."
        )

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
                        at: now,
                        reason: .duplicateDeviceLogin
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
            await app.authSessionValidationCache.store(try AuthenticatedPrincipal(user: user, session: session))
            for revokedSessionID in revokedSessionIDs {
                await app.authSessionValidationCache.invalidate(sessionID: revokedSessionID)
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

            let response = try await makeAuthResponse(for: user, session: existingSession, now: now)
            await app.authSessionValidationCache.store(try AuthenticatedPrincipal(user: user, session: existingSession))
            return response
        }
    }

    private func revokeActiveSessions(
        for userID: UUID,
        deviceID: String,
        at revokedAt: Date,
        reason: AuthSessionRevocationReason
    ) async throws -> [UUID] {
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
            .set(\.$revokedReason, to: reason.rawValue)
            .update()
        return revokedSessionIDs
    }

    private func revokeAllActiveSessions(
        for userID: UUID,
        at revokedAt: Date,
        reason: AuthSessionRevocationReason
    ) async throws -> [UUID] {
        let activeSessions = try await AuthSession.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$revokedAt == nil)
            .all()
        let revokedSessionIDs = activeSessions.compactMap(\.id)
        guard !revokedSessionIDs.isEmpty else {
            return []
        }

        try await AuthSession.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$revokedAt == nil)
            .set(\.$revokedAt, to: revokedAt)
            .set(\.$revokedReason, to: reason.rawValue)
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
            ),
            kid: config.activeJWTKeyID.map { JWKIdentifier(string: $0) }
        )

        let refreshToken = try await app.jwtKeys.sign(
            RefreshTokenPayload(
                sub: try user.requireID(),
                sid: try session.requireID(),
                nonce: session.currentNonce,
                iss: config.issuer,
                exp: session.refreshExpiresAt.unixTimestamp,
                typ: .refresh
            ),
            kid: config.activeJWTKeyID.map { JWKIdentifier(string: $0) }
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

    private func loadAuthenticatedPrincipal(
        sessionID: UUID,
        userID: UUID,
        shouldRevokeExpired: Bool
    ) async throws -> AuthenticatedPrincipal {
        let session = try await requireActiveSession(
            id: sessionID,
            userID: userID,
            shouldRevokeExpired: shouldRevokeExpired
        )
        let user = try await requireActiveUser(id: userID)
        return try AuthenticatedPrincipal(user: user, session: session)
    }

    private func requireActiveSession(id sessionID: UUID, userID: UUID, shouldRevokeExpired: Bool) async throws -> AuthSession {
        guard let session = try await AuthSession.find(sessionID, on: db),
              session.$user.id == userID
        else {
            throw AuthError.invalidToken
        }

        if session.revokedAt != nil {
            await kickRevokedSession(
                sessionID: sessionID,
                reason: .sessionRevoked,
                message: "Current login is invalid. Please sign in again."
            )
            throw AuthError.sessionRevoked
        }

        if session.refreshExpiresAt <= now {
            if shouldRevokeExpired {
                session.revokedAt = now
                session.revokedReason = AuthSessionRevocationReason.sessionRevoked.rawValue
                try await session.update(on: db)
                await app.authSessionValidationCache.invalidate(sessionID: sessionID)
                await kickRevokedSession(
                    sessionID: sessionID,
                    reason: .sessionRevoked,
                    message: "Current login is invalid. Please sign in again."
                )
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

    private func kickRevokedSession(sessionID: UUID, reason: IMTCPKickReason, message: String) async {
        await app.gatewaySessionService.kickConnections(
            forSessionID: sessionID,
            reason: reason,
            message: message
        )
    }

    private func issueEmailVerificationChallenge(
        for user: User,
        email: String,
        clientIPAddress: String?,
        userAgent: String?
    ) async throws -> Int {
        let code = TokenValueGenerator.makeNumericCode()
        let expiresIn = Int(securityConfig.verificationCodeTTL)
        let challenge = try AuthEmailVerificationChallenge(
            userID: user.requireID(),
            email: email,
            codeHash: TokenValueGenerator.hash(code),
            expiresAt: now.addingTimeInterval(securityConfig.verificationCodeTTL),
            createdIP: clientIPAddress,
            createdUserAgent: userAgent?.nilIfBlank
        )
        try await challenge.create(on: db)
        try await app.authEmailSender.sendEmailVerificationCode(
            email: email,
            code: code,
            expiresIn: securityConfig.verificationCodeTTL
        )
        return expiresIn
    }

    private func issuePasswordResetChallenge(
        for user: User,
        email: String,
        clientIPAddress: String?,
        userAgent: String?
    ) async throws -> Int {
        let code = TokenValueGenerator.makeNumericCode(digits: 8)
        let expiresIn = Int(securityConfig.passwordResetCodeTTL)
        let challenge = try AuthPasswordResetChallenge(
            userID: user.requireID(),
            email: email,
            codeHash: TokenValueGenerator.hash(code),
            expiresAt: now.addingTimeInterval(securityConfig.passwordResetCodeTTL),
            createdIP: clientIPAddress,
            createdUserAgent: userAgent?.nilIfBlank
        )
        try await challenge.create(on: db)
        try await app.authEmailSender.sendPasswordResetCode(
            email: email,
            code: code,
            expiresIn: securityConfig.passwordResetCodeTTL
        )
        return expiresIn
    }

    private func validate(challenge: AuthEmailVerificationChallenge, code: String) async throws {
        try await validateChallenge(
            expiresAt: challenge.expiresAt,
            attemptCount: challenge.attemptCount,
            expectedHash: challenge.codeHash,
            code: code,
            incrementAttempt: {
                challenge.attemptCount += 1
                try await challenge.update(on: db)
            }
        )
    }

    private func validate(challenge: AuthPasswordResetChallenge, code: String) async throws {
        try await validateChallenge(
            expiresAt: challenge.expiresAt,
            attemptCount: challenge.attemptCount,
            expectedHash: challenge.codeHash,
            code: code,
            incrementAttempt: {
                challenge.attemptCount += 1
                try await challenge.update(on: db)
            }
        )
    }

    private func validateChallenge(
        expiresAt: Date,
        attemptCount: Int,
        expectedHash: String,
        code: String,
        incrementAttempt: () async throws -> Void
    ) async throws {
        guard expiresAt > now else {
            throw AuthError.verificationCodeExpired
        }

        guard attemptCount < securityConfig.verificationAttemptLimit else {
            throw AuthError.invalidVerificationCode
        }

        guard TokenValueGenerator.hash(code.normalizedCode) == expectedHash else {
            try await incrementAttempt()
            throw AuthError.invalidVerificationCode
        }
    }

    private func audit(
        eventType: String,
        user: User?,
        email: String?,
        sessionID: UUID?,
        deviceID: String?,
        ipAddress: String?,
        succeeded: Bool,
        failureReason: String?
    ) async {
        let userID: UUID?
        if let user {
            userID = try? user.requireID()
        } else {
            userID = nil
        }
        let event = AuthSecurityEvent(
            eventType: eventType,
            userID: userID,
            email: email,
            sessionID: sessionID,
            deviceID: deviceID,
            ipAddress: ipAddress,
            succeeded: succeeded,
            failureReason: failureReason
        )
        do {
            try await event.create(on: db)
        } catch {
            app.logger.warning("Failed to persist auth security event", metadata: ["error": "\(error)"])
        }
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

    static func makeNumericCode(digits: Int = 6) -> String {
        let lower = Int(pow(10.0, Double(max(1, digits - 1))))
        let upper = Int(pow(10.0, Double(max(1, digits)))) - 1
        return String(Int.random(in: lower...upper))
    }

    static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum PasswordPolicy {
    static func validate(password: String, email: String) throws {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else {
            throw AuthError.weakPassword
        }

        let lowercased = trimmed.lowercased()
        let blocked = ["password", "1234567890", "qwerty12345"]
        guard !blocked.contains(lowercased) else {
            throw AuthError.weakPassword
        }

        if let localPart = email.split(separator: "@").first,
           localPart.count >= 3,
           lowercased.contains(localPart.lowercased())
        {
            throw AuthError.weakPassword
        }
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

    var normalizedCode: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
