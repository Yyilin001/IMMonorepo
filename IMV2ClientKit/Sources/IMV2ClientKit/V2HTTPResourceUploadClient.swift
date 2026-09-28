import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public struct V2HTTPResourceUploadClient: V2BackgroundResourceUploadControlling, V2ResourceCapabilityReading {
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
    public func target(_ session: V2ResourceUploadSession) async throws -> V2ResourceTransferPlan? {
        try await target(session, background: false)
    }
    public func backgroundTarget(_ session: V2ResourceUploadSession) async throws -> V2ResourceTransferPlan? {
        try await target(session, background: true)
    }
    private func target(_ session: V2ResourceUploadSession, background: Bool) async throws -> V2ResourceTransferPlan? {
        let plans: [V2ResourceTransferPlan] = try await send(path: "targets", body: V2ResourceUploadTargetsRequest(locator: session.locator, generation: session.generation, background: background), validating: { plans, businessToken in
            guard plans.allSatisfy({ plan in
                !plan.headers.contains(where: { $0.value.contains(businessToken) }) && !plan.url.absoluteString.contains(businessToken)
            }) else { throw V2ClientMediaTransferError.invalidTarget }
        })
        guard plans.count <= 1, plans.allSatisfy({ $0.mode == .httpPut || $0.mode == .httpPartPut }) else { throw V2ClientMediaTransferError.invalidTarget }
        guard plans.allSatisfy({ ($0.backgroundAuthorization != nil) == background }) else { throw V2ClientMediaTransferError.invalidTarget }
        return plans.first
    }
    public func finalize(_ session: V2ResourceUploadSession) async throws -> V2ResourceUploadSession {
        try await send(path: "finalize", body: V2ResourceUploadFinalizeRequest(locator: session.locator, generation: session.generation, parts: session.confirmedParts))
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
        V2HTTPRequestDeadline.attach(credential.requestDeadline, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard data.count <= 512 * 1_024 else { throw V2ClientMediaTransferError.invalidMediaEdgeResponse }
        switch response.statusCode {
        case 200...299 where V2HTTPContract.isJSON(response): break
        case 401: throw V2ClientMediaTransferError.authorizationUnavailable
        case 403: throw V2HTTPFailure.status(response, service: "resourceUpload")
        case 409: throw V2ClientMediaTransferError.uploadStateConflict
        default: throw V2HTTPFailure.status(response, service: "resourceUpload")
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
    private let scheduler: V2AccountWorkScheduler?
    private let diagnostics: V2NetworkDiagnostics?
    public init(session: URLSession = V2SecureURLSession.mediaProvider,scheduler: V2AccountWorkScheduler? = nil, diagnostics: V2NetworkDiagnostics? = nil) { self.session = session; self.scheduler = scheduler; self.diagnostics = diagnostics }
    public func upload(fileURL: URL, plan: V2ResourceTransferPlan) async throws {
        try Task.checkCancellation()
        guard (plan.mode == .httpPut || plan.mode == .httpPartPut), plan.formFields.isEmpty,
              plan.url.scheme == "https", plan.url.host != nil,
              plan.url.user == nil, plan.url.password == nil, plan.url.fragment == nil else { throw V2ClientMediaTransferError.invalidTarget }
        guard plan.expiresAt > Date() else { throw V2ClientMediaTransferError.targetExpired }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let sourceBytes = (attributes[.size] as? NSNumber)?.int64Value else { throw V2ClientMediaTransferError.byteCountMismatch }
        let transferFile: URL
        if plan.mode == .httpPartPut {
            guard let range = plan.byteRange, range.upperBound < sourceBytes, range.byteCount == plan.expectedByteCount else { throw V2ClientMediaTransferError.byteCountMismatch }
            transferFile = try await V2ResourcePartFile.create(source: fileURL, lowerBound: range.lowerBound, byteCount: range.byteCount)
        } else {
            guard plan.byteRange == nil, sourceBytes == plan.expectedByteCount else { throw V2ClientMediaTransferError.byteCountMismatch }
            transferFile = fileURL
        }
        defer { if transferFile != fileURL { try? FileManager.default.removeItem(at: transferFile) } }
        try Task.checkCancellation()
        guard plan.expiresAt > Date() else { throw V2ClientMediaTransferError.targetExpired }
        var request = URLRequest(url: plan.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        request.httpMethod = plan.mode.httpMethod
        for header in plan.headers { request.setValue(header.value, forHTTPHeaderField: header.name) }
        let transportDeadline = ContinuousClock.now.advanced(by: .seconds(min(60,plan.expiresAt.timeIntervalSinceNow)))
        let deadline = min(transportDeadline, V2HTTPRequestDeadline.deadline(for: request) ?? transportDeadline, V2HTTPRequestDeadline.current ?? transportDeadline)
        let permit = try await scheduler?.acquire(.init(service: "mediaProvider",priority: .recovery,kind: .byteTransfer,isRetry: V2NetworkWorkScope.context?.isRetry ?? false),deadline: deadline)
        do {
            let http = try await V2BoundedFileUpload(session: session, diagnostics: diagnostics, metricMode: plan.mode == .httpPartPut ? .multipartUpload : .upload).send(request,file: transferFile,deadline: deadline)
            if [429,503].contains(http.statusCode), let retry = V2RetryAfter.date(from: http.value(forHTTPHeaderField: "Retry-After")) {
                await scheduler?.coolDown(service: "mediaProvider", for: retry.timeIntervalSinceNow)
            }
            try Task.checkCancellation()
            guard (200...299).contains(http.statusCode) else { throw V2HTTPFailure.status(http,service: "mediaProvider") }
            if let permit { _ = await scheduler?.release(permit) }
        } catch {
            if let failure = error as? V2HTTPFailure, [429,503].contains(failure.statusCode ?? 0), let retry = failure.retryAfter {
                await scheduler?.coolDown(service: "mediaProvider", for: retry.timeIntervalSinceNow)
            }
            if let permit { _ = await scheduler?.release(permit) }
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw error
        }
    }
}
