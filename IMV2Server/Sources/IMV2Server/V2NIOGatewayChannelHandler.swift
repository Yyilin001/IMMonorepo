import Foundation
import IMV2Core
import Logging
@preconcurrency import NIOCore
import Synchronization

/// 单条已完成 TLS 解码的 NIO 通道。
///
/// 工作在进入由 actor 支撑的字节流之前先被串行化，因此异步认证或数据库操作
/// 不会把同一连接上的应答顺序打乱。队列显式按字节限量：过载应由可续传的同步吸收，
/// 而不是让内存无上限增长。
public final class V2NIOGatewayChannelHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private let stream: V2GatewayByteStream
    private let timeouts: V2GatewayConnectionTimeouts
    private let transportMetrics: any V2GatewayTransportMetricsRecorder
    private let foregroundWriteScheduler: V2NIOForegroundWriteScheduler
    private let now: @Sendable () -> NIODeadline
    private let logger = Logger(label: "imv2.gateway.transport")
    private var pending: V2GatewayInboundQueue
    private var processing = false
    /// 通道唯一的请求任务。
    ///
    /// EOF、超时、吊销以及所有显式关闭路径都会在丢弃排队输入之前先取消它，
    /// 因此对已经消失的客户端不会继续执行数据库或连接池获取。
    private var processingTask: Task<Void, Never>?
    private var attachmentTask: Task<Void, Never>?
    private var revocationTask: Task<Void, Never>?
    private var cleanupStarted = false
    private let drained: V2GatewayConnectionDrainCompletion?
    private let onDrained: (@Sendable () -> Void)?
    /// 尽力而为的前台推送没有请求承诺，因而可以合并。
    ///
    /// 它们的事件循环切换与有序命令应答分开处理，使一次实时事件突发不会为每个接收者
    /// 各创建一个 Swift 任务与 actor 等待续期。
    private var foregroundWriter: V2NIOGatewayForegroundWriter?
    private struct PendingResponseWrite {
        let frame: V2Frame
        let promise: EventLoopPromise<Void>
    }
    private var pendingResponseWrite: PendingResponseWrite?
    /// 上一次有界解码批次可能仍在字节流中留下后续线路帧。
    ///
    /// 必须先排空它们再处理后续 TCP 分片，才能保持应答先进先出。
    private var needsFrameDrain = false
    private var closed = false
    // `V2GatewayByteStream` 是 Actor，安装通道回调会跨越异步边界。
    // 撤销关闭回调尚未就绪前，绝不能让认证帧在在线设备注册表中登记。
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
            foregroundWriteScheduler: .init(),
            drained: nil,
            onDrained: nil,
            now: { .now() }
        )
    }

    init(
        stream: V2GatewayByteStream,
        maximumQueuedInboundBytes: Int,
        maximumQueuedInboundChunks: Int,
        authenticationTimeoutMilliseconds: Int,
        idleTimeoutMilliseconds: Int,
        transportMetrics: any V2GatewayTransportMetricsRecorder,
        foregroundWriteScheduler: V2NIOForegroundWriteScheduler,
        drained: V2GatewayConnectionDrainCompletion? = nil,
        onDrained: (@Sendable () -> Void)? = nil,
        now: @escaping @Sendable () -> NIODeadline = { .now() }
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
        self.now = now
        self.drained = drained
        self.onDrained = onDrained
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        lastInboundAt = now()
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
        attachmentTask = Task {
            let attached = await stream.attachNIOTransport(deviceRevocationHandler: {
                await withCheckedContinuation { continuation in
                    eventLoop.execute {
                        let handler = boundHandler.value
                        let context = boundContext.value
                        guard !handler.closed else {
                            context.channel.closeFuture.whenComplete { _ in continuation.resume() }
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
                // 等待这次事件循环跳转，防止通道停滞期间高频通知者
                // 排入无界数量的闭包。
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
            }, requiredNotificationWriter: { bytes in
                await withCheckedContinuation { continuation in
                    eventLoop.execute {
                        let handler = boundHandler.value
                        let context = boundContext.value
                        guard !handler.closed, context.channel.isActive, context.channel.isWritable else {
                            let reason: V2GatewayConnectionClosure = context.channel.isActive && !context.channel.isWritable
                                ? .requiredNotificationBackpressure : .requestFailure
                            handler.close(context: context, reason: reason)
                            continuation.resume(returning: false)
                            return
                        }
                        let completion = NIOLoopBound(
                            V2RequiredNotificationCompletion(continuation), eventLoop: eventLoop)
                        let timeout = eventLoop.scheduleTask(in: .seconds(10)) {
                            if completion.value.finish(false) {
                                boundHandler.value.close(context: boundContext.value, reason: .requiredNotificationWriteTimeout)
                            }
                        }
                        let promise = eventLoop.makePromise(of: Void.self)
                        promise.futureResult.whenComplete { result in
                            timeout.cancel()
                            switch result {
                            case .success:
                                _ = completion.value.finish(true)
                            case .failure:
                                if completion.value.finish(false) {
                                    boundHandler.value.close(context: boundContext.value, reason: .requestFailure)
                                }
                            }
                        }
                        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
                        buffer.writeBytes(bytes)
                        context.writeAndFlush(handler.wrapOutboundOut(buffer), promise: promise)
                    }
                }
            }, requiredNotificationClose: {
                await withCheckedContinuation { continuation in
                    eventLoop.execute {
                        let promise = eventLoop.makePromise(of: Void.self)
                        promise.futureResult.whenComplete { _ in continuation.resume() }
                        boundHandler.value.close(context: boundContext.value, reason: .requestFailure,
                            revokeDevice: false, closePromise: promise)
                    }
                }
            }, foregroundWriter: foregroundWriter, authorPresentationWriter: { write in
                await withCheckedContinuation { continuation in
                    eventLoop.execute {
                        let handler = boundHandler.value, context = boundContext.value
                        // Optional data gets no retry queue and never closes a
                        // healthy connection merely because it is congested.
                        guard !handler.closed, !handler.processing, !handler.needsFrameDrain,
                              handler.pendingResponseWrite == nil, context.channel.isActive,
                              context.channel.isWritable, !foregroundWriter.hasPendingFrames else {
                            continuation.resume(returning: false); return
                        }
                        let accepted = write.enqueueIfCurrent {
                            let context = boundContext.value
                            var buffer = context.channel.allocator.buffer(capacity: write.bytes.count)
                            buffer.writeBytes(write.bytes)
                            context.writeAndFlush(boundHandler.value.wrapOutboundOut(buffer), promise: nil)
                        }
                        continuation.resume(returning: accepted)
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
        lastInboundAt = now()
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
        stream.invalidateForegroundAuthorization()
        foregroundWriter?.finish()
        foregroundWriter = nil
        idleCheck?.cancel()
        idleCheck = nil
        authenticationDeadline?.cancel()
        authenticationDeadline = nil
        pending.removeAll()
        failPendingResponse(V2GatewayTransportWriteError.channelClosed)
        processingTask?.cancel()
        attachmentTask?.cancel()
        processing = false
        let stream = stream
        if !cleanupStarted {
            cleanupStarted = true
            let processingTask = processingTask
            let attachmentTask = attachmentTask
            let revocationTask = revocationTask
            let drained = drained
            let onDrained = onDrained
            Task {
                await processingTask?.value
                await attachmentTask?.value
                await revocationTask?.value
                await stream.finishSilently()
                onDrained?()
                drained?.complete()
            }
        }
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
                let needsFrameDrain = try await stream.receiveFrames(inbound, authenticationCompleted: {
                    await withCheckedContinuation { continuation in
                        eventLoop.execute {
                            let handler = boundHandler.value
                            handler.authenticationDeadline?.cancel()
                            handler.authenticationDeadline = nil
                            continuation.resume()
                        }
                    }
                }) { response in
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
                // 公开协议规定请求格式错误或无效时关闭连接。
                // 对客户端保持不透明；服务端只记录固定分类和错误类型，
                // 不输出可能包含协议载荷、连接地址或凭据的异常描述。
                let closeReason = v2GatewayClosureReason(for: error)
                var metadata = V2SafeLogMetadata.failure(error, stage: "gateway_transport")
                metadata["closure_reason"] = "\(closeReason.rawValue)"
                logger.warning(
                    "gateway request processing failed",
                    metadata: metadata
                )
                outcome = .failure(reason: closeReason)
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
        guard !closed else { return }
        processingTask = nil
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
        stream.invalidateForegroundAuthorization()
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
        processing = false
        if revokeDevice {
            let stream = stream
            revocationTask = Task { await stream.revokeDevice() }
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
            // 流在分发下一帧前会等待此 promise，
            // 因此停滞通道至多保留一个完整响应。
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

    private func scheduleIdleCheck(context: ChannelHandlerContext, after delay: TimeAmount? = nil) {
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = context.loopBound
        idleCheck = context.eventLoop.scheduleTask(in: delay ?? timeouts.idle) {
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
        let elapsed = now().uptimeNanoseconds - lastInboundAt.uptimeNanoseconds
        let timeout = UInt64(timeouts.idle.nanoseconds)
        if elapsed >= timeout {
            close(context: context, reason: .idleTimeout)
        } else {
            scheduleIdleCheck(context: context, after: .nanoseconds(Int64(timeout - elapsed)))
        }
    }
}

/// 进程级前台写合并器。
///
/// 每个子事件循环各自拥有一条通道：第一个就绪的连接负责调度一次排空，
/// 之后就绪的连接加入同一轮有界处理，而不是各自分配一个 `EventLoop.execute` 闭包。
/// 每轮处理数量设有上限，使实时事件突发时心跳、命令应答与 TLS 处理仍能公平获得事件循环。
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

        /// 批量入队写者。
        ///
        /// 一次群组发布通常会让同一 EventLoop 上的多个写者同时就绪。
        /// 在单次通道锁内追加整批写者，可避免为每个接收者重复获取跨线程调度器锁，
        /// 同时保持完全相同的写者 FIFO 以及公平、有界的事件循环排空轮次。
        ///
        /// - Parameter writers: 本次要追加的写者列表；为空时直接返回。
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

/// 一个已受生命周期围栏保护、且已完成编码的前台帧，等待被某个连接写者接纳。
///
/// 创建该值本身不会入队任何工作；群组发布方可以收集大量提交，只进入每个 EventLoop 通道一次。
struct V2NIOGatewayForegroundWriteSubmission: Sendable {
    let writer: V2NIOGatewayForegroundWriter
    let bytes: ByteBuffer
    let isAuthorizedToWrite: @Sendable () -> Bool

    init(writer: V2NIOGatewayForegroundWriter, bytes: ByteBuffer,
         isAuthorizedToWrite: @escaping @Sendable () -> Bool = { true }) {
        self.writer = writer
        self.bytes = bytes
        self.isAuthorizedToWrite = isAuthorizedToWrite
    }
}

/// 单个前台连接写者使用的 FIFO。
///
/// 正常运行时它保留每一个有序实时批次。若有界前缀被写满，
/// 则单独保留一个最新的恢复帧：前缀排空后，其更高的水位线会刻意暴露一个游标缺口，
/// 从而驱动持久拉取路径。这样可在不悄悄假设后缀连续的前提下限制内存占用。
struct V2GatewayForegroundWriteQueue: Sendable {
    struct Entry: Sendable {
        let bytes: ByteBuffer
        let isAuthorizedToWrite: @Sendable () -> Bool
    }
    enum AppendOutcome: Equatable, Sendable {
        case queued
        case recoveryQueued
        case recoveryReplaced
    }

    struct Drain: Sendable {
        let entries: [Entry]
        let bytes: Int
        var frames: [ByteBuffer] { entries.map(\.bytes) }
    }

    private let maximumQueuedBytes: Int
    private let maximumQueuedFrames: Int
    private var frames: CircularBuffer<Entry>
    private var frameBytes = 0
    private var recoveryFrame: Entry?

    init(maximumQueuedBytes: Int, maximumQueuedFrames: Int) {
        precondition(maximumQueuedBytes > 0 && maximumQueuedFrames > 0)
        self.maximumQueuedBytes = maximumQueuedBytes
        self.maximumQueuedFrames = maximumQueuedFrames
        frames = .init(initialCapacity: min(maximumQueuedFrames, 32))
    }

    var isEmpty: Bool { frames.isEmpty && recoveryFrame == nil }
    var count: Int { frames.count + (recoveryFrame == nil ? 0 : 1) }
    var queuedBytes: Int { frameBytes + (recoveryFrame?.bytes.readableBytes ?? 0) }

    mutating func append(_ bytes: ByteBuffer,
                         isAuthorizedToWrite: @escaping @Sendable () -> Bool = { true }) -> AppendOutcome {
        let entry = Entry(bytes: bytes, isAuthorizedToWrite: isAuthorizedToWrite)
        if recoveryFrame != nil {
            recoveryFrame = entry
            return .recoveryReplaced
        }
        if frames.count < maximumQueuedFrames,
           bytes.readableBytes <= maximumQueuedBytes,
           frameBytes <= maximumQueuedBytes - bytes.readableBytes {
            frames.append(entry)
            frameBytes += bytes.readableBytes
            return .queued
        }
        recoveryFrame = entry
        return .recoveryQueued
    }

    mutating func popBatch(
        maximumFrames: Int,
        maximumBytes: Int
    ) -> Drain? {
        precondition(maximumFrames > 0 && maximumBytes > 0)
        guard !isEmpty else { return nil }
        var drained: [Entry] = []
        drained.reserveCapacity(min(maximumFrames, count))
        var drainedBytes = 0
        while drained.count < maximumFrames, let first = frames.first {
            if !drained.isEmpty, drainedBytes + first.bytes.readableBytes > maximumBytes { break }
            _ = frames.removeFirst()
            frameBytes -= first.bytes.readableBytes
            drained.append(first)
            drainedBytes += first.bytes.readableBytes
            if drainedBytes >= maximumBytes { break }
        }
        if frames.isEmpty,
           drained.count < maximumFrames,
           let recoveryFrame,
           drained.isEmpty || drainedBytes + recoveryFrame.bytes.readableBytes <= maximumBytes {
            self.recoveryFrame = nil
            drained.append(recoveryFrame)
            drainedBytes += recoveryFrame.bytes.readableBytes
        }
        guard !drained.isEmpty else { return nil }
        return .init(entries: drained, bytes: drainedBytes)
    }

    mutating func removeAll() {
        frames.removeAll(keepingCapacity: true)
        frameBytes = 0
        recoveryFrame = nil
    }
}

/// 从已认证前台路由到单个 NIO channel 的有界、不挂起桥接。
///
/// 共享的不可变帧在排队期间保持写时复制。一次排空会把若干完整协议帧复制进单个 NIO 缓冲区，
/// 并只执行一次 flush，使解码器可以消费这些合并帧，
/// 同时摊薄事件循环、系统调用与 TLS 记录的开销。
final class V2NIOGatewayForegroundWriter: @unchecked Sendable {
    /// Read from the actual EventLoop before optional author bytes are written.
    /// Body drain writes synchronously on that same loop, so an extracted body
    /// batch cannot be overtaken between this check and the optional write.
    var hasPendingFrames: Bool { state.withLock { !$0.queue.isEmpty } }
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
    /// 生产 NIO channel 及其 EventLoop 是线程安全的入口点。
    ///
    /// 所有可变的 channel handler 状态都局限在该 EventLoop 内；
    /// 该引用绝不会被用来就地运行业务工作。
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

    /// 兼容入口，供聚焦的队列测试与未预处理数据的本地调用方使用。
    ///
    /// 生产环境的群组发布会提交已准备好的 `ByteBuffer`，
    /// 从而避免每个连接都做一次这样的转换。
    ///
    /// - Parameter bytes: 待提交的已编码字节。
    func submit(_ bytes: Data) {
        submit(ByteBuffer(bytes: bytes))
    }

    func submit(_ bytes: ByteBuffer) {
        submit(bytes, isAuthorizedToWrite: { true })
    }

    func submit(_ bytes: ByteBuffer,
                isAuthorizedToWrite: @escaping @Sendable () -> Bool) {
        if append(bytes, isAuthorizedToWrite: isAuthorizedToWrite) { schedulerLane.enqueue(self) }
    }

    /// 接纳一个已准备好的帧，但不立即进入共享通道。
    ///
    /// `submitBatch` 借此把通道锁开销从「每个接收者一次」降为「每个 EventLoop 一次」。
    /// 每连接互斥锁仍然是生命周期、有界队列与 FIFO 的权威。
    ///
    /// - Parameter bytes: 待接纳的已准备帧。
    /// - Returns: 是否需要将本写者加入调度通道。
    private func append(_ bytes: ByteBuffer,
                        isAuthorizedToWrite: @escaping @Sendable () -> Bool) -> Bool {
        guard isAuthorizedToWrite() else { return false }
        let submission = state.withLock { state -> (
            shouldEnqueue: Bool,
            outcome: V2GatewayForegroundWriteQueue.AppendOutcome,
            queuedBytes: Int
        )? in
            guard !state.finished else { return nil }
            let outcome = state.queue.append(bytes, isAuthorizedToWrite: isAuthorizedToWrite)
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

    /// 真实群组广播路径使用的批量对应实现。
    ///
    /// 所有队列接纳都发生在调度之前，因此即使本次调用不再把某写者加入通道，
    /// 一个已被并发调度的写者也能安全地排空已接纳的帧。
    /// 通过对象标识按预先注册的 EventLoop 通道对写者分组，
    /// 无需对进程级调度器做哈希或加锁。
    ///
    /// - Parameter submissions: 本批待提交的写者与帧。
    static func submitBatch(_ submissions: [V2NIOGatewayForegroundWriteSubmission]) {
        guard !submissions.isEmpty else { return }
        var batches: [ObjectIdentifier: LaneBatch] = [:]
        batches.reserveCapacity(min(submissions.count, 8))
        for submission in submissions {
            let writer = submission.writer
            guard writer.append(submission.bytes,
                                isAuthorizedToWrite: submission.isAuthorizedToWrite) else { continue }
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
        let frames = batch.entries.filter { $0.isAuthorizedToWrite() }.map(\.bytes)
        guard !frames.isEmpty else {
            if result.1 { schedulerLane.enqueue(self) }
            return
        }
        let bytes = frames.reduce(0) { $0 + $1.readableBytes }
        let buffer: ByteBuffer
        if frames.count == 1 {
            // 常规群组广播路径直接写入共享的不可变写时复制存储。
            // 读索引变化只影响本地值；下游处理器真正修改字节时会自动分离存储。
            buffer = frames[0]
        } else {
            var combined = channel.allocator.buffer(capacity: bytes)
            for frame in frames { combined.writeImmutableBuffer(frame) }
            buffer = combined
        }
        channel.writeAndFlush(buffer, promise: nil)
        metrics?.foregroundWriteBatch(frames: frames.count, bytes: bytes)
        if result.1 { schedulerLane.enqueue(self) }
    }
}

/// 把稳定的 18 字节网关头与 protobuf 载荷直接编码进 NIO 持有的存储。
///
/// 字节序刻意与 `V2FrameCodec.encode` 保持一致；
/// 在帧跨越到事件循环之前，校验仍由 `V2GatewayByteStream` 负责。
///
/// - Parameters:
///   - frame: 待编码的帧。
///   - allocator: NIO 缓冲区分配器。
/// - Returns: 可直接写入 channel 的缓冲区。
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

/// 局限于事件循环的二维接纳队列。
///
/// `CircularBuffer` 让追加/弹出保持摊还 O(1)，
/// 因此排空一个写满的碎片化连接时，
/// 绝不会在共享事件循环上搬移成千上万个保留的 `Data` 值。
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

/// 只能在所属事件循环上通过 NIOLoopBound 访问。
private final class V2RequiredNotificationCompletion {
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func finish(_ result: Bool) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: result)
        return true
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
