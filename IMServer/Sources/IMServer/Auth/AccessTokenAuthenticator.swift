import Fluent
import Vapor

// 每个受保护请求都会先走这里：验证 access token，再把 User 和 SessionContext 塞进 req.auth。
struct AccessTokenAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for req: Request) async throws {
        do {
            let (user, sessionContext) = try await AuthService(app: req.application, db: req.db)
                .authenticateAccessToken(bearer.token)
            req.auth.login(user)
            req.auth.login(sessionContext)
        } catch {
            req.logger.debug(
                "Access token authentication failed",
                metadata: ["error": .string(String(describing: error))]
            )
            return
        }
    }
}
