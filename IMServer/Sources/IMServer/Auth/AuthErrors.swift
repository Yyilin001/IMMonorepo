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

    var status: HTTPResponseStatus {
        switch self {
        case .invalidRegistration, .weakPassword:
            return .badRequest
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
            return "密码长度至少需要 8 位。"
        case .sessionNotFound:
            return "设备会话不存在。"
        }
    }
}
