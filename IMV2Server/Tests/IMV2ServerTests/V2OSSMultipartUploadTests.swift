import AsyncHTTPClient
import Crypto
import Foundation
import IMV2Core
import IMV2ServerApplication
import Testing
@testable import IMV2ServerInfrastructure

struct V2OSSMultipartUploadTests {
    @Test func restartResumesMissingPartAndStreamsExactContent() async throws {
        let origin = OSSMultipartTestOrigin()
        let configuration = try originConfiguration()
        let transport = V2OSSUploadTransport(client: originClient(origin, configuration: configuration))
        let media = MediaID(uuid: UUID()), session = MediaUploadSessionID(uuid: UUID())
        let first = Data(repeating: 7, count: 8 * 1_024 * 1_024), last = Data([1, 2, 3])
        let content = first + last, checksum = try ossMultipartChecksum(content)
        #expect(transport.capabilities.modes == [.httpPartPut, .httpPut] && transport.maximumParts == 32)
        let one = try #require(try await transport.partPlans(mediaID: media, contentType: "application/octet-stream",
            byteCount: Int64(content.count), checksum: checksum, requestedParts: [], expiresAt: .now.addingTimeInterval(60)).first)
        #expect(one.partNumber == 1 && one.byteRange?.lowerBound == 0 && one.expectedByteCount == Int64(first.count))
        #expect(await origin.nativePut(one, bytes: first) == 200)
        // The native write succeeded even if its response was lost. No process-local state is reused.
        let restarted = V2OSSUploadTransport(client: originClient(origin, configuration: configuration))
        let instant = Date()
        let two = try #require(try await restarted.backgroundPlans(mode: .httpPartPut, mediaID: media,
            contentType: "application/octet-stream", byteCount: Int64(content.count), checksum: checksum,
            requestedParts: [], sessionID: session, generation: 4, issuedAt: instant, expiresAt: instant.addingTimeInterval(600)).first)
        #expect(two.partNumber == 2 && two.byteRange?.lowerBound == Int64(first.count) && two.expectedByteCount == 3)
        let grant = try #require(two.backgroundAuthorization)
        #expect(grant.sessionID == session && grant.generation == 4 && grant.mediaID == media && grant.partNumber == 2)
        let query = try #require(URLComponents(url: two.url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains { $0.name == "x-oss-additional-headers" && $0.value == "content-length" })
        #expect(two.headers.contains { $0.name == "x-oss-forbid-overwrite" && $0.value == "true" })
        #expect(two.headers.contains { $0.name == "x-oss-object-acl" && $0.value == "private" })
        #expect(two.headers.allSatisfy { $0.name.lowercased() != "authorization" })
        #expect(await origin.nativePut(two, bytes: last) == 200)
        let confirmed = try await restarted.confirmedParts(mediaID: media, byteCount: Int64(content.count), checksum: checksum)
        #expect(confirmed.map(\.number) == [1, 2])
        #expect(try await restarted.partPlans(mediaID: media, contentType: "application/octet-stream",
            byteCount: Int64(content.count), checksum: checksum, requestedParts: [], expiresAt: .now.addingTimeInterval(60)).isEmpty)
        let input = try await restarted.completedParts(mediaID: media, byteCount: Int64(content.count), checksum: checksum, parts: confirmed)
        #expect(try await collectOSSMultipart(input) == content)
        #expect(await origin.getCount == 9)
        let whole = try #require(try await restarted.backgroundPlans(mode: .httpPut, mediaID: MediaID(uuid: UUID()),
            contentType: "application/octet-stream", byteCount: Int64(content.count), checksum: checksum,
            requestedParts: [], sessionID: session, generation: 4, issuedAt: instant, expiresAt: instant.addingTimeInterval(600)).first)
        #expect(whole.byteRange == nil && whole.checksum == checksum)
        #expect(whole.backgroundAuthorization?.scope == .whole(byteCount: Int64(content.count), checksum: checksum))
    }

    @Test(arguments: ["length", "receipt", "replacement", "digest"])
    func inconsistentPartsCannotComplete(fault: String) async throws {
        let origin = OSSMultipartTestOrigin()
        let transport = V2OSSUploadTransport(client: originClient(origin, configuration: try originConfiguration()))
        let media = MediaID(uuid: UUID()), content = Data(repeating: 31, count: 65_537)
        let checksum = try ossMultipartChecksum(content)
        let plan = try #require(try await transport.partPlans(mediaID: media, contentType: "application/octet-stream",
            byteCount: Int64(content.count), checksum: checksum, requestedParts: [], expiresAt: .now.addingTimeInterval(60)).first)
        #expect(await origin.nativePut(plan, bytes: content) == 200)
        if fault == "length" {
            await origin.replace(plan.url, bytes: content + Data([0]))
            await #expect(throws: V2ResourceProviderError.integrityMismatch) {
                _ = try await transport.confirmedParts(mediaID: media, byteCount: Int64(content.count), checksum: checksum)
            }
            return
        }
        let confirmed = try await transport.confirmedParts(mediaID: media, byteCount: Int64(content.count), checksum: checksum)
        if fault == "receipt" {
            let forged = try V2ResourceUploadPart(number: 1, byteCount: Int64(content.count), receipt: "forged")
            await #expect(throws: V2ResourceProviderError.preconditionFailed) {
                _ = try await transport.completedParts(mediaID: media, byteCount: Int64(content.count), checksum: checksum, parts: [forged])
            }
            return
        }
        let input = try await transport.completedParts(mediaID: media, byteCount: Int64(content.count), checksum: checksum, parts: confirmed)
        if fault == "replacement" {
            await origin.replace(plan.url, bytes: Data(repeating: 32, count: content.count))
            await #expect(throws: V2ResourceProviderError.preconditionFailed) { _ = try await input.next() }
        } else {
            await origin.setCorruptReads()
            await #expect(throws: V2ResourceProviderError.integrityMismatch) { _ = try await collectOSSMultipart(input) }
        }
        await #expect(throws: V2ResourceProviderError.preconditionFailed) { _ = try await input.next() }
    }

    @Test func interruptedAbortSealsUploadedAndStillMissingPartsOnRetry() async throws {
        let origin = OSSMultipartTestOrigin(), configuration = try originConfiguration()
        let transport = V2OSSUploadTransport(client: originClient(origin, configuration: configuration))
        let media = MediaID(uuid: UUID()), first = Data(repeating: 4, count: 8 * 1_024 * 1_024), last = Data([8])
        let checksum = try ossMultipartChecksum(first + last), total = Int64(first.count + last.count)
        let plans = try await transport.partPlans(mediaID: media, contentType: "application/octet-stream",
            byteCount: total, checksum: checksum, requestedParts: [1, 2], expiresAt: .now.addingTimeInterval(60))
        #expect(plans.count == 2)
        #expect(await origin.nativePut(plans[0], bytes: first) == 200)
        await origin.failNextTombstone(part: 2)
        await #expect(throws: V2ResourceProviderError.throttled(retryAfter: 1)) {
            try await transport.abortParts(mediaID: media, byteCount: total, checksum: checksum)
        }
        #expect(await origin.nativePut(plans[0], bytes: first) == 409)
        let restarted = V2OSSUploadTransport(client: originClient(origin, configuration: configuration))
        try await restarted.abortParts(mediaID: media, byteCount: total, checksum: checksum)
        // A native PUT that had been issued before cancellation can no longer commit.
        #expect(await origin.nativePut(plans[1], bytes: last) == 409)
        #expect(try await restarted.confirmedParts(mediaID: media, byteCount: total, checksum: checksum).isEmpty)
        #expect(await origin.allStoredBytesAreEmpty())
        #expect(await origin.methods.allSatisfy { ["HEAD", "PUT"].contains($0) })
    }

    @Test func boundsAndProviderFailuresDoNotIssueAnUnboundedOrDuplicateGrant() async throws {
        let origin = OSSMultipartTestOrigin()
        let transport = V2OSSUploadTransport(client: originClient(origin, configuration: try originConfiguration()))
        let media = MediaID(uuid: UUID()), checksum = try ossMultipartChecksum(Data([1]))
        for count in [Int64(0), Int64(256 * 1_024 * 1_024 + 1)] {
            await #expect(throws: V2ResourceProviderError.unsupportedCapability) {
                _ = try await transport.partPlans(mediaID: media, contentType: "text/plain", byteCount: count,
                    checksum: checksum, requestedParts: [], expiresAt: .now.addingTimeInterval(60))
            }
        }
        for requested in [[0], [33], [1, 1], Array(1...17)] {
            await #expect(throws: V2ResourceProviderError.preconditionFailed) {
                _ = try await transport.partPlans(mediaID: media, contentType: "text/plain", byteCount: 256 * 1_024 * 1_024,
                    checksum: checksum, requestedParts: requested, expiresAt: .now.addingTimeInterval(60))
            }
        }
        #expect(await origin.methods.isEmpty)
        await origin.failNextHead()
        await #expect(throws: V2ResourceProviderError.throttled(retryAfter: 1)) {
            _ = try await transport.partPlans(mediaID: media, contentType: "text/plain", byteCount: 1,
                checksum: checksum, requestedParts: [], expiresAt: .now.addingTimeInterval(60))
        }
        let maximum = try #require(try await transport.partPlans(mediaID: media, contentType: "text/plain", byteCount: 256 * 1_024 * 1_024,
            checksum: checksum, requestedParts: [32], expiresAt: .now.addingTimeInterval(60)).first)
        #expect(maximum.expectedByteCount == 8 * 1_024 * 1_024 && maximum.byteRange?.upperBound == 256 * 1_024 * 1_024 - 1)
    }
}

func ossMultipartChecksum(_ data: Data) throws -> V2ResourceChecksum {
    try .init(value: V2OSSSigner.hex(Data(SHA256.hash(data: data))))
}

func collectOSSMultipart(_ input: V2ResourceByteStream) async throws -> Data {
    var data = Data()
    while let chunk = try await input.next() { #expect(chunk.count <= 65_536); data.append(chunk) }
    return data
}

func originConfiguration() throws -> V2OSSConfiguration {
    try .init(bucket: "fixture-bucket", region: "cn-shenzhen", endpoint: #require(URL(string: "https://fixture-bucket.oss-cn-shenzhen.aliyuncs.com")),
        prefix: "validation/" + UUID().uuidString.lowercased() + "/", binding: .init(id: "oss-parts", configurationRevision: 1))
}

func originClient(_ origin: OSSMultipartTestOrigin, configuration: V2OSSConfiguration) -> V2OSSClient {
    .init(configuration: configuration, credentials: .init(load: { .init(accessKeyID: "test-key", accessKeySecret: "test-secret") }),
        execute: { request, maximum in try await origin.execute(request, maximumBytes: maximum) })
}

/// Synthetic OSS responses at the signed HTTP boundary; no credentials or cloud writes.
actor OSSMultipartTestOrigin {
    private struct Object { let bytes: Data; let etag: String; let deleted: Bool }
    private var objects: [String: Object] = [:]
    private var failingPart: Int?
    private var failHead = false
    private var corruptReads = false
    private(set) var getCount = 0
    private(set) var methods: [String] = []

    func failNextTombstone(part: Int) { failingPart = part }
    func failNextHead() { failHead = true }
    func setCorruptReads() { corruptReads = true }
    func allStoredBytesAreEmpty() -> Bool { objects.values.allSatisfy { $0.bytes.isEmpty && $0.deleted } }

    func nativePut(_ plan: V2ResourceTransferPlan, bytes: Data) -> Int {
        guard Int64(bytes.count) == plan.expectedByteCount else { return 400 }
        guard objects[plan.url.path] == nil else { return 409 }
        replace(plan.url, bytes: bytes)
        return 200
    }
    func replace(_ url: URL, bytes: Data) {
        objects[url.path] = .init(bytes: bytes, etag: "\"" + V2OSSSigner.hex(Data(SHA256.hash(data: bytes))) + "\"", deleted: false)
    }
    func execute(_ request: HTTPClientRequest, maximumBytes: Int) throws -> V2OSSResponse {
        let key = try #require(URL(string: request.url)?.path)
        #expect(request.headers.first(name: "authorization")?.hasPrefix("OSS4-HMAC-SHA256") == true)
        #expect(request.headers.first(name: "x-oss-date") != nil)
        methods.append(request.method.rawValue)
        switch request.method.rawValue {
        case "HEAD":
            if failHead { failHead = false; return .init(status: 503, headers: [:], body: Data()) }
            guard let object = objects[key] else { return .init(status: 404, headers: [:], body: Data()) }
            var headers = ["content-length": String(object.bytes.count), "etag": object.etag]
            if object.deleted { headers["x-oss-meta-im-deleted"] = "true" }
            return .init(status: 200, headers: headers, body: Data())
        case "GET":
            getCount += 1
            guard let object = objects[key] else { return .init(status: 404, headers: [:], body: Data()) }
            guard request.headers.first(name: "if-match") == object.etag else { return .init(status: 412, headers: [:], body: Data()) }
            let range = try #require(request.headers.first(name: "range"))
            let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
            guard bounds.count == 2, bounds[0] >= 0, bounds[1] >= bounds[0], bounds[1] < object.bytes.count else {
                return .init(status: 416, headers: [:], body: Data())
            }
            var bytes = object.bytes.subdata(in: bounds[0]..<(bounds[1] + 1))
            #expect(bytes.count <= maximumBytes)
            if corruptReads { bytes[0] ^= 1 }
            return .init(status: 206, headers: ["etag": object.etag,
                "content-range": "bytes \(bounds[0])-\(bounds[1])/\(object.bytes.count)"], body: bytes)
        case "PUT":
            #expect(request.headers.first(name: "x-oss-meta-im-deleted") == "true")
            #expect(request.headers.first(name: "x-oss-forbid-overwrite") == nil)
            if let failingPart, key.hasSuffix("/\(failingPart)") {
                self.failingPart = nil
                return .init(status: 503, headers: [:], body: Data())
            }
            objects[key] = .init(bytes: Data(), etag: "deleted-" + UUID().uuidString, deleted: true)
            return .init(status: 200, headers: [:], body: Data())
        default:
            Issue.record("Unexpected OSS method")
            return .init(status: 400, headers: [:], body: Data())
        }
    }
}
