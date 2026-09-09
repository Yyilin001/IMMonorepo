import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// A separately approved account factor returns a short-lived opaque assertion
/// bound to the installation. ClientKit neither interprets nor persists it.
public protocol V2DeviceBoundAccountAssertionProvider: Sendable {
    func accountAssertion(for deviceID: DeviceID) async throws -> String
}

/// Supplies the stable V2 device identity owned by the app's secure device
/// registration layer. It is intentionally independent from the account
/// assertion mechanism.
public protocol V2DeviceIdentityProvider: Sendable {
    func deviceID() async throws -> DeviceID
}

/// Non-sensitive label shown only in the owner's device-session inventory.
/// The app owns platform-specific discovery; ClientKit only transports it.
public struct V2ClientDeviceRegistrationMetadata: Equatable, Sendable {
    public let deviceName: String
    public let platform: String

    public init(deviceName: String, platform: String) {
        self.deviceName = deviceName
        self.platform = platform
    }

    public static let unknown = Self(deviceName: "This device", platform: "Unknown")
}

/// Persist before issuance. The purpose-limited cancellation proof must remain
/// available even when the server's entire credential response is lost.
public struct V2PendingDeviceCredentialRegistration: Codable, Equatable, Sendable {
    public let cancellation: V2DeviceRegistrationCancellation
    public var deviceID: DeviceID { cancellation.deviceID }
    public var operationID: UUID { cancellation.operationID }

    public init(cancellation: V2DeviceRegistrationCancellation) { self.cancellation = cancellation }

    public static func prepare(deviceID: DeviceID, operationID: UUID, now: Date = Date()) throws -> Self {
        guard let cutoff = Int64(exactly: (now.addingTimeInterval(600).timeIntervalSince1970 * 1_000).rounded(.down)) else {
            throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord
        }
        return try .init(cancellation: .init(deviceID: deviceID, operationID: operationID,
            proof: .generate(), issueBeforeMilliseconds: cutoff))
    }
}

public enum V2DeviceCredentialRegistrationOperationStoreError: Error, Equatable, Sendable {
    case unavailable
    case malformedRecord
    case permanentlyInvalidated
    case capacityExceeded
    case unexpectedStatus(Int32)
}

public protocol V2DeviceCredentialRegistrationOperationStore: Sendable {
    func load() async throws -> V2PendingDeviceCredentialRegistration?
    func save(_ registration: V2PendingDeviceCredentialRegistration) async throws
    func delete() async throws
}

public enum V2AccountAssertionCredentialProviderError: Error, Equatable, Sendable {
    case assertionUnavailable
    case invalidAssertion
    case deviceIdentityUnavailable
    case registrationOperationUnavailable
    case assertionRejected
    case registrationConflict
    case registrationExpired
    case unexpectedResponse
    case issuedCredentialMismatch
    case noIssuedCredentialToFinalize
}

/// Generic HTTPS implementation of `POST /v2/device-credentials`. It is a
/// transport adapter, not an authentication method: an app injects its chosen
/// account assertion and device-identity providers. The pending operation is
/// deleted only after `V2ClientSessionBootstrapper` has made credentials
/// durable, preserving safe server replay across response loss.
public actor V2HTTPAccountAssertionDeviceCredentialProvider: V2AccountDeviceCredentialProvider, V2AccountDeviceCredentialIssueFinalizer {
    private let issueEndpoint: URL
    private let assertionProvider: any V2DeviceBoundAccountAssertionProvider
    private let deviceIdentityProvider: any V2DeviceIdentityProvider
    private let operationStore: any V2DeviceCredentialRegistrationOperationStore
    private let recovery: any V2IssuedCredentialRecovering
    private let registrationMetadata: V2ClientDeviceRegistrationMetadata
    private let transport: any V2AuthHTTPTransport
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private var issuedRegistration: IssuedRegistration?

    public init(
        issueEndpoint: URL,
        assertionProvider: any V2DeviceBoundAccountAssertionProvider,
        deviceIdentityProvider: any V2DeviceIdentityProvider,
        operationStore: any V2DeviceCredentialRegistrationOperationStore,
        recovery: any V2IssuedCredentialRecovering,
        registrationMetadata: V2ClientDeviceRegistrationMetadata = .unknown,
        transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport(),
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard issueEndpoint.scheme?.lowercased() == "https", issueEndpoint.host != nil else {
            throw V2HTTPAuthTransportError.invalidEndpoint
        }
        self.issueEndpoint = issueEndpoint
        self.assertionProvider = assertionProvider
        self.deviceIdentityProvider = deviceIdentityProvider
        self.operationStore = operationStore
        self.recovery = recovery
        self.registrationMetadata = registrationMetadata
        self.transport = transport
        self.makeUUID = makeUUID
        self.now = now
    }

    public func issueDeviceCredentials() async throws -> V2AuthCredentials {
        try Task.checkCancellation()
        let deviceID: DeviceID
        do { deviceID = try await deviceIdentityProvider.deviceID() }
        catch is CancellationError { throw CancellationError() }
        catch { throw V2AccountAssertionCredentialProviderError.deviceIdentityUnavailable }
        try Task.checkCancellation()

        let assertion: String
        do { assertion = try await assertionProvider.accountAssertion(for: deviceID) }
        catch is CancellationError { throw CancellationError() }
        // Password/passkey factors can report actionable account errors before
        // any device credential is requested. Preserve those errors for the
        // app instead of presenting a misleading generic assertion failure.
        catch let error as V2AccountAuthenticationError { throw error }
        catch let error as V2LegacyRegistrationCancellationError { throw error }
        catch let error as V2DeviceCredentialRegistrationOperationStoreError { throw error }
        catch { throw V2AccountAssertionCredentialProviderError.assertionUnavailable }
        try Task.checkCancellation()
        guard isValidAssertion(assertion) else { throw V2AccountAssertionCredentialProviderError.invalidAssertion }

        let pending = try await pendingRegistration(for: deviceID)
        try Task.checkCancellation()
        guard pending.cancellation.issueBefore > now() else { throw V2AccountAssertionCredentialProviderError.registrationExpired }
        let request = try makeRequest(assertion: assertion, pending: pending)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as V2HTTPAuthTransportError {
            throw error
        } catch {
            throw V2HTTPAuthTransportError.networkFailure
        }
        switch response.statusCode {
        case 200 where V2HTTPContract.isJSON(response): break
        case 200: throw V2HTTPAuthTransportError.invalidResponse
        case 401, 403: throw V2AccountAssertionCredentialProviderError.assertionRejected
        case 409: throw V2AccountAssertionCredentialProviderError.registrationConflict
        default: throw V2HTTPAuthTransportError.serverStatus(response.statusCode)
        }

        let credentials: V2AuthCredentials
        let confirmedCancellation: V2DeviceRegistrationCancellation?
        do {
            let body = try JSONDecoder().decode(IssueResponse.self, from: data)
            confirmedCancellation = (try? JSONDecoder().decode(CancellationConfirmation.self, from: data))?.registrationCancellation
            credentials = try .init(
                userID: .init(body.userID),
                deviceID: .init(body.deviceID),
                accessToken: body.accessToken,
                accessTokenExpiresAt: Date(timeIntervalSince1970: Double(body.accessTokenExpiresAtMilliseconds) / 1_000),
                refreshCredential: body.refreshCredential,
                revocationCredential: body.revocationCredential,
                revocationCredentialExpiresAt: Date(timeIntervalSince1970: Double(body.revocationCredentialExpiresAtMilliseconds) / 1_000)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw V2AccountAssertionCredentialProviderError.unexpectedResponse
        }
        guard credentials.deviceID == deviceID else {
            throw V2AccountAssertionCredentialProviderError.issuedCredentialMismatch
        }
        // Persist purpose-limited authority before returning, including when
        // a transport delivers a successful response after cancellation.
        let receipt = try await recovery.receive(credentials, operationID: pending.operationID)
        issuedRegistration = .init(pending: pending, credentials: credentials, receipt: receipt)
        guard confirmedCancellation == pending.cancellation else {
            // A stale/mismatched server response is still received authority.
            // Relinquish it durably before rejecting the unsupported binding.
            try await discardIssuedDeviceCredentials(credentials)
            throw V2AccountAssertionCredentialProviderError.issuedCredentialMismatch
        }
        return credentials
    }

    public func finalizeIssuedDeviceCredentials(_ credentials: V2AuthCredentials) async throws {
        guard let issuedRegistration, issuedRegistration.credentials == credentials else {
            throw V2AccountAssertionCredentialProviderError.noIssuedCredentialToFinalize
        }
        do {
            try await operationStore.delete()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw V2AccountAssertionCredentialProviderError.registrationOperationUnavailable
        }
        try await recovery.adopt(issuedRegistration.receipt)
        self.issuedRegistration = nil
    }

    public func discardIssuedDeviceCredentials(_ credentials: V2AuthCredentials) async throws {
        guard let issuedRegistration, issuedRegistration.credentials == credentials else {
            throw V2AccountAssertionCredentialProviderError.noIssuedCredentialToFinalize
        }
        try await recovery.abandon(issuedRegistration.receipt)
        try await operationStore.delete()
        self.issuedRegistration = nil
    }

    private func pendingRegistration(for deviceID: DeviceID) async throws -> V2PendingDeviceCredentialRegistration {
        do {
            let existing = try await operationStore.load()
            try Task.checkCancellation()
            if let existing, existing.deviceID == deviceID {
                return existing
            }
            let pending = try V2PendingDeviceCredentialRegistration.prepare(deviceID: deviceID, operationID: makeUUID(), now: now())
            try await operationStore.save(pending)
            return pending
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw V2AccountAssertionCredentialProviderError.registrationOperationUnavailable
        }
    }

    private func makeRequest(assertion: String, pending: V2PendingDeviceCredentialRegistration) throws -> URLRequest {
        var request = URLRequest(
            url: issueEndpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        do {
            request.httpBody = try JSONEncoder().encode(IssueRequest(
                accountAssertion: assertion,
                deviceID: pending.deviceID.rawValue,
                operationID: pending.operationID,
                cancellation: pending.cancellation,
                deviceName: registrationMetadata.deviceName,
                platform: registrationMetadata.platform
            ))
        } catch {
            throw V2HTTPAuthTransportError.invalidRequest
        }
        return request
    }

    private func isValidAssertion(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }
}

private struct IssuedRegistration: Equatable, Sendable {
    let pending: V2PendingDeviceCredentialRegistration
    let credentials: V2AuthCredentials
    let receipt: V2DeviceRevocationIntent
}

private struct IssueRequest: Encodable {
    let accountAssertion: String
    let deviceID: String
    let operationID: UUID
    let cancellation: V2DeviceRegistrationCancellation
    let deviceName: String
    let platform: String
}

private struct IssueResponse: Decodable {
    let userID: String
    let deviceID: String
    let accessToken: String
    let accessTokenExpiresAtMilliseconds: Int64
    let refreshCredential: String
    let revocationCredential: V2DeviceRevocationCredential
    let revocationCredentialExpiresAtMilliseconds: Int64
}

private struct CancellationConfirmation: Decodable {
    let registrationCancellation: V2DeviceRegistrationCancellation
}
