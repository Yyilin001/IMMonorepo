import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 native media transfer")
struct V2MediaTransferTests {
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

    @Test("target model rejects plaintext URLs and malformed headers")
    func targetValidationRejectsUnsafeValues() async throws {
        #expect(throws: V2ClientMediaTransferError.invalidTarget) {
            _ = try V2ClientMediaTransferTarget(url: try #require(URL(string: "http://media.invalid/object")), expiresAt: .now)
        }
        #expect(throws: V2ClientMediaTransferError.invalidTarget) {
            _ = try V2ClientMediaTransferTarget(url: try #require(URL(string: "https://media.invalid/object")), headers: ["x-test": "line\nbreak"], expiresAt: .now)
        }
    }

    @Test("HTTPS edge resolver keeps gateway authorization separate from the provider target")
    func edgeResolverBuildsNoStoreRequestAndMapsEnvelope() async throws {
        let expiry = Date(timeIntervalSince1970: 1_750_000_020)
        let envelope = try V2MediaDownloadTargetEnvelope(
            url: #require(URL(string: "https://provider.invalid/object")),
            headers: ["x-provider": "opaque"],
            expiresAt: expiry,
            expectedByteCount: 9
        )
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

        let target = try await resolver.resolveDownloadTarget(mediaID: .init("media"))

        #expect(target.url == providerURL)
        #expect(target.headers == ["x-provider": "opaque"])
        #expect(target.expectedByteCount == 9)
        let request = try #require(await transport.lastRequest())
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://edge.invalid/v2/media/media")
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

    @Test("upload resolves a device-bound target, transfers exact bytes, then completes")
    func uploadCompletesOnlyAfterByteTransfer() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let mediaID = try MediaID("media")
        let operationID = try MediaUploadOperationID("operation")
        let target = try target(expiresAt: now.addingTimeInterval(30))
        let resolver = RecordingUploadTargetResolver(result: .success(target))
        let transfer = UploadRecordingByteTransfer()
        let completer = RecordingUploadCompleter()
        let statusReader = RecordingUploadStatusReader(states: [.scanning, .available])
        let service = V2ClientMediaUploadService(
            targetResolver: resolver,
            byteTransfer: transfer,
            completer: completer,
            statusReader: statusReader,
            now: { now },
            sleep: { _ in }
        )
        let fileURL = URL(fileURLWithPath: "/tmp/v2-media-upload")

        try await service.upload(
            fileURL: fileURL,
            operationID: operationID,
            mediaID: mediaID,
            contentType: "image/png",
            byteCount: 4
        )

        #expect(await resolver.requests() == [.init(operationID: operationID, mediaID: mediaID, contentType: "image/png", byteCount: 4)])
        #expect(await transfer.uploads() == [.init(fileURL: fileURL, target: target)])
        #expect(await completer.completedMedia() == [mediaID])
        #expect(await statusReader.requestedMedia() == [mediaID, mediaID])
    }

    @Test("failed byte upload does not call the durable completion endpoint")
    func uploadDoesNotCompleteAfterByteFailure() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let resolver = RecordingUploadTargetResolver(result: .success(try target(expiresAt: now.addingTimeInterval(30))))
        let transfer = UploadRecordingByteTransfer(uploadError: V2ClientMediaTransferError.networkFailure)
        let completer = RecordingUploadCompleter()
        let service = V2ClientMediaUploadService(
            targetResolver: resolver,
            byteTransfer: transfer,
            completer: completer,
            statusReader: RecordingUploadStatusReader(states: [.available]),
            now: { now }
        )

        await #expect(throws: V2ClientMediaTransferError.networkFailure) {
            try await service.upload(
                fileURL: URL(fileURLWithPath: "/tmp/v2-media-upload"),
                operationID: .init("operation"),
                mediaID: .init("media"),
                contentType: "image/png",
                byteCount: 4
            )
        }
        #expect(await completer.completedMedia().isEmpty)
    }

    @Test("upload edge client produces no-store metadata request and completes through the same authenticated boundary")
    func httpUploadClientMapsTargetAndCompletion() async throws {
        let expiry = Date(timeIntervalSince1970: 1_750_000_020)
        let envelope = try V2MediaUploadTargetEnvelope(
            url: #require(URL(string: "https://provider.invalid/upload")),
            headers: ["x-provider": "opaque"],
            expiresAt: expiry,
            expectedByteCount: 4
        )
        let uploadResponseURL = try #require(URL(string: "https://edge.invalid/v2/media/uploads"))
        let completionResponseURL = try #require(URL(string: "https://edge.invalid/v2/media/media/complete"))
        let statusResponseURL = try #require(URL(string: "https://edge.invalid/v2/media/media/upload-status"))
        let transport = SequencedEdgeTransport(responses: [
            .success((try JSONEncoder().encode(envelope), try #require(HTTPURLResponse(url: uploadResponseURL, statusCode: 200, httpVersion: nil, headerFields: nil)))),
            .success((Data(), try #require(HTTPURLResponse(url: completionResponseURL, statusCode: 204, httpVersion: nil, headerFields: nil)))),
            .success((try JSONEncoder().encode(V2MediaUploadStatusEnvelope(state: .available)), try #require(HTTPURLResponse(url: statusResponseURL, statusCode: 200, httpVersion: nil, headerFields: nil)))),
        ])
        let client = try V2HTTPMediaUploadEdgeClient(
            endpoint: #require(URL(string: "https://edge.invalid/v2/media")),
            credentials: FixedMediaEdgeCredentials(accessToken: "access-token", deviceID: try .init("device")),
            transport: transport
        )

        let target = try await client.resolveUploadTarget(
            operationID: .init("operation"),
            mediaID: .init("media"),
            contentType: "image/png",
            byteCount: 4
        )
        try await client.completeUpload(mediaID: .init("media"))
        #expect(try await client.uploadStatus(mediaID: .init("media")) == .available)

        let providerURL = try #require(URL(string: "https://provider.invalid/upload"))
        #expect(target.url == providerURL)
        let requests = await transport.requests()
        #expect(requests.count == 3)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].url?.absoluteString == "https://edge.invalid/v2/media/uploads")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(requests[0].value(forHTTPHeaderField: "X-IM-Device-ID") == "device")
        #expect(requests[0].value(forHTTPHeaderField: "Cache-Control") == "no-store")
        let body = try #require(requests[0].httpBody)
        let input = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(input["operationID"] as? String == "operation")
        #expect(input["mediaID"] as? String == "media")
        #expect(input["contentType"] as? String == "image/png")
        #expect(input["byteCount"] as? Int == 4)
        #expect(requests[1].url?.absoluteString == "https://edge.invalid/v2/media/media/complete")
        #expect(requests[2].httpMethod == "GET")
        #expect(requests[2].url?.absoluteString == "https://edge.invalid/v2/media/media/upload-status")
    }

    private func target(expiresAt: Date) throws -> V2ClientMediaTransferTarget {
        try .init(url: try #require(URL(string: "https://media.invalid/object")), headers: ["x-media": "opaque"], expiresAt: expiresAt, expectedByteCount: 4)
    }
}

private actor RecordingTargetResolver: V2ClientMediaDownloadTargetResolver {
    private let result: Result<V2ClientMediaTransferTarget, Error>
    private var requests: [MediaID] = []

    init(result: Result<V2ClientMediaTransferTarget, Error>) { self.result = result }
    func resolveDownloadTarget(mediaID: MediaID) throws -> V2ClientMediaTransferTarget {
        requests.append(mediaID)
        return try result.get()
    }
    func requestedMedia() -> [MediaID] { requests }
}

private actor RecordingByteTransfer: V2ClientMediaByteTransfer {
    struct Download: Equatable, Sendable { let target: V2ClientMediaTransferTarget; let destination: URL }
    private var receivedDownloads: [Download] = []
    func upload(fileURL _: URL, target _: V2ClientMediaTransferTarget) {}
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) { receivedDownloads.append(.init(target: target, destination: destinationURL)) }
    func downloads() -> [Download] { receivedDownloads }
}

private actor RecordingUploadTargetResolver: V2ClientMediaUploadTargetResolver {
    struct Request: Equatable, Sendable {
        let operationID: MediaUploadOperationID
        let mediaID: MediaID
        let contentType: String
        let byteCount: Int64
    }

    private let result: Result<V2ClientMediaTransferTarget, Error>
    private var receivedRequests: [Request] = []

    init(result: Result<V2ClientMediaTransferTarget, Error>) { self.result = result }

    func resolveUploadTarget(operationID: MediaUploadOperationID, mediaID: MediaID, contentType: String, byteCount: Int64) throws -> V2ClientMediaTransferTarget {
        receivedRequests.append(.init(operationID: operationID, mediaID: mediaID, contentType: contentType, byteCount: byteCount))
        return try result.get()
    }

    func requests() -> [Request] { receivedRequests }
}

private actor UploadRecordingByteTransfer: V2ClientMediaByteTransfer {
    struct Upload: Equatable, Sendable { let fileURL: URL; let target: V2ClientMediaTransferTarget }
    private let uploadError: (any Error)?
    private var receivedUploads: [Upload] = []

    init(uploadError: (any Error)? = nil) { self.uploadError = uploadError }

    func upload(fileURL: URL, target: V2ClientMediaTransferTarget) throws {
        if let uploadError { throw uploadError }
        receivedUploads.append(.init(fileURL: fileURL, target: target))
    }

    func download(target _: V2ClientMediaTransferTarget, destinationURL _: URL) {}
    func uploads() -> [Upload] { receivedUploads }
}

private actor RecordingUploadCompleter: V2ClientMediaUploadCompleting {
    private var media: [MediaID] = []
    func completeUpload(mediaID: MediaID) { media.append(mediaID) }
    func completedMedia() -> [MediaID] { media }
}

private actor RecordingUploadStatusReader: V2ClientMediaUploadStatusReading {
    private var states: [V2MediaObjectState]
    private var media: [MediaID] = []

    init(states: [V2MediaObjectState]) { self.states = states }

    func uploadStatus(mediaID: MediaID) -> V2MediaObjectState {
        media.append(mediaID)
        guard !states.isEmpty else { return .scanning }
        return states.removeFirst()
    }

    func requestedMedia() -> [MediaID] { media }
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

private actor SequencedEdgeTransport: V2ClientMediaEdgeHTTPTransport {
    private var responses: [Result<(Data, HTTPURLResponse), Error>]
    private var receivedRequests: [URLRequest] = []

    init(responses: [Result<(Data, HTTPURLResponse), Error>]) { self.responses = responses }

    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        receivedRequests.append(request)
        guard !responses.isEmpty else { throw TargetResolutionFailure.denied }
        return try responses.removeFirst().get()
    }

    func requests() -> [URLRequest] { receivedRequests }
}
