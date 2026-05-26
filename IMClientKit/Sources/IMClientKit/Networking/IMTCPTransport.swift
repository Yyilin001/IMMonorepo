import Foundation
import Network

public protocol IMTCPTransport: Sendable {
    func connect(host: String, port: UInt16) async throws -> IMTCPTransportConnection
}

public struct IMTCPTransportConnection: Sendable {
    public let frames: AsyncThrowingStream<Data, Error>

    private let sendFrameHandler: @Sendable (Data) async throws -> Void
    private let disconnectHandler: @Sendable () async -> Void

    init(
        frames: AsyncThrowingStream<Data, Error>,
        sendFrame: @escaping @Sendable (Data) async throws -> Void,
        disconnect: @escaping @Sendable () async -> Void
    ) {
        self.frames = frames
        self.sendFrameHandler = sendFrame
        self.disconnectHandler = disconnect
    }

    public func sendFrame(_ frame: Data) async throws {
        try await sendFrameHandler(frame)
    }

    public func disconnect() async {
        await disconnectHandler()
    }
}

public struct NWIMTCPTransport: IMTCPTransport {
    public func connect(host: String, port: UInt16) async throws -> IMTCPTransportConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw URLError(.badURL)
        }

        let bridge = NWIMTCPConnectionBridge(
            connection: NWConnection(
                host: NWEndpoint.Host(host),
                port: nwPort,
                using: .tcp
            )
        )
        return try await bridge.open()
    }
}

private final class NWIMTCPConnectionBridge: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.codex.imapp.imtcp")
    private let lock = NSLock()

    private var openContinuation: CheckedContinuation<Void, Error>?
    private var didResumeOpen = false
    private var isConnected = false
    private var isFinished = false
    private var incomingBuffer = Data()
    private var frameContinuation: AsyncThrowingStream<Data, Error>.Continuation?

    init(connection: NWConnection) {
        self.connection = connection
    }

    public func open() async throws -> IMTCPTransportConnection {
        let frames = AsyncThrowingStream<Data, Error> { continuation in
            lock.lock()
            frameContinuation = continuation
            lock.unlock()
        }

        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            openContinuation = continuation
            lock.unlock()

            connection.stateUpdateHandler = { [weak self] state in
                self?.handle(state: state)
            }
            connection.start(queue: queue)
        }

        return IMTCPTransportConnection(
            frames: frames,
            sendFrame: { frame in
                try await self.send(frame: frame)
            },
            disconnect: {
                self.cancel()
            }
        )
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            resumeOpenIfNeeded(with: .success(()))
            setConnected(true)
            receiveNext()

        case .failed(let error):
            resumeOpenIfNeeded(with: .failure(error))
            finish(with: error)

        case .cancelled:
            let error = IMTCPClientError.connectionClosed
            resumeOpenIfNeeded(with: .failure(error))
            finish(with: nil)

        case .setup, .preparing, .waiting:
            break

        @unknown default:
            let error = IMTCPClientError.connectionClosed
            resumeOpenIfNeeded(with: .failure(error))
            finish(with: error)
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let data, !data.isEmpty {
                self.consume(data: data)
            }

            if let error {
                self.finish(with: error)
                return
            }

            if isComplete {
                self.finish(with: nil)
                return
            }

            self.receiveNext()
        }
    }

    private func consume(data: Data) {
        lock.lock()
        incomingBuffer.append(data)
        let continuation = frameContinuation

        while incomingBuffer.count >= 4 {
            let length = incomingBuffer.prefix(4).reduce(UInt32(0)) { partial, byte in
                (partial << 8) | UInt32(byte)
            }
            if length > 64 * 1024 {
                lock.unlock()
                finish(with: IMTCPClientError.invalidPacket)
                return
            }
            let frameLength = Int(length)
            guard incomingBuffer.count >= 4 + frameLength else {
                break
            }
            let frame = Data(incomingBuffer.dropFirst(4).prefix(frameLength))
            incomingBuffer.removeSubrange(0..<(4 + frameLength))
            continuation?.yield(frame)
        }

        lock.unlock()
    }

    private func send(frame: Data) async throws {
        guard frame.count <= Int(UInt32.max) else {
            throw IMTCPClientError.invalidPacket
        }
        var data = Data()
        let length = UInt32(frame.count)
        data.append(UInt8((length >> 24) & 0xff))
        data.append(UInt8((length >> 16) & 0xff))
        data.append(UInt8((length >> 8) & 0xff))
        data.append(UInt8(length & 0xff))
        data.append(frame)

        guard currentConnectedState() else {
            throw IMTCPClientError.connectionClosed
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private func cancel() {
        setConnected(false)
        connection.cancel()
        finish(with: nil)
    }

    private func resumeOpenIfNeeded(with result: Result<Void, Error>) {
        lock.lock()
        guard !didResumeOpen else {
            lock.unlock()
            return
        }

        didResumeOpen = true
        let continuation = openContinuation
        openContinuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }

    private func finish(with error: Error?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }

        isFinished = true
        isConnected = false
        let continuation = frameContinuation
        frameContinuation = nil
        lock.unlock()

        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }

    private func currentConnectedState() -> Bool {
        lock.lock()
        let isConnected = self.isConnected
        lock.unlock()
        return isConnected
    }

    private func setConnected(_ isConnected: Bool) {
        lock.lock()
        self.isConnected = isConnected
        lock.unlock()
    }
}
