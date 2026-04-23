import Foundation
@testable import IMClientKit

actor MockIMTCPTransport: IMTCPTransport {
    typealias Handler = @Sendable (String, UInt16) async throws -> IMTCPTransportConnection

    private let handler: Handler
    private var recordedEndpoints: [(String, UInt16)] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func connect(host: String, port: UInt16) async throws -> IMTCPTransportConnection {
        recordedEndpoints.append((host, port))
        return try await handler(host, port)
    }

    func endpoints() -> [(String, UInt16)] {
        recordedEndpoints
    }
}

actor MockIMTCPWire: Sendable {
    private var sentLines: [String] = []
    private var disconnectCount = 0
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?

    func makeConnection() -> IMTCPTransportConnection {
        let lines = AsyncThrowingStream<String, Error> { continuation in
            self.continuation = continuation
        }

        return IMTCPTransportConnection(
            lines: lines,
            sendLine: { line in
                await self.record(line)
            },
            disconnect: {
                await self.disconnect()
            }
        )
    }

    func yieldIncoming(_ line: String) {
        continuation?.yield(line)
    }

    func finishIncoming(throwing error: Error? = nil) {
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        continuation = nil
    }

    func recordedLines() -> [String] {
        sentLines
    }

    func disconnections() -> Int {
        disconnectCount
    }

    private func record(_ line: String) {
        sentLines.append(line)
    }

    private func disconnect() {
        disconnectCount += 1
        continuation?.finish()
        continuation = nil
    }
}
