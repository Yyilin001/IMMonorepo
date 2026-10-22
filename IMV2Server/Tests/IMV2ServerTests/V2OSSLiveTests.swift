import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts
import Testing
@testable import IMV2ServerInfrastructure

/// Explicit opt-in: only synthetic data under a unique prefix in the supplied test bucket.
struct V2OSSLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IM_V2_OSS_LIVE_TEST"] == "1"))
    func realCloudStorageAndUploadContract() async throws {
        let values = ProcessInfo.processInfo.environment
        let bucket = try #require(values["IM_V2_OSS_BUCKET"])
        let region = try #require(values["IM_V2_OSS_REGION"])
        let configuration = try V2OSSConfiguration(bucket: bucket, region: region,
            endpoint: #require(URL(string: "https://\(bucket).oss-\(region).aliyuncs.com")),
            prefix: "validation/\(UUID().uuidString.lowercased())/", binding: .init(id: "oss-test", configurationRevision: 1))
        let client = V2OSSClient(configuration: configuration,
            credentials: .init(environment: V2DictionaryRuntimeEnvironment(values)))
        do {
            try await client.verifyReadiness()
            let storage = V2OSSObjectStorage(client: client)
            let reference = try storage.allocate()
            let bytes = Data((0..<180_000).map { UInt8($0 % 251) })
            let hash = Data(SHA256.hash(data: bytes))
            let expected = try V2StoredObjectFacts(reference: reference, byteCount: Int64(bytes.count), sha256: hash)
            #expect(try await storage.write(reference, byteCount: expected.byteCount, sha256: hash, bytes: stream(bytes)) == expected)
            #expect(try await storage.write(reference, byteCount: expected.byteCount, sha256: hash, bytes: stream(bytes)) == expected)
            #expect(try await collect(storage.read(reference)) == bytes)
            let registry = try V2ResourceStorageRegistry(storages: [storage], defaultBinding: storage.binding)
            let delivery = try V2SignedResourceDelivery(registry: registry, baseURL: URL(string: "https://resource.example")!,
                keyID: "test", keys: ["test": Data(repeating: 8, count: 32)])
            let download = try await delivery.issue(.init(facts: expected, expiresAt: Date().addingTimeInterval(60)))
            let capability = try #require(URLComponents(url: download.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cap" })?.value)
            let served = try await delivery.stream(placementID: reference.placementID, capability: capability)
            do { #expect(try await collect(served.bytes) == bytes); await served.close() }
            catch { await served.close(); throw error }
            let different = Data(repeating: 7, count: bytes.count)
            await #expect(throws: V2ResourceProviderError.integrityMismatch) {
                _ = try await storage.write(reference, byteCount: expected.byteCount,
                    sha256: Data(SHA256.hash(data: different)), bytes: stream(different))
            }
            try await storage.delete(reference)
            try await storage.delete(reference)
            await #expect(throws: V2ResourceProviderError.notFound) { _ = try await storage.inspect(reference) }
            await #expect(throws: V2ResourceProviderError.preconditionFailed) {
                _ = try await storage.write(reference, byteCount: expected.byteCount, sha256: hash, bytes: stream(bytes))
            }

            let uploads = V2OSSUploadTransport(client: client)
            let media = MediaID(uuid: UUID())
            let checksum = try V2ResourceChecksum(algorithm: .sha256, value: V2OSSSigner.hex(hash))
            let plan = try await uploads.plan(mode: .httpPut, mediaID: media, contentType: "application/octet-stream",
                byteCount: expected.byteCount, checksum: checksum, expiresAt: Date().addingTimeInterval(90))
            var request = URLRequest(url: plan.url)
            request.httpMethod = plan.httpMethod
            for header in plan.headers { request.setValue(header.value, forHTTPHeaderField: header.name) }
            #expect(try await upload(request, bytes: bytes) == 200)
            #expect(try await collect(uploads.completedBytes(mediaID: media, byteCount: expected.byteCount)) == bytes)
            try await uploads.abort(mediaID: media)
            #expect(try await upload(request, bytes: bytes) == 409)
            await #expect(throws: V2ResourceProviderError.notFound) {
                _ = try await uploads.completedBytes(mediaID: media, byteCount: expected.byteCount)
            }
            let imported = MediaID(uuid: UUID())
            try await uploads.importBytes(mediaID: imported, contentType: "application/octet-stream", byteCount: expected.byteCount, bytes: stream(bytes))
            try await uploads.importBytes(mediaID: imported, contentType: "application/octet-stream", byteCount: expected.byteCount, bytes: stream(bytes))
            try await uploads.abort(mediaID: imported)

            // Pause an already streaming PUT, delete its exact key, then let it finish.
            // This checks OSS's commit-time no-overwrite fence, not only a late new request.
            let racing = try storage.allocate()
            let racingKey = try storage.key(racing)
            let gate = OSSInFlightUpload(bytes)
            let writing = Task {
                try await client.request("PUT", key: racingKey,
                    headers: ["x-oss-forbid-overwrite": "true", "x-oss-meta-im-sha256": V2OSSSigner.hex(hash)],
                    body: .init { try await gate.next() }, byteCount: expected.byteCount)
            }
            do {
                for _ in 0..<250 {
                    if await gate.paused { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(await gate.paused)
                try await storage.delete(racing)
                await gate.release()
                #expect(try await writing.value.status == 409)
                await #expect(throws: V2ResourceProviderError.notFound) { _ = try await storage.inspect(racing) }
            } catch {
                await gate.release(); writing.cancel(); _ = try? await writing.value
                throw error
            }
            try await client.shutdown()
        } catch { try? await client.shutdown(); throw error }
    }

    private func collect(_ input: V2ResourceByteStream) async throws -> Data {
        var bytes = Data()
        while let chunk = try await input.next() { #expect(chunk.count <= 65_536); bytes.append(chunk) }
        return bytes
    }
    private func upload(_ request: URLRequest, bytes: Data) async throws -> Int {
        do {
            let (_, response) = try await URLSession.shared.upload(for: request, from: bytes)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch { throw V2ResourceProviderError.temporarilyUnavailable }
    }
    private func stream(_ data: Data) -> V2ResourceByteStream {
        let cursor = OSSFixtureCursor(data)
        return .init { await cursor.next() }
    }
}

private actor OSSFixtureCursor {
    let data: Data
    var offset = 0
    init(_ data: Data) { self.data = data }
    func next() -> Data? {
        guard offset < data.count else { return nil }
        let end = min(offset + 65_536, data.count)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
}

private actor OSSInFlightUpload {
    let data: Data
    var offset = 0
    var paused = false
    var released = false
    init(_ data: Data) { self.data = data }
    func release() { released = true }
    func next() async throws -> Data? {
        if offset > 0 && !released {
            paused = true
            while !released { try await Task.sleep(for: .milliseconds(10)) }
        }
        guard offset < data.count else { return nil }
        let end = min(offset + 65_536, data.count)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
}
