import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Resource HTTP cancellation admission")
struct V2ResourceHTTPAdmissionCancellationTests {
    enum Client: String, CaseIterable, Sendable { case directory, upload, resourceImport, mediaDownload }
    enum Boundary: String, CaseIterable, Sendable { case entry, credentials, response }

    @Test(arguments: Client.allCases, Boundary.allCases)
    func cancellationPreventsFurtherAdmission(client: Client, boundary: Boundary) async throws {
        let endpoint = try #require(URL(string: "https://account.invalid/v2/resource-uploads"))
        let credentials = AdmissionCredentials(cancel: boundary == .credentials)
        let http = AdmissionHTTP(cancel: boundary == .response, download: client == .mediaDownload)
        let room = RoomID(uuid: UUID())
        let operation = Task {
            if boundary == .entry { withUnsafeCurrentTask { $0?.cancel() } }
            switch client {
            case .directory:
                let client = try V2HTTPRoomResourceDirectoryClient(baseURL: endpoint, credentials: credentials, transport: http)
                _ = try await client.query(roomID: room, query: .init())
            case .upload:
                let client = try V2HTTPResourceUploadClient(endpoint: endpoint, credentials: credentials, transport: http)
                _ = try await client.capabilities()
            case .resourceImport:
                let client = try V2HTTPResourceImportClient(endpoint: endpoint, credentials: credentials, transport: http)
                _ = try await client.status(.init(home: .room(room), operationID: .init(uuid: UUID())))
            case .mediaDownload:
                let client = try V2HTTPMediaDownloadTargetResolver(endpoint: endpoint, credentials: credentials, transport: http)
                _ = try await client.resolveDownloadTarget(mediaID: .init(uuid: UUID()))
            }
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await credentials.calls == (boundary == .entry ? 0 : 1))
        #expect(await http.calls == (boundary == .response ? 1 : 0))
    }
}

private actor AdmissionCredentials: V2ClientMediaEdgeCredentialProvider {
    let cancel: Bool
    var calls = 0
    init(cancel: Bool) { self.cancel = cancel }
    func mediaEdgeCredentials() -> V2ClientMediaEdgeCredentials {
        calls += 1
        // Models a credential refresh which returns after its caller cancelled.
        // Cancellation remains cooperative; the client must recheck admission.
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        return .init(accessToken: "fixture", deviceID: .init(uuid: UUID()))
    }
}

private actor AdmissionHTTP: V2ClientMediaEdgeHTTPTransport {
    let cancel: Bool
    let download: Bool
    var calls = 0
    init(cancel: Bool, download: Bool) { self.cancel = cancel; self.download = download }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        calls += 1
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        if download {
            let plan = try V2ResourceTransferPlan(mode: .httpGet,
                url: #require(URL(string: "https://objects.invalid/opaque")),
                expiresAt: Date().addingTimeInterval(60), expectedByteCount: 3,
                checksum: .init(value: String(repeating: "a", count: 64)))
            return (try JSONEncoder().encode(V2MediaDownloadTargetEnvelope(plan: plan)), response)
        }
        return (Data("{}".utf8), response)
    }
}
