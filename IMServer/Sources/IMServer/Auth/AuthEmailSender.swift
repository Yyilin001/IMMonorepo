import Vapor

protocol AuthEmailSending: Sendable {
    func sendEmailVerificationCode(email: String, code: String, expiresIn: TimeInterval) async throws
    func sendPasswordResetCode(email: String, code: String, expiresIn: TimeInterval) async throws
}

struct LoggingAuthEmailSender: AuthEmailSending {
    let logger: Logger

    func sendEmailVerificationCode(email: String, code: String, expiresIn: TimeInterval) async throws {
        logger.notice(
            "Auth email verification code issued",
            metadata: [
                "email": "\(email)",
                "code": "\(code)",
                "expires_in": "\(Int(expiresIn))"
            ]
        )
    }

    func sendPasswordResetCode(email: String, code: String, expiresIn: TimeInterval) async throws {
        logger.notice(
            "Auth password reset code issued",
            metadata: [
                "email": "\(email)",
                "code": "\(code)",
                "expires_in": "\(Int(expiresIn))"
            ]
        )
    }
}

final class WebhookAuthEmailSender: AuthEmailSending, @unchecked Sendable {
    private let app: Application
    private let url: URI
    private let secret: String?

    init(app: Application, url: String, secret: String?) {
        self.app = app
        self.url = URI(string: url)
        self.secret = secret
    }

    func sendEmailVerificationCode(email: String, code: String, expiresIn: TimeInterval) async throws {
        try await send(
            AuthEmailWebhookPayload(
                type: "email_verification",
                email: email,
                code: code,
                expiresIn: Int(expiresIn)
            )
        )
    }

    func sendPasswordResetCode(email: String, code: String, expiresIn: TimeInterval) async throws {
        try await send(
            AuthEmailWebhookPayload(
                type: "password_reset",
                email: email,
                code: code,
                expiresIn: Int(expiresIn)
            )
        )
    }

    private func send(_ payload: AuthEmailWebhookPayload) async throws {
        let response = try await app.client.post(url) { request in
            if let secret {
                request.headers.replaceOrAdd(name: "X-IMApp-Auth-Email-Secret", value: secret)
            }
            try request.content.encode(payload)
        }

        guard 200..<300 ~= response.status.code else {
            throw Abort(.badGateway, reason: "认证邮件发送失败。")
        }
    }
}

struct AuthEmailWebhookPayload: Content {
    let type: String
    let email: String
    let code: String
    let expiresIn: Int
}

enum AuthEmailSenderFactory {
    static func make(app: Application, configuration: AuthSecurityConfiguration) throws -> any AuthEmailSending {
        switch configuration.emailDeliveryMode {
        case .log:
            return LoggingAuthEmailSender(logger: app.logger)
        case .webhook:
            guard let url = configuration.emailWebhookURL else {
                if app.environment == .production {
                    throw Abort(.internalServerError, reason: "生产环境必须配置 AUTH_EMAIL_WEBHOOK_URL。")
                }
                app.logger.warning("AUTH_EMAIL_WEBHOOK_URL missing; falling back to log auth email sender")
                return LoggingAuthEmailSender(logger: app.logger)
            }
            return WebhookAuthEmailSender(app: app, url: url, secret: configuration.emailWebhookSecret)
        }
    }
}

private struct AuthEmailSenderStorageKey: StorageKey {
    typealias Value = any AuthEmailSending
}

extension Application {
    var authEmailSender: any AuthEmailSending {
        get {
            guard let sender = storage[AuthEmailSenderStorageKey.self] else {
                preconditionFailure("AuthEmailSender not configured")
            }
            return sender
        }
        set {
            storage[AuthEmailSenderStorageKey.self] = newValue
        }
    }
}
