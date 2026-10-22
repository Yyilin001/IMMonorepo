import AsyncHTTPClient
import Foundation
import IMV2ServerApplication
import NIOCore

struct V2OSSResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}

/// A lifecycle-owned HTTP connection pool. Redirects cannot forward signed credentials.
public final class V2OSSClient: Sendable {
    let configuration: V2OSSConfiguration
    let credentials: V2OSSCredentialProvider
    private let http: HTTPClient

    public init(configuration: V2OSSConfiguration, credentials: V2OSSCredentialProvider) {
        self.configuration = configuration; self.credentials = credentials
        self.http = HTTPClient(configuration: .init(redirectConfiguration: .disallow))
    }
    public func shutdown() async throws { try await http.shutdown() }

    func signer() async throws -> V2OSSSigner {
        try await .init(region: configuration.region, bucket: configuration.bucket, credentials: credentials.load())
    }

    func request(_ method: String, key: String, query: [String: String] = [:],
                 headers: [String: String] = [:], body: V2ResourceByteStream? = nil,
                 byteCount: Int64 = 0, maximumResponseBytes: Int = 65_536) async throws -> V2OSSResponse {
        var url = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false)!
        url.percentEncodedPath = "/" + V2OSSSigner.encode(key, preserveSlash: true)
        if !query.isEmpty { url.percentEncodedQuery = V2OSSSigner.queryString(query) }
        let signed = try await signer().authorization(method: method, key: key, query: query,
            headers: headers, additionalHeaders: Set(headers.keys.filter { !$0.hasPrefix("x-oss-") }), now: Date())
        var request = HTTPClientRequest(url: url.url!.absoluteString)
        request.method = .init(rawValue: method)
        for (name, value) in signed { request.headers.add(name: name, value: value) }
        if let body {
            request.body = .stream(V2OSSBodySequence(stream: body), length: .known(byteCount))
        } else if method == "PUT" { request.body = .bytes(Data()) }
        do {
            let response = try await http.execute(request, timeout: .seconds(120))
            let collected = try await response.body.collect(upTo: maximumResponseBytes)
            var resultHeaders: [String: String] = [:]
            for (name, value) in response.headers { resultHeaders[name.lowercased()] = value }
            return .init(status: Int(response.status.code), headers: resultHeaders,
                         body: Data(collected.readableBytesView))
        } catch is CancellationError { throw CancellationError()
        } catch {
            try Task.checkCancellation()
            // Transport failures may happen after a PUT commits. Never leak SDK URLs/tokens.
            throw method == "PUT" ? V2ResourceProviderError.operationOutcomeUnknown : .temporarilyUnavailable
        }
    }

    static func require(_ response: V2OSSResponse, statuses: Set<Int> = [200]) throws {
        guard !statuses.contains(response.status) else { return }
        switch response.status {
        case 404: throw V2ResourceProviderError.notFound
        case 409, 412: throw V2ResourceProviderError.preconditionFailed
        case 429, 503: throw V2ResourceProviderError.throttled(retryAfter: 1)
        case 500...599: throw V2ResourceProviderError.temporarilyUnavailable
        default: throw V2ResourceProviderError.configurationInvalid
        }
    }

    /// No-overwrite is ineffective on enabled/suspended versioned buckets. Fail closed.
    /// A private bucket also prevents unsigned reads of stored resource bytes.
    public func verifyReadiness() async throws {
        let versioning = try await request("GET", key: "", query: ["versioning": ""])
        try Self.require(versioning)
        let versionText = String(decoding: versioning.body, as: UTF8.self)
        guard versionText.contains("VersioningConfiguration"), !versionText.contains("<Status>") else {
            throw V2ResourceProviderError.configurationInvalid
        }
        let acl = try await request("GET", key: "", query: ["acl": ""])
        try Self.require(acl)
        guard String(decoding: acl.body, as: UTF8.self).contains("<Grant>private</Grant>") else {
            throw V2ResourceProviderError.configurationInvalid
        }
    }
}

private struct V2OSSBodySequence: AsyncSequence, Sendable {
    typealias Element = ByteBuffer
    let stream: V2ResourceByteStream
    struct AsyncIterator: AsyncIteratorProtocol {
        let stream: V2ResourceByteStream
        mutating func next() async throws -> ByteBuffer? {
            guard let bytes = try await stream.next() else { return nil }
            return ByteBuffer(bytes: bytes)
        }
    }
    func makeAsyncIterator() -> AsyncIterator { .init(stream: stream) }
}
