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
private final class V2GatewayForegroundTransport: Sendable {
    private enum Writer: Sendable {
        case callback(@Sendable (ByteBuffer) -> Void)
        case nio(V2NIOGatewayForegroundWriter)
    }

    private struct State: Sendable {
        var protocolVersion: UInt8?
        var compression: V2NegotiatedFrameCompression?
        var writer: Writer?
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
        compression: V2NegotiatedFrameCompression?
    ) {
        state.withLock {
            $0.protocolVersion = protocolVersion
            $0.compression = compression
        }
    }

    func deactivate() {
        state.withLock {
            $0.protocolVersion = nil
            $0.compression = nil
        }
    }

    func detach() {
        state.withLock {
            $0.protocolVersion = nil
            $0.compression = nil
            $0.writer = nil
        }
    }

    func submit(_ prepared: V2PreparedGatewayGroupEventAvailable) -> Bool {
        let submission = state.withLock { state -> (
            writer: Writer,
            bytes: ByteBuffer
        )? in
            guard state.protocolVersion == prepared.protocolVersion else { return nil }
            guard let writer = state.writer else { return nil }
            return (writer, prepared.bytes(for: state.compression))
        }
        guard let submission else { return false }
        switch submission.writer {
        case .callback(let writer):
            writer(submission.bytes)
        case .nio(let writer):
            writer.submit(submission.bytes)
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
                  case .nio(let writer)? = state.writer
            else { return nil }
            return .init(
                writer: writer,
                bytes: prepared.bytes(for: state.compression)
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
    // A revocation worker must not advance its durable cursor until the
    // transport confirms the local channel has closed. The handler therefore
    // bridges the NIO close future into this actor rather than merely
    // scheduling a best-effort close.
    private var deviceRevocationHandler: (@Sendable () async -> Void)?
    private var outboundWriter: (@Sendable (Data) async -> Void)?
    private var requiredNotificationWriter: (@Sendable (Data) async -> Bool)?
    private var requiredNotificationClose: (@Sendable () async -> Void)?
    /// 一旦所属传输关闭，迟到的回调安装就不得重新形成
    /// 流 -> 回调 -> channel handler -> 流的循环强引用。
    ///
    /// 它同时为 handlerAdded/channelInactive 之间的竞态建立围栏。
    private var transportClosed = false

    public init(
        frameLimits: V2FrameLimits,
        session: V2GatewaySession,
        handler: any V2GatewayCommandHandler,
        connectionID: UUID = V2GatewayByteStream.makeConnectionID(),
        registry: V2DeviceConnectionRegistry
    ) {
        self.decoder = .init(limits: frameLimits)
        self.frameLimits = frameLimits
        self.session = session
        self.handler = handler
        self.connectionID = connectionID
        self.registry = registry
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
        respond: (V2Frame) async throws -> Void
    ) async throws -> Bool {
        do {
            let inbound = try decoder.append(bytes)
            for frame in inbound {
                let exchange = try await session.receive(
                    frame,
                    handler: handler,
                    originatingConnectionID: connectionID
                )
                try await registerAuthenticatedDeviceIfNeeded()
                try await updateHybridGroupSubscription(
                    inbound: exchange.request,
                    response: exchange.responseEnvelope
                )
                try V2FrameCodec.validateForEncoding(exchange.response, limits: frameLimits)
                try await respond(exchange.response)
                if case .accountRoomChangesReady(let ready)? = exchange.responseEnvelope.body {
                    try await registry.accountRoomChangesReadyWritten(connectionID: connectionID, epoch: ready.connectionEpoch)
                }
                if let rejection = exchange.terminalAuthenticationError {
                    // The awaited transport write must finish before the
                    // existing failure path closes the channel. Stop here so
                    // coalesced commands cannot run after a failed login.
                    throw rejection
                }
            }
            // A full decode quantum can leave a valid complete frame behind.
            // The NIO owner schedules one continuation before it consumes a
            // later TCP chunk, retaining per-connection wire order. A trailing
            // partial frame costs at most one empty drain and remains buffered
            // for the next actual transport read.
            return inbound.count == frameLimits.maximumFramesPerAppend && decoder.hasBufferedBytes
        } catch {
            // A framing failure may leave an invalid prefix buffered. Session
            // closure fences further commands, but resetting the parser also
            // prevents a later receive from rethrowing stale framing data.
            decoder = .init(limits: frameLimits)
            await unregisterAuthenticatedDevice()
            await session.close()
            throw error
        }
    }

    /// 必须在底层 TLS 通道到达 EOF 时调用。
    ///
    /// 末尾残留的不完整帧属于协议失败，而不是可忽略的断开。
    ///
    /// - Throws: 末尾存在不完整帧时抛出。
    public func finish() async throws {
        detachTransport()
        do {
            try decoder.finish()
            await unregisterAuthenticatedDevice()
            await session.close()
        } catch {
            await unregisterAuthenticatedDevice()
            await session.close()
            throw error
        }
    }

    public func revokeDevice() async {
        await unregisterAuthenticatedDevice()
        await session.revokeDevice()
        if let deviceRevocationHandler {
            await deviceRevocationHandler()
        }
        detachTransport()
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
        foregroundWriter: (@Sendable (Data) -> Void)? = nil
    ) -> Bool {
        guard !transportClosed else { return false }
        self.deviceRevocationHandler = deviceRevocationHandler
        self.outboundWriter = outboundWriter
        self.requiredNotificationWriter = requiredNotificationWriter
        self.requiredNotificationClose = requiredNotificationClose ?? deviceRevocationHandler
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
        foregroundWriter: V2NIOGatewayForegroundWriter?
    ) -> Bool {
        guard !transportClosed else { return false }
        self.deviceRevocationHandler = deviceRevocationHandler
        self.outboundWriter = outboundWriter
        self.requiredNotificationWriter = requiredNotificationWriter
        self.requiredNotificationClose = requiredNotificationClose ?? deviceRevocationHandler
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
    public func sendGroupEventAvailable(
        roomID: RoomID,
        highWatermark: UInt64,
        directEvent: V2DirectRoomLiveEvent? = nil
    ) async {
        guard let version = await session.authenticatedProtocolVersion(), let outboundWriter else { return }
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
        else { return }
        await outboundWriter(bytes)
    }

    /// 发送一份为进程本地已授权受众编码一次的帧。
    ///
    /// 该流仍会用自身已认证的协商结果与当前传输回调为写入建立围栏；
    /// 过期或协议版本不同的流无法消费这份共享字节。
    ///
    /// - Parameter prepared: 已准备的群组事件帧。
    func sendGroupEventAvailable(_ prepared: V2PreparedGatewayGroupEventAvailable) async {
        guard let contract = await session.authenticatedFrameContract(),
              contract.protocolVersion == prepared.protocolVersion,
              let outboundWriter
        else { return }
        let buffer = prepared.bytes(for: contract.compression)
        await outboundWriter(Data(buffer.readableBytesView))
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

    /// Success acknowledges the transport write, not client persistence.
    /// A false result requires the notification owner to stop draining.
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
        if let requiredNotificationClose { await requiredNotificationClose() }
        await unregisterAuthenticatedDevice()
        await session.close()
        detachTransport()
    }

    private func detachTransport() {
        transportClosed = true
        deviceRevocationHandler = nil
        outboundWriter = nil
        requiredNotificationWriter = nil
        requiredNotificationClose = nil
        foregroundTransport.detach()
    }

    private func registerAuthenticatedDeviceIfNeeded() async throws {
        guard registeredIdentity == nil, let identity = await session.authenticatedIdentity() else { return }
        registeredIdentity = identity
        let accepted = try await registry.register(self, connectionID: connectionID, identity: identity)
        guard accepted, registeredIdentity == identity, !transportClosed else {
            if registeredIdentity == identity { registeredIdentity = nil }
            foregroundTransport.deactivate()
            await registry.unregister(connectionID: connectionID)
            throw V2GatewaySessionError.authenticatedConnectionLimit
        }
        guard let contract = await session.authenticatedFrameContract() else {
            registeredIdentity = nil
            foregroundTransport.deactivate()
            await registry.unregister(connectionID: connectionID)
            throw V2GatewaySessionError.unsupportedCommand
        }
        foregroundTransport.activate(
            protocolVersion: contract.protocolVersion,
            compression: contract.compression
        )
    }

    private func unregisterAuthenticatedDevice() async {
        guard registeredIdentity != nil else { return }
        registeredIdentity = nil
        foregroundTransport.deactivate()
        await registry.unregister(connectionID: connectionID)
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
        case .setLiveActivityPreferences:
            guard case .liveActivityPreferencesSet(let updated)? = response.body
            else { return }
            guard await registry.applyLiveActivityPreferences(
                connectionID: connectionID,
                allowsOnlinePresence: updated.allowsOnlinePresence
            ) else { throw V2GatewaySessionError.authenticatedConnectionLimit }
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
