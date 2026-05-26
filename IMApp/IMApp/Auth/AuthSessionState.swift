import Foundation
import IMClientKit

enum AuthAvailability: Equatable {
    case online
    case offline(message: String)
}

enum AuthRouteState: Equatable {
    case launching
    case signedOut(AuthNotice?)
    case signedIn(AuthUser, availability: AuthAvailability)
}

enum AuthSubmissionKind: Equatable {
    case login
    case register
}

enum AuthOperationState: Equatable {
    case idle
    case authenticating(AuthSubmissionKind)
    case restoring
    case signingOut
    case verifyingEmail
    case resettingPassword
    case loadingSessions
    case updatingProfile

    var isBusy: Bool {
        self != .idle
    }
}

enum AuthNoticeSeverity: Equatable {
    case info
    case warning
    case error
}

enum AuthNoticeCode: Equatable {
    case invalidCredentials
    case weakPassword
    case rateLimited
    case offline
    case serverUnavailable
    case sessionExpired
    case sessionRevoked
    case refreshTokenReuseDetected
    case emailVerificationRequired
    case verificationCodeInvalid
    case verificationCodeExpired
    case passwordResetCompleted
    case forbidden
    case unknown
}

struct AuthNotice: Equatable {
    let code: AuthNoticeCode
    let message: String
    let severity: AuthNoticeSeverity
    let isRecoverable: Bool
}

enum AuthClientErrorMapper {
    static func notice(for error: Error) -> AuthNotice {
        if let apiError = error as? APIError {
            return notice(for: apiError)
        }

        if let keychainError = error as? KeychainError {
            return AuthNotice(
                code: .unknown,
                message: keychainError.localizedDescription,
                severity: .error,
                isRecoverable: false
            )
        }

        if let tcpError = error as? IMTCPClientError {
            return notice(for: tcpError)
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                return AuthNotice(
                    code: .offline,
                    message: "当前无法连接服务器。",
                    severity: .warning,
                    isRecoverable: true
                )
            default:
                break
            }
        }

        return AuthNotice(
            code: .unknown,
            message: error.localizedDescription,
            severity: .error,
            isRecoverable: false
        )
    }

    static func notice(forMessage message: String?) -> AuthNotice? {
        guard let message, !message.isEmpty else {
            return nil
        }

        let code = code(for: message)
        return AuthNotice(
            code: code,
            message: message,
            severity: severity(for: code),
            isRecoverable: isRecoverable(code: code)
        )
    }

    private static func notice(for apiError: APIError) -> AuthNotice {
        let code: AuthNoticeCode
        switch apiError {
        case .unauthorized(let reason):
            code = self.code(for: reason ?? apiError.localizedDescription)
        case .forbidden:
            code = .forbidden
        case .validationFailed(let message):
            code = self.code(for: message)
        case .rateLimited:
            code = .rateLimited
        case .emailVerificationRequired:
            code = .emailVerificationRequired
        case .verificationCodeInvalid:
            code = .verificationCodeInvalid
        case .verificationCodeExpired:
            code = .verificationCodeExpired
        case .passwordPolicyFailed:
            code = .weakPassword
        case .server:
            code = .serverUnavailable
        case .timeout, .connectivity:
            code = .offline
        default:
            code = .unknown
        }

        return AuthNotice(
            code: code,
            message: apiError.localizedDescription,
            severity: severity(for: code),
            isRecoverable: isRecoverable(code: code)
        )
    }

    private static func notice(for tcpError: IMTCPClientError) -> AuthNotice {
        switch tcpError {
        case .authRejected(let code, let message):
            return AuthNotice(
                code: self.code(for: "\(code) \(message)"),
                message: message,
                severity: .error,
                isRecoverable: false
            )
        case .kicked(let reason, let message):
            let noticeCode: AuthNoticeCode
            switch reason {
            case .sessionRevoked, .logoutCurrent, .logoutAll:
                noticeCode = .sessionRevoked
            case .duplicateConnection, .serverShutdown, .protocolError:
                noticeCode = .unknown
            }
            return AuthNotice(
                code: noticeCode,
                message: message,
                severity: .error,
                isRecoverable: false
            )
        default:
            return AuthNotice(
                code: .unknown,
                message: tcpError.localizedDescription,
                severity: .error,
                isRecoverable: false
            )
        }
    }

    private static func code(for message: String) -> AuthNoticeCode {
        if message.contains("密码长度至少") || message.localizedCaseInsensitiveContains("weak") {
            return .weakPassword
        }
        if message.contains("邮箱尚未验证") || message.localizedCaseInsensitiveContains("verification required") {
            return .emailVerificationRequired
        }
        if message.contains("验证码无效") {
            return .verificationCodeInvalid
        }
        if message.contains("验证码已过期") {
            return .verificationCodeExpired
        }
        if message.contains("密码已重置") {
            return .passwordResetCompleted
        }
        if message.contains("邮箱或密码错误") || message.localizedCaseInsensitiveContains("invalid credentials") {
            return .invalidCredentials
        }
        if message.contains("请求过于频繁") || message.localizedCaseInsensitiveContains("rate") {
            return .rateLimited
        }
        if message.contains("无法连接服务器") || message.localizedCaseInsensitiveContains("offline") {
            return .offline
        }
        if message.contains("服务器暂不可用") || message.localizedCaseInsensitiveContains("server unavailable") {
            return .serverUnavailable
        }
        if message.contains("会话已过期") || message.localizedCaseInsensitiveContains("session expired") {
            return .sessionExpired
        }
        if message.contains("会话已失效")
            || message.contains("登录已失效")
            || message.contains("设备已被撤销")
            || message.localizedCaseInsensitiveContains("revoked") {
            return .sessionRevoked
        }
        if message.contains("刷新令牌重复")
            || message.localizedCaseInsensitiveContains("reuse")
            || message.localizedCaseInsensitiveContains("replay") {
            return .refreshTokenReuseDetected
        }
        return .unknown
    }

    private static func severity(for code: AuthNoticeCode) -> AuthNoticeSeverity {
        switch code {
        case .offline, .serverUnavailable, .rateLimited:
            return .warning
        case .passwordResetCompleted:
            return .info
        default:
            return .error
        }
    }

    private static func isRecoverable(code: AuthNoticeCode) -> Bool {
        switch code {
        case .offline, .serverUnavailable, .rateLimited, .emailVerificationRequired, .verificationCodeInvalid,
             .verificationCodeExpired:
            return true
        default:
            return false
        }
    }
}
