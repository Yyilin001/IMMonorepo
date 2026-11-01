import Crypto
import Foundation
import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
import Testing

struct V2OSSRangeReaderTests {
    @Test("OSS reads use bounded larger requests while preserving 64 KiB stream chunks")
    func boundedReadRequestCount() async throws {
        let bytes = Data(repeating: 42, count: 2 * 1_024 * 1_024 + 19)
        let source = RangeSource(bytes: bytes)
        let reader = V2OSSRangeReader(size: Int64(bytes.count), etag: "version", expectedHash: Data(SHA256.hash(data: bytes))) {
            try await source.read(start: $0, end: $1)
        }
        let stream = V2ResourceByteStream { try await reader.next() }
        var result = Data()
        while let chunk = try await stream.next() {
            #expect(chunk.count <= 65_536)
            result.append(chunk)
        }
        #expect(result == bytes)
        #expect(await source.requestCount == 3)
        #expect(try await stream.next() == nil)
    }

    @Test("OSS range and digest failures cannot yield data or resume", arguments: ["etag", "range", "length", "digest"])
    func invalidResponseStopsRead(fault: String) async throws {
        let bytes = Data(repeating: 42, count: 97)
        let source = RangeSource(bytes: bytes, fault: fault)
        let reader = V2OSSRangeReader(size: Int64(bytes.count), etag: "version", expectedHash: Data(SHA256.hash(data: bytes))) {
            try await source.read(start: $0, end: $1)
        }
        await #expect(throws: V2ResourceProviderError.integrityMismatch) { try await reader.next() }
        await #expect(throws: V2ResourceProviderError.preconditionFailed) { try await reader.next() }
        #expect(await source.requestCount == 1)
    }

    @Test("Cancellation stops delivery of already buffered OSS bytes")
    func cancellationBeforeBufferedChunk() async throws {
        let bytes = Data(repeating: 42, count: 128 * 1_024)
        let source = RangeSource(bytes: bytes)
        let reader = V2OSSRangeReader(size: Int64(bytes.count), etag: "version", expectedHash: nil) {
            try await source.read(start: $0, end: $1)
        }
        #expect(try await reader.next()?.count == 65_536)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.next()
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await source.requestCount == 1)
    }
}

private actor RangeSource {
    let bytes: Data
    let fault: String?
    private(set) var requestCount = 0
    init(bytes: Data, fault: String? = nil) { self.bytes = bytes; self.fault = fault }
    func read(start: Int64, end: Int64) throws -> V2OSSResponse {
        requestCount += 1
        #expect(end - start + 1 <= 1_024 * 1_024)
        var body = bytes.subdata(in: Int(start)..<(Int(end) + 1))
        if fault == "length" { body.removeLast() }
        if fault == "digest" { body[0] ^= 1 }
        return .init(status: 206, headers: [
            "etag": fault == "etag" ? "replaced" : "version",
            "content-range": fault == "range" ? "bytes 1-2/3" : "bytes \(start)-\(end)/\(bytes.count)"
        ], body: body)
    }
}
