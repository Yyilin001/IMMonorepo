import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public protocol V2NameOperationClient: Sendable {
    func contactSnapshot(owner: UserID, target: UserID) async throws -> V2ContactAliasSnapshot
    func groupSnapshot(actor: UserID, room: RoomID) async throws -> V2GroupNicknameSnapshot
    func submit(_ command: V2ContactAliasUpdateCommand) async throws -> V2ContactAliasUpdateReceipt
    func submit(_ command: V2GroupNicknameUpdateCommand) async throws -> V2GroupNicknameUpdateReceipt
    func recover(_ request: V2ContactAliasRecoveryRequest) async throws -> V2ContactAliasRecoveryResult
    func recover(_ request: V2GroupNicknameRecoveryRequest) async throws -> V2GroupNicknameRecoveryResult
}
public struct V2HTTPNameOperationClient: V2NameOperationClient, Sendable {
    private let endpoint: URL
    private let credentials: any V2ClientPushEndpointCredentialProvider
    private let transport: any V2ClientPushEndpointHTTPTransport
    public init(endpoint: URL, credentials: any V2ClientPushEndpointCredentialProvider, transport: any V2ClientPushEndpointHTTPTransport) throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil, endpoint.user == nil,
              endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else { throw V2OwnProfileClientError.invalidEndpoint }
        self.endpoint = endpoint; self.credentials = credentials; self.transport = transport
    }
    private func path(_ target: V2NameTarget) -> URL {
        switch target {
        case .contact(let id): endpoint.appendingPathComponent("contact-aliases").appendingPathComponent(id.rawValue)
        case .group(let id): endpoint.appendingPathComponent("groups").appendingPathComponent(id.rawValue).appendingPathComponent("nickname")
        }
    }
    private func request<T: Decodable & Sendable>(_ url: URL, method: String, body: Data? = nil) async throws -> T {
        try Task.checkCancellation()
        let credential = try await credentials.pushEndpointCredentials()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        V2HTTPRequestDeadline.attach(credential.requestDeadline, to: &request)
        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else { throw V2HTTPFailure.status(response, service: "name-operations") }
        guard data.count <= 65_536, V2HTTPContract.isJSON(response), let value = try? JSONDecoder().decode(T.self, from: data) else { throw V2OwnProfileClientError.invalidResponse }
        return value
    }
    public func contactSnapshot(owner: UserID, target: UserID) async throws -> V2ContactAliasSnapshot {
        let value: V2ContactAliasSnapshot = try await request(path(.contact(target)), method: "GET")
        guard value.ownerUserID == owner, value.targetUserID == target else { throw V2OperationWorkError.identityConflict }
        return value
    }
    public func groupSnapshot(actor: UserID, room: RoomID) async throws -> V2GroupNicknameSnapshot {
        let value: V2GroupNicknameSnapshot = try await request(path(.group(room)), method: "GET")
        guard value.actorUserID == actor, value.roomID == room else { throw V2OperationWorkError.identityConflict }
        return value
    }
    public func submit(_ command: V2ContactAliasUpdateCommand) async throws -> V2ContactAliasUpdateReceipt {
        let result: V2ContactAliasUpdateReceipt = try await request(path(.contact(command.targetUserID)), method: "PUT", body: JSONEncoder().encode(command))
        try V2FrozenNameOperation.contact(command).validate(.contact(result)); return result
    }
    public func submit(_ command: V2GroupNicknameUpdateCommand) async throws -> V2GroupNicknameUpdateReceipt {
        let result: V2GroupNicknameUpdateReceipt = try await request(path(.group(command.roomID)), method: "PUT", body: JSONEncoder().encode(command))
        try V2FrozenNameOperation.group(command).validate(.group(result)); return result
    }
    public func recover(_ input: V2ContactAliasRecoveryRequest) async throws -> V2ContactAliasRecoveryResult {
        guard case .userPair(_, let target) = input.identity.scope else { throw V2OperationWorkError.invalidRecord }
        let result: V2ContactAliasRecoveryResult = try await request(path(.contact(target)).appendingPathComponent("operations/recover"), method: "POST", body: JSONEncoder().encode(input))
        if case .receipt(let r) = result { guard r.identity == input.identity, r.fingerprint == input.fingerprint else { throw V2OperationWorkError.identityConflict } }
        return result
    }
    public func recover(_ input: V2GroupNicknameRecoveryRequest) async throws -> V2GroupNicknameRecoveryResult {
        guard case .room(let room) = input.identity.scope else { throw V2OperationWorkError.invalidRecord }
        let result: V2GroupNicknameRecoveryResult = try await request(path(.group(room)).appendingPathComponent("operations/recover"), method: "POST", body: JSONEncoder().encode(input))
        if case .receipt(let r) = result { guard r.identity == input.identity, r.fingerprint == input.fingerprint else { throw V2OperationWorkError.identityConflict } }
        return result
    }
}
