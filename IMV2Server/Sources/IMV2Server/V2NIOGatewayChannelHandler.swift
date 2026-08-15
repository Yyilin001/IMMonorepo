import Foundation
import IMV2Core
@preconcurrency import NIOCore

/// A single TLS-decoded NIO channel. Work is serialized before it enters the
/// actor-backed byte stream, so async authentication/database work cannot
/// reorder replies on a connection. The queue is explicitly byte-bounded:
/// resumable sync must absorb overload rather than memory growing without
/// limit.
public final class V2NIOGatewayChannelHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private let stream: V2GatewayByteStream
    private let maximumQueuedInboundBytes: Int
    private let maximumQueuedInboundChunks: Int
    private let authenticationTimeoutMilliseconds: Int
    private let idleTimeoutMilliseconds: Int
    private let transportMetrics: (any V2GatewayTransportMetricsRecorder)?
    private var pending: [Data] = []
    private var pendingHead = 0
    private var queuedInboundBytes = 0
    private var processing = false
    /// Exactly one request task belongs to the channel. EOF, timeout,
    /// revocation, and every explicit close path cancel it before dropping
    /// queued input, so database/pool acquisition does not continue for a
    /// client that no longer exists.
    private var processingTask: Task<Void, Never>?
    private struct PendingResponseWrite {
        let bytes: Data
        let promise: EventLoopPromise<Void>
    }
    private var pendingResponseWrite: PendingResponseWrite?
    private var closed = false
    // `V2GatewayByteStream` is an actor, so installing its channel callbacks
    // crosses an async boundary. Never let an authenticate frame register in
    // the live-device registry before the revocation-close callback exists.
    private var callbacksReady = false
    private var lastInboundAt: NIODeadline?
    private var idleCheck: Scheduled<Void>?
    private var authenticationDeadline: Scheduled<Void>?
    private var closeReason: V2GatewayConnectionClosure?

    public init(
        stream: V2GatewayByteStream,
        maximumQueuedInboundBytes: Int,
        maximumQueuedInboundChunks: Int,
        authenticationTimeoutMilliseconds: Int,
        idleTimeoutMilliseconds: Int,
        transportMetrics: (any V2GatewayTransportMetricsRecorder)? = nil
    ) {
        precondition(
            maximumQueuedInboundBytes > 0 &&
            maximumQueuedInboundChunks > 0 &&
            authenticationTimeoutMilliseconds > 0 &&
            idleTimeoutMilliseconds > 0
        )
        self.stream = stream
        self.maximumQueuedInboundBytes = maximumQueuedInboundBytes
        self.maximumQueuedInboundChunks = maximumQueuedInboundChunks
        self.authenticationTimeoutMilliseconds = authenticationTimeoutMilliseconds
        self.idleTimeoutMilliseconds = idleTimeoutMilliseconds
        self.transportMetrics = transportMetrics
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        lastInboundAt = .now()
        if let transportMetrics {
            transportMetrics.connectionOpened()
        }
        scheduleIdleCheck(context: context)
        scheduleAuthenticationDeadline(context: context)
        let boundContext = context.loopBound
        let boundHandler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let eventLoop = context.eventLoop
        let stream = stream
        Task {
            let attached = await stream.attachTransport(deviceRevocationHandler: {
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
            })
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
        guard queuedInboundBytes <= maximumQueuedInboundBytes - bytes.count else {
            close(context: context, reason: .inboundQueueLimit)
            return
        }
        guard pending.count - pendingHead < maximumQueuedInboundChunks else {
            close(context: context, reason: .inboundQueueLimit)
            return
        }
        pending.append(bytes)
        queuedInboundBytes += bytes.count
        if let transportMetrics {
            let queuedBytes = queuedInboundBytes
            transportMetrics.observeQueuedInboundBytes(queuedBytes)
        }
        processNext(context: context)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        closed = true
        idleCheck?.cancel()
        idleCheck = nil
        authenticationDeadline?.cancel()
        authenticationDeadline = nil
        pending.removeAll(keepingCapacity: false)
        pendingHead = 0
        queuedInboundBytes = 0
        failPendingResponse(V2GatewayTransportWriteError.channelClosed)
        processingTask?.cancel()
        processingTask = nil
        processing = false
        let stream = stream
        Task { await stream.finishSilently() }
        if let transportMetrics {
            let reason = closeReason ?? .peerDisconnected
            transportMetrics.connectionClosed(reason: reason)
        }
        context.fireChannelInactive()
    }

    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            flushPendingResponse(context: context)
            processNext(context: context)
        }
        context.fireChannelWritabilityChanged()
    }

    private func processNext(context: ChannelHandlerContext) {
        guard callbacksReady, !closed, !processing,
              context.channel.isWritable,
              pendingHead < pending.count
        else { return }
        processing = true
        let inbound = pending[pendingHead]
        pendingHead += 1
        if pendingHead >= 64, pendingHead * 2 >= pending.count {
            pending.removeFirst(pendingHead)
            pendingHead = 0
        }
        queuedInboundBytes -= inbound.count
        let stream = stream
        let boundHandler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = context.loopBound
        let eventLoop = context.eventLoop
        processingTask = Task {
            let outcome: V2GatewayProcessingOutcome
            do {
                try Task.checkCancellation()
                try await stream.receive(inbound) { response in
                    try Task.checkCancellation()
                    try await eventLoop.flatSubmit {
                        boundHandler.value.writeWhenWritable(
                            response,
                            context: boundContext.value
                        )
                    }.get()
                }
                try Task.checkCancellation()
                outcome = .success(authenticated: await stream.isAuthenticated())
            } catch {
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
        case .success(let authenticated):
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
        idleCheck?.cancel()
        idleCheck = nil
        authenticationDeadline?.cancel()
        authenticationDeadline = nil
        pending.removeAll(keepingCapacity: false)
        pendingHead = 0
        queuedInboundBytes = 0
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

    private func writeWhenWritable(
        _ bytes: Data,
        context: ChannelHandlerContext
    ) -> EventLoopFuture<Void> {
        let promise = context.eventLoop.makePromise(of: Void.self)
        guard !closed, context.channel.isActive else {
            promise.fail(V2GatewayTransportWriteError.channelClosed)
            return promise.futureResult
        }
        if context.channel.isWritable {
            write(bytes, promise: promise, context: context)
        } else if pendingResponseWrite == nil {
            // The stream awaits this promise before dispatching another frame,
            // so a stalled channel retains at most one complete response.
            pendingResponseWrite = .init(bytes: bytes, promise: promise)
        } else {
            promise.fail(V2GatewayTransportWriteError.responseAlreadyPending)
        }
        return promise.futureResult
    }

    private func flushPendingResponse(context: ChannelHandlerContext) {
        guard context.channel.isWritable, let pendingResponseWrite else { return }
        self.pendingResponseWrite = nil
        write(
            pendingResponseWrite.bytes,
            promise: pendingResponseWrite.promise,
            context: context
        )
    }

    private func write(
        _ bytes: Data,
        promise: EventLoopPromise<Void>,
        context: ChannelHandlerContext
    ) {
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
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
        idleCheck = context.eventLoop.scheduleTask(in: .milliseconds(Int64(idleTimeoutMilliseconds))) {
            handler.value.checkIdle(context: boundContext.value)
        }
    }

    private func scheduleAuthenticationDeadline(context: ChannelHandlerContext) {
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = context.loopBound
        authenticationDeadline = context.eventLoop.scheduleTask(
            in: .milliseconds(Int64(authenticationTimeoutMilliseconds))
        ) {
            let handler = handler.value
            guard !handler.closed, handler.authenticationDeadline != nil else { return }
            handler.close(context: boundContext.value, reason: .authenticationTimeout)
        }
    }

    private func checkIdle(context: ChannelHandlerContext) {
        guard !closed, let lastInboundAt else { return }
        let elapsed = NIODeadline.now().uptimeNanoseconds - lastInboundAt.uptimeNanoseconds
        let timeout = UInt64(idleTimeoutMilliseconds) * 1_000_000
        if elapsed >= timeout {
            close(context: context, reason: .idleTimeout)
        } else {
            scheduleIdleCheck(context: context)
        }
    }
}

private enum V2GatewayTransportWriteError: Error {
    case channelClosed
    case responseAlreadyPending
}

private enum V2GatewayProcessingOutcome: Sendable {
    case success(authenticated: Bool)
    case failure(reason: V2GatewayConnectionClosure)
}

private extension V2GatewayByteStream {
    func finishSilently() async { try? await finish() }
}

func v2GatewayClosureReason(for error: Error) -> V2GatewayConnectionClosure {
    if let frameError = error as? V2FrameCodecError {
        switch frameError {
        case .declaredPayloadTooLarge, .tooManyFramesInBatch:
            return .frameLimitViolation
        default:
            break
        }
    }
    return .requestFailure
}
