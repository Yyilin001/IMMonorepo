import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public struct V2HTTPProfilePresentationClient: V2ProfilePresentationReading {
    private let endpoint: URL
    private let credentials: any V2ClientMediaEdgeCredentialProvider
    private let transport: any V2ClientMediaEdgeHTTPTransport
    public init(endpoint: URL, credentials: any V2ClientMediaEdgeCredentialProvider, transport: any V2ClientMediaEdgeHTTPTransport) throws {
        guard endpoint.scheme == "https", endpoint.host != nil, endpoint.user == nil, endpoint.password == nil else { throw V2ClientMediaTransferError.invalidMediaEdgeEndpoint }
        self.endpoint = endpoint; self.credentials = credentials; self.transport = transport
    }
    public func readPresentations(_ keys: [V2ProfileViewLookupKey]) async throws -> V2ProfilePresentationBatch {
        try Task.checkCancellation()
        let credential = try await credentials.mediaEdgeCredentials()
        guard !credential.accessToken.isEmpty, !credential.accessToken.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw V2ClientMediaTransferError.authorizationUnavailable }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(V2ProfilePresentationBatchRequest(keys: keys))
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        V2HTTPRequestDeadline.attach(credential.requestDeadline, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (bytes, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        if response.statusCode == 429 || (response.statusCode == 503 && response.value(forHTTPHeaderField: "Retry-After") != nil) {
            let delay = V2RetryAfter.delay(from: response.value(forHTTPHeaderField: "Retry-After"))
            throw V2ProfilePresentationError.throttled(retryAfter: delay)
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw V2ClientMediaTransferError.authorizationUnavailable
        }
        guard response.statusCode == 200, V2HTTPContract.isJSON(response), bytes.count <= 2 * 1_024 * 1_024 else { throw V2ClientMediaTransferError.invalidMediaEdgeResponse }
        let batch = try JSONDecoder().decode(V2ProfilePresentationBatchResponse.self, from: bytes)
        var presentations: [V2ProfileViewLookupKey: V2AuthorizedProfilePresentation] = [:]
        var avatars: [V2ProfileViewLookupKey: V2ResourceAvatarAccess] = [:]
        var denials: [V2ProfileViewLookupKey: V2PresentationAuthorityVersion] = [:]
        var retryable = Set<V2ProfileViewLookupKey>()
        for entry in batch.results {
            switch entry {
            case .presentation(let presentation, let avatar):
                presentations[entry.key] = presentation
                if let avatar {
                    if let plan = avatar.plan {
                        guard !plan.headers.contains(where: { $0.value.contains(credential.accessToken) }), !plan.url.absoluteString.contains(credential.accessToken) else { throw V2ClientMediaTransferError.invalidTarget }
                    }
                    avatars[entry.key] = avatar
                }
            case .unavailable(let denial): denials[denial.key] = denial.authorityVersion
            case .retryable(let key): retryable.insert(key)
            }
        }
        return .init(presentations: presentations, denials: denials, serverNow: Date(timeIntervalSince1970: Double(batch.serverNowUnixMilliseconds) / 1_000), avatars: avatars, retryable: retryable)
    }
}
