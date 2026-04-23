import Foundation
@testable import IMApp
@testable import IMClientKit

actor MockHTTPTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let handler: Handler
    private var recordedRequests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        return try await handler(request)
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}
