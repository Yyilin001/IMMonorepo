import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 native media transfer")
struct V2MediaTransferTests {
    @Test func downloadTargetRetainsExplicitOSDelegationAndDoesNotInventOne() throws {
        let now = Date(), expiry = now.addingTimeInterval(60)
        let checksum = try V2ResourceChecksum(value: String(repeating: "a", count: 64))
        let grant = try V2ResourceBackgroundDownloadAuthorization(id: UUID(), expectedByteCount: 3,
            checksum: checksum, issuedAt: now, expiresAt: expiry)
        let url = try #require(URL(string: "https://objects.invalid/opaque"))
        let permitted = try V2ResourceTransferPlan(mode: .httpGet, url: url, expiresAt: expiry,
            expectedByteCount: 3, checksum: checksum, backgroundDownloadAuthorization: grant)
        #expect(try V2ClientMediaTransferTarget(downloadPlan: permitted).backgroundDownloadAuthorization == grant)
        let foreground = try V2ResourceTransferPlan(mode: .httpGet, url: url, expiresAt: expiry,
            expectedByteCount: 3, checksum: checksum)
        #expect(try V2ClientMediaTransferTarget(downloadPlan: foreground).backgroundDownloadAuthorization == nil)
    }
    @Test("download publishes a file only after size and checksum verification", arguments: ["valid", "digest", "length", "partial"])
    func verifiesDownloadedFileBeforePublishing(mode: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResourceDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("published")
        let digest = mode == "digest" ? String(repeating: "0", count: 64)
            : "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let plan = try V2ResourceTransferPlan(mode: .httpGet, url: #require(URL(string: "https://resource-download.test/\(mode)")),
            expiresAt: Date().addingTimeInterval(60), expectedByteCount: mode == "length" ? 4 : 3,
            checksum: .init(value: digest))
        let transfer = V2URLSessionMediaByteTransfer(session: session)
        let target = try V2ClientMediaTransferTarget(downloadPlan: plan)
        if mode == "valid" {
            try await transfer.download(target: target, destinationURL: destination)
            #expect(try Data(contentsOf: destination) == Data("abc".utf8))
            await #expect(throws: V2ClientMediaTransferError.destinationAlreadyExists) {
                try await transfer.download(target: target, destinationURL: destination)
            }
            #expect(try Data(contentsOf: destination) == Data("abc".utf8))
        } else {
            if mode == "partial" {
                await #expect(throws: V2RangeDownloadError.invalidRange) { try await transfer.download(target: target,destinationURL: destination) }
            } else {
                await #expect(throws: mode == "digest" ? V2ClientMediaTransferError.checksumMismatch : .byteCountMismatch) {
                    try await transfer.download(target: target, destinationURL: destination)
                }
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }
    @Test("structured object credentials are vendor-neutral and never forward the account token", arguments:["valid","account-token","missing-plan"])
    func resourcePlanCredentials(_ mode:String) async throws {
        let endpoint=try #require(URL(string:"https://account.invalid/v2/media"))
        let objectURL=try #require(URL(string:"https://independent-edge.invalid/object"))
        let credential=mode == "account-token" ? "Bearer account-secret" : "Bearer object-capability"
        let plan=try V2ResourceTransferPlan(mode:.httpGet,url:objectURL,
            headers:[.init(name:"Authorization",value:credential,kind:.objectCapability),.init(name:"X-Independent-Ticket",value:"opaque")],
            expiresAt:Date().addingTimeInterval(60),expectedByteCount:3,checksum:.init(value:String(repeating:"a",count:64)))
        let envelope = try V2MediaDownloadTargetEnvelope(plan: plan)
        var data=try JSONEncoder().encode(envelope)
        if mode == "missing-plan" {
            var json=try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
            json.removeValue(forKey: "plan")
            data=try JSONSerialization.data(withJSONObject:json)
        }
        let response=try #require(HTTPURLResponse(url:endpoint,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"]))
        let transport=RecordingEdgeTransport(result:.success((data,response)))
        let resolver=try V2HTTPMediaDownloadTargetResolver(endpoint:endpoint,
            credentials:FixedMediaEdgeCredentials(accessToken:"account-secret",deviceID:.init(uuid:UUID())),transport:transport)
        if mode == "valid" {
            let result=try await resolver.resolveDownloadTarget(mediaID:.init(uuid:UUID()))
            #expect(result.headers["Authorization"]=="Bearer object-capability")
            #expect(result.headers["X-Independent-Ticket"]=="opaque")
            #expect(result.checksum==plan.checksum)
        } else {
            await #expect(throws: mode == "account-token" ? V2ClientMediaTransferError.invalidTarget : .invalidMediaEdgeResponse) {
                _ = try await resolver.resolveDownloadTarget(mediaID:.init(uuid:UUID()))
            }
        }
    }
    @Test("download resolves one target and transfers without exposing auth to the caller")
    func downloadUsesResolvedTarget() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let mediaID = try MediaID("media")
        let target = try target(expiresAt: now.addingTimeInterval(30))
        let resolver = RecordingTargetResolver(result: .success(target))
        let transfer = RecordingByteTransfer()
        let service = V2ClientMediaDownloadService(targetResolver: resolver, byteTransfer: transfer, now: { now })
        let destination = URL(fileURLWithPath: "/tmp/v2-media-download")

        try await service.download(mediaID: mediaID, to: destination)

        #expect(await resolver.requestedMedia() == [mediaID])
        #expect(await transfer.downloads() == [.init(target: target, destination: destination)])
    }

    @Test("expired authorization target never reaches byte transfer")
    func expiredTargetDoesNotTransfer() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let resolver = RecordingTargetResolver(result: .success(try target(expiresAt: now.addingTimeInterval(-1))))
        let transfer = RecordingByteTransfer()
        let service = V2ClientMediaDownloadService(targetResolver: resolver, byteTransfer: transfer, now: { now })

        await #expect(throws: V2ClientMediaTransferError.targetExpired) {
            try await service.download(mediaID: .init("media"), to: URL(fileURLWithPath: "/tmp/v2-media-download"))
        }
        #expect(await transfer.downloads().isEmpty)
    }

    @Test("authorization failure never falls through to an unsigned download")
    func authorizationFailureDoesNotTransfer() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let resolver = RecordingTargetResolver(result: .failure(TargetResolutionFailure.denied))
        let transfer = RecordingByteTransfer()
        let service = V2ClientMediaDownloadService(targetResolver: resolver, byteTransfer: transfer, now: { now })

        await #expect(throws: V2ClientMediaTransferError.authorizationUnavailable) {
            try await service.download(mediaID: .init("media"), to: URL(fileURLWithPath: "/tmp/v2-media-download"))
        }
        #expect(await transfer.downloads().isEmpty)
    }

    @Test("explicit authorization denial remains distinguishable from an unavailable edge")
    func preservesAuthorizationDenial() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let resolver = RecordingTargetResolver(result: .failure(V2ClientMediaTransferError.authorizationDenied))
        let transfer = RecordingByteTransfer()
        let service = V2ClientMediaDownloadService(targetResolver: resolver, byteTransfer: transfer, now: { now })

        await #expect(throws: V2ClientMediaTransferError.authorizationDenied) {
            try await service.download(mediaID: .init("media"), to: URL(fileURLWithPath: "/tmp/v2-media-download"))
        }
        #expect(await transfer.downloads().isEmpty)
    }

    @Test("download target requires a complete GET plan and checksum", arguments: [false, true])
    func targetRejectsIncompletePlan(upload: Bool) throws {
        let plan = try V2ResourceTransferPlan(mode: upload ? .httpPut : .httpGet,
            url: #require(URL(string: "https://media.invalid/object")), expiresAt: .now, expectedByteCount: 1,
            checksum: upload ? .init(value: String(repeating: "a", count: 64)) : nil)
        #expect(throws: V2ClientMediaTransferError.invalidTarget) { try V2ClientMediaTransferTarget(downloadPlan: plan) }
    }

    @Test("HTTPS edge resolver keeps gateway authorization separate from the provider target", arguments: [false, true])
    func edgeResolverBuildsNoStoreRequestAndMapsEnvelope(scoped: Bool) async throws {
        let expiry = Date(timeIntervalSince1970: 1_750_000_020)
        let envelope = try V2MediaDownloadTargetEnvelope(plan: .init(mode: .httpGet,
            url: #require(URL(string: "https://provider.invalid/object")),
            headers: [.init(name: "X-Object-Ticket", value: "opaque")], expiresAt: expiry,
            expectedByteCount: 9, checksum: .init(value: String(repeating: "a", count: 64))))
        let credentials = FixedMediaEdgeCredentials(accessToken: "access-token", deviceID: try .init("device"))
        let edgeResponseURL = try #require(URL(string: "https://edge.invalid/v2/media/media"))
        let edgeResponse = try #require(HTTPURLResponse(
            url: edgeResponseURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        let providerURL = try #require(URL(string: "https://provider.invalid/object"))
        let transport = RecordingEdgeTransport(
            result: .success((
                try JSONEncoder().encode(envelope),
                edgeResponse
            ))
        )
        let resolver = try V2HTTPMediaDownloadTargetResolver(
            endpoint: #require(URL(string: "https://edge.invalid/v2/media")),
            credentials: credentials,
            transport: transport
        )

        let location = try V2MediaMessageLocation(roomID: .init("room-value_1"), messageID: .init("message-value_1"))
        let target = try await resolver.resolveDownloadTarget(mediaID: .init("media"), message: scoped ? location : nil)

        #expect(target.url == providerURL)
        #expect(target.headers == ["X-Object-Ticket": "opaque"])
        #expect(target.expectedByteCount == 9)
        let request = try #require(await transport.lastRequest())
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v2/media/media")
        let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query == (scoped ? [.init(name: "room_id", value: location.roomID.rawValue), .init(name: "message_id", value: location.messageID.rawValue)] : nil))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request.value(forHTTPHeaderField: "X-IM-Device-ID") == "device")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    }

    @Test("edge resolver rejects a non-HTTPS endpoint before reading credentials")
    func edgeResolverRejectsInsecureEndpoint() throws {
        #expect(throws: V2ClientMediaTransferError.invalidMediaEdgeEndpoint) {
            _ = try V2HTTPMediaDownloadTargetResolver(
                endpoint: #require(URL(string: "http://edge.invalid/v2/media")),
                credentials: FixedMediaEdgeCredentials(accessToken: "access-token", deviceID: try .init("device"))
            )
        }
    }

    private func target(expiresAt: Date) throws -> V2ClientMediaTransferTarget {
        try .init(downloadPlan: .init(mode: .httpGet, url: #require(URL(string: "https://media.invalid/object")),
            headers: [.init(name: "X-Object-Ticket", value: "opaque")], expiresAt: expiresAt,
            expectedByteCount: 4, checksum: .init(value: String(repeating: "a", count: 64))))
    }
}

private final class ResourceDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    // No shared mutable state; each request returns the same fixture through its own client.
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "resource-download.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: url.lastPathComponent == "partial" ? 206 : 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "3", "Content-Type": "application/octet-stream"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("abc".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor RecordingTargetResolver: V2ClientMediaDownloadTargetResolver {
    private let result: Result<V2ClientMediaTransferTarget, Error>
    private var requests: [MediaID] = []

    init(result: Result<V2ClientMediaTransferTarget, Error>) { self.result = result }
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) throws -> V2ClientMediaTransferTarget {
        requests.append(mediaID)
        return try result.get()
    }
    func requestedMedia() -> [MediaID] { requests }
}

private actor RecordingByteTransfer: V2ClientMediaByteTransfer {
    struct Download: Equatable, Sendable { let target: V2ClientMediaTransferTarget; let destination: URL }
    private var receivedDownloads: [Download] = []
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) { receivedDownloads.append(.init(target: target, destination: destinationURL)) }
    func downloads() -> [Download] { receivedDownloads }
}

private enum TargetResolutionFailure: Error { case denied }

private struct FixedMediaEdgeCredentials: V2ClientMediaEdgeCredentialProvider {
    let accessToken: String
    let deviceID: DeviceID
    func mediaEdgeCredentials() -> V2ClientMediaEdgeCredentials {
        .init(accessToken: accessToken, deviceID: deviceID)
    }
}

private actor RecordingEdgeTransport: V2ClientMediaEdgeHTTPTransport {
    private let result: Result<(Data, HTTPURLResponse), Error>
    private var request: URLRequest?

    init(result: Result<(Data, HTTPURLResponse), Error>) { self.result = result }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        self.request = request
        return try result.get()
    }
    func lastRequest() -> URLRequest? { request }
}
