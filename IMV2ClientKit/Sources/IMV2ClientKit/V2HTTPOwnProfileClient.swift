import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public protocol V2OwnProfileManaging: Sendable {
    func currentProfile() async throws -> V2ProfileView
    func patchProfile(_ command: V2ProfileUpdateCommand) async throws -> V2ProfileUpdateResult
    func recoverProfile(_ request: V2ProfileOperationRecoveryRequest) async throws -> V2ProfileOperationRecoveryResult
}

public enum V2OwnProfileClientError: Error, Equatable, Sendable {
    case invalidEndpoint, authorizationUnavailable, authorizationDenied, invalidRequest
    case revisionConflict(V2ProfileRevision)
    case invalidResponse, networkFailure, serverStatus(Int)
}

/// One request per call; original receipt and current snapshot have distinct meanings.
public struct V2HTTPOwnProfileClient: V2OwnProfileManaging, Sendable {
    private let queries: V2QueryCoordinator<V2ProfileView>?
    private let queryScope: V2QueryScope?
    private let endpoint: URL
    private let credentials: any V2ClientPushEndpointCredentialProvider
    private let transport: any V2ClientPushEndpointHTTPTransport
    public init(endpoint: URL, credentials: any V2ClientPushEndpointCredentialProvider,
                transport: any V2ClientPushEndpointHTTPTransport = V2URLSessionPushEndpointHTTPTransport(),
                queries: V2QueryCoordinator<V2ProfileView>? = nil, queryScope: V2QueryScope? = nil) throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil,
              endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil else { throw V2OwnProfileClientError.invalidEndpoint }
        self.endpoint = endpoint; self.credentials = credentials; self.transport = transport
        self.queries = queries; self.queryScope = queryScope
    }
    public func currentProfile() async throws -> V2ProfileView {
        if let queries, let queryScope {
            return try await queries.query(.init(scope: queryScope, requestID: "own-profile:" + endpoint.absoluteString)) {
                try await self.readCurrentProfile()
            }
        }
        return try await readCurrentProfile()
    }
    private func readCurrentProfile() async throws -> V2ProfileView {
        let result = try await send(try await authenticatedRequest(method: "GET"), as: V2ProfileView.self)
        if let queryScope, result.userID.rawValue != queryScope.accountID { throw V2OwnProfileClientError.invalidResponse }
        return result
    }
    public func patchProfile(_ command: V2ProfileUpdateCommand) async throws -> V2ProfileUpdateResult {
        var request = try await authenticatedRequest(method: "PUT")
        request.httpBody = try JSONEncoder().encode(UpdateBody(command: command))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let result = try await send(request, as: V2ProfileUpdateResult.self)
        guard result.receipt.validates(actorUserID: command.actorUserID, operationID: command.operationID, fingerprint: command.fingerprint),
              result.currentSnapshot.map({ $0.userID == command.actorUserID }) ?? true else { throw V2OwnProfileClientError.invalidResponse }
        if case .committed(let revision, _) = result.receipt.outcome {
            guard revision > command.expectedRevision, result.currentSnapshot.map({ $0.revision >= revision }) ?? true else { throw V2OwnProfileClientError.invalidResponse }
        }
        return result
    }
    public func recoverProfile(_ input: V2ProfileOperationRecoveryRequest) async throws -> V2ProfileOperationRecoveryResult {
        var request = try await authenticatedRequest(method: "POST", url: endpoint.appendingPathComponent("operations/recover"))
        request.httpBody = try JSONEncoder().encode(RecoveryBody(operationID: input.operationID.rawValue, fingerprint: input.fingerprint, action: input.action))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let result = try await send(request, as: V2ProfileOperationRecoveryResult.self)
        if case .receipt(let receipt, let snapshot) = result {
            guard receipt.validates(actorUserID: input.actorUserID, operationID: input.operationID, fingerprint: input.fingerprint),
                  snapshot.map({ $0.userID == input.actorUserID }) ?? true else { throw V2OwnProfileClientError.invalidResponse }
        }
        return result
    }
    private func authenticatedRequest(method: String, url: URL? = nil) async throws -> URLRequest {
        try Task.checkCancellation()
        let credential: V2ClientPushEndpointCredentials
        do { credential = try await credentials.pushEndpointCredentials() }
        catch is CancellationError { throw CancellationError() } catch let failure as V2HTTPFailure { throw failure } catch { throw V2OwnProfileClientError.authorizationUnavailable }
        var request = URLRequest(url: url ?? endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        V2HTTPRequestDeadline.attach(credential.requestDeadline, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }
    private func send<Value: Decodable>(_ request: URLRequest, as: Value.Type) async throws -> Value {
        let data: Data; let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as V2HTTPFailure { throw error }
        catch let error as URLError { throw V2HTTPFailure(kind: .transport, service: "profile", urlErrorCode: error.code.rawValue) }
        catch { throw V2HTTPFailure(kind: .transport, service: "profile") }
        if response.statusCode == 401 { throw V2OwnProfileClientError.authorizationUnavailable }
        if response.statusCode == 403 { throw V2OwnProfileClientError.authorizationDenied }
        guard response.statusCode == 200 else { throw V2HTTPFailure.status(response, service: "profile") }
        guard V2HTTPContract.isJSON(response), let body = try? JSONDecoder().decode(Value.self, from: data) else { throw V2OwnProfileClientError.invalidResponse }
        return body
    }
}
private struct UpdateBody: Encodable {
    let operationID: String
    let expectedRevision: UInt64
    let patch: V2ProfilePatch
    let deadline: UInt64
    init(command: V2ProfileUpdateCommand) {
        operationID = command.operationID.rawValue; expectedRevision = command.expectedRevision.rawValue
        patch = command.patch; deadline = command.firstSubmissionDeadlineMilliseconds
    }
    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id", expectedRevision = "expected_revision", patch
        case deadline = "first_submission_deadline_ms"
    }
}
private struct RecoveryBody: Encodable {
    let operationID: String
    let fingerprint: V2OperationFingerprint
    let action: V2OperationRecoveryRequest.Action
    enum CodingKeys: String, CodingKey { case operationID = "operation_id", fingerprint, action }
}
