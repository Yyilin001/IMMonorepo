import Foundation
import IMV2Core
import Logging
@preconcurrency import NIOCore
import Synchronization

/// A single TLS-decoded NIO channel. Work is serialized before it enters the
/// actor-backed byte stream, so async authentication/database work cannot
/// reorder replies on a connection. The queue is explicitly byte-bounded:
/// resumable sync must absorb overload rather than memory growing without
/// limit.
public final class V2NIOGatewayChannelHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private let stream: V2GatewayByteStream
    private let timeouts: V2GatewayConnectionTimeouts
    private let transportMetrics: any V2GatewayTransportMetricsRecorder
    private let foregroundWriteScheduler: V2NIOForegroundWriteScheduler
    private let logger = Logger(label: "imv2.gateway.transport")
    private var pending: V2GatewayInboundQueue
    private var processing = false
    /// Exactly one request task belongs to the channel. EOF, timeout,
    /// revocation, and every explicit close path cancel it before dropping
    /// queued input, so database/pool acquisition does not continue for a
    /// client that no longer exists.
    private var processingTask: Task<Void, Never>?
    /// Best-effort foreground pushes have no request promise and may be
    /// coalesced. Keep their EventLoop handoff separate from ordered command
    /// responses so a live-event burst never creates one Swift task and actor
    /// continuation per recipient.
    private var foregroundWriter: V2NIOGatewayForegroundWriter?
    private struct PendingResponseWrite {
        let frame: V2Frame
        let promise: EventLoopPromise<Void>
    }
    private var pendingResponseWrite: PendingResponseWrite?
    /// A bounded decoder batch left later wire frames in the byte stream.
    /// Drain those before later TCP chunks so response order remains FIFO.
    private var needsFrameDrain = false
    private var closed = false
    // `V2GatewayByteStream` is an actor, so installing its channel callbacks
    // crosses an async boundary. Never let an authenticate frame register in
    // the live-device registry before the revocation-close callback exists.
    private var callbacksReady = false
    private var lastInboundAt: NIODeadline?
    private var idleCheck: Scheduled<Void>?
    private var authenticationDeadline: Scheduled<Void>?
    private var closeReason: V2GatewayConnectionClosure?

    public convenience init(
        stream: V2GatewayByteStream,
        maximumQueuedInboundBytes: Int,
        maximumQueuedInboundChunks: Int,
        authenticationTimeoutMilliseconds: Int,
        idleTimeoutMilliseconds: Int,
        transportMetrics: any V2GatewayTransportMetricsRecorder
    ) throws {
        try self.init(
            stream: stream,
            maximumQueuedInboundBytes: maximumQueuedInboundBytes,
            maximumQueuedInboundChunks: maximumQueuedInboundChunks,
            authenticationTimeoutMilliseconds: authenticationTimeoutMilliseconds,
            idleTimeoutMilliseconds: idleTimeoutMilliseconds,
            transportMetrics: transportMetrics,
            foregroundWriteScheduler: .init()
        )
    }

    init(
        stream: V2GatewayByteStream,
        maximumQueuedInboundBytes: Int,
        maximumQueuedInboundChunks: Int,
        authenticationTimeoutMilliseconds: Int,
        idleTimeoutMilliseconds: Int,
        transportMetrics: any V2GatewayTransportMetricsRecorder,
        foregroundWriteScheduler: V2NIOForegroundWriteScheduler
    ) throws {
        self.timeouts = try .init(authenticationMilliseconds: authenticationTimeoutMilliseconds,
                                  idleMilliseconds: idleTimeoutMilliseconds)
        precondition(
            maximumQueuedInboundBytes > 0 &&
            maximumQueuedInboundChunks > 0
        )
        self.stream = stream
        self.pending = .init(
            maximumBytes: maximumQueuedInboundBytes,
            maximumChunks: maximumQueuedInboundChunks
        )
        self.transportMetrics = transportMetrics
        self.foregroundWriteScheduler = foregroundWriteScheduler
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        lastInboundAt = .now()
        transportMetrics.connectionOpened()
        scheduleIdleCheck(context: context)
        scheduleAuthenticationDeadline(context: context)
        let boundContext = context.loopBound
        let boundHandler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let eventLoop = context.eventLoop
        let stream = stream
        let foregroundWriter = V2NIOGatewayForegroundWriter(
            channel: context.channel,
            scheduler: foregroundWriteScheduler,
            metrics: transportMetrics
        )
        self.foregroundWriter = foregroundWriter
        Task {
            let attached = await stream.attachNIOTransport(deviceRevocationHandler: {
                await withCheckedContinuation { continuation in
                    eventLoop.execute {
                        let handler = boundHandler.value
                        let context = boundContext.value
                        guard !handler.closed else {
                            continuation.resume()
                            return
                        }
                        let closePromise = eventLoop.makePromise(of: Void.self)
                        closePromise.futureResult.whenComplete { _ in
                            continuation.resume()
                        }
                        handler.close(
                            context: context,
                            reason: .deviceRevoked,
                            revokeDevice: false,
                            closePromise: closePromise
                        )
                    }
                }
            }, outboundWriter: { bytes in
                // Await the one event-loop hop so a hot notifier cannot queue
                // an unbounded number of closures while this channel stalls.
                await withCheckedContinuation { continuation in
                    eventLoop.execute {
                        defer { continuation.resume() }
                        let context = boundContext.value
                        guard context.channel.isActive, context.channel.isWritable else { return }
                        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
                        buffer.writeBytes(bytes)
                        context.writeAndFlush(boundHandler.value.wrapOutboundOut(buffer), promise: nil)
                    }
                }
            }, foregroundWriter: foregroundWriter)
            eventLoop.execute {
                let handler = boundHandler.value
                guard attached, !handler.closed else { return }
                handler.callbacksReady = true
                handler.processNext(context: boundContext.value)
            }
        }
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        lastInboundAt = .now()
        let buffer = unwrapInboundIn(data)
        let bytes = Data(buffer.readableBytesView)
        guard pending.append(bytes) else {
            close(context: context, reason: .inboundQueueLimit)
            return
        }
        transportMetrics.observeQueuedInboundBytes(pending.queuedBytes)
        processNext(context: context)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        closed = true
        foregroundWriter?.finish()
        foregroundWriter = nil
        idleCheck?.cancel()
        idleCheck = nil
        authenticationDeadline?.cancel()
        authenticationDeadline = nil
        pending.removeAll()
        failPendingResponse(V2GatewayTransportWriteError.channelClosed)
        processingTask?.cancel()
        processingTask = nil
        processing = false
        let stream = stream
        Task { await stream.finishSilently() }
        let reason = closeReason ?? .peerDisconnected
        transportMetrics.connectionClosed(reason: reason)
        context.fireChannelInactive()
    }

    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            foregroundWriter?.resumeAfterWritabilityChange()
            flushPendingResponse(context: context)
            processNext(context: context)
        }
        context.fireChannelWritabilityChanged()
    }

    private func processNext(context: ChannelHandlerContext) {
        guard callbacksReady, !closed, !processing,
              context.channel.isWritable,
              (needsFrameDrain || !pending.isEmpty)
        else { return }
        processing = true
        let inbound: Data
        if needsFrameDrain {
            needsFrameDrain = false
            inbound = Data()
        } else {
            guard let next = pending.popFirst() else {
                processing = false
                return
            }
            inbound = next
        }
        let stream = stream
        let boundHandler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = context.loopBound
        let eventLoop = context.eventLoop
        let logger = logger
        processingTask = Task {
            let outcome: V2GatewayProcessingOutcome
            do {
                try Task.checkCancellation()
                let needsFrameDrain = try await stream.receiveFrames(inbound) { response in
                    try Task.checkCancellation()
                    try await eventLoop.flatSubmit {
                        boundHandler.value.writeFrameWhenWritable(
                            response,
                            context: boundContext.value
                        )
                    }.get()
                }
                try Task.checkCancellation()
                outcome = .success(
                    authenticated: await stream.isAuthenticated(),
                    needsFrameDrain: needsFrameDrain
                )
            } catch {
                // The public protocol intentionally closes after a malformed
                // or invalid request. Keep the client-facing behavior opaque,
                // but retain the server-side error class for operations; the
                // closure counter alone cannot distinguish a bad frame from a
                // configuration or lifecycle regression.
                logger.warning(
                    "gateway request processing failed",
                    metadata: ["error": "\(String(reflecting: error))"]
                )
                outcome = .failure(reason: v2GatewayClosureReason(for: error))
            }
            eventLoop.execute {
                boundHandler.value.completeProcessing(
                    outcome,
                    context: boundContext.value
                )
            }
        }
    }

    private func completeProcessing(
        _ outcome: V2GatewayProcessingOutcome,
        context: ChannelHandlerContext
    ) {
        processingTask = nil
        guard !closed else { return }
        processing = false
        switch outcome {
        case .success(let authenticated, let needsFrameDrain):
            self.needsFrameDrain = needsFrameDrain
            if authenticated {
                authenticationDeadline?.cancel()
                authenticationDeadline = nil
            }
            processNext(context: context)
        case .failure(let reason):
            close(context: context, reason: reason)
        }
    }

    private func close(
        context: ChannelHandlerContext,
        reason: V2GatewayConnectionClosure,
        revokeDevice: Bool = true,
        closePromise: EventLoopPromise<Void>? = nil
    ) {
        guard !closed else {
            closePromise?.succeed(())
            return
        }
        closed = true
        closeReason = reason
        foregroundWriter?.finish()
        foregroundWriter = nil
        idleCheck?.cancel()
        idleCheck = nil
        authenticationDeadline?.cancel()
        authenticationDeadline = nil
        pending.removeAll()
        failPendingResponse(V2GatewayTransportWriteError.channelClosed)
        processingTask?.cancel()
        processingTask = nil
        processing = false
        if revokeDevice {
            let stream = stream
            Task { await stream.revokeDevice() }
        }
        context.close(promise: closePromise)
    }

    private func writeFrameWhenWritable(
        _ frame: V2Frame,
        context: ChannelHandlerContext
    ) -> EventLoopFuture<Void> {
        let promise = context.eventLoop.makePromise(of: Void.self)
        guard !closed, context.channel.isActive else {
            promise.fail(V2GatewayTransportWriteError.channelClosed)
            return promise.futureResult
        }
        if context.channel.isWritable {
            write(frame, promise: promise, context: context)
        } else if pendingResponseWrite == nil {
            // The stream awaits this promise before dispatching another frame,
            // so a stalled channel retains at most one complete response.
            pendingResponseWrite = .init(frame: frame, promise: promise)
        } else {
            promise.fail(V2GatewayTransportWriteError.responseAlreadyPending)
        }
        return promise.futureResult
    }

    private func flushPendingResponse(context: ChannelHandlerContext) {
        guard context.channel.isWritable, let pendingResponseWrite else { return }
        self.pendingResponseWrite = nil
        write(
            pendingResponseWrite.frame,
            promise: pendingResponseWrite.promise,
            context: context
        )
    }

    private func write(
        _ frame: V2Frame,
        promise: EventLoopPromise<Void>,
        context: ChannelHandlerContext
    ) {
        let buffer = v2GatewayWireBuffer(
            frame,
            allocator: context.channel.allocator
        )
        context.writeAndFlush(wrapOutboundOut(buffer), promise: promise)
    }

    private func failPendingResponse(_ error: any Error) {
        let pending = pendingResponseWrite
        pendingResponseWrite = nil
        pending?.promise.fail(error)
    }

    private func scheduleIdleCheck(context: ChannelHandlerContext) {
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = context.loopBound
        idleCheck = context.eventLoop.scheduleTask(in: timeouts.idle) {
            handler.value.checkIdle(context: boundContext.value)
        }
    }

    private func scheduleAuthenticationDeadline(context: ChannelHandlerContext) {
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = context.loopBound
        authenticationDeadline = context.eventLoop.scheduleTask(
            in: timeouts.authentication
        ) {
            let handler = handler.value
            guard !handler.closed, handler.authenticationDeadline != nil else { return }
            handler.close(context: boundContext.value, reason: .authenticationTimeout)
        }
    }

    private func checkIdle(context: ChannelHandlerContext) {
        guard !closed, let lastInboundAt else { return }
        let elapsed = NIODeadline.now().uptimeNanoseconds - lastInboundAt.uptimeNanoseconds
        let timeout = UInt64(timeouts.idle.nanoseconds)
        if elapsed >= timeout {
            close(context: context, reason: .idleTimeout)
        } else {
            scheduleIdleCheck(context: context)
        }
    }
}

/// Process-wide foreground write combiner. One lane belongs to each child
/// EventLoop: the first ready connection schedules a drain and later ready
/// connections join the same bounded turn instead of each allocating an
/// `EventLoop.execute` closure. Turns are capped so heartbeats, command
/// responses and TLS work retain fair access to the loop under a live-event
/// burst.
final class V2NIOForegroundWriteScheduler: @unchecked Sendable {
    final class Lane: @unchecked Sendable {
        private struct State {
            var writers = CircularBuffer<V2NIOGatewayForegroundWriter>(initialCapacity: 64)
            var drainScheduled = false
        }

        private let eventLoop: any EventLoop
        private let maximumWritesPerTurn: Int
        private let state = Mutex(State())

        init(eventLoop: any EventLoop, maximumWritesPerTurn: Int) {
            self.eventLoop = eventLoop
            self.maximumWritesPerTurn = maximumWritesPerTurn
        }

        func enqueue(_ writer: V2NIOGatewayForegroundWriter) {
            let shouldSchedule = state.withLock { state in
                state.writers.append(writer)
                guard !state.drainScheduled else { return false }
                state.drainScheduled = true
                return true
            }
            if shouldSchedule { scheduleDrain() }
        }

        /// One group publication usually makes many writers on the same
        /// EventLoop ready together. Appending that whole set under one lane
        /// lock avoids repeating the cross-thread scheduler lock for every
        /// recipient while retaining the exact same writer FIFO and fair,
        /// bounded EventLoop drain turns.
        func enqueue(_ writers: [V2NIOGatewayForegroundWriter]) {
            guard !writers.isEmpty else { return }
            let shouldSchedule = state.withLock { state in
                for writer in writers { state.writers.append(writer) }
                guard !state.drainScheduled else { return false }
                state.drainScheduled = true
                return true
            }
            if shouldSchedule { scheduleDrain() }
        }

        private func scheduleDrain() {
            eventLoop.execute { [self] in drain() }
        }

        private func drain() {
            eventLoop.preconditionInEventLoop()
            var batch: [V2NIOGatewayForegroundWriter] = []
            batch.reserveCapacity(maximumWritesPerTurn)
            state.withLock { state in
                while batch.count < maximumWritesPerTurn,
                      let writer = state.writers.popFirst() {
                    batch.append(writer)
                }
            }
            for writer in batch { writer.drainOnEventLoop() }
            let needsAnotherTurn = state.withLock { state in
                guard state.writers.isEmpty else { return true }
                state.drainScheduled = false
                return false
            }
            if needsAnotherTurn { scheduleDrain() }
        }
    }

    private struct State: Sendable {
        var lanes: [ObjectIdentifier: Lane] = [:]
    }

    private let maximumWritesPerTurn: Int
    private let state = Mutex(State())

    init(maximumWritesPerTurn: Int = 512) {
        precondition(maximumWritesPerTurn > 0)
        self.maximumWritesPerTurn = maximumWritesPerTurn
    }

    func lane(for eventLoop: any EventLoop) -> Lane {
        let identity = ObjectIdentifier(eventLoop)
        return state.withLock { state in
            if let existing = state.lanes[identity] { return existing }
            let created = Lane(
                eventLoop: eventLoop,
                maximumWritesPerTurn: maximumWritesPerTurn
            )
            state.lanes[identity] = created
            return created
        }
    }
}

/// A lifecycle-fenced, already-encoded foreground frame awaiting admission to
/// one connection writer. Creating this value does not enqueue work; the group
/// publisher can collect many submissions and enter each EventLoop lane once.
struct V2NIOGatewayForegroundWriteSubmission: Sendable {
    let writer: V2NIOGatewayForegroundWriter
    let bytes: ByteBuffer
}

/// FIFO used by one foreground connection writer. Normal operation preserves
/// every ordered live batch. If the bounded prefix fills, one latest recovery
/// frame is retained separately: after the prefix drains its higher waterline
/// deliberately exposes a cursor gap and drives the durable pull path. This
/// bounds memory without silently pretending a suffix is contiguous.
struct V2GatewayForegroundWriteQueue: Sendable {
    enum AppendOutcome: Equatable, Sendable {
        case queued
        case recoveryQueued
        case recoveryReplaced
    }

    struct Drain: Equatable, Sendable {
        let frames: [ByteBuffer]
        let bytes: Int
    }

    private let maximumQueuedBytes: Int
    private let maximumQueuedFrames: Int
    private var frames: CircularBuffer<ByteBuffer>
    private var frameBytes = 0
    private var recoveryFrame: ByteBuffer?

    init(maximumQueuedBytes: Int, maximumQueuedFrames: Int) {
        precondition(maximumQueuedBytes > 0 && maximumQueuedFrames > 0)
        self.maximumQueuedBytes = maximumQueuedBytes
        self.maximumQueuedFrames = maximumQueuedFrames
        frames = .init(initialCapacity: min(maximumQueuedFrames, 32))
    }

    var isEmpty: Bool { frames.isEmpty && recoveryFrame == nil }
    var count: Int { frames.count + (recoveryFrame == nil ? 0 : 1) }
    var queuedBytes: Int { frameBytes + (recoveryFrame?.readableBytes ?? 0) }

    mutating func append(_ bytes: ByteBuffer) -> AppendOutcome {
        if recoveryFrame != nil {
            recoveryFrame = bytes
            return .recoveryReplaced
        }
        if frames.count < maximumQueuedFrames,
           bytes.readableBytes <= maximumQueuedBytes,
           frameBytes <= maximumQueuedBytes - bytes.readableBytes {
            frames.append(bytes)
            frameBytes += bytes.readableBytes
            return .queued
        }
        recoveryFrame = bytes
        return .recoveryQueued
    }

    mutating func popBatch(
        maximumFrames: Int,
        maximumBytes: Int
    ) -> Drain? {
        precondition(maximumFrames > 0 && maximumBytes > 0)
        guard !isEmpty else { return nil }
        var drained: [ByteBuffer] = []
        drained.reserveCapacity(min(maximumFrames, count))
        var drainedBytes = 0
        while drained.count < maximumFrames, let first = frames.first {
            if !drained.isEmpty, drainedBytes + first.readableBytes > maximumBytes { break }
            _ = frames.removeFirst()
            frameBytes -= first.readableBytes
            drained.append(first)
            drainedBytes += first.readableBytes
            if drainedBytes >= maximumBytes { break }
        }
        if frames.isEmpty,
           drained.count < maximumFrames,
           let recoveryFrame,
           drained.isEmpty || drainedBytes + recoveryFrame.readableBytes <= maximumBytes {
            self.recoveryFrame = nil
            drained.append(recoveryFrame)
            drainedBytes += recoveryFrame.readableBytes
        }
        guard !drained.isEmpty else { return nil }
        return .init(frames: drained, bytes: drainedBytes)
    }

    mutating func removeAll() {
        frames.removeAll(keepingCapacity: true)
        frameBytes = 0
        recoveryFrame = nil
    }
}

/// Bounded, non-suspending bridge from an authenticated foreground route to
/// one NIO channel. Shared immutable frames remain COW while queued. A drain
/// copies several complete protocol frames into one NIO buffer and performs a
/// single flush, allowing the decoder to consume the coalesced frames while
/// amortizing EventLoop, syscall, and TLS-record work.
final class V2NIOGatewayForegroundWriter: @unchecked Sendable {
    private struct LaneBatch {
        let lane: V2NIOForegroundWriteScheduler.Lane
        var writers: [V2NIOGatewayForegroundWriter]
    }

    private struct State: Sendable {
        var queue: V2GatewayForegroundWriteQueue
        var scheduled = false
        var waitingForWritability = false
        var finished = false

        init(maximumQueuedBytes: Int, maximumQueuedFrames: Int) {
            queue = .init(
                maximumQueuedBytes: maximumQueuedBytes,
                maximumQueuedFrames: maximumQueuedFrames
            )
        }
    }

    private let state: Mutex<State>
    /// A production NIO channel and its EventLoop are thread-safe entry
    /// points. All mutable channel-handler state remains confined to that
    /// EventLoop; this reference is never used to run application work inline.
    private let channel: any Channel
    private let schedulerLane: V2NIOForegroundWriteScheduler.Lane
    private let metrics: (any V2GatewayTransportMetricsRecorder)?
    private let maximumDrainFrames: Int
    private let maximumDrainBytes: Int

    init(
        channel: any Channel,
        scheduler: V2NIOForegroundWriteScheduler,
        metrics: (any V2GatewayTransportMetricsRecorder)? = nil,
        maximumQueuedBytes: Int = 256 * 1_024,
        maximumQueuedFrames: Int = 32,
        maximumDrainBytes: Int = 64 * 1_024,
        maximumDrainFrames: Int = 32
    ) {
        precondition(
            maximumQueuedBytes > 0 && maximumQueuedFrames > 0
                && maximumDrainBytes > 0 && maximumDrainFrames > 0
        )
        self.channel = channel
        schedulerLane = scheduler.lane(for: channel.eventLoop)
        self.metrics = metrics
        self.maximumDrainFrames = maximumDrainFrames
        self.maximumDrainBytes = maximumDrainBytes
        state = .init(.init(
            maximumQueuedBytes: maximumQueuedBytes,
            maximumQueuedFrames: maximumQueuedFrames
        ))
    }

    /// Compatibility entry used by focused queue tests and non-prepared local
    /// callers. Production group publication submits an already-prepared
    /// `ByteBuffer` and avoids this one-time conversion per connection.
    func submit(_ bytes: Data) {
        submit(ByteBuffer(bytes: bytes))
    }

    func submit(_ bytes: ByteBuffer) {
        if append(bytes) { schedulerLane.enqueue(self) }
    }

    /// Admits one prepared frame without immediately entering the shared lane.
    /// `submitBatch` uses this to pay one lane lock per EventLoop rather than
    /// one per recipient. The per-connection mutex remains the lifecycle,
    /// bounded-queue, and FIFO authority.
    private func append(_ bytes: ByteBuffer) -> Bool {
        let submission = state.withLock { state -> (
            shouldEnqueue: Bool,
            outcome: V2GatewayForegroundWriteQueue.AppendOutcome,
            queuedBytes: Int
        )? in
            guard !state.finished else { return nil }
            let outcome = state.queue.append(bytes)
            guard !state.scheduled, !state.waitingForWritability else {
                return (false, outcome, state.queue.queuedBytes)
            }
            state.scheduled = true
            return (true, outcome, state.queue.queuedBytes)
        }
        guard let submission else { return false }
        metrics?.foregroundFrameSubmitted(
            bytes: bytes.readableBytes,
            recoveryQueued: submission.outcome == .recoveryQueued,
            recoveryReplaced: submission.outcome == .recoveryReplaced,
            queuedBytes: submission.queuedBytes
        )
        return submission.shouldEnqueue
    }

    /// Bulk counterpart used by the real group-broadcast path. All queue
    /// admissions happen before scheduling, so a concurrently scheduled writer
    /// can safely drain an admitted frame even when this call does not add it to
    /// a lane again. Object identity groups writers by their pre-registered
    /// EventLoop lane without hashing or locking the process-wide scheduler.
    static func submitBatch(_ submissions: [V2NIOGatewayForegroundWriteSubmission]) {
        guard !submissions.isEmpty else { return }
        var batches: [ObjectIdentifier: LaneBatch] = [:]
        batches.reserveCapacity(min(submissions.count, 8))
        for submission in submissions {
            let writer = submission.writer
            guard writer.append(submission.bytes) else { continue }
            let identity = ObjectIdentifier(writer.schedulerLane)
            if batches[identity] == nil {
                batches[identity] = .init(lane: writer.schedulerLane, writers: [])
            }
            batches[identity]!.writers.append(writer)
        }
        for batch in batches.values { batch.lane.enqueue(batch.writers) }
    }

    func finish() {
        state.withLock {
            $0.finished = true
            $0.queue.removeAll()
            $0.scheduled = false
            $0.waitingForWritability = false
        }
    }

    func resumeAfterWritabilityChange() {
        let shouldEnqueue = state.withLock { state in
            guard !state.finished, !state.queue.isEmpty else {
                state.waitingForWritability = false
                return false
            }
            state.waitingForWritability = false
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if shouldEnqueue { schedulerLane.enqueue(self) }
    }

    fileprivate func drainOnEventLoop() {
        channel.eventLoop.preconditionInEventLoop()
        guard channel.isActive else {
            finish()
            return
        }
        guard channel.isWritable else {
            state.withLock { state in
                state.scheduled = false
                if !state.finished, !state.queue.isEmpty {
                    state.waitingForWritability = true
                }
            }
            metrics?.foregroundWriteDeferredForWritability()
            return
        }
        let result = state.withLock { state -> (
            V2GatewayForegroundWriteQueue.Drain?, Bool
        ) in
            state.scheduled = false
            guard !state.finished else {
                state.queue.removeAll()
                return (nil, false)
            }
            let batch = state.queue.popBatch(
                maximumFrames: maximumDrainFrames,
                maximumBytes: maximumDrainBytes
            )
            let reschedule = !state.queue.isEmpty
            if reschedule { state.scheduled = true }
            return (batch, reschedule)
        }
        guard let batch = result.0 else { return }
        let buffer: ByteBuffer
        if batch.frames.count == 1 {
            // The common group-broadcast path writes the shared immutable COW
            // storage directly. Reader-index changes are value-local; a true
            // byte mutation in a downstream handler detaches automatically.
            buffer = batch.frames[0]
        } else {
            var combined = channel.allocator.buffer(capacity: batch.bytes)
            for frame in batch.frames { combined.writeImmutableBuffer(frame) }
            buffer = combined
        }
        channel.writeAndFlush(buffer, promise: nil)
        metrics?.foregroundWriteBatch(frames: batch.frames.count, bytes: batch.bytes)
        if result.1 { schedulerLane.enqueue(self) }
    }
}

/// Encodes the stable 18-byte gateway header and protobuf payload directly
/// into NIO-owned storage. The byte order intentionally mirrors
/// `V2FrameCodec.encode`; validation remains in `V2GatewayByteStream` before
/// the frame crosses onto the event loop.
func v2GatewayWireBuffer(
    _ frame: V2Frame,
    allocator: ByteBufferAllocator
) -> ByteBuffer {
    var buffer = allocator.buffer(capacity: V2Frame.headerLength + frame.payload.count)
    buffer.writeInteger(V2Frame.magic, endianness: .big)
    buffer.writeInteger(frame.version)
    buffer.writeInteger(frame.flags.rawValue)
    buffer.writeInteger(frame.command.rawValue, endianness: .big)
    buffer.writeInteger(frame.requestID, endianness: .big)
    buffer.writeInteger(UInt32(frame.payload.count), endianness: .big)
    buffer.writeBytes(frame.payload)
    return buffer
}

/// Event-loop-confined, two-dimensional admission queue. `CircularBuffer`
/// keeps append/pop amortized O(1), so draining a full fragmented connection
/// never shifts thousands of retained `Data` values on the shared event loop.
struct V2GatewayInboundQueue {
    private let maximumBytes: Int
    private let maximumChunks: Int
    private var chunks: CircularBuffer<Data>
    private(set) var queuedBytes = 0

    init(maximumBytes: Int, maximumChunks: Int) {
        precondition(maximumBytes > 0 && maximumChunks > 0)
        self.maximumBytes = maximumBytes
        self.maximumChunks = maximumChunks
        self.chunks = .init(initialCapacity: min(maximumChunks, 16))
    }

    var isEmpty: Bool { chunks.isEmpty }
    var count: Int { chunks.count }

    mutating func append(_ bytes: Data) -> Bool {
        guard chunks.count < maximumChunks,
              bytes.count <= maximumBytes,
              queuedBytes <= maximumBytes - bytes.count
        else { return false }
        chunks.append(bytes)
        queuedBytes += bytes.count
        return true
    }

    mutating func popFirst() -> Data? {
        guard let bytes = chunks.popFirst() else { return nil }
        queuedBytes -= bytes.count
        return bytes
    }

    mutating func removeAll() {
        chunks.removeAll(keepingCapacity: false)
        queuedBytes = 0
    }
}

private enum V2GatewayTransportWriteError: Error {
    case channelClosed
    case responseAlreadyPending
}

private enum V2GatewayProcessingOutcome: Sendable {
    case success(authenticated: Bool, needsFrameDrain: Bool)
    case failure(reason: V2GatewayConnectionClosure)
}

private extension V2GatewayByteStream {
    func finishSilently() async { try? await finish() }
}

func v2GatewayClosureReason(for error: Error) -> V2GatewayConnectionClosure {
    if let frameError = error as? V2FrameCodecError {
        switch frameError {
        case .declaredPayloadTooLarge, .payloadTooLarge, .tooManyFramesInBatch:
            return .frameLimitViolation
        default:
            break
        }
    }
    return .requestFailure
}
