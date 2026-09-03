import Foundation
import IMV2Core
import IMV2Server
import Vapor

/// `POST /v2/account-auth/password/*` is deliberately a fallback surface.
/// Both endpoints bind the returned assertion to the requested device, use
/// `no-store`, and run bcrypt through Vapor's configured worker pool.
public struct V2PasswordAccountRoutes: Sendable {
    private let store: any V2PasswordAccountStoring
    private let assertionIssuer: V2HMACAccountAssertionIssuer
    private let dummyPasswordHash: String
    private let loginAttemptLimiter: any V2PasswordLoginAttemptLimiting

    /// `dummyPasswordHash` must be a valid bcrypt digest at the same cost as
    /// the configured application password hasher. It equalizes unknown-handle
    /// and wrong-password work without treating a missing account as success.
    public init(
        store: any V2PasswordAccountStoring,
        assertionIssuer: V2HMACAccountAssertionIssuer,
        dummyPasswordHash: String,
        loginAttemptLimiter: any V2PasswordLoginAttemptLimiting
    ) {
        self.store = store
        self.assertionIssuer = assertionIssuer
        self.dummyPasswordHash = dummyPasswordHash
        self.loginAttemptLimiter = loginAttemptLimiter
    }

    public func register(on routes: RoutesBuilder) {
        routes.post("v2", "account-auth", "password", "register") { request async throws -> Response in
            let input = try request.content.decode(V2PasswordAccountHTTPRequest.self)
            let deviceID = try parsedDeviceID(input.deviceID)
            do {
                try validatePassword(input.password)
                let registration = try validateRegistration(input)
                let passwordHash = try await request.password.async.hash(input.password).get()
                let userID = try await store.register(
                    accountHandle: registration.accountHandle,
                    passwordHash: passwordHash,
                    publicHandle: registration.publicHandle,
                    displayName: registration.displayName,
                    deviceID: deviceID
                )
                return try noStoreJSONResponse(.init(accountAssertion: try assertionIssuer.issue(userID: userID, deviceID: deviceID)))
            } catch V2PasswordAccountStoreError.accountAlreadyExists {
                throw Abort(.conflict)
            } catch V2PasswordAccountStoreError.publicHandleAlreadyExists {
                throw Abort(.conflict)
            } catch V2PasswordAccountStoreError.invalidAccountHandle {
                throw Abort(.badRequest)
            } catch V2PasswordAccountStoreError.invalidPublicIdentity {
                throw Abort(.badRequest)
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
            let input = try request.content.decode(V2PasswordAccountHTTPRequest.self)
            let deviceID = try parsedDeviceID(input.deviceID)
            do {
                try validatePassword(input.password)
                _ = try canonicalAccountHandle(input.accountHandle)
                if let retryAfter = try await loginAttemptLimiter.blockedRetryAfterSeconds(accountHandle: input.accountHandle) {
                    return noStoreRetryAfterResponse(seconds: retryAfter)
                }
                let credential = try await store.passwordCredential(for: input.accountHandle)
                let candidateHash = credential?.passwordHash ?? dummyPasswordHash
                let matches = try await request.password.async.verify(input.password, created: candidateHash).get()
                guard let credential, matches else {
                    try await loginAttemptLimiter.recordRejectedAttempt(
                        accountHandle: input.accountHandle,
                        userID: credential?.userID,
                        deviceID: deviceID
                    )
                    throw V2PasswordRouteError.rejected
                }
                try await loginAttemptLimiter.recordSuccessfulAttempt(
                    accountHandle: input.accountHandle,
                    userID: credential.userID,
                    deviceID: deviceID
                )
                return try noStoreJSONResponse(.init(accountAssertion: try assertionIssuer.issue(userID: credential.userID, deviceID: deviceID)))
            } catch V2PasswordRouteError.rejected {
                throw Abort(.unauthorized)
            } catch V2PasswordAccountStoreError.invalidAccountHandle {
                throw Abort(.badRequest)
            } catch V2PasswordRouteError.invalidPassword {
                throw Abort(.badRequest)
            } catch {
                throw Abort(.serviceUnavailable)
            }
        }
    }

    private func parsedDeviceID(_ value: String) throws -> DeviceID {
        guard let deviceID = try? DeviceID(value) else { throw Abort(.badRequest) }
        return deviceID
    }

    private func validatePassword(_ password: String) throws {
        guard password.utf8.count >= 12, password.utf8.count <= 1_024 else { throw V2PasswordRouteError.invalidPassword }
    }

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

    private func noStoreJSONResponse(_ response: V2AccountAssertionHTTPResponse) throws -> Response {
        let data = try JSONEncoder().encode(response)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }

    private func noStoreRetryAfterResponse(seconds: Int) -> Response {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        headers.replaceOrAdd(name: "Retry-After", value: String(seconds))
        return .init(status: .tooManyRequests, headers: headers)
    }
}

public struct V2PasswordAccountHTTPRequest: Content, Sendable {
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
    public let accountAssertion: String
}

private enum V2PasswordRouteError: Error { case invalidPassword, rejected }
