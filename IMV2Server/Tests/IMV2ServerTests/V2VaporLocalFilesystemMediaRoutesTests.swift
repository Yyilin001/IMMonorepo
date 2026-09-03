import Foundation
import IMV2Core
import IMV2Server
@testable import IMV2ServerHTTP
import NIOCore
import Testing
import Vapor
import VaporTesting

@Suite("V2 local filesystem media routes")
struct V2VaporLocalFilesystemMediaRoutesTests {
    @Test("signed HTTPS targets transfer exact bytes through the Vapor object edge")
    func signedTargetsTransferBytes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("im-v2-local-media-route-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = try V2LocalFilesystemMediaProvider(
            rootDirectory: root,
            targetBaseURL: try #require(URL(string: "https://localhost:8443")),
            signingKey: Data(repeating: 3, count: 32)
        )
        let mediaID = try MediaID(UUID().uuidString)
        let payload = Data("local transfer through HTTP".utf8)
        let upload = try await provider.issueUploadTarget(
            mediaID: mediaID,
            contentType: "text/plain",
            byteCount: Int64(payload.count),
            expiresAt: Date().addingTimeInterval(30)
        )

        try await withApp { app in
            V2RedactedHTTPMiddlewareConfiguration.install(on: app)
            try V2VaporLocalFilesystemMediaRoutes(
                provider: provider,
                publicBaseURL: try #require(URL(string: "https://localhost:8443")),
                maximumUploadBytes: 1_024
            ).register(on: app)
            let tester = try app.testing()
            try await tester.test(
                .PUT,
                requestPath(for: upload.url),
                headers: ["Content-Type": "text/plain"],
                body: byteBuffer(payload)
            ) { response async in
                #expect(response.status == .noContent)
                #expect(response.headers.first(name: .cacheControl) == "no-store")
            }

            let download = try await provider.issueDownloadTarget(
                mediaID: mediaID,
                expiresAt: Date().addingTimeInterval(30)
            )
            try await tester.test(.GET, requestPath(for: download.url)) { response async in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: .cacheControl) == "no-store")
                #expect(Data(buffer: response.body) == payload)
            }

            let staging = root.appendingPathComponent(".upload-staging", isDirectory: true)
            #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        }
    }

    @Test("the streaming upload rejects a declared body above its edge budget before staging bytes")
    func oversizedUploadIsRejectedBeforeStaging() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("im-v2-local-media-route-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = try V2LocalFilesystemMediaProvider(
            rootDirectory: root,
            targetBaseURL: try #require(URL(string: "https://localhost:8443")),
            signingKey: Data(repeating: 5, count: 32)
        )
        let mediaID = try MediaID(UUID().uuidString)
        let upload = try await provider.issueUploadTarget(
            mediaID: mediaID,
            contentType: "application/octet-stream",
            byteCount: 2_048,
            expiresAt: Date().addingTimeInterval(30)
        )

        try await withApp { app in
            V2RedactedHTTPMiddlewareConfiguration.install(on: app)
            try V2VaporLocalFilesystemMediaRoutes(
                provider: provider,
                publicBaseURL: try #require(URL(string: "https://localhost:8443")),
                maximumUploadBytes: 1_024
            ).register(on: app)
            let tester = try app.testing()
            try await tester.test(
                .PUT,
                requestPath(for: upload.url),
                headers: [
                    "Content-Type": "application/octet-stream",
                ],
                body: byteBuffer(Data(repeating: 0x41, count: 2_048))
            ) { response async in
                #expect(response.status == .payloadTooLarge)
            }
            let staging = root.appendingPathComponent(".upload-staging", isDirectory: true)
            #expect(!FileManager.default.fileExists(atPath: staging.path))
        }
    }

    @Test("an invalid local capability is opaque to the byte edge")
    func invalidTargetIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("im-v2-local-media-route-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = try V2LocalFilesystemMediaProvider(
            rootDirectory: root,
            targetBaseURL: try #require(URL(string: "https://localhost:8443")),
            signingKey: Data(repeating: 4, count: 32)
        )
        try await withApp { app in
            V2RedactedHTTPMiddlewareConfiguration.install(on: app)
            try V2VaporLocalFilesystemMediaRoutes(
                provider: provider,
                publicBaseURL: try #require(URL(string: "https://localhost:8443")),
                maximumUploadBytes: 1_024
            ).register(on: app)
            let tester = try app.testing()
            try await tester.test(
                .PUT,
                "v2/local-media/upload/\(UUID().uuidString)?target=invalid",
                headers: ["Content-Type": "text/plain"],
                body: byteBuffer(Data("x".utf8))
            ) { response async in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test("the streaming counter rejects bytes beyond the declared edge budget")
    func streamingCounterEnforcesActualBytes() throws {
        let counter = V2StreamingUploadByteCounter(maximumBytes: 5)
        try counter.consume(3)
        try counter.consume(2)
        #expect(throws: Abort.self) {
            try counter.consume(1)
        }
    }

    private func requestPath(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            Issue.record("invalid test URL")
            return ""
        }
        return components.percentEncodedQuery.map { components.path + "?" + $0 } ?? components.path
    }

    private func byteBuffer(_ data: Data) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }
}
