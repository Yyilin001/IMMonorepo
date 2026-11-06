import Foundation
import Synchronization
import NIOCore
import IMActorWire

private final class IMCancellation: Sendable {
    private struct State { var cancelled = false; var id: UInt64? }
    private let state = Mutex(State())
    func install(_ id: UInt64) -> Bool { state.withLock { $0.id = id; return $0.cancelled } }
    func cancel() -> UInt64? { state.withLock { $0.cancelled = true; return $0.id } }
}

/// @unchecked is restricted to NIO's handler boundary: every mutable field below
/// is EventLoop-confined, except remoteState which uses a Mutex for pool queries.
final class IMConnection: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = IMFrame
    let id = UUID()
    let channel: any Channel
    let expected: IMEndpoint?
    let ready: EventLoopPromise<Void>
    private let transport: IMTransport
    private var lane: IMTrafficClass?
    private var context: ChannelHandlerContext?
    private var remote: IMNode?
    private let remoteState = Mutex<IMNode?>(nil)
    var remoteSnapshot: IMNode? { remoteState.withLock { $0 } }
    private var authenticated = false
    private var closed = false
    private var draining = false
    private var nextID: UInt64 = 1
    private var lastIncomingID: UInt64 = 0
    private var sendCredits = 0
    private var sendBytes = 0
    private var maximumSendCredits = 0
    private var maximumSendBytes = 0
    private var peerMaximumFrame = 0
    private var executing: [UInt64: Task<Void, Never>] = [:]
    private var executionTimers: [UInt64: Scheduled<Void>] = [:]
    private var executingBytes = 0
    private var writingBytes = 0
    private struct Pending {
        let continuation: CheckedContinuation<IMTransportReply, any Error>
        let deadline: NIODeadline
    }
    private var pending: [UInt64: Pending] = [:]
    private var deadlines = DeadlineHeap()
    private var deadlineTimer: Scheduled<Void>?
    private var deadlineAt: NIODeadline?
    private var handshakeTimer: Scheduled<Void>?
    private var heartbeat: RepeatedTask?
    private var lastRead = NIODeadline.now()
    private var flushScheduled = false
    private var flushFrames = 0
    private var flushBytes = 0

    init(transport: IMTransport, channel: any Channel, expected: IMEndpoint?, lane: IMTrafficClass?) {
        self.transport = transport; self.channel = channel; self.expected = expected; self.lane = lane
        self.ready = channel.eventLoop.makePromise(of: Void.self)
    }
    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func channelActive(context: ChannelHandlerContext) {
        handshakeTimer = context.eventLoop.scheduleTask(in: transport.configuration.handshakeTimeout) { [self] in
            fail(IMActorError.deadlineExceeded)
        }
        if let lane { do { try sendHello(lane) } catch { fail(error) } }
        context.fireChannelActive()
    }
    private func sendHello(_ lane: IMTrafficClass) throws {
        var bytes = ByteBuffer()
        try transport.configuration.node.encodeWire(into: &bytes)
        bytes.writeBytes(transport.configuration.protocolDigest)
        bytes.writeInteger(lane.rawValue)
        bytes.writeInteger(UInt32(transport.configuration.maximumCallsPerConnection))
        bytes.writeInteger(UInt32(transport.configuration.maximumBytesPerConnection))
        bytes.writeInteger(UInt32(transport.configuration.maximumFrameBytes))
        try write(.init(kind: .hello, body: bytes), immediate: true)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        lastRead = .now()
        let frame = unwrapInboundIn(data)
        do {
            if !authenticated { try acceptHello(frame); return }
            guard let remote else { throw IMActorError.malformed }
            switch frame.kind {
            case .hello: throw IMActorError.malformed
            case .request, .lookup: try acceptRequest(frame, remote: remote)
            case .response, .failure:
                if let call = pending.removeValue(forKey: frame.callID) {
                    call.continuation.resume(returning: .init(body: frame.body, isFailure: frame.kind == .failure))
                    scheduleDeadline()
                } // Unknown/late replies cannot re-create an entry or complete it twice.
            case .cancel: executing[frame.callID]?.cancel()
            case .credit:
                var body = frame.body
                let count = Int(try body.imRead(UInt32.self)), bytes = Int(try body.imRead(UInt32.self))
                try body.imRequireEnd()
                guard count <= maximumSendCredits - sendCredits, bytes <= maximumSendBytes - sendBytes else { throw IMActorError.malformed }
                sendCredits += count; sendBytes += bytes
            case .ping: try write(.init(kind: .pong, callID: frame.callID), immediate: true)
            case .pong: break
            case .drain: draining = true
            case .retired:
                guard frame.actorID > 0 else { throw IMActorError.malformed }
                transport.referenceRetired(.init(node: remote, localID: frame.actorID))
            }
        } catch { fail(error) }
    }
    private func acceptHello(_ frame: IMFrame) throws {
        guard frame.kind == .hello, frame.callID == 0 else { throw IMActorError.incompatibleProtocol }
        var bytes = frame.body
        let node = try IMNode.decodeWire(from: &bytes)
        guard bytes.readBytes(length: 32) == transport.configuration.protocolDigest,
              let peerLane = IMTrafficClass(rawValue: try bytes.imRead(UInt8.self)),
              lane == nil || lane == peerLane,
              expected == nil || expected == node.endpoint,
              node != transport.configuration.node else { throw IMActorError.incompatibleProtocol }
        let calls = Int(try bytes.imRead(UInt32.self)), capacity = Int(try bytes.imRead(UInt32.self))
        let frameLimit = Int(try bytes.imRead(UInt32.self)); try bytes.imRequireEnd()
        guard calls > 0, calls <= 65_536, capacity >= frameLimit,
              capacity <= 1_073_741_824, frameLimit >= 1024, frameLimit <= 33_554_432 else { throw IMActorError.malformed }
        if lane == nil { lane = peerLane; try sendHello(peerLane) }
        remote = node; remoteState.withLock { $0 = node }
        sendCredits = calls; maximumSendCredits = calls
        sendBytes = capacity; maximumSendBytes = capacity; peerMaximumFrame = frameLimit
        authenticated = true; handshakeTimer?.cancel(); handshakeTimer = nil
        ready.succeed(())
        transport.becameReady(self, node: node, lane: peerLane)
        heartbeat = channel.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(5), delay: .seconds(5)) { [weak self] _ in
            guard let self, !self.closed else { return }
            if NIODeadline.now() - self.lastRead > .seconds(30) { self.fail(IMActorError.connectionLost); return }
            do { try self.write(.init(kind: .ping), immediate: true) } catch { self.fail(error) }
        }
    }

    func request(_ original: IMFrame, expectedNode: IMNode?, deadline: ContinuousClock.Instant) async throws -> IMTransportReply {
        let cancellation = IMCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                channel.eventLoop.execute { [self] in
                    do {
                        guard !closed, authenticated, !draining else { throw IMActorError.connectionLost }
                        guard expectedNode == nil || remote == expectedNode else { throw IMActorError.staleIncarnation }
                        let duration = ContinuousClock.now.duration(to: deadline)
                        let parts = duration.components
                        guard duration > .zero, parts.seconds <= 3600 else { throw IMActorError.deadlineExceeded }
                        let ms = max(1, parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
                        let bytes = original.body.readableBytes + IMFrame.headerBytes
                        guard sendCredits > 0, sendBytes >= bytes, bytes <= peerMaximumFrame,
                              pending.count < transport.configuration.maximumCallsPerConnection,
                              channel.isWritable else { throw IMActorError.overloaded }
                        guard nextID < UInt64.max else { throw IMActorError.shuttingDown }
                        let id = nextID; nextID += 1
                        guard !cancellation.install(id) else { throw IMActorError.cancelled }
                        var frame = original; frame.callID = id; frame.budgetMilliseconds = UInt32(ms)
                        let expires = NIODeadline.now() + .milliseconds(ms)
                        pending[id] = Pending(continuation: continuation, deadline: expires)
                        deadlines.push(.init(id: id, deadline: expires)); sendCredits -= 1; sendBytes -= bytes
                        do { try write(frame); scheduleDeadline() }
                        catch { fail(error) }
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            if let id = cancellation.cancel() {
                self.channel.eventLoop.execute { self.cancel(id, reason: .cancelled) }
            }
        }
    }
    private func cancel(_ id: UInt64, reason: IMActorError) {
        guard let call = pending.removeValue(forKey: id) else { return }
        call.continuation.resume(throwing: reason)
        // Credits are returned only by execution settlement, never by caller cancellation.
        do { try write(.init(kind: .cancel, callID: id), immediate: true) } catch { fail(error) }
        scheduleDeadline()
    }
    private func scheduleDeadline() {
        while let first = deadlines.first, pending[first.id] == nil { _ = deadlines.pop() }
        if deadlines.count > pending.count * 2 + 64 {
            deadlines = DeadlineHeap(entries: pending.map { .init(id: $0.key, deadline: $0.value.deadline) })
        }
        let next = deadlines.first?.deadline
        guard next != deadlineAt else { return }
        deadlineTimer?.cancel(); deadlineAt = next
        guard let next else { deadlineTimer = nil; return }
        deadlineTimer = channel.eventLoop.scheduleTask(deadline: next) { [weak self] in
            guard let self else { return }; self.deadlineAt = nil
            while let first = self.deadlines.first, first.deadline <= .now() {
                _ = self.deadlines.pop(); self.cancel(first.id, reason: .deadlineExceeded)
            }
            self.scheduleDeadline()
        }
    }
    private func acceptRequest(_ frame: IMFrame, remote: IMNode) throws {
        guard frame.callID > lastIncomingID, frame.budgetMilliseconds > 0,
              frame.budgetMilliseconds <= 3_600_000 else { throw IMActorError.malformed }
        guard frame.kind != .lookup || lane == .control else { throw IMActorError.forbidden }
        lastIncomingID = frame.callID
        let bytes = frame.body.readableBytes + IMFrame.headerBytes
        // Input ownership lasts through actual execution. Encoded replies have
        // independent byte admission before serialization, using their exact size.
        let reservation = bytes
        guard !draining, executing.count < transport.configuration.maximumCallsPerConnection,
              bytes <= transport.configuration.maximumBytesPerConnection - executingBytes,
              transport.acquireExecution(bytes: reservation, lane: lane ?? .rpc) else {
            try sendReply(.failure(.overloaded), id: frame.callID); try returnCredit(bytes: bytes); return
        }
        executingBytes += bytes
        let task = Task { [self] in
            let reply: IMTransportReply
            do { reply = try await transport.receive(remote, lane ?? .rpc, frame) }
            catch { reply = .failure(error as? IMActorError ?? .remoteFailure) }
            // Execution ownership remains alive even after the channel/caller disappears.
            channel.eventLoop.execute { [self] in
                defer { transport.releaseExecution(bytes: reservation, lane: lane ?? .rpc) }
                executing[frame.callID] = nil; executingBytes -= bytes
                executionTimers.removeValue(forKey: frame.callID)?.cancel()
                guard !closed else { return }
                do { try sendReply(reply, id: frame.callID); try returnCredit(bytes: bytes) }
                catch { fail(error) }
            }
        }
        executing[frame.callID] = task
        executionTimers[frame.callID] = channel.eventLoop.scheduleTask(in: .milliseconds(Int64(frame.budgetMilliseconds))) {
            task.cancel()
        }
    }
    private func sendReply(_ reply: IMTransportReply, id: UInt64) throws {
        defer { withExtendedLifetime(reply) {} }
        let kind: IMFrameKind = reply.isFailure ? .failure : .response
        if reply.body.readableBytes + IMFrame.headerBytes > peerMaximumFrame {
            let failure = IMTransportReply.failure(.overloaded)
            try write(.init(kind: .failure, callID: id, body: failure.body)); return
        }
        try write(.init(kind: kind, callID: id, body: reply.body))
    }
    private func returnCredit(bytes: Int) throws {
        var body = ByteBuffer(); body.writeInteger(UInt32(1)); body.writeInteger(UInt32(bytes))
        try write(.init(kind: .credit, body: body))
    }
    private func write(_ frame: IMFrame, immediate: Bool = false) throws {
        guard !closed, let context else { throw IMActorError.connectionLost }
        let bytes = try frame.encode(maximumBytes: transport.configuration.maximumFrameBytes)
        // Even replies/control are bounded; a stalled peer cannot accumulate an unbounded writer queue.
        let count = bytes.readableBytes
        guard count <= transport.configuration.maximumBytesPerConnection + 65_536 - writingBytes,
              transport.acquireWrite(bytes: count, lane: lane ?? .control) else { throw IMActorError.overloaded }
        writingBytes += count
        let promise = channel.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { [self] result in
            writingBytes -= count; transport.releaseWrite(bytes: count, lane: lane ?? .control)
            if case .failure(let error) = result { fail(error) }
        }
        context.write(NIOAny(bytes), promise: promise)
        flushFrames += 1; flushBytes += bytes.readableBytes
        if immediate || flushFrames >= 32 || flushBytes >= 65_536 { flush(); return }
        if !flushScheduled {
            flushScheduled = true
            context.eventLoop.execute { [weak self] in self?.flush() }
        }
    }
    private func flush() {
        flushScheduled = false; flushFrames = 0; flushBytes = 0
        context?.flush()
    }
    func sendRetirement(_ id: UInt64) {
        channel.eventLoop.execute { [self] in
            guard authenticated, !closed else { return }
            do { try write(.init(kind: .retired, actorID: id), immediate: true) } catch { fail(error) }
        }
    }
    func drain() {
        channel.eventLoop.execute { [self] in
            guard !closed else { return }
            guard authenticated else { fail(IMActorError.shuttingDown); return }
            draining = true
            if authenticated { do { try write(.init(kind: .drain), immediate: true) } catch { fail(error) } }
        }
    }
    func close() { channel.eventLoop.execute { self.fail(IMActorError.connectionLost) } }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { fail(error) }
    func channelInactive(context: ChannelHandlerContext) { finish(IMActorError.connectionLost); context.fireChannelInactive() }
    func handlerRemoved(context: ChannelHandlerContext) { finish(IMActorError.connectionLost); self.context = nil }
    private func fail(_ error: any Error) {
        if !closed { transport.connectionFailed(error) }
        finish(error); channel.close(promise: nil)
    }
    private func finish(_ error: any Error) {
        guard !closed else { return }; closed = true
        handshakeTimer?.cancel(); deadlineTimer?.cancel(); heartbeat?.cancel()
        if !authenticated { ready.fail(error) }
        let calls = pending.values; pending.removeAll(); deadlines = DeadlineHeap()
        for call in calls { call.continuation.resume(throwing: error) }
        for task in executing.values { task.cancel() }
        transport.disconnected(self, node: remote)
    }
}

private struct DeadlineHeap {
    struct Entry { let id: UInt64; let deadline: NIODeadline }
    private var values: [Entry] = []
    init(entries: [Entry] = []) { for entry in entries { push(entry) } }
    var first: Entry? { values.first }
    var count: Int { values.count }
    mutating func push(_ entry: Entry) {
        values.append(entry); var i = values.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard values[i].deadline < values[parent].deadline else { break }
            values.swapAt(i, parent); i = parent
        }
    }
    @discardableResult mutating func pop() -> Entry? {
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values.removeLast() }
        let first = values[0]; values[0] = values.removeLast(); var i = 0
        while i * 2 + 1 < values.count {
            var child = i * 2 + 1
            if child + 1 < values.count, values[child + 1].deadline < values[child].deadline { child += 1 }
            guard values[child].deadline < values[i].deadline else { break }
            values.swapAt(i, child); i = child
        }
        return first
    }
}
