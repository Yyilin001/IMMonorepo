import AsyncHTTPClient
import Foundation
import NIOCore

/// External Docker JSON boundary. Shared by launch and exclusion; the caller
/// owns the HTTP client until all deployment work has actually drained.
package struct V2DockerEngineConnection: Sendable {
    private let socketPath: String
    private let client: HTTPClient
    package init(socketPath: String, client: HTTPClient) throws {
        guard socketPath.hasPrefix("/"), !socketPath.contains("\0") else {
            throw V2DockerRoomHostExclusionError.invalidBinding
        }
        self.socketPath = socketPath; self.client = client
    }
    package func request(_ method: String, _ path: String, body: Data? = nil,
                         deadline: ContinuousClock.Instant) async throws -> V2DockerRoomHostExclusionBackend.Response {
        try Task.checkCancellation()
        let now = ContinuousClock.now
        guard now < deadline, let url = URL(httpURLWithSocketPath: socketPath, uri: "/v1.47" + path) else {
            throw V2RoomHostRecoveryError.deadlineExceeded
        }
        let duration = now.duration(to: deadline).components
        guard duration.seconds <= 300 else { throw V2DockerRoomHostExclusionError.invalidBinding }
        let nanos = duration.seconds * 1_000_000_000 + duration.attoseconds / 1_000_000_000
        var input = HTTPClientRequest(url: url.absoluteString)
        input.method = .init(rawValue: method)
        // Unix targets have no DNS host, so AsyncHTTPClient does not synthesize
        // this HTTP/1.1 header. Docker rejects a request without it with 400.
        input.headers.add(name: "Host", value: "localhost")
        if let body { input.body = .bytes(body); input.headers.add(name: "Content-Type", value: "application/json") }
        let response = try await client.execute(input, timeout: .nanoseconds(nanos))
        let buffer = try await response.body.collect(upTo: 1_048_576)
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw V2RoomHostRecoveryError.deadlineExceeded }
        return .init(status: Int(response.status.code), body: Data(buffer.readableBytesView))
    }
}
