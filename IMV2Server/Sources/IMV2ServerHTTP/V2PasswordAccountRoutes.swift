import Foundation
import IMV2Core
import IMV2Server
import Vapor
import HTTPTypes

/// 密码账户认证与注册路由。
///
/// `POST /v2/account-auth/password/register` 与
/// `POST /v2/account-auth/password/assertion` 为降级鉴权路径。
/// 两个接口均将下发断言绑定到请求设备，返回头部使用 `no-store`。
public struct V2PasswordAccountRoutes: Sendable {
    private let store: any V2PasswordAccountStoring
    private let assertionIssuer: V2HMACAccountAssertionIssuer
    private let passwords: any V2PasswordHashing
    private let loginAttemptLimiter: any V2PasswordLoginAttemptLimiting

    /// 初始化。
    public init(
        store: any V2PasswordAccountStoring,
        assertionIssuer: V2HMACAccountAssertionIssuer,
        passwords: any V2PasswordHashing,
        loginAttemptLimiter: any V2PasswordLoginAttemptLimiting
    ) {
        self.store = store
        self.assertionIssuer = assertionIssuer
        self.passwords = passwords
        self.loginAttemptLimiter = loginAttemptLimiter
    }

    /// 挂载密码账号相关路由：
    /// - `POST /v2/account-auth/password/register`：注册密码账号。
    /// - `POST /v2/account-auth/password/assertion`：提交密码断言以换取会话凭据。
    public func register(on routes: RoutesBuilder) {
        routes.post("v2", "account-auth", "password", "register") { request async throws -> Response in
            let input = try await request.content.decode(V2PasswordAccountHTTPRequest.self)
            let deviceID = try parsedDeviceID(input.deviceID)
            do {
                try validatePassword(input.password)
                let registration = try validateRegistration(input)
                let passwordHash = try await passwords.hash(input.password)
                let userID = try await store.register(
                    accountHandle: registration.accountHandle,
                    passwordHash: passwordHash,
                    publicHandle: registration.publicHandle,
                    displayName: registration.displayName,
                    deviceID: deviceID
                )
                return try noStoreJSONResponse(.init(accountAssertion: try assertionIssuer.issue(userID: userID, deviceID: deviceID)))
            } catch V2PasswordAccountStoreError.accountAlreadyExists {
                return try conflictResponse(code: "account_handle_taken")
            } catch V2PasswordAccountStoreError.publicHandleAlreadyExists {
                return try conflictResponse(code: "public_handle_taken")
            } catch V2PasswordAccountStoreError.invalidAccountHandle {
                throw Abort(.badRequest)
            } catch V2PasswordAccountStoreError.invalidPublicIdentity {
                throw Abort(.badRequest)
            } catch V2PasswordHashError.busy {
                return noStoreUnavailableResponse()
            } catch V2PasswordRouteError.invalidPassword {
                throw Abort(.badRequest)
            } catch let abort as Abort {
                // Missing registration fields and other transport validation
                // failures are client errors, never a dependency outage.
                throw abort
            } catch {
                throw Abort(.serviceUnavailable)
            }
        }

        routes.post("v2", "account-auth", "password", "assertion") { request async throws -> Response in
            let input = try await request.content.decode(V2PasswordAccountHTTPRequest.self)
            let deviceID = try parsedDeviceID(input.deviceID)
            do {
                try validatePassword(input.password)
                _ = try canonicalAccountHandle(input.accountHandle)
                if let retryAfter = try await loginAttemptLimiter.consumeAttempt(accountHandle: input.accountHandle) {
                    return noStoreRetryAfterResponse(seconds: retryAfter)
                }
                let credential = try await store.passwordCredential(for: input.accountHandle)
                let candidateHash = credential?.passwordHash ?? V2PasswordHashPolicy.dummyDigest
                let matches = try await passwords.verify(input.password, created: candidateHash)
                guard let credential, matches else {
                    try await loginAttemptLimiter.auditRejectedAttempt(
                        accountHandle: input.accountHandle,
                        userID: credential?.userID,
                        deviceID: deviceID
                    )
                    throw V2PasswordRouteError.rejected
                }
                guard try await store.completeAuthentication(accountHandle: input.accountHandle,
                    expected: credential, deviceID: deviceID) else {
                    throw V2PasswordRouteError.rejected
                }
                return try noStoreJSONResponse(.init(accountAssertion: try assertionIssuer.issue(userID: credential.userID, deviceID: deviceID, credentialRevision: credential.revision)))
            } catch V2PasswordRouteError.rejected {
                throw Abort(.unauthorized)
            } catch V2PasswordAccountStoreError.invalidAccountHandle {
                throw Abort(.badRequest)
            } catch V2PasswordHashError.busy {
                return noStoreUnavailableResponse()
            } catch V2PasswordRouteError.invalidPassword {
                throw Abort(.badRequest)
            } catch {
                throw Abort(.serviceUnavailable)
            }
        }
    }

    /// 解析并校验设备 ID。
    private func parsedDeviceID(_ value: String) throws -> DeviceID {
        guard let deviceID = try? DeviceID(value) else { throw Abort(.badRequest) }
        return deviceID
    }

    /// 校验密码复杂度。
    private func validatePassword(_ password: String) throws {
        guard V2PasswordHashPolicy.accepts(password) else { throw V2PasswordRouteError.invalidPassword }
    }

    /// 验证注册参数并构造公开身份。
    private func validateRegistration(
        _ input: V2PasswordAccountHTTPRequest
    ) throws -> (accountHandle: String, publicHandle: String, displayName: String) {
        let accountHandle = try canonicalAccountHandle(input.accountHandle)
        guard let publicHandle = input.publicHandle,
              let displayName = input.displayName
        else { throw Abort(.badRequest) }
        do {
            let identity = try V2PublicIdentity(
                userID: .init("registration-validation"),
                handle: .init(publicHandle),
                displayName: displayName,
                accountKind: .regular
            )
            return (accountHandle, identity.handle.rawValue, identity.displayName)
        } catch {
            throw V2PasswordAccountStoreError.invalidPublicIdentity
        }
    }

    private func conflictResponse(code: String) throws -> Response {
        let data = try JSONEncoder().encode(["code": code])
        return .init(status: .conflict, headers: [.contentType: "application/json", .cacheControl: "no-store", .v2Pragma: "no-cache"], body: .init(data: data))
    }

    /// 返回 no-store JSON。
    private func noStoreJSONResponse(_ response: V2AccountAssertionHTTPResponse) throws -> Response {
        let data = try JSONEncoder().encode(response)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.cacheControl] = "no-store"
        headers[.v2Pragma] = "no-cache"
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }

    /// 下游忙碌时返回 503（no-store + Retry-After）。
    private func noStoreUnavailableResponse() -> Response {
        var headers = HTTPFields()
        headers[.cacheControl] = "no-store"
        headers[.v2Pragma] = "no-cache"
        headers[.retryAfter] = "1"
        return .init(status: .serviceUnavailable, headers: headers)
    }

    /// 返回限流重试响应。
    private func noStoreRetryAfterResponse(seconds: Int) -> Response {
        var headers = HTTPFields()
        headers[.cacheControl] = "no-store"
        headers[.v2Pragma] = "no-cache"
        headers[.retryAfter] = String(seconds)
        return .init(status: .tooManyRequests, headers: headers)
    }
}

public struct V2PasswordAccountHTTPRequest: Content, Sendable {
    /// 密码接口请求体。
    public let accountHandle: String
    public let password: String
    public let deviceID: String
    public let publicHandle: String?
    public let displayName: String?

    public init(accountHandle: String, password: String, deviceID: String, publicHandle: String? = nil, displayName: String? = nil) {
        self.accountHandle = accountHandle
        self.password = password
        self.deviceID = deviceID
        self.publicHandle = publicHandle
        self.displayName = displayName
    }
}

public struct V2AccountAssertionHTTPResponse: Content, Sendable {
    /// 账户断言返回体。
    public let accountAssertion: String
}

private enum V2PasswordRouteError: Error { case invalidPassword, rejected }
