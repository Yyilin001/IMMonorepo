import Crypto
import Foundation
import HTTPTypes
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ServerHTTP
import IMV2ServerInfrastructure
import Testing
import Vapor
import VaporTesting
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite("Local media reads retain an authorized ordinary file")
struct V2LocalMediaReadBoundaryTests {
    enum Replacement: CaseIterable, Sendable { case symbolicLink, hardLink, directory, fifo }
    enum SwapTime: CaseIterable, Sendable { case beforeHash, afterHash }

    @Test("signed reads and scanning reject links and special files", arguments: Replacement.allCases)
    func rejectsReplacedEntry(_ replacement: Replacement) async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let outside = fixture.base.appendingPathComponent("outside")
        try Data(repeating: 0x42, count: fixture.bytes.count).write(to: outside)
        try FileManager.default.removeItem(at: fixture.object)
        switch replacement {
        case .symbolicLink:
            try FileManager.default.createSymbolicLink(at: fixture.object, withDestinationURL: outside)
        case .hardLink:
            try FileManager.default.linkItem(at: outside, to: fixture.object)
        case .directory:
            try FileManager.default.createDirectory(at: fixture.object, withIntermediateDirectories: false)
        case .fifo:
            #expect(mkfifo(fixture.object.path, 0o600) == 0)
        }
        await #expect(throws: V2LocalFilesystemMediaProviderError.objectUnavailable) {
            _ = try await fixture.provider.readDownloadedObject(mediaID: fixture.id, targetURL: fixture.download)
        }
        await #expect(throws: V2LocalFilesystemMediaProviderError.objectUnavailable) {
            _ = try await fixture.provider.localBytesForScanning(mediaID: fixture.id)
        }
        await #expect(throws: V2LocalFilesystemMediaProviderError.objectUnavailable) {
            _ = try await fixture.provider.issueDownloadTarget(mediaID: fixture.id, expiresAt: Date().addingTimeInterval(60))
        }
    }

    @Test("HTTP hash and range bytes keep the same file across a directory replacement",
          arguments: SwapTime.allCases, [false, true])
    func httpStreamPinsAuthorizedFile(swapTime: SwapTime, range: Bool) async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let provider = SwapProvider(base: fixture.provider, swapTime: swapTime) {
            try fixture.replaceRootWithOutsideDirectory()
        }
        try await withApp { app in
            try V2VaporLocalFilesystemMediaRoutes(provider: provider,
                publicBaseURL: #require(URL(string: "https://local.test")), maximumUploadBytes: 262_144).register(on: app)
            try await app.testing { client in
                let components = try #require(URLComponents(url: fixture.download, resolvingAgainstBaseURL: false))
                let path = components.path + "?" + (components.percentEncodedQuery ?? "")
                let headers: HTTPFields = range ? [.range: "bytes=100-199"] : [:]
                let response = try await client.send(.get, headers: headers, to: URI(string: path))
                #expect(response.status == (range ? .partialContent : .ok))
                let expected = range ? fixture.bytes.subdata(in: 100..<200) : fixture.bytes
                #expect(try await response.body.data() == expected)
                let digest = SHA256.hash(data: fixture.bytes).map { String(format: "%02x", $0) }.joined()
                #expect(response.headers[.eTag] == "\"\(digest)\"")
                #expect(response.headers[.cacheControl] == "no-store")
            }
        }
        // A later request cannot traverse the replacement root symlink either.
        await #expect(throws: V2LocalFilesystemMediaProviderError.objectUnavailable) {
            _ = try await fixture.provider.readDownloadedObject(mediaID: fixture.id, targetURL: fixture.download)
        }
    }

    @Test("a resource stream is pinned before its first chunk and never reopens a replaced root")
    func resourceStreamPinsBeforeConsumption() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("im-read-resource-" + UUID().uuidString)
        let root = base.appendingPathComponent("objects", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let binding = try V2StorageBinding(id: "test-local-read", configurationRevision: 1)
        let storage = try V2LocalResourceStorage(root: root, binding: binding)
        let reference = try storage.allocate()
        let bytes = Data(repeating: 0x31, count: 131_073)
        let digest = Data(SHA256.hash(data: bytes))
        let source = TestChunks(bytes: bytes)
        _ = try await storage.write(reference, byteCount: Int64(bytes.count), sha256: digest,
                                    bytes: .init { await source.next() })
        let stream = try await storage.read(reference)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data(repeating: 0x42, count: bytes.count).write(to: outside.appendingPathComponent(reference.placementID.uuidString.lowercased()))
        try FileManager.default.moveItem(at: root, to: base.appendingPathComponent("original"))
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        var result = Data()
        while let chunk = try await stream.next() { #expect(chunk.count <= 65_536); result.append(chunk) }
        #expect(result == bytes)
        await #expect(throws: (any Error).self) { _ = try await storage.read(reference) }
        await #expect(throws: (any Error).self) { _ = try await storage.inspect(reference) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).count == 1)
    }

    private struct Fixture: Sendable {
        let base: URL
        let root: URL
        let provider: V2LocalFilesystemMediaProvider
        let id: MediaID
        let download: URL
        let bytes: Data
        var object: URL { root.appendingPathComponent(id.rawValue) }
        static func make() async throws -> Self {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("im-read-boundary-" + UUID().uuidString)
            let root = base.appendingPathComponent("objects", isDirectory: true)
            let provider = try V2LocalFilesystemMediaProvider(rootDirectory: root,
                targetBaseURL: #require(URL(string: "https://local.test")), signingKey: Data(repeating: 7, count: 32))
            let id = MediaID(uuid: UUID()), bytes = Data((0..<131_073).map { UInt8(truncatingIfNeeded: $0) })
            let upload = try await provider.issueUploadTarget(mediaID: id, contentType: "application/octet-stream",
                byteCount: Int64(bytes.count), expiresAt: Date().addingTimeInterval(120))
            try await provider.storeUploadedObject(mediaID: id, targetURL: upload.url,
                contentType: "application/octet-stream", bytes: bytes)
            let download = try await provider.issueDownloadTarget(mediaID: id, expiresAt: Date().addingTimeInterval(120))
            return .init(base: base, root: root, provider: provider, id: id, download: download.url, bytes: bytes)
        }
        func replaceRootWithOutsideDirectory() throws {
            let outside = base.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try Data(repeating: 0x42, count: bytes.count).write(to: outside.appendingPathComponent(id.rawValue))
            try FileManager.default.moveItem(at: root, to: base.appendingPathComponent("original"))
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        }
    }

    private struct SwapProvider: V2LocalMediaByteServing {
        let base: V2LocalFilesystemMediaProvider
        let swapTime: SwapTime
        let swap: @Sendable () throws -> Void
        func beginUploadedObject(mediaID: MediaID, targetURL: URL, contentType: String, declaredByteCount: Int64) async throws -> V2LocalFilesystemStagedUpload {
            try await base.beginUploadedObject(mediaID: mediaID, targetURL: targetURL, contentType: contentType, declaredByteCount: declaredByteCount)
        }
        func commitUploadedObject(_ upload: V2LocalFilesystemStagedUpload, actualByteCount: Int64) async throws {
            try await base.commitUploadedObject(upload, actualByteCount: actualByteCount)
        }
        func discardUploadedObject(_ upload: V2LocalFilesystemStagedUpload) async { await base.discardUploadedObject(upload) }
        func downloadedObject(mediaID: MediaID, targetURL: URL) async throws -> SwapObject {
            let file = try await base.downloadedObject(mediaID: mediaID, targetURL: targetURL)
            if swapTime == .beforeHash { try swap() }
            return .init(base: file, swap: swapTime == .afterHash ? swap : nil)
        }
    }

    private struct SwapObject: V2DownloadedMediaFile {
        let base: V2LocalFilesystemDownloadedObject
        let swap: (@Sendable () throws -> Void)?
        var byteCount: Int64 { base.byteCount }
        func strongETag() async throws -> String {
            let result = try await base.strongETag()
            try swap?()
            return result
        }
        func readChunk(offset: Int64, maximumBytes: Int) async throws -> Data {
            try await base.readChunk(offset: offset, maximumBytes: maximumBytes)
        }
    }

    private actor TestChunks {
        let bytes: Data
        var offset = 0
        init(bytes: Data) { self.bytes = bytes }
        func next() -> Data? {
            guard offset < bytes.count else { return nil }
            let end = min(offset + 65_536, bytes.count)
            defer { offset = end }
            return bytes.subdata(in: offset..<end)
        }
    }
}
