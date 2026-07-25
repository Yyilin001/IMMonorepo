import Foundation
import IMV2Core

/// A separately approved account system returns a short-lived opaque assertion
/// through this boundary. ClientKit neither interprets nor persists it.
public protocol V2AccountAssertionProvider: Sendable {
    func accountAssertion() async throws -> String
}

/// New V2 account factors bind their short-lived result to the installation
/// before it reaches the credential issuer. The legacy unbound form remains
/// only for independently managed adapters during migration.
public protocol V2DeviceBoundAccountAssertionProvider: V2AccountAssertionProvider {
    func accountAssertion(for deviceID: DeviceID) async throws -> String
}

/// Supplies the stable V2 device identity owned by the app's secure device
/// registration layer. It is intentionally independent from the account
/// assertion mechanism.
public protocol V2DeviceIdentityProvider: Sendable {
    func deviceID() async throws -> DeviceID
}

/// The operation is not a credential, but must be device-local and durable:
/// it is the only way to retrieve the exact registration result after a
/// response is lost before credentials reach `V2AuthSession`.
public struct V2PendingDeviceCredentialRegistration: Codable, Equatable, Sendable {
    public let deviceID: DeviceID
    public let operationID: UUID

    public init(deviceID: DeviceID, operationID: UUID) {
        self.deviceID = deviceID
        self.operationID = operationID
    }
}

public enum V2DeviceCredentialRegistrationOperationStoreError: Error, Equatable, Sendable {
    case unavailable
    case malformedRecord
    case permanentlyInvalidated
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
    private let assertionProvider: any V2AccountAssertionProvider
    private let deviceIdentityProvider: any V2DeviceIdentityProvider
    private let operationStore: any V2DeviceCredentialRegistrationOperationStore
    private let transport: any V2AuthHTTPTransport
    private let makeUUID: @Sendable () -> UUID
    private var issuedRegistration: IssuedRegistration?

    public init(
        issueEndpoint: URL,
        assertionProvider: any V2AccountAssertionProvider,
        deviceIdentityProvider: any V2DeviceIdentityProvider,
        operationStore: any V2DeviceCredentialRegistrationOperationStore,
        transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport(),
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) throws {
        guard issueEndpoint.scheme?.lowercased() == "https", issueEndpoint.host != nil else {
            throw V2HTTPAuthTransportError.invalidEndpoint
        }
        self.issueEndpoint = issueEndpoint
        self.assertionProvider = assertionProvider
        self.deviceIdentityProvider = deviceIdentityProvider
        self.operationStore = operationStore
        self.transport = transport
        self.makeUUID = makeUUID
    }

    public func issueDeviceCredentials() async throws -> V2AuthCredentials {
        try Task.checkCancellation()
        let deviceID: DeviceID
        do { deviceID = try await deviceIdentityProvider.deviceID() }
        catch is CancellationError { throw CancellationError() }
        catch { throw V2AccountAssertionCredentialProviderError.deviceIdentityUnavailable }

        let assertion: String
        do {
            if let deviceBoundProvider = assertionProvider as? any V2DeviceBoundAccountAssertionProvider {
                assertion = try await deviceBoundProvider.accountAssertion(for: deviceID)
            } else {
                assertion = try await assertionProvider.accountAssertion()
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw V2AccountAssertionCredentialProviderError.assertionUnavailable }
        guard isValidAssertion(assertion) else { throw V2AccountAssertionCredentialProviderError.invalidAssertion }

        let pending = try await pendingRegistration(for: deviceID)
        let request = try makeRequest(assertion: assertion, pending: pending)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2HTTPAuthTransportError {
            throw error
        } catch {
            throw V2HTTPAuthTransportError.networkFailure
        }
        switch response.statusCode {
        case 200 ... 299: break
        case 401, 403: throw V2AccountAssertionCredentialProviderError.assertionRejected
        case 409: throw V2AccountAssertionCredentialProviderError.registrationConflict
        default: throw V2HTTPAuthTransportError.serverStatus(response.statusCode)
        }

        let credentials: V2AuthCredentials
        do {
            let body = try JSONDecoder().decode(IssueResponse.self, from: data)
            credentials = try .init(
                userID: .init(body.userID),
                deviceID: .init(body.deviceID),
                accessToken: body.accessToken,
                accessTokenExpiresAt: Date(timeIntervalSince1970: Double(body.accessTokenExpiresAtMilliseconds) / 1_000),
                refreshCredential: body.refreshCredential
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw V2AccountAssertionCredentialProviderError.unexpectedResponse
        }
        guard credentials.deviceID == deviceID else {
            throw V2AccountAssertionCredentialProviderError.issuedCredentialMismatch
        }
        issuedRegistration = .init(pending: pending, credentials: credentials)
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
        self.issuedRegistration = nil
    }

    private func pendingRegistration(for deviceID: DeviceID) async throws -> V2PendingDeviceCredentialRegistration {
        do {
            if let existing = try await operationStore.load(), existing.deviceID == deviceID {
                return existing
            }
            let pending = V2PendingDeviceCredentialRegistration(deviceID: deviceID, operationID: makeUUID())
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
                operationID: pending.operationID
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
}

private struct IssueRequest: Encodable {
    let accountAssertion: String
    let deviceID: String
    let operationID: UUID
}

private struct IssueResponse: Decodable {
    let userID: String
    let deviceID: String
    let accessToken: String
    let accessTokenExpiresAtMilliseconds: Int64
    let refreshCredential: String
}
