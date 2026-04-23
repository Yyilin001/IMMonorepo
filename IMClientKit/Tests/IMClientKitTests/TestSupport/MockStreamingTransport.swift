import Foundation
@testable import IMClientKit

actor MockStreamingTransport: StreamingTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> (HTTPByteStream, HTTPURLResponse)

    private let handler: Handler
    private var recordedRequests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func open(_ request: URLRequest) async throws -> (HTTPByteStream, HTTPURLResponse) {
        recordedRequests.append(request)
        return try await handler(request)
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}
