import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

@Suite(.serialized)
struct AuthClientErrorMapperTests {
    @Test func invalidCredentialsMapsToStableNoticeCode() {
        let notice = AuthClientErrorMapper.notice(for: APIError.unauthorized("邮箱或密码错误。"))

        #expect(notice.code == .invalidCredentials)
        #expect(notice.severity == .error)
        #expect(!notice.isRecoverable)
    }

    @Test func revokedAndExpiredSessionReasonsMapSeparately() {
        let revoked = AuthClientErrorMapper.notice(for: APIError.unauthorized("当前登录已失效。"))
        let expired = AuthClientErrorMapper.notice(for: APIError.unauthorized("会话已过期。"))

        #expect(revoked.code == .sessionRevoked)
        #expect(expired.code == .sessionExpired)
    }

    @Test func rateLimitMapsToRecoverableWarning() {
        let notice = AuthClientErrorMapper.notice(for: APIError.rateLimited(
            retryAfter: 30,
            message: "请求过于频繁。"
        ))

        #expect(notice.code == .rateLimited)
        #expect(notice.severity == .warning)
        #expect(notice.isRecoverable)
    }

    @Test func transportFailuresMapToOffline() {
        let connectivity = AuthClientErrorMapper.notice(for: APIError.connectivity(URLError(.notConnectedToInternet)))
        let timeout = AuthClientErrorMapper.notice(for: APIError.timeout)
        let directURLError = AuthClientErrorMapper.notice(for: URLError(.cannotConnectToHost))

        #expect(connectivity.code == .offline)
        #expect(timeout.code == .offline)
        #expect(directURLError.code == .offline)
    }

    @Test func serverFailuresMapToServerUnavailable() {
        let notice = AuthClientErrorMapper.notice(for: APIError.server(
            statusCode: 503,
            message: "服务器暂不可用。"
        ))

        #expect(notice.code == .serverUnavailable)
        #expect(notice.severity == .warning)
        #expect(notice.isRecoverable)
    }

    @Test func validationForbiddenAndRefreshReuseMapToAuthCodes() {
        let weakPassword = AuthClientErrorMapper.notice(for: APIError.validationFailed("密码长度至少 8 位。"))
        let forbidden = AuthClientErrorMapper.notice(for: APIError.forbidden("当前设备已被撤销。"))
        let refreshReuse = AuthClientErrorMapper.notice(for: APIError.unauthorized("刷新令牌重复使用。"))

        #expect(weakPassword.code == .weakPassword)
        #expect(forbidden.code == .forbidden)
        #expect(refreshReuse.code == .refreshTokenReuseDetected)
    }

    @Test func tcpAuthRejectAndKickMapToStableCodes() {
        let rejected = AuthClientErrorMapper.notice(for: IMTCPClientError.authRejected(
            code: "invalid_credentials",
            message: "邮箱或密码错误。"
        ))
        let kicked = AuthClientErrorMapper.notice(for: IMTCPClientError.kicked(
            reason: .sessionRevoked,
            message: "当前登录已失效。"
        ))

        #expect(rejected.code == .invalidCredentials)
        #expect(kicked.code == .sessionRevoked)
    }

    @Test func unknownErrorMapsToUnknownCode() {
        let notice = AuthClientErrorMapper.notice(for: NSError(
            domain: "AuthClientErrorMapperTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "无法识别的认证错误。"]
        ))

        #expect(notice.code == .unknown)
        #expect(notice.severity == .error)
        #expect(!notice.isRecoverable)
    }
}
