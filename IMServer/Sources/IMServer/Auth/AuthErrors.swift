import Vapor

enum AuthError: AbortError {
    case invalidCredentials
    case invalidRegistration
    case invalidToken
    case expiredToken
    case invalidTokenType
    case sessionRevoked
    case sessionExpired
    case refreshTokenReuseDetected
    case userDisabled
    case weakPassword
    case sessionNotFound
    case emailVerificationRequired
    case invalidVerificationCode
    case verificationCodeExpired
    case passwordResetFailed

    var status: HTTPResponseStatus {
        switch self {
        case .invalidRegistration, .weakPassword, .invalidVerificationCode, .verificationCodeExpired, .passwordResetFailed:
            return .badRequest
        case .emailVerificationRequired:
            return .forbidden
        case .sessionNotFound:
            return .notFound
        default:
            return .unauthorized
        }
    }

    var reason: String {
        switch self {
        case .invalidCredentials:
            return "邮箱或密码错误。"
        case .invalidRegistration:
            return "注册信息无效。"
        case .invalidToken:
            return "令牌无效。"
        case .expiredToken:
            return "令牌已过期。"
        case .invalidTokenType:
            return "令牌类型无效。"
        case .sessionRevoked:
            return "当前会话已失效。"
        case .sessionExpired:
            return "当前会话已过期。"
        case .refreshTokenReuseDetected:
            return "检测到刷新令牌重复使用。"
        case .userDisabled:
            return "账号已被禁用。"
        case .weakPassword:
            return "密码长度至少需要 10 位。"
        case .sessionNotFound:
            return "设备会话不存在。"
        case .emailVerificationRequired:
            return "邮箱尚未验证，请先完成邮箱验证。"
        case .invalidVerificationCode:
            return "验证码无效。"
        case .verificationCodeExpired:
            return "验证码已过期，请重新获取。"
        case .passwordResetFailed:
            return "密码重置失败，请重新获取验证码。"
        }
    }
}
