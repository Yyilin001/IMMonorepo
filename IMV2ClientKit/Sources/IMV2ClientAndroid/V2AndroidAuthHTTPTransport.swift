import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Dispatch
import IMV2ClientRuntime

/// Bounded account HTTPS transport using Android's application trust configuration.
/// Business payloads, issuance, refresh and recovery remain in the shared runtime.
public struct V2AndroidAuthHTTPTransport: V2AuthHTTPTransport {
    public init() {}
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let execution = Execution()
        return try await withTaskCancellationHandler {
            defer { execution.release() }
            do {
                try Task.checkCancellation()
                let result = try await execution.execute(request)
                try Task.checkCancellation()
                return result
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: { execution.cancel() }
    }
}
private final class Execution: Sendable {
    private struct State { var handle: Int64?; var cancelled = false }
    private let state = V2Lock(initialState: State())
    private let queue = DispatchQueue(label: "im.android.auth-http")
    private struct Input: Encodable { let url: String; let method: String; let headers: [String: String]; let body: String }
    private struct Metadata: Decodable { let status: Int; let headers: [String: String] }
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              request.httpBodyStream == nil, (request.httpBody?.count ?? 0) <= 524_288 else { throw URLError(.badURL) }
        let input = try JSONEncoder().encode(Input(url: url.absoluteString, method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:], body: (request.httpBody ?? Data()).base64EncodedString()))
        return try await AndroidBridge.io(on: queue) { [self] in
            let handle = try state.withLock { state in
                guard !state.cancelled else { throw CancellationError() }
                guard let bytes = try AndroidBridge.call(20, data: input), bytes.count == 8 else { throw URLError(.cannotConnectToHost) }
                let id = bytes.reduce(Int64(0)) { ($0 << 8) | Int64($1) }; state.handle = id; return id
            }
            guard let bytes = try AndroidBridge.call(21, handle: handle), bytes.count >= 4 else { throw URLError(.badServerResponse) }
            let length = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length <= 65_536, bytes.count >= 4 + length else { throw URLError(.badServerResponse) }
            let metadata = try JSONDecoder().decode(Metadata.self, from: bytes.subdata(in: 4..<(4 + length)))
            guard let response = HTTPURLResponse(url: url, statusCode: metadata.status, httpVersion: "HTTP/1.1", headerFields: metadata.headers) else { throw URLError(.badServerResponse) }
            return (bytes.subdata(in: (4 + length)..<bytes.count), response)
        }
    }
    func cancel() {
        let handle = state.withLock { state in state.cancelled = true; return state.handle }
        if let handle { _ = try? AndroidBridge.call(22, handle: handle) }
    }
    func release() {
        let handle = state.withLock { state in defer { state.handle = nil }; return state.handle }
        if let handle { _ = try? AndroidBridge.call(23, handle: handle) }
    }
}
