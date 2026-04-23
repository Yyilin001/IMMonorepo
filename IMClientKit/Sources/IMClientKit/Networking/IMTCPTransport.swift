import Foundation
import Network

public protocol IMTCPTransport: Sendable {
    func connect(host: String, port: UInt16) async throws -> IMTCPTransportConnection
}

public struct IMTCPTransportConnection: Sendable {
    public let lines: AsyncThrowingStream<String, Error>

    private let sendLineHandler: @Sendable (String) async throws -> Void
    private let disconnectHandler: @Sendable () async -> Void

    init(
        lines: AsyncThrowingStream<String, Error>,
        sendLine: @escaping @Sendable (String) async throws -> Void,
        disconnect: @escaping @Sendable () async -> Void
    ) {
        self.lines = lines
        self.sendLineHandler = sendLine
        self.disconnectHandler = disconnect
    }

    public func sendLine(_ line: String) async throws {
        try await sendLineHandler(line)
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
    private var lineContinuation: AsyncThrowingStream<String, Error>.Continuation?

    init(connection: NWConnection) {
        self.connection = connection
    }

    public func open() async throws -> IMTCPTransportConnection {
        let lines = AsyncThrowingStream<String, Error> { continuation in
            lock.lock()
            lineContinuation = continuation
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
            lines: lines,
            sendLine: { line in
                try await self.send(line: line)
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
        let continuation = lineContinuation

        while let newlineIndex = incomingBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = incomingBuffer.prefix(upTo: newlineIndex)
            incomingBuffer.removeSubrange(...newlineIndex)

            let normalizedLineData: Data
            if lineData.last == UInt8(ascii: "\r") {
                normalizedLineData = Data(lineData.dropLast())
            } else {
                normalizedLineData = Data(lineData)
            }

            guard let line = String(data: normalizedLineData, encoding: .utf8) else {
                lock.unlock()
                finish(with: IMTCPClientError.invalidPacket)
                return
            }

            continuation?.yield(line)
        }

        lock.unlock()
    }

    private func send(line: String) async throws {
        let data = Data((line + "\n").utf8)

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
        let continuation = lineContinuation
        lineContinuation = nil
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
