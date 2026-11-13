import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Dispatch
import IMV2ClientRuntime

/// Platform byte I/O only. Callers own plan admission, checksums and durable retry.
public struct V2AndroidStreamingHTTP: Sendable {
    public init() {}
    public func stream(_ request: URLRequest, uploadFile: URL? = nil, maximumBytes: Int64,
                       receiveResponse: @escaping @Sendable (HTTPURLResponse) throws -> Void,
                       consume: @escaping @Sendable (Data) throws -> Void) async throws -> HTTPURLResponse {
        let execution = StreamingExecution()
        return try await withTaskCancellationHandler {
            defer { execution.release() }
            do {
                try Task.checkCancellation()
                let response = try await execution.run(request, file: uploadFile, maximum: maximumBytes, response: receiveResponse, consume: consume)
                try Task.checkCancellation(); return response
            } catch {
                try Task.checkCancellation()
                // The platform unavailable envelope contains no Java details or
                // credentials. Preserve transient I/O semantics for the shared
                // resource engine's existing bounded recovery policy.
                if let failure = error as? PlatformFailure, failure.status == 2 { throw URLError(.networkConnectionLost) }
                throw error
            }
        } onCancel: { execution.cancel() }
    }
}
private final class StreamingExecution: Sendable {
    struct Input: Encodable { let url: String; let method: String; let headers: [String:String]; let path: String?; let timeout: Int64; let cellular: Bool; let expensive: Bool; let constrained: Bool }
    struct Metadata: Decodable { let status: Int; let headers: [String:String] }
    struct State { var handle: Int64?; var cancelled = false }
    let state = V2Lock(initialState: State())
    let queue = DispatchQueue(label: "im.android.resource-http")
    func run(_ request: URLRequest, file: URL?, maximum: Int64, response: @escaping @Sendable (HTTPURLResponse) throws -> Void,
             consume: @escaping @Sendable (Data) throws -> Void) async throws -> HTTPURLResponse {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil, url.fragment == nil,
              request.httpBody == nil, request.httpBodyStream == nil, maximum > 0, maximum <= 512 * 1024 * 1024,
              request.timeoutInterval.isFinite, request.timeoutInterval > 0 else { throw URLError(.badURL) }
        let deadline = min(V2HTTPRequestDeadline.deadline(for: request) ?? .now.advanced(by: .seconds(60)), V2HTTPRequestDeadline.current ?? .now.advanced(by: .seconds(60)))
        let duration = ContinuousClock.now.duration(to: deadline)
        let remaining = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        guard remaining > 0 else { throw URLError(.timedOut) }
        #if os(Android)
        let constraints = V2ResourceDownloadNetworkConstraints.transferConstraints ?? .unrestricted
        #else
        let constraints = V2ResourceDownloadNetworkConstraints.unrestricted
        #endif
        let input = try JSONEncoder().encode(Input(url: url.absoluteString, method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:], path: file?.path, timeout: Int64(max(1, min(60, request.timeoutInterval, remaining) * 1000)), cellular: constraints.allowsCellular, expensive: constraints.allowsExpensive, constrained: constraints.allowsConstrained))
        return try await AndroidBridge.io(on: queue) { [self] in
            let handle = try state.withLock { state in
                guard !state.cancelled else { throw CancellationError() }
                guard let data = try AndroidBridge.call(24, data: input), data.count == 8 else { throw URLError(.cannotConnectToHost) }
                let handle = data.reduce(Int64(0)) { ($0 << 8) | Int64($1) }; state.handle = handle; return handle
            }
            guard let data = try AndroidBridge.call(25, handle: handle) else { throw URLError(.badServerResponse) }
            let meta = try JSONDecoder().decode(Metadata.self, from: data)
            guard let value = HTTPURLResponse(url: url, statusCode: meta.status, httpVersion: "HTTP/1.1", headerFields: meta.headers) else { throw URLError(.badServerResponse) }
            try response(value)
            var count: Int64 = 0
            while true {
                guard !state.withLock({ $0.cancelled }) else { throw CancellationError() }
                guard let chunk = try AndroidBridge.call(26, handle: handle) else { throw URLError(.badServerResponse) }
                if chunk.isEmpty { break }; count += Int64(chunk.count)
                guard count <= maximum else { throw URLError(.dataLengthExceedsMaximum) }
                try consume(chunk)
            }
            return value
        }
    }
    func cancel() { let handle = state.withLock { $0.cancelled = true; return $0.handle }; if let handle { _ = try? AndroidBridge.call(22, handle: handle) } }
    func release() { let handle = state.withLock { defer { $0.handle = nil }; return $0.handle }; if let handle { _ = try? AndroidBridge.call(23, handle: handle) } }
}
