import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public struct V2HTTPResourceUploadClient: V2ResourceUploadControlling, V2ResourceCapabilityReading {
    private let endpoint: URL
    private let credentials: any V2ClientMediaEdgeCredentialProvider
    private let transport: any V2ClientMediaEdgeHTTPTransport

    public init(endpoint: URL, credentials: any V2ClientMediaEdgeCredentialProvider, transport: any V2ClientMediaEdgeHTTPTransport) throws {
        guard endpoint.scheme == "https", endpoint.host != nil, endpoint.user == nil, endpoint.password == nil else { throw V2ClientMediaTransferError.invalidMediaEdgeEndpoint }
        self.endpoint = endpoint; self.credentials = credentials; self.transport = transport
    }
    public func capabilities() async throws -> V2ResourceCapabilities {
        try await send(path: nil, body: Optional<Bool>.none,
                       capabilityEndpoint: endpoint.deletingLastPathComponent().appendingPathComponent("resource-capabilities"))
    }
    public func create(_ request: V2ResourceUploadRequest) async throws -> V2ResourceUploadSession {
        try await send(path: nil, body: request)
    }
    public func status(_ locator: V2ResourceUploadLocator) async throws -> V2ResourceUploadSession {
        try await send(path: "status", body: locator)
    }
    public func target(_ session: V2ResourceUploadSession) async throws -> V2ResourceTransferPlan {
        let plans: [V2ResourceTransferPlan] = try await send(path: "targets", body: V2ResourceUploadTargetsRequest(locator: session.locator, generation: session.generation), validating: { plans, businessToken in
            guard plans.allSatisfy({ plan in
                !plan.headers.contains(where: { $0.value.contains(businessToken) }) && !plan.url.absoluteString.contains(businessToken)
            }) else { throw V2ClientMediaTransferError.invalidTarget }
        })
        guard plans.count == 1, let plan = plans.first, plan.mode == .httpPut else { throw V2ClientMediaTransferError.invalidTarget }
        return plan
    }
    public func finalize(_ session: V2ResourceUploadSession) async throws -> V2ResourceUploadSession {
        try await send(path: "finalize", body: V2ResourceUploadFinalizeRequest(locator: session.locator, generation: session.generation))
    }
    public func cancel(_ session: V2ResourceUploadSession) async throws -> V2ResourceUploadSession {
        try await send(path: "cancel", body: V2ResourceUploadCancelRequest(locator: session.locator, generation: session.generation))
    }
    private func send<Request: Encodable & Sendable, Response: Decodable & Sendable>(path: String?, body: Request, capabilityEndpoint: URL? = nil, validating: (@Sendable (Response, String) throws -> Void)? = nil) async throws -> Response {
        try Task.checkCancellation()
        let credential = try await credentials.mediaEdgeCredentials()
        guard !credential.accessToken.isEmpty, !credential.accessToken.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw V2ClientMediaTransferError.authorizationUnavailable }
        var request = URLRequest(url: capabilityEndpoint ?? path.map { endpoint.appendingPathComponent($0) } ?? endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: capabilityEndpoint == nil ? 30 : 5)
        request.httpMethod = capabilityEndpoint == nil ? "POST" : "GET"
        if capabilityEndpoint == nil { request.httpBody = try JSONEncoder().encode(body) }
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard data.count <= 512 * 1_024 else { throw V2ClientMediaTransferError.invalidMediaEdgeResponse }
        switch response.statusCode {
        case 200...299 where V2HTTPContract.isJSON(response): break
        case 401,403: throw V2ClientMediaTransferError.authorizationDenied
        case 409: throw V2ClientMediaTransferError.uploadStateConflict
        default: throw V2ClientMediaTransferError.serverStatus(response.statusCode)
        }
        let decoded: Response
        do { decoded = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw V2ClientMediaTransferError.invalidMediaEdgeResponse }
        try validating?(decoded, credential.accessToken)
        return decoded
    }
}

/// Declarative HTTP executor. The secure provider session rejects redirects and
/// has neither account cookies nor a disk URL cache. No business bearer is copied.
public actor V2URLSessionResourcePlanExecutor: V2ResourcePlanExecuting {
    private let session: URLSession
    public init(session: URLSession = V2SecureURLSession.mediaProvider) { self.session = session }
    public func upload(fileURL: URL, plan: V2ResourceTransferPlan) async throws {
        try Task.checkCancellation()
        guard plan.mode == .httpPut, plan.formFields.isEmpty, plan.byteRange == nil,
              plan.expiresAt > Date(), plan.url.scheme == "https", plan.url.host != nil,
              plan.url.user == nil, plan.url.password == nil, plan.url.fragment == nil else { throw V2ClientMediaTransferError.invalidTarget }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == plan.expectedByteCount else { throw V2ClientMediaTransferError.byteCountMismatch }
        var request = URLRequest(url: plan.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        request.httpMethod = plan.mode.httpMethod
        for header in plan.headers { request.setValue(header.value, forHTTPHeaderField: header.name) }
        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw V2ClientMediaTransferError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw V2ClientMediaTransferError.serverStatus(http.statusCode) }
    }
}
