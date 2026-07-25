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
    private let idleTimeoutMilliseconds: Int
    private let transportMetrics: (any V2GatewayTransportMetricsRecorder)?
    private var pending: [Data] = []
    private var queuedInboundBytes = 0
    private var processing = false
    private var closed = false
    private var lastInboundAt: NIODeadline?
    private var idleCheck: Scheduled<Void>?
    private var closeReason: V2GatewayConnectionClosure?

    public init(
        stream: V2GatewayByteStream,
        maximumQueuedInboundBytes: Int,
        idleTimeoutMilliseconds: Int,
        transportMetrics: (any V2GatewayTransportMetricsRecorder)? = nil
    ) {
        precondition(maximumQueuedInboundBytes > 0 && idleTimeoutMilliseconds > 0)
        self.stream = stream
        self.maximumQueuedInboundBytes = maximumQueuedInboundBytes
        self.idleTimeoutMilliseconds = idleTimeoutMilliseconds
        self.transportMetrics = transportMetrics
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        lastInboundAt = .now()
        if let transportMetrics {
            transportMetrics.connectionOpened()
        }
        scheduleIdleCheck(context: context)
        let boundContext = context.loopBound
        let boundHandler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let eventLoop = context.eventLoop
        let stream = stream
        Task {
            await stream.setDeviceRevocationHandler {
                eventLoop.execute {
                    boundHandler.value.close(
                        context: boundContext.value,
                        reason: .deviceRevoked,
                        revokeDevice: false
                    )
                }
            }
            await stream.setOutboundWriter { bytes in
                eventLoop.execute {
                    let context = boundContext.value
                    guard context.channel.isActive, context.channel.isWritable else { return }
                    var buffer = context.channel.allocator.buffer(capacity: bytes.count)
                    buffer.writeBytes(bytes)
                    context.writeAndFlush(boundHandler.value.wrapOutboundOut(buffer), promise: nil)
                }
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
        pending.removeAll(keepingCapacity: false)
        queuedInboundBytes = 0
        let stream = stream
        Task { await stream.finishSilently() }
        if let transportMetrics {
            let reason = closeReason ?? .peerDisconnected
            transportMetrics.connectionClosed(reason: reason)
        }
        context.fireChannelInactive()
    }

    private func processNext(context: ChannelHandlerContext) {
        guard !closed, !processing, !pending.isEmpty else { return }
        processing = true
        let inbound = pending.removeFirst()
        queuedInboundBytes -= inbound.count
        let stream = stream
        let boundHandler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = context.loopBound
        context.eventLoop.makeFutureWithTask { try await stream.receive(inbound) }.whenComplete { result in
            let handler = boundHandler.value
            let context = boundContext.value
            guard !handler.closed else { return }
            handler.processing = false
            switch result {
            case .success(let responses):
                for response in responses {
                    var buffer = context.channel.allocator.buffer(capacity: response.count)
                    buffer.writeBytes(response)
                    context.writeAndFlush(handler.wrapOutboundOut(buffer), promise: nil)
                }
                handler.processNext(context: context)
            case .failure(let error):
                handler.close(
                    context: context,
                    reason: v2GatewayClosureReason(for: error)
                )
            }
        }
    }

    private func close(
        context: ChannelHandlerContext,
        reason: V2GatewayConnectionClosure,
        revokeDevice: Bool = true
    ) {
        guard !closed else { return }
        closed = true
        closeReason = reason
        idleCheck?.cancel()
        idleCheck = nil
        pending.removeAll(keepingCapacity: false)
        queuedInboundBytes = 0
        if revokeDevice {
            let stream = stream
            Task { await stream.revokeDevice() }
        }
        context.close(promise: nil)
    }

    private func scheduleIdleCheck(context: ChannelHandlerContext) {
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = context.loopBound
        idleCheck = context.eventLoop.scheduleTask(in: .milliseconds(Int64(idleTimeoutMilliseconds))) {
            handler.value.checkIdle(context: boundContext.value)
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

private extension V2GatewayByteStream {
    func finishSilently() async { try? await finish() }
}

func v2GatewayClosureReason(for error: Error) -> V2GatewayConnectionClosure {
    if let frameError = error as? V2FrameCodecError,
       case .declaredPayloadTooLarge = frameError {
        return .frameLimitViolation
    }
    return .requestFailure
}
