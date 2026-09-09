import Foundation
import IMV2Core
import IMV2Server
import Vapor

public struct V2DeviceCredentialIssueHTTPRequest: Content, Sendable {
    public let accountAssertion: String
    public let deviceID: String
    public let operationID: UUID
    public let cancellation: V2DeviceRegistrationCancellation
    public let deviceName: String?
    public let platform: String?

    public init(accountAssertion: String, deviceID: String, operationID: UUID, cancellation: V2DeviceRegistrationCancellation, deviceName: String? = nil, platform: String? = nil) {
        self.accountAssertion = accountAssertion
        self.deviceID = deviceID
        self.operationID = operationID
        self.cancellation = cancellation
        self.deviceName = deviceName
        self.platform = platform
    }

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: RequestKey.self)
        let required = Set(["accountAssertion", "deviceID", "operationID", "cancellation"])
        let actual = Set(keys.allKeys.map(\.stringValue))
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(["deviceName", "platform"])) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid credential issue request"))
        }
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        accountAssertion = try fields.decode(String.self, forKey: .accountAssertion)
        deviceID = try fields.decode(String.self, forKey: .deviceID)
        operationID = try fields.decode(UUID.self, forKey: .operationID)
        cancellation = try fields.decode(V2DeviceRegistrationCancellationHTTPRequest.self, forKey: .cancellation).cancellation
        deviceName = try fields.decodeIfPresent(String.self, forKey: .deviceName)
        platform = try fields.decodeIfPresent(String.self, forKey: .platform)
    }
    private enum CodingKeys: String, CodingKey { case accountAssertion, deviceID, operationID, cancellation, deviceName, platform }
    private struct RequestKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

public struct V2DeviceCredentialIssueHTTPResponse: Content, Sendable {
    public let userID: String
    public let deviceID: String
    public let accessToken: String
    public let accessTokenExpiresAtMilliseconds: Int64
    public let refreshCredential: String
    public let revocationCredential: V2DeviceRevocationCredential
    public let revocationCredentialExpiresAtMilliseconds: Int64
    public let registrationCancellation: V2DeviceRegistrationCancellation?

    init(credentials: V2IssuedDeviceCredentials, registrationCancellation: V2DeviceRegistrationCancellation? = nil) throws {
        let milliseconds = credentials.accessTokenExpiresAt.timeIntervalSince1970 * 1_000
        guard let signedMilliseconds = Int64(exactly: milliseconds.rounded(.towardZero)),
              let revocationMilliseconds = Int64(exactly: (credentials.revocationCredentialExpiresAt.timeIntervalSince1970 * 1_000).rounded(.towardZero)) else {
            throw V2DeviceCredentialServiceError.malformedPersistence
        }
        userID = credentials.userID.rawValue
        deviceID = credentials.deviceID.rawValue
        accessToken = credentials.accessToken
        accessTokenExpiresAtMilliseconds = signedMilliseconds
        refreshCredential = credentials.refreshCredential
        revocationCredential = credentials.revocationCredential
        revocationCredentialExpiresAtMilliseconds = revocationMilliseconds
        self.registrationCancellation = registrationCancellation
    }
}

public struct V2DeviceCredentialRefreshHTTPRequest: Content, Sendable {
    public let userID: String
    public let deviceID: String
    public let refreshCredential: String
    public let revocationCredential: V2DeviceRevocationCredential
    public let operationID: UUID

    public init(userID: String, deviceID: String, refreshCredential: String, revocationCredential: V2DeviceRevocationCredential, operationID: UUID) {
        self.userID = userID
        self.deviceID = deviceID
        self.refreshCredential = refreshCredential
        self.revocationCredential = revocationCredential
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
        routes.on(.POST, "v2", "device-credentials", body: .collect(maxSize: "16kb")) { request async throws -> Response in
            guard request.headers.contentType?.type == "application", request.headers.contentType?.subType == "json" else { throw Abort(.badRequest) }
            let input: V2DeviceCredentialIssueHTTPRequest
            do { input = try request.content.decode(V2DeviceCredentialIssueHTTPRequest.self) }
            catch { throw Abort(.badRequest) }
            guard !input.accountAssertion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let deviceID = try? DeviceID(input.deviceID),
                  UUID(uuidString: deviceID.rawValue) == UUID(uuidString: input.cancellation.deviceID.rawValue),
                  input.operationID == input.cancellation.operationID,
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
            } catch V2AccountAssertionError.invalidClock {
                return .init(status: .serviceUnavailable, headers: ["Cache-Control": "no-store", "Pragma": "no-cache"])
            } catch {
                throw Abort(.unauthorized)
            }
            let outcome: V2DeviceRegistrationOutcome
            do {
                outcome = try await issuer.register(V2CancellableDeviceRegistration(registration: .init(
                    userID: userID,
                    deviceID: deviceID,
                    operationID: input.operationID,
                    metadata: metadata
                ), cancellation: input.cancellation))
            } catch V2DeviceSessionServiceError.invalidRequest {
                throw Abort(.badRequest)
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
            return try noStoreJSONResponse(.init(credentials: credentials, registrationCancellation: input.cancellation))
        }
        routes.post("v2", "device-credentials", "refresh") { request async throws -> Response in
            let input = try request.content.decode(V2DeviceCredentialRefreshHTTPRequest.self)
            guard let userID = try? UserID(input.userID),
                  let deviceID = try? DeviceID(input.deviceID),
                  let refresh = try? V2DeviceCredentialRefresh(userID: userID, deviceID: deviceID, refreshCredential: input.refreshCredential, revocationCredential: input.revocationCredential, operationID: input.operationID)
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
