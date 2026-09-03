import Foundation
import IMV2Core
import IMV2Server
import Vapor

public struct V2DeviceCredentialIssueHTTPRequest: Content, Sendable {
    public let accountAssertion: String
    public let deviceID: String
    public let operationID: UUID
    public let deviceName: String?
    public let platform: String?

    public init(accountAssertion: String, deviceID: String, operationID: UUID, deviceName: String? = nil, platform: String? = nil) {
        self.accountAssertion = accountAssertion
        self.deviceID = deviceID
        self.operationID = operationID
        self.deviceName = deviceName
        self.platform = platform
    }
}

public struct V2DeviceCredentialIssueHTTPResponse: Content, Sendable {
    public let userID: String
    public let deviceID: String
    public let accessToken: String
    public let accessTokenExpiresAtMilliseconds: Int64
    public let refreshCredential: String

    init(credentials: V2IssuedDeviceCredentials) throws {
        let milliseconds = credentials.accessTokenExpiresAt.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds >= Double(Int64.min), milliseconds <= Double(Int64.max) else {
            throw V2DeviceCredentialServiceError.malformedPersistence
        }
        userID = credentials.userID.rawValue
        deviceID = credentials.deviceID.rawValue
        accessToken = credentials.accessToken
        accessTokenExpiresAtMilliseconds = Int64(milliseconds.rounded(.towardZero))
        refreshCredential = credentials.refreshCredential
    }
}

public struct V2DeviceCredentialRefreshHTTPRequest: Content, Sendable {
    public let userID: String
    public let deviceID: String
    public let refreshCredential: String
    public let operationID: UUID

    public init(userID: String, deviceID: String, refreshCredential: String, operationID: UUID) {
        self.userID = userID
        self.deviceID = deviceID
        self.refreshCredential = refreshCredential
        self.operationID = operationID
    }
}

/// Thin `POST /v2/device-credentials` transport adapter. It is intentionally
/// not registered by the realtime gateway composition root; a deployment must
/// provide an approved assertion verifier and mount it on the account-service
/// listener with its own rate limits and TLS policy.
public struct V2VaporDeviceCredentialRoutes: Sendable {
    private let assertionVerifier: any V2DeviceBoundAccountAssertionVerifier
    private let issuer: any V2DeviceCredentialIssuing

    public init(assertionVerifier: any V2DeviceBoundAccountAssertionVerifier, issuer: any V2DeviceCredentialIssuing) {
        self.assertionVerifier = assertionVerifier
        self.issuer = issuer
    }

    public func register(on routes: RoutesBuilder) {
        routes.post("v2", "device-credentials") { request async throws -> Response in
            let input = try request.content.decode(V2DeviceCredentialIssueHTTPRequest.self)
            guard !input.accountAssertion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let deviceID = try? DeviceID(input.deviceID),
                  let metadata = try? V2DeviceRegistrationMetadata.validated(
                      displayName: input.deviceName,
                      platform: input.platform
                  )
            else { throw Abort(.badRequest) }
            let userID: UserID
            do {
                userID = try await assertionVerifier.verifiedUserID(
                    for: input.accountAssertion,
                    deviceID: deviceID
                )
            } catch {
                throw Abort(.unauthorized)
            }
            let outcome: V2DeviceRegistrationOutcome
            do {
                outcome = try await issuer.register(.init(
                    userID: userID,
                    deviceID: deviceID,
                    operationID: input.operationID,
                    metadata: metadata
                ))
            } catch {
                throw Abort(.serviceUnavailable)
            }
            let credentials: V2IssuedDeviceCredentials
            switch outcome {
            case .issued(let value), .idempotent(let value): credentials = value
            case .idempotencyConflict: throw Abort(.conflict)
            case .deviceUnavailable: throw Abort(.forbidden)
            case .activeDeviceLimitReached: throw Abort(.conflict)
            case .rateLimited(let retryAfterSeconds):
                return noStoreRetryAfterResponse(seconds: retryAfterSeconds)
            }
            return try noStoreJSONResponse(.init(credentials: credentials))
        }
        routes.post("v2", "device-credentials", "refresh") { request async throws -> Response in
            let input = try request.content.decode(V2DeviceCredentialRefreshHTTPRequest.self)
            guard let userID = try? UserID(input.userID),
                  let deviceID = try? DeviceID(input.deviceID),
                  let refresh = try? V2DeviceCredentialRefresh(userID: userID, deviceID: deviceID, refreshCredential: input.refreshCredential, operationID: input.operationID)
            else { throw Abort(.badRequest) }
            let outcome: V2DeviceCredentialRefreshOutcome
            do {
                outcome = try await issuer.refresh(refresh)
            } catch {
                throw Abort(.serviceUnavailable)
            }
            let credentials: V2IssuedDeviceCredentials
            switch outcome {
            case .rotated(let value), .idempotent(let value): credentials = value
            case .terminalRejection: throw Abort(.unauthorized)
            }
            return try noStoreJSONResponse(.init(credentials: credentials))
        }
    }

    private func noStoreJSONResponse(_ response: V2DeviceCredentialIssueHTTPResponse) throws -> Response {
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
        headers.replaceOrAdd(name: "Retry-After", value: String(max(1, seconds)))
        return .init(status: .tooManyRequests, headers: headers)
    }
}
