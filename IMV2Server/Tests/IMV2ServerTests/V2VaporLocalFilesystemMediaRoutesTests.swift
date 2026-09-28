import HTTPTypes
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
                fileIO: app.fileio,
                publicBaseURL: try #require(URL(string: "https://localhost:8443")),
                maximumUploadBytes: 1_024
            ).register(on: app)

            try await app.testing { client in
                let response = try await client.send(.put, headers: [.contentType: "text/plain"], to: URI(string: requestPath(for: upload.url)), beforeSend: { $0.body = .init(data: Data(buffer: byteBuffer(payload))) })
                #expect(response.status == .noContent)
                #expect(response.headers[.cacheControl] == "no-store")
            }

            let download = try await provider.issueDownloadTarget(
                mediaID: mediaID,
                expiresAt: Date().addingTimeInterval(30)
            )
            try await app.testing { client in
                let response = try await client.send(.get, to: URI(string: requestPath(for: download.url)))
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                #expect((try await response.body.data() ?? Data()) == payload)
            }

            let staging = root.appendingPathComponent(".upload-staging", isDirectory: true)
            #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        }
    }

    @Test("running media edge flushes a buffered upload and streams back exact bytes")
    func runningUploadFlushesBytes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("im-v2-local-media-route-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = try V2LocalFilesystemMediaProvider(
            rootDirectory: root,
            targetBaseURL: try #require(URL(string: "https://localhost:8443")),
            signingKey: Data(repeating: 0x43, count: 32)
        )
        let mediaID = try MediaID(UUID().uuidString)
        let payload = Data((0..<131_071).map { UInt8(truncatingIfNeeded: $0) })
        let upload = try await provider.issueUploadTarget(
            mediaID: mediaID, contentType: "application/octet-stream",
            byteCount: Int64(payload.count), expiresAt: Date().addingTimeInterval(30)
        )

        try await withApp { app in
            V2RedactedHTTPMiddlewareConfiguration.install(on: app)
            try V2VaporLocalFilesystemMediaRoutes(
                provider: provider,
                fileIO: app.fileio,
                publicBaseURL: try #require(URL(string: "https://localhost:8443")),
                maximumUploadBytes: 131_072
            ).register(on: app)
            try await app.testing(.running) { client in
                let uploaded = try await client.put(URI(string: requestPath(for: upload.url)), headers: [.contentType: "application/octet-stream"]) {
                    $0.body = .init(data: payload)
                }
                #expect(uploaded.status == .noContent)
                let download = try await provider.issueDownloadTarget(
                    mediaID: mediaID, expiresAt: Date().addingTimeInterval(30)
                )
                let downloaded = try await client.get(URI(string: requestPath(for: download.url)))
                #expect(downloaded.status == .ok)
                #expect(downloaded.headers[.cacheControl] == "no-store")
                #expect(try await downloaded.body.data() == payload)
                let partial = try await client.get(
                    URI(string: requestPath(for: download.url)), headers: [.range: "bytes=100-199"]
                )
                #expect(partial.status == .partialContent)
                #expect(partial.headers[.contentRange] == "bytes 100-199/131071")
                #expect(try await partial.body.data() == payload.subdata(in: 100..<200))
                let eTag = try #require(downloaded.headers[.eTag])
                #expect(eTag.hasPrefix("\"") && eTag.hasSuffix("\""))
                #expect(!eTag.hasPrefix("W/"))
                let matched = try await client.get(
                    URI(string: requestPath(for: download.url)),
                    headers: [.range: "bytes=100-199", .ifRange: eTag]
                )
                #expect(matched.status == .partialContent)
                #expect(matched.headers[.eTag] == eTag)
                #expect(matched.headers[.contentRange] == "bytes 100-199/131071")
                #expect(try await matched.body.data() == payload.subdata(in: 100..<200))
                let stale = try await client.get(
                    URI(string: requestPath(for: download.url)),
                    headers: [.range: "bytes=200000-200099", .ifRange: "\"stale-object-version\""]
                )
                #expect(stale.status == .ok)
                #expect(stale.headers[.eTag] == eTag)
                #expect(stale.headers[.contentRange] == nil)
                #expect(try await stale.body.data() == payload)
            }
            let staging = root.appendingPathComponent(".upload-staging", isDirectory: true)
            #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        }
    }

    @Test("interrupted socket upload discards staged bytes")
    func cancelledUploadDiscardsStaging() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("im-v2-local-media-route-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = try V2LocalFilesystemMediaProvider(
            rootDirectory: root,
            targetBaseURL: try #require(URL(string: "https://localhost:8443")),
            signingKey: Data(repeating: 0x44, count: 32)
        )
        let mediaID = try MediaID(UUID().uuidString)
        let upload = try await provider.issueUploadTarget(
            mediaID: mediaID, contentType: "application/octet-stream",
            byteCount: 16_384, expiresAt: Date().addingTimeInterval(30)
        )
        let staging = root.appendingPathComponent(".upload-staging", isDirectory: true)
        let probe = StagingProbe()

        try await withApp { app in
            V2RedactedHTTPMiddlewareConfiguration.install(on: app)
            try V2VaporLocalFilesystemMediaRoutes(
                provider: provider,
                fileIO: app.fileio,
                publicBaseURL: try #require(URL(string: "https://localhost:8443")),
                maximumUploadBytes: 16_384
            ).register(on: app)
            try await app.testing(.running) { client in
                do {
                    _ = try await client.put(URI(string: requestPath(for: upload.url)), headers: [.contentType: "application/octet-stream"]) { request in
                        request.timeout = .seconds(5)
                        request.body = try .init(stream: { writer in
                            try await writer.write(Array(repeating: UInt8(0x5a), count: 4_096))
                            for _ in 0..<200 {
                                if (try? Self.hasStagingFileOrOpenDescriptor(at: staging)) == true {
                                    await probe.markObserved()
                                    break
                                }
                                try await Task.sleep(for: .milliseconds(10))
                            }
                            throw CancellationError()
                        }, count: 16_384)
                    }
                } catch { /* The client aborted its request body on purpose. */ }
            }
            #expect(await probe.observed)
            for _ in 0..<200 {
                if (try? Self.hasStagingFileOrOpenDescriptor(at: staging)) == false { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try !Self.hasStagingFileOrOpenDescriptor(at: staging))
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
                fileIO: app.fileio,
                publicBaseURL: try #require(URL(string: "https://localhost:8443")),
                maximumUploadBytes: 1_024
            ).register(on: app)

            try await app.testing { client in
                let response = try await client.send(.put, headers: [
                    .contentType: "application/octet-stream",
                ], to: URI(string: requestPath(for: upload.url)), beforeSend: { $0.body = .init(data: Data(buffer: byteBuffer(Data(repeating: 0x41, count: 2_048)))) })
                #expect(response.status == .contentTooLarge)
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
                fileIO: app.fileio,
                publicBaseURL: try #require(URL(string: "https://localhost:8443")),
                maximumUploadBytes: 1_024
            ).register(on: app)

            try await app.testing { client in
                let response = try await client.send(.put, headers: [.contentType: "text/plain"], to: URI(string: "v2/local-media/upload/\(UUID().uuidString)?target=invalid"), beforeSend: { $0.body = .init(data: Data(buffer: byteBuffer(Data("x".utf8)))) })
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test("the streaming counter rejects bytes beyond the declared edge budget")
    func streamingCounterEnforcesActualBytes() throws {
        let counter = V2StreamingUploadByteCounter(maximumBytes: 5)
        try counter.consume(3)
        try counter.consume(2)
        do {
            try counter.consume(1)
            Issue.record("streaming upload accepted bytes over its actual limit")
        } catch let abort as Abort {
            #expect(abort.status == .contentTooLarge)
        }
    }

    /// Linux's transactional new-file handle can hold the upload as an unlinked
    /// O_TMPFILE until close, so the staging directory can remain empty while
    /// bytes are being written. The test owns a unique staging directory.
    private static func hasStagingFileOrOpenDescriptor(at staging: URL) throws -> Bool {
        let files = try FileManager.default.contentsOfDirectory(atPath: staging.path)
        if !files.isEmpty { return true }
        #if os(Linux)
        let prefix = staging.standardizedFileURL.path + "/"
        for descriptor in try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd") {
            let path = "/proc/self/fd/" + descriptor
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
               destination.hasPrefix(prefix) {
                return true
            }
        }
        #endif
        return false
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

private actor StagingProbe {
    private(set) var observed = false
    func markObserved() { observed = true }
}
