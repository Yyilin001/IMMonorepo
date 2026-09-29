import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Compression
import IMV2Core
import NIOCore
import Synchronization

/// 一份不可变的服务端推送帧，由协商到相同协议版本的每个已授权本地接收者共享。
///
/// 这些字节不携带任何连接特定状态：
/// 受众选择与传输生命周期校验都留在这个值之外。
struct V2PreparedGatewayGroupEventAvailable: Sendable {
    let protocolVersion: UInt8
    /// `ByteBuffer` 是写时复制的、`Sendable` 的值。
    ///
    /// 因此一份已准备的群组帧可以把自己的不可变存储共享给每个已授权通道；
    /// 需要修改自身副本的通道流水线会照常分离。
    private let uncompressedBytes: ByteBuffer
    private let compressedBytes: ByteBuffer?

    init?(
        roomID: RoomID,
        highWatermark: UInt64,
        directEvent: V2DirectRoomLiveEvent?,
        frameLimits: V2FrameLimits,
        protocolVersion: UInt8 = UInt8(IMV2ProtocolVersion.current),
        compression: V2NegotiatedFrameCompression? = nil,
        maximumUncompressedPayloadBytes: Int = V2ServerProtobufFrameCodec
            .defaultMaximumUncompressedPayloadBytes,
        compressionThresholdBytes: Int = V2ServerProtobufFrameCodec
            .defaultCompressionThresholdBytes,
        maximumExpansionRatio: Int = V2ZlibFrameCompression.defaultMaximumExpansionRatio
    ) {
        var envelope = IMV2Envelope()
        envelope.requestID = 0
        envelope.protocolVersion = UInt32(protocolVersion)
        envelope.groupEventAvailable = .init()
        envelope.groupEventAvailable.roomID = roomID.rawValue
        envelope.groupEventAvailable.highWatermark = highWatermark
        if let directEvent,
           directEvent.roomID == roomID,
           directEvent.highWatermark == highWatermark {
            envelope.groupEventAvailable.sourceEventID = directEvent.sourceEventID.rawValue
            envelope.groupEventAvailable.roomSequence = directEvent.roomSequence
            envelope.groupEventAvailable.projectionKind = directEvent.projectionKind
            envelope.groupEventAvailable.eventPayload = directEvent.payload
        }
        guard let uncompressedBytes = Self.encodedBytes(
            envelope,
            frameLimits: frameLimits,
            protocolVersion: protocolVersion,
            compression: nil,
            maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
            compressionThresholdBytes: compressionThresholdBytes,
            maximumExpansionRatio: maximumExpansionRatio
        ) else { return nil }
        self.protocolVersion = protocolVersion
        self.uncompressedBytes = uncompressedBytes
        compressedBytes = compression.flatMap { compression in
            Self.encodedBytes(
                envelope,
                frameLimits: frameLimits,
                protocolVersion: protocolVersion,
                compression: compression,
                maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
                compressionThresholdBytes: compressionThresholdBytes,
                maximumExpansionRatio: maximumExpansionRatio
            )
        }
    }

    /// 对单个房间本地的有序群组批次做一次编码。
    ///
    /// 其中不存在连接特定字段，因此完全相同的不可变字节可以入队到每个已授权流。
    ///
    /// - Parameters:
    ///   - groupEvents: 本批按房间顺序排列的群组实时事件。
    ///   - frameLimits: 帧编解码限制。
    ///   - protocolVersion: 目标协议版本，默认当前版本。
    ///   - compression: 已协商的帧压缩方式；`nil` 表示不压缩。
    ///   - maximumUncompressedPayloadBytes: 允许的未压缩载荷上限（字节）。
    ///   - compressionThresholdBytes: 启用压缩的字节阈值。
    ///   - maximumExpansionRatio: 允许的最大膨胀比。
    init?(
        groupEvents: [V2DirectRoomLiveEvent],
        frameLimits: V2FrameLimits,
        protocolVersion: UInt8 = UInt8(IMV2ProtocolVersion.current),
        compression: V2NegotiatedFrameCompression? = nil,
        maximumUncompressedPayloadBytes: Int = V2ServerProtobufFrameCodec
            .defaultMaximumUncompressedPayloadBytes,
        compressionThresholdBytes: Int = V2ServerProtobufFrameCodec
            .defaultCompressionThresholdBytes,
        maximumExpansionRatio: Int = V2ZlibFrameCompression.defaultMaximumExpansionRatio
    ) {
        guard let first = groupEvents.first,
              let membershipRevision = first.groupMembershipRevision,
              first.recipientUserIDs.isEmpty,
              first.excludedConnectionID == nil,
              groupEvents.allSatisfy({ event in
                  event.roomID == first.roomID
                      && event.groupMembershipRevision == membershipRevision
                      && event.recipientUserIDs.isEmpty
                      && event.excludedConnectionID == nil
              })
        else { return nil }
        let ordered = v2GroupEventsOrderedByRoomSequence(groupEvents)
        var envelope = IMV2Envelope()
        envelope.requestID = 0
        envelope.protocolVersion = UInt32(protocolVersion)
        envelope.groupEventAvailable = .init()
        envelope.groupEventAvailable.roomID = first.roomID.rawValue
        envelope.groupEventAvailable.highWatermark = ordered.last?.roomSequence ?? first.highWatermark
        envelope.groupEventAvailable.liveEvents = ordered.map { event in
            var wire = IMV2GroupEvent()
            wire.sourceEventID = event.sourceEventID.rawValue
            wire.roomSequence = event.roomSequence
            wire.projectionKind = event.projectionKind
            wire.payload = event.payload
            return wire
        }
        guard let uncompressedBytes = Self.encodedBytes(
            envelope,
            frameLimits: frameLimits,
            protocolVersion: protocolVersion,
            compression: nil,
            maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
            compressionThresholdBytes: compressionThresholdBytes,
            maximumExpansionRatio: maximumExpansionRatio
        ) else { return nil }
        self.protocolVersion = protocolVersion
        self.uncompressedBytes = uncompressedBytes
        compressedBytes = compression.flatMap { compression in
            Self.encodedBytes(
                envelope,
                frameLimits: frameLimits,
                protocolVersion: protocolVersion,
                compression: compression,
                maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
                compressionThresholdBytes: compressionThresholdBytes,
                maximumExpansionRatio: maximumExpansionRatio
            )
        }
    }

    func bytes(for compression: V2NegotiatedFrameCompression?) -> ByteBuffer {
        compression == .zlib ? (compressedBytes ?? uncompressedBytes) : uncompressedBytes
    }

    private static func encodedBytes(
        _ envelope: IMV2Envelope,
        frameLimits: V2FrameLimits,
        protocolVersion: UInt8,
        compression: V2NegotiatedFrameCompression?,
        maximumUncompressedPayloadBytes: Int,
        compressionThresholdBytes: Int,
        maximumExpansionRatio: Int
    ) -> ByteBuffer? {
        guard let frame = try? V2ServerProtobufFrameCodec.encode(
            envelope,
            frameVersion: protocolVersion,
            compression: compression,
            maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
            compressionThresholdBytes: compressionThresholdBytes,
            maximumExpansionRatio: maximumExpansionRatio
        ) else { return nil }
        guard let bytes = try? V2FrameCodec.encode(frame, limits: frameLimits) else {
            return nil
        }
        return ByteBuffer(bytes: bytes)
    }
}

/// 面向高频前台推送路径的进程本地授权与生命周期栅栏。
///
/// 注册表仍会从已认证订阅中选出受众；
/// 这第二道栅栏则防止过期的路由快照在注销、吊销或传输关闭之后继续写入。
/// 同步写者只在该通道自身的 EventLoop 上入队有界的尽力而为工作。
/// 持久房间日志游标拉取仍是每一次丢弃的恢复路径。
final class V2GatewayForegroundAuthorization: Sendable {
    private let active = Mutex(true)
    private let sessionIsLive: @Sendable () -> Bool

    init(sessionIsLive: @escaping @Sendable () -> Bool) {
        self.sessionIsLive = sessionIsLive
    }

    func invalidate() { active.withLock { $0 = false } }
    func isAuthorizedToWrite() -> Bool {
        active.withLock { $0 } && sessionIsLive()
    }
}

private final class V2GatewayForegroundTransport: Sendable {
    private enum Writer: Sendable {
        case callback(@Sendable (ByteBuffer) -> Void)
        case nio(V2NIOGatewayForegroundWriter)
    }

    private struct State: Sendable {
        var protocolVersion: UInt8?
        var compression: V2NegotiatedFrameCompression?
        var writer: Writer?
        var authorization: V2GatewayForegroundAuthorization?
    }

    private let state = Mutex(State())

    func attach(writer: (@Sendable (ByteBuffer) -> Void)?) {
        state.withLock { $0.writer = writer.map(Writer.callback) }
    }

    func attach(nioWriter: V2NIOGatewayForegroundWriter?) {
        state.withLock { $0.writer = nioWriter.map(Writer.nio) }
    }

    func activate(
        protocolVersion: UInt8,
        compression: V2NegotiatedFrameCompression?,
        sessionIsLive: @escaping @Sendable () -> Bool
    ) {
        state.withLock {
            $0.authorization?.invalidate()
            $0.protocolVersion = protocolVersion
            $0.compression = compression
            $0.authorization = .init(sessionIsLive: sessionIsLive)
        }
    }

    func deactivate() {
        state.withLock {
            $0.authorization?.invalidate()
            $0.authorization = nil
            $0.protocolVersion = nil
            $0.compression = nil
        }
    }

    func detach() {
        state.withLock {
            $0.authorization?.invalidate()
            $0.authorization = nil
            $0.protocolVersion = nil
            $0.compression = nil
            $0.writer = nil
        }
    }

    func submit(_ prepared: V2PreparedGatewayGroupEventAvailable) -> Bool {
        let submission = state.withLock { state -> (
            writer: Writer,
            bytes: ByteBuffer,
            authorization: V2GatewayForegroundAuthorization
        )? in
            guard state.protocolVersion == prepared.protocolVersion else { return nil }
            guard let writer = state.writer, let authorization = state.authorization else { return nil }
            return (writer, prepared.bytes(for: state.compression), authorization)
        }
        guard let submission, submission.authorization.isAuthorizedToWrite() else { return false }
        switch submission.writer {
        case .callback(let writer):
            guard submission.authorization.isAuthorizedToWrite() else { return false }
            writer(submission.bytes)
        case .nio(let writer):
            let authorization = submission.authorization
            writer.submit(submission.bytes, isAuthorizedToWrite: { authorization.isAuthorizedToWrite() })
        }
        return true
    }

    /// 捕获与 `submit` 相同的认证与生命周期栅栏，
    /// 但把通道调度留给群组发布方，使大量本地接收者可以作为单个 EventLoop 批次被接纳。
    ///
    /// - Parameter prepared: 已准备的群组事件帧。
    /// - Returns: 可供批量提交的 NIO 提交对象；不满足快速路径条件时为 `nil`。
    func prepareNIOSubmission(
        _ prepared: V2PreparedGatewayGroupEventAvailable
    ) -> V2NIOGatewayForegroundWriteSubmission? {
        state.withLock { state in
            guard state.protocolVersion == prepared.protocolVersion,
                  case .nio(let writer)? = state.writer,
                  let authorization = state.authorization,
                  authorization.isAuthorizedToWrite()
            else { return nil }
            return .init(
                writer: writer,
                bytes: prepared.bytes(for: state.compression),
                isAuthorizedToWrite: { authorization.isAuthorizedToWrite() }
            )
        }
    }
}

/// 网关连接中与传输无关的那一半。
///
/// TLS 刻意在该 actor 之外终止；调用方只投喂已解密字节，
/// 并把返回的字节写回同一连接。
/// 这使分帧、生命周期栅栏与领域分发都能在没有套接字的情况下被测试。
public actor V2GatewayByteStream {
    /// 生成进程内唯一的连接标识。
    ///
    /// 它由与已接受消息标识相同的 CSPRNG 扩展与原子计数器支撑，
    /// 从而避免在重连突发期间依赖平台 UUID 实现。
    ///
    /// - Returns: 新生成的连接标识。
    public nonisolated static func makeConnectionID() -> UUID {
        V2SecureProcessUUIDGenerator.shared.makeOne()
    }

    private var decoder: V2FrameDecoder
    private let frameLimits: V2FrameLimits
    private let session: V2GatewaySession
    private let handler: any V2GatewayCommandHandler
    private let connectionID: UUID
    private let registry: V2DeviceConnectionRegistry
    private nonisolated let foregroundTransport = V2GatewayForegroundTransport()
    private var registeredIdentity: V2AuthenticatedConnection?
    private var unregisterTask: Task<Void, Never>?
    private var revocationTask: Task<Void, Never>?
    private let authorPresentationDispatcher: V2AuthorPresentationDispatcher?
    private let authorPresentationIngress: V2AuthorPresentationIngress?
    private let authorPresentationTransport = V2AuthorPresentationTransport()
    private var authorPresentationWriter: (@Sendable (V2AuthorPresentationWrite) async -> Bool)?
    private var authorPresentationView: (roomID: RoomID, viewID: UUID)?
    private var authorPresentationRegistered = false
    private var authorPresentationWriting = false
    // 传输确认本地通道关闭前，撤销工作器不能推进持久化游标。
    // 因此处理器将 NIO 关闭 future 桥接进此 Actor，
    // 而不只是安排一次尽力而为的关闭。
    private var deviceRevocationHandler: (@Sendable () async -> Void)?
    private var outboundWriter: (@Sendable (Data) async -> Void)?
    private var requiredNotificationWriter: (@Sendable (Data) async -> Bool)?
    private var requiredNotificationClose: (@Sendable () async -> Void)?
    /// 一旦所属传输关闭，迟到的回调安装就不得重新形成
    /// 流 -> 回调 -> channel handler -> 流的循环强引用。
    ///
    /// 它同时为 handlerAdded/channelInactive 之间的竞态建立围栏。
    private var transportClosed = false
    private let messageSendBudget: V2GatewayMessageSendBudget
    private let maximumConcurrentMessageSends: Int
    private let maximumConcurrentMessageSendBytes: Int
    private var messageSendTasks: [UInt64: Task<Void, Never>] = [:]
    private var messageSendReservedBytes = 0

    /// Registry/device shutdown can invalidate every selected connection before
    /// awaiting any actor or database cleanup.
    nonisolated func invalidateForegroundAuthorization() {
        session.invalidateImmediately()
        foregroundTransport.deactivate()
    }

    public init(
        frameLimits: V2FrameLimits,
        session: V2GatewaySession,
        handler: any V2GatewayCommandHandler,
        connectionID: UUID = V2GatewayByteStream.makeConnectionID(),
        registry: V2DeviceConnectionRegistry,
        authorPresentationDispatcher: V2AuthorPresentationDispatcher? = nil,
        authorPresentationIngress: V2AuthorPresentationIngress? = nil,
        messageSendBudget: V2GatewayMessageSendBudget = .init(maximumBytes: 67_108_864),
        maximumConcurrentMessageSends: Int = 4,
        maximumConcurrentMessageSendBytes: Int = 4_194_304
    ) {
        precondition(maximumConcurrentMessageSends > 0 && maximumConcurrentMessageSendBytes > 0)
        self.decoder = .init(limits: frameLimits)
        self.frameLimits = frameLimits
        self.session = session
        self.handler = V2PresencePublicationGatewayHandler(delegate:handler,registry:registry,connectionID:connectionID)
        self.connectionID = connectionID
        self.registry = registry
        self.authorPresentationDispatcher = authorPresentationDispatcher
        self.authorPresentationIngress = authorPresentationIngress
        self.messageSendBudget = messageSendBudget
        self.maximumConcurrentMessageSends = maximumConcurrentMessageSends
        self.maximumConcurrentMessageSendBytes = maximumConcurrentMessageSendBytes
    }

    /// 接收 TLS 流产生的任意分片。
    ///
    /// 一次输入可能不产生任何响应（帧不完整）或产生多个响应（多帧合并）。
    /// 分帧或命令失败会关闭会话，
    /// 从而让畸形流无法从未知协议状态继续。
    ///
    /// - Parameter bytes: 本次收到的字节。
    /// - Returns: 本次产生的响应字节数组。
    /// - Throws: 分帧或命令处理失败时抛出。
    public func receive(_ bytes: Data) async throws -> [Data] {
        var responses: [Data] = []
        var needsFrameDrain = try await receive(bytes) { response in
            responses.append(response)
        }
        while needsFrameDrain {
            needsFrameDrain = try await receive(Data()) { response in
                responses.append(response)
            }
        }
        return responses
    }

    /// 生产传输使用该形式，使应答可以逐个跨越其可写边界，
    /// 而无需在已解码帧批次之外再物化出第二个响应批次。
    ///
    /// - Parameters:
    ///   - bytes: 本次收到的字节。
    ///   - respond: 每条应答的回调，调用方自行控制写入节奏。
    /// - Returns: 是否需要继续排空帧。
    /// - Throws: 分帧或命令处理失败时抛出。
    public func receive(
        _ bytes: Data,
        respond: (Data) async throws -> Void
    ) async throws -> Bool {
        try await receiveFrames(bytes) { frame in
            try await respond(try V2FrameCodec.encode(frame, limits: frameLimits))
        }
    }

    /// 生产 NIO 传输使用已校验的帧形式，
    /// 从而可以把头部与 protobuf 载荷直接写入其出站 `ByteBuffer`。
    /// 与传输无关的调用方仍使用上方的 `Data` API。
    ///
    /// - Parameters:
    ///   - bytes: 本次收到的字节。
    ///   - respond: 每条已校验帧的回调。
    /// - Returns: 是否需要继续排空帧。
    /// - Throws: 分帧或命令处理失败时抛出。
    func receiveFrames(
        _ bytes: Data,
        authenticationCompleted: (@Sendable () async -> Void)? = nil,
        concurrentMessageSendRespond: (@Sendable (V2Frame) async throws -> Void)? = nil,
        respond: (V2Frame) async throws -> Void
    ) async throws -> Bool {
        do {
            guard !transportClosed else { throw V2ConnectionStateError.unexpectedCommand }
            let inbound = try decoder.append(bytes)
            for frame in inbound {
                guard !transportClosed else { throw V2ConnectionStateError.unexpectedCommand }
                if let concurrentMessageSendRespond,
                   frame.command == .messageSendOperation || frame.command == .messageSendOperationRecover {
                    guard registeredIdentity != nil,
                          await session.authenticatedIdentity() == registeredIdentity else {
                        throw V2GatewaySessionError.unsupportedCommand
                    }
                    try await session.validateMessageSendDispatch(frame)
                    guard messageSendTasks[frame.requestID] == nil else {
                        throw V2GatewaySessionError.unsupportedCommand
                    }
                    let bytes = frame.flags.contains(.compressed)
                        ? frameLimits.maximumMessageSendPayloadBytes : frame.payload.count
                    let hasConnectionCapacity = messageSendTasks.count < maximumConcurrentMessageSends &&
                        bytes <= maximumConcurrentMessageSendBytes - messageSendReservedBytes
                    var hasProcessCapacity = false
                    if hasConnectionCapacity { hasProcessCapacity = await messageSendBudget.reserve(bytes) }
                    if !hasProcessCapacity {
                        var busy = IMV2Envelope()
                        busy.requestID = frame.requestID
                        busy.protocolVersion = UInt32(frame.version)
                        busy.error.code = "SERVER_BUSY"
                        busy.error.retryable = true
                        busy.error.retryAfterSeconds = 1
                        try await respond(V2ServerProtobufFrameCodec.encode(busy, frameVersion: frame.version))
                        continue
                    }
                    guard !transportClosed, registeredIdentity != nil,
                          await session.authenticatedIdentity() == registeredIdentity else {
                        await messageSendBudget.release(bytes)
                        throw V2GatewaySessionError.unsupportedCommand
                    }
                    messageSendReservedBytes += bytes
                    messageSendTasks[frame.requestID] = Task { [self] in
                        do {
                            let exchange = try await session.receive(
                                frame, handler: handler, originatingConnectionID: connectionID)
                            guard canRespondToMessageSend() else { throw CancellationError() }
                            try V2FrameCodec.validateForEncoding(exchange.response, limits: frameLimits)
                            try await concurrentMessageSendRespond(exchange.response)
                        } catch {
                            closeAfterMessageSendFailure()
                        }
                        await finishMessageSend(requestID: frame.requestID, bytes: bytes, budget: messageSendBudget)
                    }
                    continue
                }
                // Capture before the handler suspends. A late page must not
                // become optional work for a replacement view of the same room.
                let authorView = authorPresentationIngress == nil ? nil : authorPresentationView
                let exchange = try await session.receive(
                    frame,
                    handler: handler,
                    originatingConnectionID: connectionID,
                    captureAuthorSample: authorView != nil
                )
                guard !transportClosed else { throw V2ConnectionStateError.unexpectedCommand }
                let newlyAuthenticated = try await registerAuthenticatedDeviceIfNeeded()
                if newlyAuthenticated {
                    decoder.setAllowsLargeMessageSendFrames(
                        await session.authenticatedMessageSendOperationsEnabled())
                    await authenticationCompleted?()
                }
                guard !transportClosed else { throw V2ConnectionStateError.unexpectedCommand }
                try await updateHybridGroupSubscription(
                    inbound: exchange.request,
                    response: exchange.responseEnvelope
                )
                await endAuthorPresentationSubscription(inbound: exchange.request, response: exchange.responseEnvelope)
                try V2FrameCodec.validateForEncoding(exchange.response, limits: frameLimits)
                try await respond(exchange.response)
                offerPageAuthors(exchange, capturedView: authorView)
                try await activateAuthorPresentationSubscription(inbound: exchange.request, response: exchange.responseEnvelope)
                if case .accountRoomChangesReady(let ready)? = exchange.responseEnvelope.body {
                    try await registry.accountRoomChangesReadyWritten(connectionID: connectionID, epoch: ready.connectionEpoch)
                }
                if let rejection = exchange.terminalAuthenticationError {
                    // 等待中的传输写入须在既有失败路径关闭通道前结束。
                    // 此处停止，防止合并的命令在登录失败后继续执行。
                    throw rejection
                }
            }
            // 一次完整的解码配额可能留下有效的完整帧。
            // NIO 所有者在消费后续 TCP 数据块前安排一次续处理，
            // 保持单连接的线路顺序。末尾的不完整帧至多造成一次空排空，
            // 并继续留在缓冲区，等待下一次实际传输读取。
            return inbound.count == frameLimits.maximumFramesPerAppend && decoder.hasBufferedBytes
        } catch {
            // 分帧失败可能在缓冲区留下无效前缀。会话关闭会阻止后续命令；
            // 重置解析器还可防止之后的接收再次抛出过期的分帧数据。
            decoder = .init(limits: frameLimits)
            beginClosing()
            await drainMessageSends()
            await session.close()
            await unregisterAuthenticatedDevice()
            throw error
        }
    }

    /// 必须在底层 TLS 通道到达 EOF 时调用。
    ///
    /// 末尾残留的不完整帧属于协议失败，而不是可忽略的断开。
    ///
    /// - Throws: 末尾存在不完整帧时抛出。
    public func finish() async throws {
        beginClosing()
        await drainMessageSends()
        do {
            try decoder.finish()
            await session.close()
            await unregisterAuthenticatedDevice()
        } catch {
            await session.close()
            await unregisterAuthenticatedDevice()
            throw error
        }
    }

    func finishSilently() async { try? await finish() }

    public func revokeDevice() async {
        if let revocationTask {
            await revocationTask.value
            return
        }
        let revocationHandler = deviceRevocationHandler
        beginClosing()
        let task = Task {
            await session.revokeDevice()
            await drainMessageSends()
            if let revocationHandler { await revocationHandler() }
            await unregisterAuthenticatedDevice()
        }
        revocationTask = task
        await task.value
    }

    public func setDeviceRevocationHandler(_ handler: @escaping @Sendable () async -> Void) {
        guard !transportClosed else { return }
        deviceRevocationHandler = handler
    }

    /// 实时可用性提示显式采用尽力而为语义。
    ///
    /// 当出站通道不可写时，NIO 所有者会丢弃该提示；恢复始终依赖 SYNC_PULL。
    ///
    /// - Parameter writer: 出站数据写入回调。
    public func setOutboundWriter(_ writer: @escaping @Sendable (Data) async -> Void) {
        guard !transportClosed else { return }
        outboundWriter = writer
    }

    /// 在单次 actor 轮次内安装两个通道回调。
    ///
    /// 若分两次 await 安装，EOF 可能在第二个回调装上之前就清空第一个回调，
    /// 从而使已关闭的 NIO 流水线被永久持有。
    ///
    /// - Parameters:
    ///   - deviceRevocationHandler: 设备吊销通知回调。
    ///   - outboundWriter: 出站数据写入回调。
    ///   - foregroundWriter: 可选的前台帧写入回调。
    /// - Returns: 是否成功安装。
    public func attachTransport(
        deviceRevocationHandler: @escaping @Sendable () async -> Void,
        outboundWriter: @escaping @Sendable (Data) async -> Void,
        requiredNotificationWriter: (@Sendable (Data) async -> Bool)? = nil,
        requiredNotificationClose: (@Sendable () async -> Void)? = nil,
        foregroundWriter: (@Sendable (Data) -> Void)? = nil,
        authorPresentationWriter: (@Sendable (V2AuthorPresentationWrite) async -> Bool)? = nil
    ) -> Bool {
        guard !transportClosed else { return false }
        self.deviceRevocationHandler = deviceRevocationHandler
        self.outboundWriter = outboundWriter
        self.requiredNotificationWriter = requiredNotificationWriter
        self.requiredNotificationClose = requiredNotificationClose ?? deviceRevocationHandler
        self.authorPresentationWriter = authorPresentationWriter
        let adaptedForegroundWriter: (@Sendable (ByteBuffer) -> Void)?
        if let foregroundWriter {
            adaptedForegroundWriter = { buffer in
                foregroundWriter(Data(buffer.readableBytesView))
            }
        } else {
            adaptedForegroundWriter = nil
        }
        foregroundTransport.attach(writer: adaptedForegroundWriter)
        return true
    }

    /// 生产 SwiftNIO 挂载。
    ///
    /// 面向传输无关兼容性的、由 actor 支撑的 `Data` 回调保持不变；
    /// 前台群组帧则一路保留其已准备的写时复制 `ByteBuffer` 直到写入通道。
    ///
    /// - Parameters:
    ///   - deviceRevocationHandler: 设备吊销通知回调。
    ///   - outboundWriter: 出站数据写入回调。
    ///   - foregroundWriter: 前台帧写者，未启用时为 `nil`。
    /// - Returns: 是否成功挂载。
    func attachNIOTransport(
        deviceRevocationHandler: @escaping @Sendable () async -> Void,
        outboundWriter: @escaping @Sendable (Data) async -> Void,
        requiredNotificationWriter: (@Sendable (Data) async -> Bool)? = nil,
        requiredNotificationClose: (@Sendable () async -> Void)? = nil,
        foregroundWriter: V2NIOGatewayForegroundWriter?,
        authorPresentationWriter: (@Sendable (V2AuthorPresentationWrite) async -> Bool)? = nil
    ) -> Bool {
        guard !transportClosed else { return false }
        self.deviceRevocationHandler = deviceRevocationHandler
        self.outboundWriter = outboundWriter
        self.requiredNotificationWriter = requiredNotificationWriter
        self.requiredNotificationClose = requiredNotificationClose ?? deviceRevocationHandler
        self.authorPresentationWriter = authorPresentationWriter
        foregroundTransport.attach(nioWriter: foregroundWriter)
        return true
    }

    /// 传输准入只借此取消其绝对的认证前截止时间。
    ///
    /// 身份数据仍留在会话 actor 内部。
    ///
    /// - Returns: 当前会话是否已完成认证。
    public func isAuthenticated() async -> Bool {
        await session.authenticatedIdentity() != nil
    }

    public func sendSyncAvailable(eventID: UInt64, highWatermark: UInt64) async {
        guard let version = await session.authenticatedProtocolVersion(), let outboundWriter else { return }
        var envelope = IMV2Envelope()
        envelope.requestID = 0
        envelope.protocolVersion = UInt32(version)
        envelope.syncAvailable = .init()
        envelope.syncAvailable.eventID = eventID
        envelope.syncAvailable.highWatermark = highWatermark
        guard let frame = try? V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version),
              let bytes = try? V2FrameCodec.encode(frame, limits: frameLimits)
        else { return }
        await outboundWriter(bytes)
    }

    /// 在同一条已认证 TLS 流上发送尽力而为的前台唤醒。
    ///
    /// 普通私聊事件可以附带可选的提交后载荷，
    /// 但游标拉取仍是持久恢复与缺口修复的路径。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间标识。
    ///   - highWatermark: 该房间当前的高水位。
    @discardableResult
    public func sendGroupEventAvailable(
        roomID: RoomID,
        highWatermark: UInt64,
        directEvent: V2DirectRoomLiveEvent? = nil
    ) async -> Bool {
        guard let version = await session.authenticatedProtocolVersion(), let outboundWriter else { return false }
        var envelope = IMV2Envelope()
        envelope.requestID = 0
        envelope.protocolVersion = UInt32(version)
        envelope.groupEventAvailable = .init()
        envelope.groupEventAvailable.roomID = roomID.rawValue
        envelope.groupEventAvailable.highWatermark = highWatermark
        if let directEvent,
           directEvent.roomID == roomID,
           directEvent.highWatermark == highWatermark {
            envelope.groupEventAvailable.sourceEventID = directEvent.sourceEventID.rawValue
            envelope.groupEventAvailable.roomSequence = directEvent.roomSequence
            envelope.groupEventAvailable.projectionKind = directEvent.projectionKind
            envelope.groupEventAvailable.eventPayload = directEvent.payload
        }
        guard let frame = try? V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version),
              let bytes = try? V2FrameCodec.encode(frame, limits: frameLimits)
        else { return false }
        await outboundWriter(bytes)
        return true
    }

    /// 发送一份为进程本地已授权受众编码一次的帧。
    ///
    /// 该流仍会用自身已认证的协商结果与当前传输回调为写入建立围栏；
    /// 过期或协议版本不同的流无法消费这份共享字节。
    ///
    /// - Parameter prepared: 已准备的群组事件帧。
    @discardableResult
    func sendGroupEventAvailable(_ prepared: V2PreparedGatewayGroupEventAvailable) async -> Bool {
        guard let contract = await session.authenticatedFrameContract(),
              contract.protocolVersion == prepared.protocolVersion,
              let outboundWriter
        else { return false }
        let buffer = prepared.bytes(for: contract.compression)
        await outboundWriter(Data(buffer.readableBytesView))
        return true
    }

    /// 生产前台通知使用该 nonisolated 快速路径。
    ///
    /// 返回 `false` 表示连接未认证、已分离、使用其他协议版本，或没有 NIO 快速写者；
    /// 这些情况下调用方保留由 actor 支撑的兼容路径。
    ///
    /// - Parameter prepared: 已准备的群组事件帧。
    /// - Returns: 是否已通过快速路径提交。
    nonisolated func submitGroupEventAvailable(
        _ prepared: V2PreparedGatewayGroupEventAvailable
    ) -> Bool {
        foregroundTransport.submit(prepared)
    }

    /// 生产群组发布会先收集这些受生命周期围栏保护的 NIO 提交，再逐个进入每个 EventLoop 通道一次。
    ///
    /// 其他传输返回 `nil`，并继续走不变的 `submitGroupEventAvailable` 路径。
    ///
    /// - Parameter prepared: 已准备的群组事件帧。
    /// - Returns: NIO 提交对象；不满足快速路径条件时为 `nil`。
    nonisolated func prepareNIOGroupEventAvailable(
        _ prepared: V2PreparedGatewayGroupEventAvailable
    ) -> V2NIOGatewayForegroundWriteSubmission? {
        foregroundTransport.prepareNIOSubmission(prepared)
    }

    public func sendPresenceState(_ state: V2PresenceState) async {
        guard let version = await session.authenticatedProtocolVersion(), let outboundWriter,
              let milliseconds = try? v2GatewayMilliseconds(state.expiresAt) else { return }
        var envelope = IMV2Envelope(); envelope.requestID = 0; envelope.protocolVersion = UInt32(version); envelope.presenceChanged = .init()
        envelope.presenceChanged.roomID = state.roomID.rawValue
        envelope.presenceChanged.targetUserID = state.targetUserID.rawValue
        envelope.presenceChanged.isOnline = state.isOnline
        envelope.presenceChanged.expiresAtMs = milliseconds
        guard let frame = try? V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version), let bytes = try? V2FrameCodec.encode(frame, limits: frameLimits) else { return }
        await outboundWriter(bytes)
    }

    public func sendTypingState(_ state: V2TypingState) async {
        guard let version = await session.authenticatedProtocolVersion(), let outboundWriter,
              let milliseconds = try? v2GatewayMilliseconds(state.expiresAt) else { return }
        var envelope = IMV2Envelope(); envelope.requestID = 0; envelope.protocolVersion = UInt32(version); envelope.typingStateChanged = .init()
        envelope.typingStateChanged.roomID = state.roomID.rawValue
        envelope.typingStateChanged.userID = state.userID.rawValue
        envelope.typingStateChanged.isTyping = state.isTyping
        envelope.typingStateChanged.expiresAtMs = milliseconds
        guard let frame = try? V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version), let bytes = try? V2FrameCodec.encode(frame, limits: frameLimits) else { return }
        await outboundWriter(bytes)
    }

    /// 成功只确认传输写入，不代表客户端已持久化。
    /// 返回 false 时，通知所有者必须停止排空。
    func sendAccountRoomNotification(_ notification: V2AccountRoomNotification) async -> Bool {
        guard let identity = registeredIdentity, let writer = requiredNotificationWriter,
              !transportClosed, let contract = await session.authenticatedFrameContract(),
              registeredIdentity == identity, !transportClosed else { return false }
        var envelope = notification.envelope()
        envelope.requestID = 0
        envelope.protocolVersion = UInt32(contract.protocolVersion)
        guard let frame = try? V2ServerProtobufFrameCodec.encode(envelope,
                frameVersion: contract.protocolVersion, compression: contract.compression),
              let bytes = try? V2FrameCodec.encode(frame, limits: frameLimits) else { return false }
        let written = await writer(bytes)
        return written && !transportClosed && registeredIdentity == identity
    }

    func supportsRequiredNotifications() -> Bool {
        !transportClosed && requiredNotificationWriter != nil
    }

    func closeForAccountRecovery() async {
        let close = requiredNotificationClose
        beginClosing()
        if let close { await close() }
        await drainMessageSends()
        await session.close()
        await unregisterAuthenticatedDevice()
    }

    private func beginClosing() {
        invalidateForegroundAuthorization()
        detachTransport()
        for task in messageSendTasks.values { task.cancel() }
    }

    private func canRespondToMessageSend() -> Bool {
        !transportClosed && registeredIdentity != nil && !Task.isCancelled
    }

    private func closeAfterMessageSendFailure() {
        guard !transportClosed else { return }
        let close = requiredNotificationClose
        beginClosing()
        if let close { Task { await close() } }
    }

    private func finishMessageSend(requestID: UInt64, bytes: Int, budget: V2GatewayMessageSendBudget) async {
        messageSendTasks.removeValue(forKey: requestID)
        messageSendReservedBytes -= bytes
        await budget.release(bytes)
    }

    private func drainMessageSends() async {
        let tasks = Array(messageSendTasks.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    private func detachTransport() {
        transportClosed = true
        deviceRevocationHandler = nil
        outboundWriter = nil
        requiredNotificationWriter = nil
        requiredNotificationClose = nil
        foregroundTransport.detach()
        authorPresentationTransport.deactivate()
        authorPresentationWriter = nil
    }

    private func registerAuthenticatedDeviceIfNeeded() async throws -> Bool {
        guard !transportClosed, registeredIdentity == nil,
              let identity = await session.authenticatedIdentity() else { return false }
        registeredIdentity = identity
        let accepted = try await registry.register(self, connectionID: connectionID, identity: identity,publicationSuppressed:await session.initialPresencePublicationSuppressed())
        guard accepted, registeredIdentity == identity, !transportClosed else {
            if registeredIdentity == identity { registeredIdentity = nil }
            foregroundTransport.deactivate()
            await registry.unregister(connectionID: connectionID)
            throw V2GatewaySessionError.authenticatedConnectionLimit
        }
        guard let contract = await session.authenticatedFrameContract(),
              let sessionIsLive = await session.authenticatedForegroundSessionCheck(),
              !transportClosed else {
            registeredIdentity = nil
            foregroundTransport.deactivate()
            await registry.unregister(connectionID: connectionID)
            throw V2GatewaySessionError.unsupportedCommand
        }
        if let streamID = await session.authenticatedAuthorPresentationStreamID() {
            guard let authorPresentationDispatcher, authorPresentationWriter != nil,
                  registeredIdentity == identity, !transportClosed else { throw V2GatewaySessionError.unsupportedCommand }
            let authorRegistered: Bool
            do {
                _ = try await authorPresentationDispatcher.register(connectionID: connectionID, identity: identity,
                    streamID: streamID, send: { [weak self] bytes, deadline in
                        await self?.sendAuthorPresentation(bytes, deadline: deadline) ?? false
                    })
                authorRegistered = true
            } catch V2ResourceProviderError.throttled {
                // Supplement capacity must never consume a healthy messaging
                // connection. This negotiated stream may deliver no deltas;
                // visible demand continues through normal batch HTTP.
                authorRegistered = false
            }
            guard registeredIdentity == identity, !transportClosed else {
                if authorRegistered { await authorPresentationDispatcher.unregister(connectionID: connectionID) }
                throw V2GatewaySessionError.unsupportedCommand
            }
            authorPresentationRegistered = authorRegistered
        }
        foregroundTransport.activate(
            protocolVersion: contract.protocolVersion,
            compression: contract.compression,
            sessionIsLive: sessionIsLive
        )
        return true
    }

    private func unregisterAuthenticatedDevice() async {
        if let unregisterTask {
            await unregisterTask.value
            return
        }
        guard registeredIdentity != nil else { return }
        registeredIdentity = nil
        foregroundTransport.deactivate()
        authorPresentationTransport.deactivate(); authorPresentationView = nil
        authorPresentationRegistered = false
        let dispatcher = authorPresentationDispatcher
        let registry = registry
        let connectionID = connectionID
        let task = Task {
            await dispatcher?.unregister(connectionID: connectionID)
            await registry.unregister(connectionID: connectionID)
        }
        unregisterTask = task
        await task.value
    }

    /// Start resource work only after the subscription response crosses the
    /// transport write boundary, so a delta cannot overtake its nonce echo.
    private func activateAuthorPresentationSubscription(inbound: IMV2Envelope, response: IMV2Envelope) async throws {
        guard case .groupEventSubscribe(let request) = inbound.body,
              case .groupEventSubscribed(let subscribed) = response.body else { return }
        guard !transportClosed, registeredIdentity != nil else { throw V2GatewaySessionError.unsupportedCommand }
        let roomID = try RoomID(request.roomID)
        guard !subscribed.authorPresentationViewID.isEmpty,
              let viewID = UUID(uuidString: subscribed.authorPresentationViewID), authorPresentationRegistered else {
            // A separate room's ordinary subscription does not end the selected
            // foreground author page. A same-room ordinary subscribe does.
            if authorPresentationView?.roomID == roomID { await clearAuthorPresentationView() }
            return
        }
        let activated = await authorPresentationDispatcher?.activateView(connectionID: connectionID, roomID: roomID, viewID: viewID) ?? false
        guard activated, registeredIdentity != nil, !transportClosed else { throw V2GatewaySessionError.unsupportedCommand }
        authorPresentationView = (roomID, viewID)
        authorPresentationTransport.activate(viewID: viewID, roomID: roomID)
    }

    /// Called only after the registry selected this recipient using the body
    /// event's membership fence and submitted its shared frame. Never await here.
    nonisolated func offerAuthorPresentation(_ hints: V2AuthorPresentationHints, to ingress: V2AuthorPresentationIngress) {
        guard let viewID = authorPresentationTransport.selectedView(in: hints.roomID) else { return }
        ingress.submit(connectionID: connectionID, roomID: hints.roomID, viewID: viewID, authors: hints.authors)
    }

    private func offerPageAuthors(_ exchange: V2GatewaySessionExchange,
                                 capturedView: (roomID: RoomID, viewID: UUID)?) {
        guard !Task.isCancelled, !transportClosed, authorPresentationRegistered,
              let ingress = authorPresentationIngress, let view = capturedView,
              authorPresentationTransport.selectedView(in: view.roomID) == view.viewID,
              case .groupEventPull(let pull) = exchange.request.body,
              (try? RoomID(pull.roomID)) == view.roomID,
              case .groupEventPage(let page) = exchange.responseEnvelope.body,
              (try? RoomID(page.roomID)) == view.roomID,
              let sample = exchange.authorSample, sample.roomID == view.roomID,
              let hints = V2AuthorPresentationHints(page: sample) else { return }
        ingress.submit(connectionID: connectionID, roomID: view.roomID,
                       viewID: view.viewID, authors: hints.authors)
    }

    private func clearAuthorPresentationView() async {
        let previous = authorPresentationView
        authorPresentationView = nil; authorPresentationTransport.deactivate()
        if let previous { await authorPresentationDispatcher?.deactivateView(connectionID: connectionID, viewID: previous.viewID) }
    }

    /// Invalidate the actual enqueue permit before writing the acknowledgement.
    /// The session already checked this connection's negotiated stream identity.
    private func endAuthorPresentationSubscription(inbound: IMV2Envelope, response: IMV2Envelope) async {
        guard case .authorPresentationEnd(let request) = inbound.body,
              case .authorPresentationEnded = response.body,
              let view = authorPresentationView,
              (try? RoomID(request.roomID)) == view.roomID,
              UUID(uuidString: request.viewID) == view.viewID else { return }
        await clearAuthorPresentationView()
    }

    /// Called by the bounded dispatcher, never by the message/ACK writer.
    private func sendAuthorPresentation(_ payload: Data, deadline: ContinuousClock.Instant) async -> Bool {
        guard !authorPresentationWriting, !Task.isCancelled, .now < deadline,
              let identity = registeredIdentity, let view = authorPresentationView,
              let writer = authorPresentationWriter, !transportClosed else { return false }
        authorPresentationWriting = true
        defer { authorPresentationWriting = false }
        do {
            guard let frame = try await session.authorPresentationFrame(payload),
                  let sessionIsLive = await session.authorPresentationSessionCheck(),
                  registeredIdentity == identity, authorPresentationView?.viewID == view.viewID,
                  !transportClosed, !Task.isCancelled else { return false }
            let bytes = try V2FrameCodec.encode(frame, limits: frameLimits)
            let delta = try V2AuthorPresentationDelta.decode(payload)
            guard delta.roomID == view.roomID, delta.viewID == view.viewID,
                  let write = authorPresentationTransport.prepare(bytes: bytes, viewID: view.viewID,
                    deadline: deadline, sessionIsLive: sessionIsLive) else { return false }
            return await withTaskCancellationHandler(operation: { await writer(write) }, onCancel: { write.cancel() })
        } catch { return false }
    }

    private func updateHybridGroupSubscription(inbound: IMV2Envelope, response: IMV2Envelope) async throws {
        switch inbound.body {
        case .snapshotPagePull:
            guard case .snapshotPage(let page)? = response.body else { return }
            try await registry.refreshAccountRoomSnapshotMemberships(connectionID: connectionID, page: page)
        case .syncPull:
            guard case .syncBatch(let batch)? = response.body else { return }
            try await registry.refreshAccountRoomMemberships(connectionID: connectionID, batch: batch)
        case .userRoomDirectoryList:
            guard case .userRoomDirectoryPage(let page)? = response.body else { return }
            try await registry.installAccountRoomDirectory(connectionID: connectionID, page: page)
        case .groupEventSubscribe(let request):
            guard case .groupEventSubscribed(let subscribed)? = response.body,
                  let roomID = try? RoomID(request.roomID),
                  let subscribedRoomID = try? RoomID(subscribed.roomID),
                  subscribedRoomID == roomID
            else { return }
            await registry.subscribeForegroundGroup(
                self,
                connectionID: connectionID,
                roomID: roomID,
                membershipRevision: subscribed.membershipRevision
            )
        case .groupEventUnsubscribe(let request):
            guard case .acknowledged? = response.body else { return }
            await registry.unsubscribeForegroundGroup(connectionID: connectionID, roomID: try .init(request.roomID))
            if authorPresentationView?.roomID == (try? RoomID(request.roomID)) { await clearAuthorPresentationView() }
        case .subscribePresence(let request):
            guard case .presenceSubscribed(let subscribed)? = response.body,
                  let roomID = try? RoomID(request.roomID),
                  let subscribedRoomID = try? RoomID(subscribed.roomID),
                  subscribedRoomID == roomID,
                  let targetUserID = try? UserID(subscribed.targetUserID)
            else { return }
            await registry.subscribePresence(self, connectionID: connectionID, roomID: roomID, targetUserID: targetUserID)
        case .unsubscribePresence(let request):
            guard case .acknowledged? = response.body else { return }
            await registry.unsubscribePresence(connectionID: connectionID, roomID: try .init(request.roomID))
        case .subscribeTyping(let request):
            guard case .acknowledged? = response.body else { return }
            await registry.subscribeTyping(self, connectionID: connectionID, roomID: try .init(request.roomID))
        case .unsubscribeTyping(let request):
            guard case .acknowledged? = response.body else { return }
            await registry.unsubscribeTyping(connectionID: connectionID, roomID: try .init(request.roomID))
        case .setTypingState(let request):
            guard case .acknowledged? = response.body,
                  let identity = registeredIdentity
            else { return }
            await registry.notifyTyping(roomID: try .init(request.roomID), actorUserID: identity.userID, isTyping: request.isTyping, expiresAt: request.isTyping ? Date().addingTimeInterval(6) : Date())
        case .heartbeat:
            guard await registry.refreshLivePresence(connectionID: connectionID)
            else { throw V2GatewaySessionError.authenticatedConnectionLimit }
        default:
            return
        }
    }
}
