#if canImport(Network) && canImport(Security)
import Foundation
import Synchronization
import Network
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("TLS request and generation lifecycle", .timeLimit(.minutes(1)))
struct V2TLSFrameConnectionLifecycleTests {
    @Test("a delayed old-generation operation cannot be registered on a new socket")
    func oldRequestScopeCannotReachNewSocket() async throws {
        let old = TLSTestPeer()
        let new = TLSTestPeer()
        let connection = try makeConnection([old, new])
        let oldSession = try await authenticate(connection)
        let oldID = try #require(oldSession.connectionID)
        await connection.disconnect()
        let newSession = try await authenticate(connection)
        #expect(newSession.connectionID != oldID)
        try await V2ConnectionRequestScope.$connectionID.withValue(oldID) {
            await #expect(throws: V2TLSFrameConnectionError.connectionClosed) {
                _ = try await connection.request(request(90))
            }
            await #expect(throws: V2TLSFrameConnectionError.connectionClosed) {
                _ = try await connection.nextAvailabilityHint()
            }
        }
        let valid = Task { try await connection.request(request(90)) }
        await new.waitForRequest(90)
        try await new.reply([90])
        #expect(try await valid.value.requestID == 90)
        await connection.disconnect()
    }

    @Test("real Network callbacks from a suspended old socket cannot close the new connection")
    func realNetworkOldCallbackIsFenced() async throws {
        let oldPeer = TLSTestPeer()
        let newPeer = TLSTestPeer()
        let server = try TCPCallbackTestServer(peers: [oldPeer, newPeer])
        let port = try await server.start()
        let oldQueue = DispatchQueue(label: "im-v2-test-old-network-callbacks")
        let cancelled = TLSTestPeer()
        let oldReads = NetworkReadObservation()
        let oldBytes = V2NetworkTLSByteConnection(
            connection: NWConnection(host: "127.0.0.1", port: port, using: .tcp), queue: oldQueue
        )
        let newBytes = V2NetworkTLSByteConnection(
            connection: NWConnection(host: "127.0.0.1", port: port, using: .tcp), queue: .global()
        )
        let transports = Mutex<[any V2TLSByteConnection]>([
            ObservedNetworkBytes(bytes: oldBytes, cancellation: cancelled, reads: oldReads), newBytes
        ])
        let connection = V2TLSFrameConnection(
            connectionFactory: { transports.withLock { $0.removeFirst() } }, frameLimits: try limits()
        )
        var paused = false
        do {
            let oldSession = try await authenticate(connection)
            // Bootstrap has finished. Require the background reader to enter
            // receive before cancelling, so this cannot pass without a late read.
            await oldReads.waitForPendingReceive()
            oldQueue.suspend()
            paused = true
            let closing = Task { await connection.disconnect() }
            await cancelled.waitForCancellation()
            let newSession = try await authenticate(connection)
            #expect(newSession.connectionID != oldSession.connectionID)
            let b = Task { try await connection.request(request(80)) }
            await newPeer.waitForRequest(80)
            #expect(await oldReads.failures == 0)
            oldQueue.resume()
            paused = false
            await closing.value
            #expect(await oldReads.failures == 1)
            #expect(await oldReads.pending == false)
            try await newPeer.reply([80])
            #expect(try await b.value.requestID == 80)
            await connection.disconnect()
            await server.stop()
        } catch {
            if paused { oldQueue.resume() }
            await connection.disconnect()
            await server.stop()
            throw error
        }
    }

    @Test("an already cancelled consumer cannot steal a queued hint", arguments: ["sync", "group", "activity"])
    func cancelledConsumerPreservesQueuedHint(kind: String) async throws {
        let peer = TLSTestPeer()
        let connection = try makeConnection([peer])
        try await authenticate(connection)
        let barrier = Task { try await connection.request(request(70)) }
        await peer.waitForRequest(70)
        try await peer.hintBeforeReply(kind: kind, requestID: 70)
        _ = try await barrier.value
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await readHint(connection, kind: kind)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await readHint(connection, kind: kind)
        await connection.disconnect()
    }

    private func readHint(_ connection: V2TLSFrameConnection, kind: String) async throws {
        switch kind {
        case "sync": #expect(try await connection.nextAvailabilityHint().highWatermark == 7)
        case "group": #expect(try await connection.nextGroupEventAvailabilityHint().highWatermark == 7)
        default: _ = try await connection.nextLiveActivityEvent()
        }
    }
    @Test("cancelled A keeps correlation while late A and live B arrive together")
    func lateCancelledResponseDoesNotKillOtherRequest() async throws {
        let peer = TLSTestPeer()
        let connection = try makeConnection([peer])
        try await authenticate(connection)
        let a = Task { try await connection.request(request(10)) }
        await peer.waitForRequest(10)
        a.cancel()
        await #expect(throws: CancellationError.self) { _ = try await a.value }
        let b = Task { try await connection.request(request(11)) }
        await peer.waitForRequest(11)
        try await peer.reply([10, 11])
        #expect(try await b.value.requestID == 11)
        await connection.disconnect()
    }

    @Test("cancelled entries occupy the bounded capacity until their matching reply")
    func cancelledEntryRetainsCapacity() async throws {
        let peer = TLSTestPeer()
        let connection = try makeConnection([peer], maximumPendingRequests: 1)
        try await authenticate(connection)
        let a = Task { try await connection.request(request(20)) }
        await peer.waitForRequest(20)
        a.cancel()
        _ = await a.result
        await #expect(throws: V2TLSFrameConnectionError.tooManyPendingRequests) {
            _ = try await connection.request(request(21))
        }
        try await peer.reply([20], followedByHint: true)
        _ = try await connection.nextAvailabilityHint() // Reader has consumed A.
        let b = Task { try await connection.request(request(21)) }
        await peer.waitForRequest(21)
        try await peer.reply([21])
        #expect(try await b.value.requestID == 21)
        await connection.disconnect()
    }

    @Test("cancelled entries keep their original hard deadline and close that generation")
    func cancelledRequestDeadlineStillRuns() async throws {
        let peer = TLSTestPeer()
        let connection = try makeConnection([peer], timeout: .seconds(1))
        try await authenticate(connection)
        let a = Task { try await connection.request(request(30)) }
        await peer.waitForRequest(30)
        a.cancel()
        _ = await a.result
        let hint = Task { try await connection.nextAvailabilityHint() }
        await #expect(throws: V2TLSFrameConnectionError.requestTimedOut) { _ = try await hint.value }
        await #expect(throws: V2TLSFrameConnectionError.notConnected) {
            _ = try await connection.request(request(31))
        }
        await connection.disconnect()
    }

    @Test("an unregistered response remains a protocol failure")
    func unknownResponseStillClosesConnection() async throws {
        let peer = TLSTestPeer()
        let connection = try makeConnection([peer])
        try await authenticate(connection)
        let requestTask = Task { try await connection.request(request(40)) }
        await peer.waitForRequest(40)
        try await peer.reply([999])
        await #expect(throws: V2TLSFrameConnectionError.connectionClosed) { _ = try await requestTask.value }
        await connection.disconnect()
    }

    @Test("old partial frame bytes and old reader failure cannot touch the replacement", arguments: [false, true])
    func oldReaderCannotCloseOrDecodeNewGeneration(returnOldBytes: Bool) async throws {
        let old = TLSTestPeer(ignoreCancellation: true)
        let new = TLSTestPeer()
        let connection = try makeConnection([old, new])
        try await authenticate(connection)
        let oldBytes = try wireResponse(50)
        await old.push(Data(oldBytes.prefix(8)))
        await old.waitForReceives(4) // Two bootstrap reads, prefix, then suffix.
        let closing = Task { await connection.disconnect() }
        await old.waitForCancellation()
        try await authenticate(connection)
        let b = Task { try await connection.request(request(50)) }
        await new.waitForRequest(50)
        if returnOldBytes { await old.push(Data(oldBytes.dropFirst(8))) }
        else { await old.failReceive() }
        await closing.value // All old callbacks have now passed their fences.
        try await new.reply([50])
        #expect(try await b.value.requestID == 50)
        await connection.disconnect()
    }

    @Test("a delayed send failure from the old socket cannot fail a reused request ID")
    func oldSendFailureCannotCloseNewGeneration() async throws {
        let old = TLSTestPeer(blockedSend: 60)
        let new = TLSTestPeer()
        let connection = try makeConnection([old, new])
        try await authenticate(connection)
        let a = Task { try await connection.request(request(60)) }
        await old.waitForRequest(60)
        let closing = Task { await connection.disconnect() }
        await old.waitForCancellation()
        _ = await a.result
        try await authenticate(connection)
        let b = Task { try await connection.request(request(60)) }
        await new.waitForRequest(60)
        await old.failSend()
        await closing.value
        try await new.reply([60])
        #expect(try await b.value.requestID == 60)
        await connection.disconnect()
    }

    private func makeConnection(_ peers: [TLSTestPeer], timeout: Duration = .seconds(10), maximumPendingRequests: Int = 8) throws -> V2TLSFrameConnection {
        let factory = TLSTestFactory(peers: peers)
        return V2TLSFrameConnection(connectionFactory: { factory.next() }, frameLimits: try limits(), requestTimeout: timeout, maximumPendingRequests: maximumPendingRequests)
    }
    @discardableResult
    private func authenticate(_ connection: V2TLSFrameConnection) async throws -> V2AuthenticatedClientSession {
        try await connection.connectAndAuthenticate(accessToken: "fixture-access", deviceID: .init("fixture-device"), supportedCapabilityProfiles: ["base"])
    }
}

private func limits() throws -> V2FrameLimits {
    try .init(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
}
private func request(_ id: UInt64) throws -> V2Frame {
    var envelope = IMV2Envelope()
    envelope.requestID = id
    envelope.protocolVersion = IMV2ProtocolVersion.current
    envelope.heartbeat = .init()
    return try V2ProtobufFrameCodec.encode(envelope, frameVersion: UInt8(IMV2ProtocolVersion.current))
}
private func wireResponse(_ id: UInt64) throws -> Data {
    try V2FrameCodec.encode(request(id), limits: limits())
}
private final class TLSTestFactory: Sendable {
    let peers: Mutex<[TLSTestPeer]>
    init(peers: [TLSTestPeer]) { self.peers = Mutex(peers) }
    func next() -> any V2TLSByteConnection {
        peers.withLock { TLSTestBytes(peer: $0.removeFirst()) }
    }
}
private struct TLSTestBytes: V2TLSByteConnection {
    let peer: TLSTestPeer
    func start() async throws {}
    func send(_ data: Data) async throws { try await peer.send(data) }
    func receive(maximumLength: Int) async throws -> Data { try await peer.receive() }
    func cancel() { Task { await peer.cancel() } }
}
actor TLSTestPeer {
    private let ignoreCancellation: Bool
    private let blockedSend: UInt64?
    private var data: [Data] = []
    private var receiveWaiter: CheckedContinuation<Data, Error>?
    private var sendWaiter: CheckedContinuation<Void, Error>?
    private var requests = Set<UInt64>()
    private var requestObservers: [(UInt64, CheckedContinuation<Void, Never>)] = []
    private var receives = 0
    private var receiveObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancelled = false
    private var cancellationObservers: [CheckedContinuation<Void, Never>] = []
    private let commandResponder: (@Sendable (IMV2Envelope) async throws -> IMV2Envelope)?
    init(ignoreCancellation: Bool = false, blockedSend: UInt64? = nil,
         commandResponder: (@Sendable (IMV2Envelope) async throws -> IMV2Envelope)? = nil) {
        self.ignoreCancellation = ignoreCancellation
        self.blockedSend = blockedSend
        self.commandResponder = commandResponder
    }
    func send(_ bytes: Data) async throws {
        var decoder = V2FrameDecoder(limits: try limits())
        let frame = try #require(decoder.append(bytes).first)
        let envelope = try V2ProtobufFrameCodec.decode(frame)
        var response = IMV2Envelope()
        response.requestID = envelope.requestID
        response.protocolVersion = IMV2ProtocolVersion.current
        switch envelope.body {
        case .clientHello:
            response.serverHello = .init()
            response.serverHello.selectedProtocolVersion = IMV2ProtocolVersion.current
            response.serverHello.selectedCapabilityProfile = "base"
        case .authenticate(let auth):
            response.protocolVersion = IMV2ProtocolVersion.current
            response.authenticated = .init()
            response.authenticated.userID = "fixture-user"
            response.authenticated.deviceID = auth.deviceID
            response.authenticated.selectedCapabilityProfile = "base"
        default:
            if let commandResponder {
                response = try await commandResponder(envelope)
                break
            }
            requests.insert(envelope.requestID)
            let observers = requestObservers.filter { $0.0 == envelope.requestID }
            requestObservers.removeAll { $0.0 == envelope.requestID }
            // Install the failing send continuation before observers resume.
            if envelope.requestID == blockedSend {
                try await withCheckedThrowingContinuation { continuation in
                    sendWaiter = continuation
                    for observer in observers { observer.1.resume() }
                }
            } else { for observer in observers { observer.1.resume() } }
            return
        }
        push(try V2FrameCodec.encode(V2ProtobufFrameCodec.encode(response, frameVersion: UInt8(IMV2ProtocolVersion.current)), limits: limits()))
    }
    func receive() async throws -> Data {
        receives += 1
        let observers = receiveObservers.filter { receives >= $0.0 }
        receiveObservers.removeAll { receives >= $0.0 }
        for observer in observers { observer.1.resume() }
        if !data.isEmpty { return data.removeFirst() }
        if cancelled && !ignoreCancellation { throw V2TLSFrameConnectionError.connectionClosed }
        return try await withCheckedThrowingContinuation { receiveWaiter = $0 }
    }
    func push(_ bytes: Data) {
        if let waiter = receiveWaiter { receiveWaiter = nil; waiter.resume(returning: bytes) }
        else { data.append(bytes) }
    }
    func reply(_ ids: [UInt64], followedByHint: Bool = false) throws {
        var bytes = Data()
        for id in ids { bytes.append(try wireResponse(id)) }
        if followedByHint {
            var hint = IMV2Envelope()
            hint.protocolVersion = IMV2ProtocolVersion.current
            hint.syncAvailable = .init()
            hint.syncAvailable.highWatermark = 1
            bytes.append(try V2FrameCodec.encode(V2ProtobufFrameCodec.encode(hint, frameVersion: UInt8(IMV2ProtocolVersion.current)), limits: limits()))
        }
        push(bytes)
    }
    func hintBeforeReply(kind: String, requestID: UInt64) throws {
        var hint = IMV2Envelope()
        hint.protocolVersion = IMV2ProtocolVersion.current
        switch kind {
        case "sync":
            hint.syncAvailable = .init()
            hint.syncAvailable.highWatermark = 7
        case "group":
            hint.groupEventAvailable = .init()
            hint.groupEventAvailable.roomID = "fixture-room"
            hint.groupEventAvailable.highWatermark = 7
        default:
            hint.presenceChanged = .init()
            hint.presenceChanged.roomID = "fixture-room"
            hint.presenceChanged.targetUserID = "fixture-user"
        }
        var bytes = try V2FrameCodec.encode(V2ProtobufFrameCodec.encode(hint, frameVersion: UInt8(IMV2ProtocolVersion.current)), limits: limits())
        bytes.append(try wireResponse(requestID))
        push(bytes)
    }
    func cancel() {
        cancelled = true
        for observer in cancellationObservers { observer.resume() }
        cancellationObservers.removeAll()
        if !ignoreCancellation { failReceive() }
    }
    func failReceive() {
        receiveWaiter?.resume(throwing: V2TLSFrameConnectionError.connectionClosed)
        receiveWaiter = nil
    }
    func failSend() {
        sendWaiter?.resume(throwing: V2TLSFrameConnectionError.connectionFailed)
        sendWaiter = nil
    }
    func waitForRequest(_ id: UInt64) async {
        if requests.contains(id) { return }
        await withCheckedContinuation { requestObservers.append((id, $0)) }
    }
    func waitForReceives(_ count: Int) async {
        if receives >= count { return }
        await withCheckedContinuation { receiveObservers.append((count, $0)) }
    }
    func waitForCancellation() async {
        if cancelled { return }
        await withCheckedContinuation { cancellationObservers.append($0) }
    }
}
// A loopback TCP fixture exercises Network.framework's real callbacks and
// cancellation queue ordering. TLS certificate validation remains an external
// deployment check; production callers cannot select this test-only transport.
private struct ObservedNetworkBytes: V2TLSByteConnection {
    let bytes: V2NetworkTLSByteConnection
    let cancellation: TLSTestPeer
    let reads: NetworkReadObservation
    func start() async throws { try await bytes.start() }
    func send(_ data: Data) async throws { try await bytes.send(data) }
    func receive(maximumLength: Int) async throws -> Data {
        await reads.started()
        do {
            let data = try await bytes.receive(maximumLength: maximumLength)
            await reads.finished(failed: false)
            return data
        } catch {
            await reads.finished(failed: true)
            throw error
        }
    }
    func cancel() {
        bytes.cancel()
        Task { await cancellation.cancel() }
    }
}

private actor NetworkReadObservation {
    private(set) var pending = false
    private(set) var failures = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func started() {
        pending = true
        waiter?.resume()
        waiter = nil
    }
    func finished(failed: Bool) {
        pending = false
        if failed { failures += 1 }
    }
    func waitForPendingReceive() async {
        if pending { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

actor TCPCallbackTestServer {
    private let listener: NWListener
    private let peers: [TLSTestPeer]
    private var nextPeer = 0
    private var tasks: [Task<Void, Never>] = []
    private var connections: [V2NetworkTLSByteConnection] = []
    init(peers: [TLSTestPeer]) throws {
        self.peers = peers
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> NWEndpoint.Port {
        listener.newConnectionHandler = { connection in Task { await self.accept(connection) } }
        return try await withCheckedThrowingContinuation { continuation in
            let pending = Mutex<CheckedContinuation<NWEndpoint.Port, Error>?>(continuation)
            listener.stateUpdateHandler = { [listener] state in
                let result: Result<NWEndpoint.Port, Error>
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    result = .success(port)
                case .failed, .cancelled: result = .failure(V2TLSFrameConnectionError.connectionFailed)
                default: return
                }
                let waiter = pending.withLock { value in
                    let waiter = value
                    value = nil
                    return waiter
                }
                listener.stateUpdateHandler = nil
                waiter?.resume(with: result)
            }
            listener.start(queue: .global())
        }
    }
    private func accept(_ connection: NWConnection) {
        guard nextPeer < peers.count else { connection.cancel(); return }
        let peer = peers[nextPeer]
        nextPeer += 1
        let bytes = V2NetworkTLSByteConnection(connection: connection, queue: .global())
        connections.append(bytes)
        tasks.append(Task {
            do {
                try await bytes.start()
                var decoder = V2FrameDecoder(limits: try limits())
                while !Task.isCancelled {
                    let chunk = try await bytes.receive(maximumLength: 65_536)
                    for frame in try decoder.append(chunk) {
                        try await peer.send(V2FrameCodec.encode(frame, limits: limits()))
                        let response = try await peer.receive()
                        try await bytes.send(response)
                    }
                }
            } catch {
                // The fixture expects the old and final sockets to close.
            }
        })
    }
    func stop() async {
        listener.cancel()
        for connection in connections { connection.cancel() }
        for task in tasks { task.cancel() }
        for peer in peers { await peer.cancel() }
        for task in tasks { await task.value }
    }
}
#endif
