@testable import IMServer
import Fluent
import Foundation
import JWTKit
import Vapor
import VaporTesting
import Testing

extension IMServerTests {
    @Test("Email verification gates new production-style registrations")
    func emailVerificationGatesNewRegistrations() async throws {
        try await withApp(configure: configure) { app in
            enableEmailVerification(on: app)

            let email = "verify-new@example.com"
            let password = "verified12345"
            try await app.testing().test(.POST, "api/auth/register", beforeRequest: { req in
                try req.content.encode(
                    RegisterRequest(
                        email: email,
                        password: password,
                        device: DeviceMetadata(
                            deviceID: "verify-device",
                            deviceName: "Verify Device",
                            platform: "iOS",
                            appVersion: "1.0"
                        )
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(RegisterResponse.self)
                #expect(body.state == .verificationRequired)
                #expect(body.auth?.accessToken == nil)
                #expect(body.email == email)
            })

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(LoginRequest(email: email, password: password, device: nil))
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("邮箱尚未验证"))
            })

            try await setEmailVerificationCode("123456", for: email, on: app)
            try await app.testing().test(.POST, "api/auth/email-verifications/confirm", beforeRequest: { req in
                try req.content.encode(EmailVerificationConfirmRequest(email: email, code: "000000"))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("验证码无效"))
            })

            try await app.testing().test(.POST, "api/auth/email-verifications/confirm", beforeRequest: { req in
                try req.content.encode(EmailVerificationConfirmRequest(email: email, code: "123456"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(LoginRequest(email: email, password: password, device: nil))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(AuthResponse.self)
                #expect(body.user.email == email)
            })

            let completedEvent = try await AuthSecurityEvent.query(on: app.db)
                .filter(\.$email == email)
                .filter(\.$eventType == "email_verification_completed")
                .first()
            #expect(completedEvent?.succeeded == true)
        }
    }

    @Test("Password reset is generic and revokes existing sessions")
    func passwordResetRevokesExistingSessions() async throws {
        try await withApp(configure: configure) { app in
            var oldAccessToken = ""
            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(
                    LoginRequest(
                        email: "demo@example.com",
                        password: "password1234",
                        device: DeviceMetadata(
                            deviceID: "reset-device",
                            deviceName: "Reset Device",
                            platform: "iOS",
                            appVersion: "1.0"
                        )
                    )
                )
            }, afterResponse: { res async throws in
                oldAccessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            try await app.testing().test(.POST, "api/auth/password-resets/request", beforeRequest: { req in
                try req.content.encode(PasswordResetRequest(email: "missing-reset@example.com"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("如果账号存在"))
            })

            try await app.testing().test(.POST, "api/auth/password-resets/request", beforeRequest: { req in
                try req.content.encode(PasswordResetRequest(email: "demo@example.com"))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("如果账号存在"))
            })

            try await setPasswordResetCode("87654321", for: "demo@example.com", on: app)
            try await app.testing().test(.POST, "api/auth/password-resets/confirm", beforeRequest: { req in
                try req.content.encode(
                    PasswordResetConfirmRequest(
                        email: "demo@example.com",
                        code: "87654321",
                        newPassword: "changed12345"
                    )
                )
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(LoginRequest(email: "demo@example.com", password: "password1234", device: nil))
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(LoginRequest(email: "demo@example.com", password: "changed12345", device: nil))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: oldAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            let oldSession = try await session(for: "demo@example.com", deviceID: "reset-device", on: app)
            #expect(oldSession.revokedReason == AuthSessionRevocationReason.passwordReset.rawValue)
        }
    }

    @Test("Refresh token reuse revokes only the reused session")
    func refreshReuseRevokesOnlyCurrentSession() async throws {
        try await withApp(configure: configure) { app in
            var primaryTokens: AuthResponse?
            var secondaryAccessToken = ""

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(
                    LoginRequest(
                        email: "demo@example.com",
                        password: "password1234",
                        device: DeviceMetadata(
                            deviceID: "reuse-primary",
                            deviceName: "Primary",
                            platform: "iOS",
                            appVersion: "1.0"
                        )
                    )
                )
            }, afterResponse: { res async throws in
                primaryTokens = try res.content.decode(AuthResponse.self)
            })

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(
                    LoginRequest(
                        email: "demo@example.com",
                        password: "password1234",
                        device: DeviceMetadata(
                            deviceID: "reuse-secondary",
                            deviceName: "Secondary",
                            platform: "iOS",
                            appVersion: "1.0"
                        )
                    )
                )
            }, afterResponse: { res async throws in
                secondaryAccessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            guard let primaryTokens else {
                Issue.record("Missing primary auth response")
                return
            }

            try await app.testing().test(.POST, "api/auth/refresh", beforeRequest: { req in
                try req.content.encode(RefreshRequest(refreshToken: primaryTokens.refreshToken))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            let primarySession = try await session(for: "demo@example.com", deviceID: "reuse-primary", on: app)
            primarySession.previousValidUntil = Date().addingTimeInterval(-1)
            try await primarySession.update(on: app.db)

            try await app.testing().test(.POST, "api/auth/refresh", beforeRequest: { req in
                try req.content.encode(RefreshRequest(refreshToken: primaryTokens.refreshToken))
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
                #expect(res.body.string.contains("重复使用"))
            })

            let revokedPrimary = try await session(for: "demo@example.com", deviceID: "reuse-primary", on: app)
            #expect(revokedPrimary.revokedReason == AuthSessionRevocationReason.refreshTokenReuse.rawValue)

            let secondarySession = try await session(for: "demo@example.com", deviceID: "reuse-secondary", on: app)
            #expect(secondarySession.revokedAt == nil)

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: secondaryAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("JWT keyring signs with active kid and verifies old kid")
    func jwtKeyringSignsWithActiveKidAndVerifiesOldKid() async throws {
        let originalSecrets = Environment.get("JWT_SECRETS")
        let originalActiveKID = Environment.get("JWT_ACTIVE_KID")
        defer {
            restoreEnvironment("JWT_SECRETS", to: originalSecrets)
            restoreEnvironment("JWT_ACTIVE_KID", to: originalActiveKID)
        }
        setenv("JWT_SECRETS", "old:old-secret-for-tests,active:active-secret-for-tests", 1)
        setenv("JWT_ACTIVE_KID", "active", 1)

        try await withApp(configure: configure) { app in
            var auth: AuthResponse?
            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                auth = try res.content.decode(AuthResponse.self)
            })

            guard let auth else {
                Issue.record("Missing auth response")
                return
            }

            let header = try jwtHeader(auth.accessToken)
            #expect(header["kid"] as? String == "active")

            let payload = try await app.jwtKeys.verify(auth.accessToken, as: AccessTokenPayload.self)
            let oldKeyToken = try await app.jwtKeys.sign(
                payload,
                kid: JWKIdentifier(string: "old")
            )
            let verifiedOldPayload = try await app.jwtKeys.verify(oldKeyToken, as: AccessTokenPayload.self)
            #expect(verifiedOldPayload.sub == payload.sub)
            #expect(verifiedOldPayload.sid == payload.sid)
        }
    }

    private func enableEmailVerification(on app: Application) {
        app.authSecurityConfiguration = AuthSecurityConfiguration(
            rateLimitBackend: .memory,
            redisURL: nil,
            emailVerificationRequired: true,
            verificationCodeTTL: 15 * 60,
            passwordResetCodeTTL: 15 * 60,
            verificationAttemptLimit: 6,
            auditRetentionDays: 90,
            emailDeliveryMode: .log,
            emailWebhookURL: nil,
            emailWebhookSecret: nil
        )
    }

    private func setEmailVerificationCode(_ code: String, for email: String, on app: Application) async throws {
        guard let challenge = try await AuthEmailVerificationChallenge.query(on: app.db)
            .filter(\.$email == User.normalize(email))
            .filter(\.$consumedAt == nil)
            .sort(\.$createdAt, .descending)
            .first()
        else {
            throw AuthSecurityTestFailure.missingEntity("Missing email verification challenge for \(email)")
        }

        challenge.codeHash = TokenValueGenerator.hash(code)
        challenge.expiresAt = Date().addingTimeInterval(15 * 60)
        try await challenge.update(on: app.db)
    }

    private func setPasswordResetCode(_ code: String, for email: String, on app: Application) async throws {
        guard let challenge = try await AuthPasswordResetChallenge.query(on: app.db)
            .filter(\.$email == User.normalize(email))
            .filter(\.$consumedAt == nil)
            .sort(\.$createdAt, .descending)
            .first()
        else {
            throw AuthSecurityTestFailure.missingEntity("Missing password reset challenge for \(email)")
        }

        challenge.codeHash = TokenValueGenerator.hash(code)
        challenge.expiresAt = Date().addingTimeInterval(15 * 60)
        try await challenge.update(on: app.db)
    }

    private func jwtHeader(_ token: String) throws -> [String: Any] {
        guard let firstSegment = token.split(separator: ".").first else {
            throw AuthSecurityTestFailure.missingEntity("Missing JWT header")
        }

        let base64 = String(firstSegment)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = base64.padding(toLength: ((base64.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        guard let data = Data(base64Encoded: padded),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AuthSecurityTestFailure.missingEntity("Invalid JWT header")
        }
        return json
    }
}

private enum AuthSecurityTestFailure: Error {
    case missingEntity(String)
}
