import JWTKit
import Vapor

enum TokenKind: String, Codable {
    case access
    case refresh
}

// access token 只承载接口鉴权必需信息，保持短生命周期。
struct AccessTokenPayload: JWTPayload {
    let sub: UUID
    let sid: UUID
    let email: String
    let iss: String
    let exp: Int
    let typ: TokenKind

    func verify(using _: some JWTAlgorithm) throws {
        guard exp > Date().unixTimestamp else {
            throw AuthError.expiredToken
        }
    }
}

// refresh token 额外带 nonce，用于服务端 rotation 和 reuse detection。
struct RefreshTokenPayload: JWTPayload {
    let sub: UUID
    let sid: UUID
    let nonce: String
    let iss: String
    let exp: Int
    let typ: TokenKind

    func verify(using _: some JWTAlgorithm) throws {
        guard exp > Date().unixTimestamp else {
            throw AuthError.expiredToken
        }
    }
}

// 受保护接口除了拿到用户身份，还要知道当前 session，便于“退出当前设备”等操作。
struct SessionContext: Authenticatable, Sendable {
    let userID: UUID
    let sessionID: UUID
    let deviceID: String?
}
