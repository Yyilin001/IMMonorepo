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
    private var sentFrames: [Data] = []
    private var disconnectCount = 0
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    func makeConnection() -> IMTCPTransportConnection {
        let frames = AsyncThrowingStream<Data, Error> { continuation in
            self.continuation = continuation
        }

        return IMTCPTransportConnection(
            frames: frames,
            sendFrame: { frame in
                await self.record(frame)
            },
            disconnect: {
                await self.disconnect()
            }
        )
    }

    func yieldIncoming(_ frame: Data) {
        continuation?.yield(frame)
    }

    func finishIncoming(throwing error: Error? = nil) {
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        continuation = nil
    }

    func recordedFrames() -> [Data] {
        sentFrames
    }

    func disconnections() -> Int {
        disconnectCount
    }

    private func record(_ frame: Data) {
        sentFrames.append(frame)
    }

    private func disconnect() {
        disconnectCount += 1
        continuation?.finish()
        continuation = nil
    }
}
