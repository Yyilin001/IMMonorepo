import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Compression
import IMV2Core
import NIOCore
import Synchronization
import IMV2ActorContracts

/// 一份不可变的服务端推送帧，由协商到相同协议版本的每个已授权本地接收者共享。
///
/// 这些字节不携带任何连接特定状态：
/// 受众选择与传输生命周期校验都留在这个值之外。
struct V2PreparedGatewayGroupEventAvailable: Sendable {
    let highWatermark: UInt64
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
        self.highWatermark = envelope.groupEventAvailable.highWatermark
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
        self.highWatermark = envelope.groupEventAvailable.highWatermark
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
    private struct State: Sendable {
        var protocolVersion: UInt8?
        var compression: V2NegotiatedFrameCompression?
        var writer: V2NIOGatewayForegroundWriter?
        var authorization: V2GatewayForegroundAuthorization?
    }

    private let state = Mutex(State())

    func attach(nioWriter: V2NIOGatewayForegroundWriter?) {
        state.withLock { $0.writer = nioWriter }
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

    func submit(_ prepared: V2PreparedGatewayGroupEventAvailable,
                enqueueIfCurrent: (@Sendable (@Sendable () -> Void) -> Bool)? = nil) -> Bool {
        let submission = state.withLock { state -> (
            writer: V2NIOGatewayForegroundWriter,
            bytes: ByteBuffer,
            authorization: V2GatewayForegroundAuthorization
        )? in
            guard state.protocolVersion == prepared.protocolVersion else { return nil }
            guard let writer = state.writer, let authorization = state.authorization else { return nil }
            return (writer, prepared.bytes(for: state.compression), authorization)
        }
        guard let submission, submission.authorization.isAuthorizedToWrite() else { return false }
        let authorization = submission.authorization
        submission.writer.submit(submission.bytes,
            isAuthorizedToWrite: { authorization.isAuthorizedToWrite() },
            enqueueIfCurrent: enqueueIfCurrent)
        return true
    }

    func submitRoomHead(_ permit: V2GatewayRoomSubscriptionAuthority.Permit, highWatermark: UInt64) -> Bool {
        state.withLock { $0.writer }?.submitRoomHead(permit, highWatermark: highWatermark) ?? false
    }
    func activateRoomHead(_ permit: V2GatewayRoomSubscriptionAuthority.Permit,
                          enqueueIfCurrent: @escaping @Sendable (@Sendable () -> Void) -> Bool,
                          encode: @escaping @Sendable (UInt64) -> ByteBuffer?) -> Bool {
        guard let writer = state.withLock({ $0.writer }) else { return false }
        writer.activateRoomHead(permit, enqueueIfCurrent: enqueueIfCurrent, encode: encode)
        return true
    }

    /// 捕获与 `submit` 相同的认证与生命周期栅栏，
    /// 但把通道调度留给群组发布方，使大量本地接收者可以作为单个 EventLoop 批次被接纳。
    ///
    /// - Parameter prepared: 已准备的群组事件帧。
    /// - Returns: 可供批量提交的 NIO 提交对象；不满足快速路径条件时为 `nil`。
    func prepareNIOSubmission(
        _ prepared: V2PreparedGatewayGroupEventAvailable,
        enqueueIfCurrent: (@Sendable (@Sendable () -> Void) -> Bool)? = nil
    ) -> V2NIOGatewayForegroundWriteSubmission? {
        state.withLock { state in
            guard state.protocolVersion == prepared.protocolVersion,
                  let writer = state.writer,
                  let authorization = state.authorization,
                  authorization.isAuthorizedToWrite()
            else { return nil }
            return .init(
                writer: writer,
                bytes: prepared.bytes(for: state.compression),
                isAuthorizedToWrite: { authorization.isAuthorizedToWrite() }, enqueueIfCurrent: enqueueIfCurrent
            )
        }
    }
}

private final class V2GatewayNotificationDispatchResult: Sendable {
    private struct State: Sendable {
        var dispatched = false
        var scopeRejected = false
    }
    private let value = Mutex(State())
    func mark() { value.withLock { $0.dispatched = true } }
    func rejectScope() { value.withLock { $0.scopeRejected = true } }
    var wasDispatched: Bool { value.withLock { $0.dispatched } }
    var scopeWasRejected: Bool { value.withLock { $0.scopeRejected } }
}

/// A recovery notification with an atomic write-time lifecycle permit.
/// The socket owner invokes enqueueIfCurrent synchronously at actual enqueue.
public struct V2GatewayScopedNotificationWrite: Sendable {
    public let bytes: Data
    private let permit: @Sendable (@Sendable () -> Void) -> Bool
    init(bytes: Data, permit: @escaping @Sendable (@Sendable () -> Void) -> Bool) {
        self.bytes = bytes
        let consumed = Mutex(false)
        self.permit = { enqueue in
            consumed.withLock { used in
                guard !used else { return false }
                let accepted = permit(enqueue)
                if accepted { used = true }
                return accepted
            }
        }
    }
    public func enqueueIfCurrent(_ enqueue: @Sendable () -> Void) -> Bool { permit(enqueue) }
}

private enum V2RecoveryNotificationWorkerContext {
    @TaskLocal static var connectionID: UUID?
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
    let frameLimits: V2FrameLimits
    private let session: V2GatewaySession
    private let handler: any V2GatewayCommandHandler
    private let connectionID: UUID
    nonisolated let heartbeatDiagnosticsSelected: Bool
    private let registry: V2DeviceConnectionRegistry
    private nonisolated let foregroundTransport = V2GatewayForegroundTransport()
    private var authenticatedResponseWritten = false
    private var notificationsReady = false
    private var coverageRevision: UInt64 = 0
    private var coverageGenerations: [Int: UInt64] = [:]
    private var activeCoverageScopes: [Int: String] = [:]
    private var diagnosticPeerPort: Int?
    private var diagnosticAccountWaitingSince: ContinuousClock.Instant?
    private var diagnosticAccountAdmittedState: String?
    private var diagnosticAccountScopeRejectedRevision: UInt64?

    private struct PendingCoverageTransition {
        var state: IMV2RealtimeCoverage
        let confirms: (@Sendable () -> Bool)?
        let scopePermit: (@Sendable (@Sendable () -> Void) -> Bool)?
        let onReadyAdmitted: (@Sendable () async -> Void)?
    }
    private struct CoverageWriteFence: Sendable {
        let generation: UInt64
        let revision: UInt64
    }
    // At most a Recovering predecessor and its Ready successor per scope.
    private var pendingCoverage: [Int: [PendingCoverageTransition]] = [:]
    private var coverageWritesInFlight: Set<Int> = []
    private nonisolated let coverageWriteFences = Mutex<[Int: CoverageWriteFence]>([:])
    private var recoveryNotificationRetry: Task<Void, Never>?
    private struct RoomSubscriptionState {
        let authorization: V2GatewayRoomSubscriptionAuthority.Permit
        var highWatermark: UInt64
        var submittedHighWatermark: UInt64?
        var permit: @Sendable (@Sendable () -> Void) -> Bool
    }
    private var roomSubscriptionState: RoomSubscriptionState?
    private var roomSubscriptionReportedProgress: (authorization: V2GatewayRoomSubscriptionAuthority.Permit, applied: UInt64)?
    private var roomSubscriptionReady: V2GatewayRoomSubscriptionAuthority.Permit?
    private var roomSubscriptionRecovering: V2GatewayRoomSubscriptionAuthority.Permit?
    private var roomSubscriptionWakePending = false
    private var roomSubscriptionWriter: Task<Void, Never>?
    package var roomSubscriptionWriterCount: Int { roomSubscriptionWriter == nil ? 0 : 1 }
    private nonisolated let roomSubscriptionConnectionRevocation = Mutex<V2CallbackBox<@Sendable () -> Void>?>(nil)
    private let recoveryOutbound = V2GatewayRecoveryOutbound()

    private var suppressesInitialPresencePublication = false
    private struct PendingSyncRecovery: Sendable {
        let eventID: UInt64
        let highWatermark: UInt64
        let required: Bool
        let permit: @Sendable (@Sendable () -> Void) -> Bool
    }
    private nonisolated let pendingSyncRecovery = Mutex<PendingSyncRecovery?>(nil)
    private var registeredIdentity: V2AuthenticatedConnection?
    private var unregisterTask: Task<Void, Never>?
    private var revocationTask: Task<Void, Never>?
    private let authorPresentationDispatcher: V2AuthorPresentationDispatcher?
    private let authorPresentationIngress: V2AuthorPresentationIngress?
    private let authorPresentationTransport = V2AuthorPresentationTransport()
    private var authorPresentationWriter: (@Sendable (V2AuthorPresentationWrite) async -> V2AuthorPresentationWriteResult)?
    private var authorPresentationView: (messageRoomIDs: Set<RoomID>, viewID: UUID)?
    private var authorPresentationRegistered = false
    private var authorPresentationWriting = false
    // 传输确认本地通道关闭前，撤销工作器不能推进持久化游标。
    // 因此处理器将 NIO 关闭 future 桥接进此 Actor，
    // 而不只是安排一次尽力而为的关闭。
    private var deviceRevocationHandler: (@Sendable () async -> Void)?
    private nonisolated let liveStatePrimaryAuthentication = Mutex<V2CallbackBox<@Sendable (@Sendable () -> Void) -> Bool>?>(nil)
    private var outboundWriter: (@Sendable (Data) async -> Void)?
    private var scopedNotificationWriter: (@Sendable (V2GatewayScopedNotificationWrite) async -> Bool)?
    private var requiredNotificationWriter: (@Sendable (Data) async -> Bool)?
    private var requiredNotificationClose: (@Sendable () async -> Void)?
    /// 一旦所属传输关闭，迟到的回调安装就不得重新形成
    /// 流 -> 回调 -> channel handler -> 流的循环强引用。
    ///
    /// 它同时为 handlerAdded/channelInactive 之间的竞态建立围栏。
    var roomSubscriptionSocketGate: V2RoomSubscriptionSocketGate?
    private var transportClosed = false
    private let messageSendBudget: V2GatewayMessageSendBudget
    private let maximumConcurrentMessageSends: Int
    private let maximumConcurrentMessageSendBytes: Int
    // 业务执行名额在响应发布前归还；任务句柄和字节预算保留到实际写出结束。
    private var messageSendExecutingRequests = 0
    private var messageSendTasks: [UInt64: Task<Void, Never>] = [:]
    private var messageSendReservedBytes = 0

    /// Physical connection revocation is independent of the persisted online projection.
    nonisolated func connectionAllowsDispatch() -> Bool { session.connectionIsActive }

    private nonisolated func connectionFencedNotification(bytes: Data,
        permit: @escaping @Sendable (@Sendable () -> Void) -> Bool) -> V2GatewayScopedNotificationWrite {
        .init(bytes: bytes, permit: { enqueue in
            self.recoveryOutbound.enqueueIfActive {
                guard self.connectionAllowsDispatch() else { return false }
                return permit(enqueue)
            }
        })
    }

    /// Registry/device shutdown can invalidate every selected connection before
    /// awaiting any actor or database cleanup.
    nonisolated func configureRoomSubscriptionConnectionRevocation(_ revoke: @escaping @Sendable () -> Void) {
        roomSubscriptionConnectionRevocation.withLock { $0 = V2CallbackBox(revoke) }
    }
    private nonisolated func revokeRoomSubscriptionConnection() {
        roomSubscriptionConnectionRevocation.withLock { $0?.callback }?()
    }

    nonisolated func invalidateForegroundAuthorization() {
        revokeRoomSubscriptionConnection()
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
        self.heartbeatDiagnosticsSelected = V2GatewayHeartbeatDiagnostics.enabled
            && V2GatewayHeartbeatDiagnostics.selects(connectionID)
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
        let inbound: [V2Frame]
        do {
            guard !transportClosed else { throw V2ConnectionStateError.unexpectedCommand }
            inbound = try decoder.append(bytes)
        }
        catch { await failReceivingFrames(); throw error }
        try await receiveDecodedFrames(inbound,
            authenticationCompleted: { _ in await authenticationCompleted?() },
            concurrentMessageSendRespond: concurrentMessageSendRespond, respond: respond)
        return inbound.count == frameLimits.maximumFramesPerAppend && decoder.hasBufferedBytes
    }

    /// NIO owns wire framing on its EventLoop; only complete frames cross into
    /// the business actor. Data-based callers retain their decoder above.
    func receiveDecodedFrames(
        _ inbound: [V2Frame],
        authenticationCompleted: (@Sendable (Bool) async -> Void)? = nil,
        concurrentMessageSendRespond: (@Sendable (V2Frame) async throws -> Void)? = nil,
        respond: (V2Frame) async throws -> Void
    ) async throws {
        let bufferedConcurrentRespond: (@Sendable (V2GatewayOutboundFrame) async throws -> Void)?
        if let callback = concurrentMessageSendRespond {
            bufferedConcurrentRespond = { frame in try await callback(frame.dataFrame) }
        } else {
            bufferedConcurrentRespond = nil
        }
        try await receiveInboundFrames(inbound.map(V2GatewayInboundFrame.init),
            authenticationCompleted: authenticationCompleted,
            concurrentMessageSendRespond: bufferedConcurrentRespond,
            respond: { frame in try await respond(frame.dataFrame) })
    }

    func receiveInboundFrames(
        _ inbound: [V2GatewayInboundFrame],
        authenticationCompleted: (@Sendable (Bool) async -> Void)? = nil,
        concurrentMessageSendRespond: (@Sendable (V2GatewayOutboundFrame) async throws -> Void)? = nil,
        respond: (V2GatewayOutboundFrame) async throws -> Void
    ) async throws {
        do {
            guard !transportClosed else { throw V2ConnectionStateError.unexpectedCommand }
            for frame in inbound {
                let heartbeatProbe = frame.heartbeatProbe
                heartbeatProbe?.mark(.streamEntered)

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
                        ? frameLimits.maximumMessageSendPayloadBytes : frame.payloadCount
                    var hasProcessCapacity = false
                    if messageSendExecutingRequests >= maximumConcurrentMessageSends
                        || messageSendTasks.count >= maximumConcurrentMessageSends * 2 {
                        messageSendBudget.recordRejection(.connectionCount)
                    } else if bytes > maximumConcurrentMessageSendBytes - messageSendReservedBytes {
                        messageSendBudget.recordRejection(.connectionBytes)
                    } else {
                        hasProcessCapacity = messageSendBudget.reserve(bytes)
                    }
                    if !hasProcessCapacity {
                        var busy = IMV2Envelope()
                        busy.requestID = frame.requestID
                        busy.protocolVersion = UInt32(frame.version)
                        busy.error.code = "SERVER_BUSY"
                        busy.error.retryable = true
                        busy.error.retryAfterSeconds = 1
                        try await respond(V2ServerProtobufFrameCodec.encodeBuffered(busy, frameVersion: frame.version))
                        continue
                    }
                    guard !transportClosed, registeredIdentity != nil,
                          await session.authenticatedIdentity() == registeredIdentity else {
                        messageSendBudget.release(bytes)
                        throw V2GatewaySessionError.unsupportedCommand
                    }
                    messageSendReservedBytes += bytes
                    messageSendExecutingRequests += 1
                    let sendTrace = V2SendPathTrace.enabled && frame.command == .messageSendOperation
                        ? V2SendPathTrace(operations: [], segment: "gateway") : nil
                    messageSendTasks[frame.requestID] = Task { [self] in
                        await V2SendPathTrace.$current.withValue(sendTrace) {
                        defer { sendTrace?.finish() }
                        var hasExecutionSlot = true
                        do {
                            let startedAt = ContinuousClock.now
                            let exchange = try await session.receive(
                                frame, handler: handler, originatingConnectionID: connectionID)
                            sendTrace?.record("gateway_to_result_ready", from: startedAt)
                            guard canRespondToMessageSend() else { throw CancellationError() }
                            let writeStartedAt = ContinuousClock.now
                            try exchange.wireResponse.validate(limits: frameLimits)
                            // 先释放业务名额，再让 ACK 对客户端可见。慢写仍受总任务和字节预算约束。
                            messageSendExecutingRequests -= 1
                            hasExecutionSlot = false
                            try await concurrentMessageSendRespond(exchange.wireResponse)
                            sendTrace?.record("result_ready_to_ack_write", from: writeStartedAt)
                        } catch {
                            closeAfterMessageSendFailure()
                        }
                        finishMessageSend(requestID: frame.requestID, bytes: bytes,
                            hasExecutionSlot: hasExecutionSlot, budget: messageSendBudget)
                        }
                    }
                    continue
                }
                // Capture before the handler suspends. A late page must not
                // become optional work for a replacement view of the same room.
                let authorView = authorPresentationIngress == nil ? nil : authorPresentationView

                let diagnosticRequestID = frame.requestID
                heartbeatProbe?.mark(.sessionSubmitted)
                let exchange = try await session.receive(
                    frame,
                    handler: handler,
                    originatingConnectionID: connectionID,
                    captureAuthorSample: authorView != nil,
                    roomProgress: { [weak self] heartbeat in
                        heartbeatProbe?.mark(.progressEntered)
                        defer { heartbeatProbe?.mark(.progressCompleted) }
                        let progress = await self?.exchangeRoomProgress(heartbeat, diagnosticRequestID: diagnosticRequestID) ?? []
                        if V2GatewayCoverageDiagnostics.enabled {
                            await self?.recordAccountCoverageDiagnostic(heartbeat, requestID: diagnosticRequestID)
                        }
                        return progress
                    }
                )
                heartbeatProbe?.mark(.sessionReturned)
                guard !transportClosed else { throw V2ConnectionStateError.unexpectedCommand }
                let newlyAuthenticated = try await registerAuthenticatedDeviceIfNeeded()
                if newlyAuthenticated {
                    let allowsLargeFrames = await session.authenticatedMessageSendOperationsEnabled()
                    decoder.setAllowsLargeMessageSendFrames(allowsLargeFrames)
                    await authenticationCompleted?(allowsLargeFrames)
                }
                guard !transportClosed else { throw V2ConnectionStateError.unexpectedCommand }
                if let heartbeatProbe {
                    try await V2GatewayHeartbeatDiagnostics.$current.withValue(heartbeatProbe) {
                        try await updateAcknowledgedConnectionControls(
                            inbound: exchange.request, response: exchange.responseEnvelope)
                    }
                } else {
                    try await updateAcknowledgedConnectionControls(
                        inbound: exchange.request,
                        response: exchange.responseEnvelope
                    )
                }
                await endAuthorPresentationSubscription(inbound: exchange.request, response: exchange.responseEnvelope)
                if case .authorPresentationInterests(let interests) = exchange.request.body,
                   case .authorPresentationInterestsReceived = exchange.responseEnvelope.body {
                    await authorPresentationDispatcher?.replaceVisibleInterests(connectionID: connectionID, interests: try interests.domain())
                }
                if case .authorPresentationReceipt(let receipt) = exchange.request.body,
                   case .authorPresentationReceipted = exchange.responseEnvelope.body {
                    await authorPresentationDispatcher?.acknowledge(connectionID: connectionID, receipt: try receipt.domain())
                }
                try exchange.wireResponse.validate(limits: frameLimits)
                var wireResponse = exchange.wireResponse
                wireResponse.heartbeatProbe = heartbeatProbe
                try await respond(wireResponse)
                if newlyAuthenticated, !transportClosed, registeredIdentity != nil {
                    authenticatedResponseWritten = true
                    await registry.authenticationResponseWritten(connectionID: connectionID)

                    // Native clients explicitly suppress initial presence and
                    // finish bootstrap with publication-control request 3.
                    // Keep unsolicited sync behind that response as well.
                    if !suppressesInitialPresencePublication { await makeNotificationsReady() }
                    try await registry.installAuthenticatedAccountCoverage(connectionID: connectionID)
                } else if authenticatedResponseWritten {
                    await makeNotificationsReady()
                }
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
        } catch {
            await failReceivingFrames()
            throw error
        }
    }

    private func failReceivingFrames() async {
        decoder = .init(limits: frameLimits)
        beginClosing()
        await drainMessageSends()
        await session.close()
        await unregisterAuthenticatedDevice()
        await drainRecoveryOutboundWork()
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
            await drainRecoveryOutboundWork()
        } catch {
            await session.close()
            await unregisterAuthenticatedDevice()
            await drainRecoveryOutboundWork()
            throw error
        }
    }

    func finishSilently() async { try? await finish() }

    public func revokeDevice() async {
        await closeTransportForDeviceRevocation()
        await unregisterAuthenticatedDevice()
        await drainRecoveryOutboundWork()
    }

    /// Registry closes every selected transport before joining resource cleanup.
    func closeTransportForDeviceRevocation() async {
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

    /// 生产 SwiftNIO 挂载。
    ///
    /// 普通响应和恢复通知使用有生命周期围栏的回调；前台群组帧
    /// 保留其已准备的写时复制 `ByteBuffer` 直到写入通道。
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
        scopedNotificationWriter: (@Sendable (V2GatewayScopedNotificationWrite) async -> Bool)? = nil,
        requiredNotificationClose: (@Sendable () async -> Void)? = nil,
        foregroundWriter: V2NIOGatewayForegroundWriter? = nil,
        authorPresentationWriter: (@Sendable (V2AuthorPresentationWrite) async -> V2AuthorPresentationWriteResult)? = nil,
        roomSubscriptionSocketGate: V2RoomSubscriptionSocketGate? = nil,
        diagnosticPeerPort: Int? = nil
    ) -> Bool {
        guard !transportClosed else { return false }
        self.roomSubscriptionSocketGate = roomSubscriptionSocketGate
        if V2GatewayCoverageDiagnostics.enabled { self.diagnosticPeerPort = diagnosticPeerPort }
        self.deviceRevocationHandler = deviceRevocationHandler
        self.outboundWriter = outboundWriter
        self.requiredNotificationWriter = requiredNotificationWriter
        self.scopedNotificationWriter = scopedNotificationWriter
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
        // This ordinary API promises no Ready barrier and remains best effort.
        guard !transportClosed else { return }
        if !notificationsReady || !authenticatedResponseWritten {
            _ = retainPendingSync(eventID: eventID, highWatermark: highWatermark, required: false,
                permit: { enqueue in enqueue(); return true })
            return
        }
        guard let version = await session.authenticatedProtocolVersion(), let outboundWriter else { return }
        var envelope = IMV2Envelope(); envelope.requestID = 0; envelope.protocolVersion = UInt32(version)
        envelope.syncAvailable.eventID = eventID; envelope.syncAvailable.highWatermark = highWatermark
        guard let frame = try? V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version),
              let bytes = try? V2FrameCodec.encode(frame, limits: frameLimits) else { return }
        await outboundWriter(bytes)
    }

    @discardableResult
    public func retainSyncAvailable(eventID: UInt64, highWatermark: UInt64,
        enqueueIfCurrent: @escaping @Sendable (@Sendable () -> Void) -> Bool) async -> Bool {
        guard !transportClosed, !recoveryOutbound.isRevoked else { return false }
        if !notificationsReady || !authenticatedResponseWritten {
            return retainPendingSync(eventID: eventID, highWatermark: highWatermark, permit: enqueueIfCurrent)
        }
        guard await admitPendingRecovering(kind: IMV2RealtimeCoverage.Scope.account.rawValue) else { return false }
        guard let version = await session.authenticatedProtocolVersion(), let writer = scopedNotificationWriter,
              !transportClosed else { return false }
        var envelope = IMV2Envelope(); envelope.requestID = 0; envelope.protocolVersion = UInt32(version)
        envelope.syncAvailable.eventID = eventID; envelope.syncAvailable.highWatermark = highWatermark
        guard let frame = try? V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version),
              let bytes = try? V2FrameCodec.encode(frame, limits: frameLimits) else { return false }
        return await writer(connectionFencedNotification(bytes: bytes, permit: enqueueIfCurrent))
    }

    private func retainPendingSync(eventID: UInt64, highWatermark: UInt64, required: Bool = true,
        permit: @escaping @Sendable (@Sendable () -> Void) -> Bool) -> Bool {
        return recoveryOutbound.enqueueIfActive {
            permit {
                self.pendingSyncRecovery.withLock { prior in
                    prior = .init(eventID: max(prior?.eventID ?? 0, eventID),
                        highWatermark: max(prior?.highWatermark ?? 0, highWatermark),
                        required: required || prior?.required == true,
                        permit: required || prior?.required != true ? permit : prior!.permit)
                }
            }
        }
    }

    /// Accept bounded per-connection ownership without waiting for socket work.
    /// `true` means retained; only `onSettled(true)` proves actual admission.
    /// The operation retains its original scope generation and proof deadline.
    public func offerRecoveryOperation(scope: IMV2RealtimeCoverage.Scope, scopeID: String,
        scopeGeneration: UInt64, operation: @escaping @Sendable () async -> Bool,
        onSettled: @escaping @Sendable (Bool) async -> Void) async -> Bool {
        guard !transportClosed, !recoveryOutbound.isRevoked, registeredIdentity != nil, authenticatedResponseWritten,
              scopeGeneration > 0, !scopeID.isEmpty else { return false }
        return await recoveryOutbound.offer(kind: scope.rawValue, operation: operation, onSettled: onSettled)
    }

    func recoveryOutboundSnapshot() async -> V2GatewayRecoveryOutbound.Snapshot {
        await recoveryOutbound.snapshot()
    }

    /// Service shutdown revokes admission before waiting on another owner.
    /// The actual worker handles remain retained until drainRecoveryWork joins.
    nonisolated func revokeRecoveryWorkImmediately() {
        revokeRoomSubscriptionConnection()
        recoveryOutbound.revoke()
        coverageWriteFences.withLock { $0.removeAll() }
        pendingSyncRecovery.withLock { $0 = nil }
    }

    func drainRecoveryWork() async {
        revokeRecoveryWorkImmediately()
        roomSubscriptionWriter?.cancel(); roomSubscriptionState = nil; roomSubscriptionReportedProgress = nil
        pendingCoverage.removeAll()
        recoveryNotificationRetry?.cancel()
        await drainRecoveryOutboundWork()
    }

    public func sendRealtimeCoverage(scope: IMV2RealtimeCoverage.Scope, scopeID: String,
                                     scopeGeneration: UInt64, highWatermark: UInt64 = 0,
                                     connectionEpoch: String = "", ready: Bool, ended: Bool = false,
                                     reason: IMV2RealtimeCoverage.Reason,
                                     confirms: (@Sendable () -> Bool)? = nil,
                                     scopePermit: (@Sendable (@Sendable () -> Void) -> Bool)? = nil,
                                     onReadyAdmitted: (@Sendable () async -> Void)? = nil) async {
        if !ready {
            // Recovering/Ended are bounded control state, not a reason to hold
            // a subscription caller across socket admission. The connection's
            // existing worker owns retries. This return is NOT an enqueue ACK.
            _ = storeRealtimeCoverage(scope: scope, scopeID: scopeID, scopeGeneration: scopeGeneration,
                highWatermark: highWatermark, connectionEpoch: connectionEpoch, ready: false, ended: ended,
                reason: reason, confirms: confirms, scopePermit: scopePermit, onReadyAdmitted: onReadyAdmitted)
            scheduleRecoveryNotificationRetry()
            return
        }
        _ = await enqueueRealtimeCoverage(scope: scope, scopeID: scopeID, scopeGeneration: scopeGeneration,
            highWatermark: highWatermark, connectionEpoch: connectionEpoch, ready: ready, ended: ended,
            reason: reason, confirms: confirms, scopePermit: scopePermit, onReadyAdmitted: onReadyAdmitted)
    }

    private func enqueueRealtimeCoverage(scope: IMV2RealtimeCoverage.Scope, scopeID: String,
                                     scopeGeneration: UInt64, highWatermark: UInt64 = 0,
                                     connectionEpoch: String = "", ready: Bool, ended: Bool = false,
                                     reason: IMV2RealtimeCoverage.Reason,
                                     confirms: (@Sendable () -> Bool)? = nil,
                                     scopePermit: (@Sendable (@Sendable () -> Void) -> Bool)? = nil,
                                     onReadyAdmitted: (@Sendable () async -> Void)? = nil) async -> Bool {
        guard storeRealtimeCoverage(scope: scope, scopeID: scopeID, scopeGeneration: scopeGeneration,
            highWatermark: highWatermark, connectionEpoch: connectionEpoch, ready: ready, ended: ended,
            reason: reason, confirms: confirms, scopePermit: scopePermit, onReadyAdmitted: onReadyAdmitted) else { return false }
        let targetRevision = pendingCoverage[scope.rawValue]?.last?.state.revision
        // Retain Ready before awaiting its predecessor. An in-flight control
        // write must not discard the successor when admission returns false.
        if notificationsReady {
            for _ in 0..<2 {
                let revision = pendingCoverage[scope.rawValue]?.first?.state.revision
                guard await writeRealtimeCoverage(kind: scope.rawValue) else { break }
                if revision == targetRevision { scheduleRecoveryNotificationRetry(); return true }
            }
        }
        scheduleRecoveryNotificationRetry()
        return false
    }

    /// Explicit actual Recovering admission for a recovery handoff's dependency
    /// barrier. Unlike the ordinary control API, `true` may clear that barrier.
    public func retainRealtimeCoverageRecovering(scope: IMV2RealtimeCoverage.Scope, scopeID: String,
        scopeGeneration: UInt64, reason: IMV2RealtimeCoverage.Reason,
        scopePermit: @escaping @Sendable (@Sendable () -> Void) -> Bool) async -> Bool {
        await enqueueRealtimeCoverage(scope: scope, scopeID: scopeID, scopeGeneration: scopeGeneration,
            ready: false, reason: reason, scopePermit: scopePermit)
    }

    /// A retained control predecessor cannot be bypassed by its watermark.
    /// Retries retain the same original permit; failure grants no Ready proof.
    private func admitPendingRecovering(kind: Int) async -> Bool {
        guard pendingCoverage[kind]?.first?.state.state == .recovering else { return !transportClosed }
        let accepted = await writeRealtimeCoverage(kind: kind)
        if !accepted { scheduleRecoveryNotificationRetry() }
        return accepted
    }

    private func storeRealtimeCoverage(scope: IMV2RealtimeCoverage.Scope, scopeID: String,
                                     scopeGeneration: UInt64, highWatermark: UInt64 = 0,
                                     connectionEpoch: String = "", ready: Bool, ended: Bool = false,
                                     reason: IMV2RealtimeCoverage.Reason,
                                     confirms: (@Sendable () -> Bool)? = nil,
                                     scopePermit: (@Sendable (@Sendable () -> Void) -> Bool)? = nil,
                                     onReadyAdmitted: (@Sendable () async -> Void)? = nil) -> Bool {
        guard !transportClosed, !recoveryOutbound.isRevoked, registeredIdentity != nil, authenticatedResponseWritten,
              (1...5).contains(scope.rawValue), scopeGeneration > 0 else { return false }
        let kind = scope.rawValue
        let prior = coverageGenerations[kind] ?? 0
        guard scopeGeneration >= prior else { return false }
        if ready {
            guard scopeGeneration == prior, activeCoverageScopes[kind] == scopeID else { return false }
        } else {
            coverageGenerations[kind] = scopeGeneration
            activeCoverageScopes[kind] = ended ? nil : scopeID
        }
        guard coverageRevision < UInt64.max else { return false }
        coverageRevision += 1
        var state = IMV2RealtimeCoverage()
        state.scope = scope; state.scopeID = scopeID; state.revision = coverageRevision
        state.scopeGeneration = scopeGeneration; state.highWatermark = highWatermark
        state.connectionEpoch = connectionEpoch
        state.state = ended ? .ended : ready ? .ready : .recovering; state.reason = reason
        let transition = PendingCoverageTransition(state: state, confirms: confirms, scopePermit: scopePermit, onReadyAdmitted: onReadyAdmitted)
        if V2GatewayCoverageDiagnostics.enabled, scope == .account, !ready {
            diagnosticAccountWaitingSince = .now
            diagnosticAccountScopeRejectedRevision = nil
        }
        if ready, let predecessor = pendingCoverage[kind]?.first,
           predecessor.state.state == .recovering, predecessor.state.scopeGeneration == scopeGeneration {
            pendingCoverage[kind] = [predecessor, transition]
        } else { pendingCoverage[kind] = [transition] }
        let front = pendingCoverage[kind]!.first!.state
        coverageWriteFences.withLock { $0[kind] = .init(generation: front.scopeGeneration, revision: front.revision) }
        return true
    }

    /// True means this actual scoped socket-owner enqueue, not completed wire
    /// writing or client receipt. Failed transitions retain the existing owned retry.
    public func retainRealtimeCoverageReady(scope: IMV2RealtimeCoverage.Scope, scopeID: String,
        scopeGeneration: UInt64, highWatermark: UInt64,
        confirms: @escaping @Sendable () -> Bool,
        scopePermit: @escaping @Sendable (@Sendable () -> Void) -> Bool) async -> Bool {
        await enqueueRealtimeCoverage(scope: scope, scopeID: scopeID, scopeGeneration: scopeGeneration,
            highWatermark: highWatermark, ready: true, reason: .unspecified,
            confirms: confirms, scopePermit: scopePermit)
    }

    @discardableResult
    private func writeRealtimeCoverage(kind: Int) async -> Bool {
        guard !transportClosed, authenticatedResponseWritten, notificationsReady,
              let item = pendingCoverage[kind]?.first, let writer = scopedNotificationWriter,
              coverageWritesInFlight.insert(kind).inserted else { return false }
        // The retained-control worker and an explicit actual handoff may race.
        // One kind owns at most one submitted writer until its real await ends.
        defer { coverageWritesInFlight.remove(kind) }
        guard let version = await session.authenticatedProtocolVersion(), !transportClosed,
              pendingCoverage[kind]?.first?.state.revision == item.state.revision else { return false }
        if item.state.state == .ready, item.confirms?() != true {
            degradePendingCoverage(kind: kind, revision: item.state.revision)
            return false
        }
        var envelope = IMV2Envelope(); envelope.requestID = 0; envelope.protocolVersion = UInt32(version)
        envelope.realtimeCoverage = item.state
        guard let frame = try? V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version),
              let bytes = try? V2FrameCodec.encode(frame, limits: frameLimits) else { return false }
        let generation = item.state.scopeGeneration, revision = item.state.revision
        let ready = item.state.state == .ready, confirms = item.confirms, scopePermit = item.scopePermit
        let dispatched = V2GatewayNotificationDispatchResult()
        let accepted = await writer(connectionFencedNotification(bytes: bytes, permit: { enqueue in
            self.coverageWriteFences.withLock { current in
                guard current[kind]?.generation == generation, current[kind]?.revision == revision else { return false }
                if let scopePermit {
                    // The child callback stays synchronous and nonescaping;
                    // no stored closure can retain the socket enqueue operation.
                    let result = scopePermit {
                        guard !ready || confirms?() == true else { return }
                        dispatched.mark(); enqueue()
                    }
                    if !result { dispatched.rejectScope() }
                    return result && dispatched.wasDispatched
                }
                guard !ready || confirms?() == true else { return false }
                enqueue(); return true
            }
        }))
        guard pendingCoverage[kind]?.first?.state.revision == revision else { return false }
        if accepted {
            if V2GatewayCoverageDiagnostics.enabled, kind == IMV2RealtimeCoverage.Scope.account.rawValue {
                diagnosticAccountAdmittedState = String(describing: item.state.state)
                if ready {
                    diagnosticAccountWaitingSince = nil
                    if let port = diagnosticPeerPort { V2GatewayCoverageDiagnostics.examples.remove(sourcePort: port) }
                }
            }
            pendingCoverage[kind]?.removeFirst()
            if let next = pendingCoverage[kind]?.first {
                coverageWriteFences.withLock { $0[kind] = .init(generation: next.state.scopeGeneration, revision: next.state.revision) }
            } else { pendingCoverage.removeValue(forKey: kind) }
        }
        else if dispatched.scopeWasRejected {
            if V2GatewayCoverageDiagnostics.enabled, kind == IMV2RealtimeCoverage.Scope.account.rawValue {
                diagnosticAccountScopeRejectedRevision = revision
            }
            // Only an actual socket-owner permit check proves cancellation.
            // A busy/nonwritable transport may not evaluate the permit at all;
            // checking an EventLoop-bound permit on this actor would falsely
            // reject a live scope and silently discard its retained control.
            pendingCoverage.removeValue(forKey: kind)
        } else if ready, item.confirms?() != true { degradePendingCoverage(kind: kind, revision: revision) }
        if accepted, ready { await item.onReadyAdmitted?() }
        return accepted
    }

    private func degradePendingCoverage(kind: Int, revision: UInt64) {
        guard var item = pendingCoverage[kind]?.first, item.state.revision == revision, coverageRevision < UInt64.max else { return }
        coverageRevision += 1
        item.state.revision = coverageRevision; item.state.state = .recovering
        item.state.reason = .coverageLost; item.state.highWatermark = 0
        pendingCoverage[kind] = [item]
        coverageWriteFences.withLock { $0[kind] = .init(generation: item.state.scopeGeneration, revision: item.state.revision) }
    }

    private func scheduleRecoveryNotificationRetry() {
        guard !transportClosed, !recoveryOutbound.isRevoked, notificationsReady, authenticatedResponseWritten,
              scopedNotificationWriter != nil, recoveryNotificationRetry == nil, connectionAllowsDispatch(),
              !pendingCoverage.isEmpty || pendingSyncRecovery.withLock({ $0 != nil }) else { return }
        recoveryNotificationRetry = Task {
            await V2RecoveryNotificationWorkerContext.$connectionID.withValue(connectionID) {
                await self.retryRecoveryNotifications()
            }
        }
    }

    private func retryRecoveryNotifications() async {
        defer { recoveryNotificationRetry = nil }
        var delay = 250
        while !Task.isCancelled, !transportClosed, !recoveryOutbound.isRevoked, notificationsReady, connectionAllowsDispatch(),
              !pendingCoverage.isEmpty || pendingSyncRecovery.withLock({ $0 != nil }) {
            do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
            guard !Task.isCancelled, !transportClosed else { return }
            await drainRecoveryNotifications()
            delay = min(2_000, delay * 2)
        }
    }

    private func drainRecoveryNotifications() async {
        let kinds = pendingCoverage.keys.sorted { (pendingCoverage[$0]?.first?.state.revision ?? 0) < (pendingCoverage[$1]?.first?.state.revision ?? 0) }
        for kind in kinds { await writeRealtimeCoverage(kind: kind) }
        if let pending = pendingSyncRecovery.withLock({ value in let prior = value; value = nil; return prior }) {
            if !pending.required {
                await sendSyncAvailable(eventID: pending.eventID, highWatermark: pending.highWatermark)
                return
            }
            let accepted = await retainSyncAvailable(eventID: pending.eventID,
                highWatermark: pending.highWatermark, enqueueIfCurrent: pending.permit)
            if !accepted, !transportClosed {
                _ = retainPendingSync(eventID: pending.eventID, highWatermark: pending.highWatermark, permit: pending.permit)
            }
        }
    }

    private func makeNotificationsReady() async {
        guard !transportClosed, registeredIdentity != nil, authenticatedResponseWritten else { return }
        notificationsReady = true
        await drainRecoveryNotifications()
        scheduleRecoveryNotificationRetry()
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
        directEvent: V2DirectRoomLiveEvent? = nil,
        enqueueIfCurrent: (@Sendable (@Sendable () -> Void) -> Bool)? = nil
    ) async -> Bool {
        guard !transportClosed, let version = await session.authenticatedProtocolVersion(), let outboundWriter, !transportClosed else { return false }
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
        if let enqueueIfCurrent {
            guard let scopedNotificationWriter else { return false }
            return await scopedNotificationWriter(connectionFencedNotification(bytes: bytes, permit: enqueueIfCurrent))
        }
        await outboundWriter(bytes)
        return !transportClosed
    }

    /// Required recovery uses actual Bool admission at the socket owner. The
    /// ordinary body accelerator above retains its existing NIO fast path.
    public func retainGroupEventAvailable(roomID: RoomID, highWatermark: UInt64,
        enqueueIfCurrent: @escaping @Sendable (@Sendable () -> Void) -> Bool) async -> Bool {
        guard await admitPendingRecovering(kind: IMV2RealtimeCoverage.Scope.room.rawValue) else { return false }
        guard !transportClosed, let writer = scopedNotificationWriter,
              let version = await session.authenticatedProtocolVersion(), !transportClosed else { return false }
        var envelope = IMV2Envelope(); envelope.requestID = 0; envelope.protocolVersion = UInt32(version)
        envelope.groupEventAvailable.roomID = roomID.rawValue
        envelope.groupEventAvailable.highWatermark = highWatermark
        guard let frame = try? V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version),
              let bytes = try? V2FrameCodec.encode(frame, limits: frameLimits) else { return false }
        return await writer(connectionFencedNotification(bytes: bytes, permit: enqueueIfCurrent))
    }

    private func recordAccountCoverageDiagnostic(_ heartbeat: IMV2Heartbeat, requestID: UInt64) async {
        guard !transportClosed, let sourcePort = diagnosticPeerPort,
              let since = diagnosticAccountWaitingSince, since.duration(to: .now) >= .seconds(10) else { return }
        let kind = IMV2RealtimeCoverage.Scope.account.rawValue
        guard let generation = coverageGenerations[kind] else { return }
        let recovery = await registry.accountCoverageDiagnostic(connectionID: connectionID)
        // The read crosses actors: an intervening Ready/retirement invalidates
        // this sample. It never changes scope ownership or schedules a repair.
        guard !transportClosed, diagnosticAccountWaitingSince == since,
              coverageGenerations[kind] == generation else { return }
        V2GatewayCoverageDiagnostics.examples.record(.init(sourcePort: sourcePort, requestID: requestID,
            clientTimeMilliseconds: heartbeat.clientTimeMs,
            observedAtUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000), generation: generation,
            lastAdmittedState: diagnosticAccountAdmittedState,
            pendingStates: (pendingCoverage[kind] ?? []).map { "\($0.state.state):\($0.state.revision)" },
            writeInFlight: coverageWritesInFlight.contains(kind), retryOwned: recoveryNotificationRetry != nil,
            scopeRejectedRevision: diagnosticAccountScopeRejectedRevision, recovery: recovery))
    }

    /// Independent room-local lifecycle. No partition coverage or Journal
    /// witness enters this path; the supplied gate is checked at actual enqueue.
    func beginRoomSubscription(roomID: RoomID, scopeGeneration: UInt64,
        permit: @escaping @Sendable (@Sendable () -> Void) -> Bool) async {
        guard !transportClosed, !recoveryOutbound.isRevoked else { return }
        if activeCoverageScopes[IMV2RealtimeCoverage.Scope.room.rawValue] == roomID.rawValue,
           coverageGenerations[IMV2RealtimeCoverage.Scope.room.rawValue] == scopeGeneration { return }
        await sendRealtimeCoverage(scope: .room, scopeID: roomID.rawValue, scopeGeneration: scopeGeneration,
            ready: false, reason: .installing, scopePermit: permit)
    }

    private func recordRoomCoverageDiagnostic(_ heartbeat: IMV2Heartbeat, requestID: UInt64,
        observation: V2GatewayRoomSubscriptionAuthority.ProgressObservation) {
        let kind = IMV2RealtimeCoverage.Scope.room.rawValue
        guard !transportClosed, let sourcePort = diagnosticPeerPort,
              activeCoverageScopes[kind] != nil, let generation = coverageGenerations[kind] else { return }
        let snapshot = observation.snapshot
        let ready = snapshot.map { roomSubscriptionReady == $0.authorization } ?? false
        if ready { V2GatewayCoverageDiagnostics.roomExamples.remove(sourcePort: sourcePort); return }
        V2GatewayCoverageDiagnostics.roomExamples.record(.init(sourcePort: sourcePort, requestID: requestID,
            clientTimeMilliseconds: heartbeat.clientTimeMs,
            observedAtUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            requestedGeneration: generation, authorityGeneration: snapshot?.authorization.scopeGeneration,
            absence: observation.absence?.rawValue, highWatermark: snapshot?.highWatermark,
            socketReady: ready, retainedHead: roomSubscriptionState != nil,
            headWriterOwned: roomSubscriptionWriter != nil,
            pendingStates: (pendingCoverage[kind] ?? []).map { "\($0.state.state):\($0.state.revision)" }))
    }

    /// H is trusted local authority state; C is only this device's report.
    /// Actual socket enqueue (G) is deliberately not evidence of local application.
    func exchangeRoomProgress(_ heartbeat: IMV2Heartbeat, diagnosticRequestID: UInt64? = nil) async -> [IMV2GroupEventProgressState] {
        guard !transportClosed, !recoveryOutbound.isRevoked, registeredIdentity != nil,
              heartbeat.roomProgress.count <= 1 else { return [] }
        let observation = await registry.roomSubscriptionProgressObservation(connectionID: connectionID)
        if V2GatewayCoverageDiagnostics.enabled, let diagnosticRequestID {
            recordRoomCoverageDiagnostic(heartbeat, requestID: diagnosticRequestID, observation: observation)
        }
        guard let snapshot = observation.snapshot else {
            switch observation.absence {
            case .authorizationNotReady, .sessionUnavailable:
                await registry.roomSubscriptionProgressNeedsRepair(connectionID: connectionID)
            default: break
            }
            return []
        }
        let authorization = snapshot.authorization
        var applied: UInt64 = 0
        if let prior = roomSubscriptionReportedProgress, prior.authorization == authorization { applied = prior.applied }
        if let report = heartbeat.roomProgress.first,
           (try? RoomID(report.roomID)) == authorization.fence.roomID,
           report.scopeGeneration == authorization.scopeGeneration,
           report.appliedRoomSequence <= snapshot.highWatermark {
            applied = max(applied, report.appliedRoomSequence)
        }
        roomSubscriptionReportedProgress = (authorization, applied)
        var result = IMV2GroupEventProgressState()
        result.roomID = authorization.fence.roomID.rawValue
        result.scopeGeneration = authorization.scopeGeneration
        result.highWatermark = snapshot.highWatermark
        result.appliedRoomSequence = applied
        result.ready = roomSubscriptionReady == authorization
        V2RoomSubscriptionHeadDeliveryMetrics.shared.record(result.ready ? .progressReady : .progressSocketNotReady)
        if !result.ready {
            // A healthy authority may have superseded an old socket offer.
            // Demand reoffers its current trusted head; only the actual scoped
            // socket enqueue can establish Ready, never this heartbeat itself.
            await registry.roomSubscriptionBaselineInstalled(roomID: authorization.fence.roomID)
        }
        return [result]
    }

    /// The socket retains only one latest H for its requested detail room.
    /// Ready's S is immutable in the authorization; later H never changes it.
    nonisolated func offerRoomSubscriptionHead(_ authorization: V2GatewayRoomSubscriptionAuthority.Permit,
        highWatermark: UInt64, permit: @escaping @Sendable (@Sendable () -> Void) -> Bool) async -> Bool {
        if foregroundTransport.submitRoomHead(authorization, highWatermark: highWatermark) { return true }
        return await initializeRoomSubscriptionHead(authorization, highWatermark: highWatermark, permit: permit)
    }
    private func initializeRoomSubscriptionHead(_ authorization: V2GatewayRoomSubscriptionAuthority.Permit,
        highWatermark: UInt64, permit: @escaping @Sendable (@Sendable () -> Void) -> Bool) async -> Bool {
        V2RoomSubscriptionHeadDeliveryMetrics.shared.record(.headOffered)
        guard !transportClosed, !recoveryOutbound.isRevoked, scopedNotificationWriter != nil,
              let gate = authorization.socketGate,
              (try? await gate.eventLoop.submit { permit({}) }.get()) == true,
              !transportClosed, !recoveryOutbound.isRevoked else {
            V2RoomSubscriptionHeadDeliveryMetrics.shared.record(.headOfferRefused)
            return false
        }
        if var old = roomSubscriptionState, old.authorization == authorization {
            old.highWatermark = max(old.highWatermark, highWatermark)
            old.permit = permit
            roomSubscriptionState = old
        } else {
            let retainedHead: UInt64
            if let prior = roomSubscriptionState,
               prior.authorization.fence.roomID == authorization.fence.roomID,
               prior.authorization.scopeGeneration == authorization.scopeGeneration {
                retainedHead = max(prior.highWatermark, highWatermark)
            } else { retainedHead = highWatermark }
            roomSubscriptionState = .init(authorization: authorization, highWatermark: retainedHead, permit: permit)
            roomSubscriptionReady = nil
            // Recovering is a socket-scope predecessor, not an authority
            // credential. A fresh grant still needs its own actual Ready,
            // but must not put the same live scope back into Recovering.
            if !hasAdmittedRoomRecovering(for: authorization) { roomSubscriptionRecovering = nil }
        }
        V2RoomSubscriptionHeadDeliveryMetrics.shared.record(.headRetained)
        if let current = roomSubscriptionState,
           roomSubscriptionReady == current.authorization,
           hasAdmittedRoomRecovering(for: current.authorization),
           let submitted = current.submittedHighWatermark, current.highWatermark <= submitted {
            V2RoomSubscriptionHeadDeliveryMetrics.shared.record(.headAlreadySubmitted)
            return true
        }
        // Coalesce offers while the actual writer is suspended. No idle task
        // or AsyncStream retains the deepest async stack for this connection.
        roomSubscriptionWakePending = true
        if roomSubscriptionWriter == nil {
            roomSubscriptionWriter = Task {
                await V2RecoveryNotificationWorkerContext.$connectionID.withValue(connectionID) {
                    await self.consumeRoomSubscriptionHeads()
                }
            }
        }
        return true
    }
    private func hasAdmittedRoomRecovering(for authorization: V2GatewayRoomSubscriptionAuthority.Permit) -> Bool {
        guard let admitted = roomSubscriptionRecovering else { return false }
        return admitted.connectionID == authorization.connectionID && admitted.lifecycle == authorization.lifecycle
            && admitted.fence.roomID == authorization.fence.roomID
            && admitted.scopeGeneration == authorization.scopeGeneration
    }
    func endRoomSubscription(roomID: RoomID, scopeGeneration: UInt64) async {
        let kind = IMV2RealtimeCoverage.Scope.room.rawValue
        // Old cleanup can return after a successor subscribed to the same room.
        // Reject it before changing head/Ready/progress, not just when encoding
        // the later Ended control. A room ID alone is not a scope identity.
        guard coverageGenerations[kind] == scopeGeneration,
              activeCoverageScopes[kind] == roomID.rawValue else { return }
        if roomSubscriptionState?.authorization.fence.roomID == roomID,
           roomSubscriptionState?.authorization.scopeGeneration == scopeGeneration {
            roomSubscriptionState = nil; roomSubscriptionReportedProgress = nil
            roomSubscriptionReady = nil; roomSubscriptionRecovering = nil
        }
        await sendRealtimeCoverage(scope: .room, scopeID: roomID.rawValue, scopeGeneration: scopeGeneration,
            ready: false, ended: true, reason: .cancelled)
    }
    private func consumeRoomSubscriptionHeads() async {
        defer { roomSubscriptionWriter = nil }
        repeat {
            roomSubscriptionWakePending = false
            while !Task.isCancelled, !transportClosed, !recoveryOutbound.isRevoked,
                  let selected = roomSubscriptionState {
                let authorization = selected.authorization
                guard let gate = authorization.socketGate,
                      (try? await gate.eventLoop.submit { selected.permit({}) }.get()) == true else {
                    if selected.submittedHighWatermark.map({ selected.highWatermark > $0 }) ?? true {
                        V2RoomSubscriptionHeadDeliveryMetrics.shared.record(.headPermitExpiredWithUnsentHead)
                    }
                    // Retain only the bounded hint. Do not retry this expired gate;
                    // a new trusted offer must supply a valid permit and signal us.
                    break
                }
                if !authenticatedResponseWritten || !notificationsReady {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    continue
                }
                if !hasAdmittedRoomRecovering(for: authorization) {
                    let accepted = await retainRealtimeCoverageRecovering(scope: .room,
                        scopeID: authorization.fence.roomID.rawValue, scopeGeneration: authorization.scopeGeneration,
                        reason: .installing, scopePermit: selected.permit)
                    guard roomSubscriptionState?.authorization == authorization else { continue }
                    if accepted { roomSubscriptionRecovering = authorization }
                    else {
                        V2RoomSubscriptionHeadDeliveryMetrics.shared.record(.headRecoveringRefused)
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }; continue
                    }
                }
                if roomSubscriptionReady != authorization {
                    // All authority validation belongs to scopePermit; confirms
                    // must not recursively acquire that same authority mutex.
                    let accepted = await retainRealtimeCoverageReady(scope: .room,
                        scopeID: authorization.fence.roomID.rawValue, scopeGeneration: authorization.scopeGeneration,
                        highWatermark: authorization.baselineSequence, confirms: { true }, scopePermit: selected.permit)
                    guard roomSubscriptionState?.authorization == authorization else { continue }
                    if accepted { roomSubscriptionReady = authorization }
                    else {
                        V2RoomSubscriptionHeadDeliveryMetrics.shared.record(.headReadyRefused)
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }; continue
                    }
                }
                guard let current = roomSubscriptionState, current.authorization == authorization else { continue }
                // Once lifecycle controls reached the socket, normal heads share
                // the bounded foreground writer. It checks body coverage at actual
                // drain, and wakes on writability instead of polling this actor.
                if let contract = await session.authenticatedFrameContract(),
                   roomSubscriptionState?.authorization == authorization {
                    // Bytes sent before Ready may have been ignored by a
                    // recovering client. Start hint coverage after that boundary.
                    guard let gate = authorization.socketGate,
                          (try? await gate.eventLoop.submit { gate.resetSubmittedHead() }.get()) != nil,
                          roomSubscriptionState?.authorization == authorization else { continue }
                    let limits = frameLimits
                    let session = self.session, outbound = recoveryOutbound
                    if foregroundTransport.activateRoomHead(authorization, enqueueIfCurrent: { enqueue in
                        outbound.enqueueIfActive {
                            guard session.connectionIsActive else { return false }
                            return authorization.socketGate?.enqueue(authorization, now: .now, body: enqueue) ?? false
                        }
                    }, encode: { head in
                        V2PreparedGatewayGroupEventAvailable(roomID: authorization.fence.roomID,
                            highWatermark: head, directEvent: nil, frameLimits: limits,
                            protocolVersion: contract.protocolVersion, compression: contract.compression)?
                            .bytes(for: contract.compression)
                    }) {
                        _ = foregroundTransport.submitRoomHead(authorization, highWatermark: current.highWatermark)
                        break
                    }
                }
                // Admission is acknowledged by the socket owner. Repeated
                // offers of the same H need not create another TCP frame;
                // refused writes remain dirty and fresh authorization starts
                // with no submitted watermark, including an initial H of zero.
                if let submitted = current.submittedHighWatermark, current.highWatermark <= submitted {
                    V2RoomSubscriptionHeadDeliveryMetrics.shared.record(.headAlreadySubmitted)
                    break
                }
                let accepted = await sendGroupEventAvailable(roomID: authorization.fence.roomID,
                    highWatermark: current.highWatermark, enqueueIfCurrent: current.permit)
                V2RoomSubscriptionHeadDeliveryMetrics.shared.record(accepted ? .headEnqueueAccepted : .headEnqueueRefused)
                guard var latest = roomSubscriptionState, latest.authorization == authorization else { continue }
                if accepted {
                    latest.submittedHighWatermark = max(latest.submittedHighWatermark ?? 0, current.highWatermark)
                    roomSubscriptionState = latest
                } else { do { try await Task.sleep(for: .milliseconds(100)) } catch { return } }
            }
        } while roomSubscriptionWakePending && !Task.isCancelled && !transportClosed && !recoveryOutbound.isRevoked
        // The last pending-wake check and handle release share this actor turn.
        // A fresh offer cannot be lost between deciding to idle and clearing it.
    }

    /// 发送一份为进程本地已授权受众编码一次的帧。
    ///
    /// 该流仍会用自身已认证的协商结果与当前传输回调为写入建立围栏；
    /// 过期或协议版本不同的流无法消费这份共享字节。
    ///
    /// - Parameter prepared: 已准备的群组事件帧。
    @discardableResult
    func sendGroupEventAvailable(_ prepared: V2PreparedGatewayGroupEventAvailable,
        enqueueIfCurrent: (@Sendable (@Sendable () -> Void) -> Bool)? = nil) async -> Bool {
        guard let contract = await session.authenticatedFrameContract(),
              contract.protocolVersion == prepared.protocolVersion,
              let outboundWriter
        else { return false }
        let buffer = prepared.bytes(for: contract.compression)
        if let enqueueIfCurrent {
            guard !transportClosed, let scopedNotificationWriter else { return false }
            return await scopedNotificationWriter(connectionFencedNotification(bytes: Data(buffer.readableBytesView), permit: enqueueIfCurrent))
        }
        await outboundWriter(Data(buffer.readableBytesView))
        return !transportClosed
    }

    /// 生产前台通知使用该 nonisolated 快速路径。
    ///
    /// 返回 `false` 表示连接未认证、已分离、使用其他协议版本，或没有 NIO 快速写者；
    /// 未提交的通知依赖持久日志与恢复水位继续同步。
    ///
    /// - Parameter prepared: 已准备的群组事件帧。
    /// - Returns: 是否已通过快速路径提交。
    nonisolated func submitGroupEventAvailable(
        _ prepared: V2PreparedGatewayGroupEventAvailable,
        enqueueIfCurrent: (@Sendable (@Sendable () -> Void) -> Bool)? = nil
    ) -> Bool {
        foregroundTransport.submit(prepared, enqueueIfCurrent: fencedForegroundPermit(enqueueIfCurrent))
    }

    /// 生产群组发布会先收集这些受生命周期围栏保护的 NIO 提交，再逐个进入每个 EventLoop 通道一次。
    ///
    /// 未认证或已失效的连接返回 `nil`，不会进入本轮广播。
    ///
    /// - Parameter prepared: 已准备的群组事件帧。
    /// - Returns: NIO 提交对象；不满足快速路径条件时为 `nil`。
    nonisolated func prepareNIOGroupEventAvailable(
        _ prepared: V2PreparedGatewayGroupEventAvailable,
        enqueueIfCurrent: (@Sendable (@Sendable () -> Void) -> Bool)? = nil
    ) -> V2NIOGatewayForegroundWriteSubmission? {
        foregroundTransport.prepareNIOSubmission(prepared, enqueueIfCurrent: fencedForegroundPermit(enqueueIfCurrent))
    }

    private nonisolated func fencedForegroundPermit(_ permit: (@Sendable (@Sendable () -> Void) -> Bool)?)
        -> (@Sendable (@Sendable () -> Void) -> Bool)? {
        guard let permit else { return nil }
        let write = connectionFencedNotification(bytes: Data(), permit: permit)
        return { enqueue in write.enqueueIfCurrent(enqueue) }
    }

    nonisolated func configureLiveStatePrimaryAuthentication(
        _ permit: @escaping @Sendable (@Sendable () -> Void) -> Bool
    ) {
        liveStatePrimaryAuthentication.withLock { $0 = V2CallbackBox(permit) }
    }

    /// Observation authorization remains the caller's independent fence.
    /// Primary auth is added only at actual enqueue, never as a room grant.
    private nonisolated func liveStatePermit(
        _ observation: @escaping @Sendable (@Sendable () -> Void) -> Bool,
        primary: (@Sendable (@Sendable () -> Void) -> Bool)? = nil
    ) -> @Sendable (@Sendable () -> Void) -> Bool {
        let primary = primary ?? liveStatePrimaryAuthentication.withLock { $0?.callback }
        guard let primary else { return observation }
        return { enqueue in
            let dispatched = Mutex(false)
            let allowed = observation {
                let written = primary(enqueue)
                dispatched.withLock { $0 = written }
            }
            return allowed && dispatched.withLock { $0 }
        }
    }

    public func sendPresenceState(_ state: V2PresenceState) async {
        // Ordinary notifications remain best effort. This path never certifies Ready.
        guard let bytes = await presenceNotificationBytes(state), let outboundWriter else { return }
        if liveStatePrimaryAuthentication.withLock({ $0 != nil }) {
            guard let scopedNotificationWriter else { return }
            _ = await scopedNotificationWriter(connectionFencedNotification(bytes: bytes, permit: liveStatePermit { enqueue in enqueue(); return true }))
        } else { await outboundWriter(bytes) }
    }

    @discardableResult
    public func retainPresenceState(_ state: V2PresenceState,
        enqueueIfCurrent: @escaping @Sendable (@Sendable () -> Void) -> Bool,
        primaryAuthPermit: (@Sendable (@Sendable () -> Void) -> Bool)? = nil) async -> Bool {
        guard await admitPendingRecovering(kind: IMV2RealtimeCoverage.Scope.presence.rawValue) else { return false }
        guard !transportClosed, let writer = scopedNotificationWriter,
              let bytes = await presenceNotificationBytes(state), !transportClosed else { return false }
        return await writer(connectionFencedNotification(bytes: bytes, permit: liveStatePermit(enqueueIfCurrent, primary: primaryAuthPermit)))
    }

    private func presenceNotificationBytes(_ state: V2PresenceState) async -> Data? {
        guard !transportClosed, let version = await session.authenticatedProtocolVersion(),
              let milliseconds = try? v2GatewayMilliseconds(state.expiresAt), !transportClosed else { return nil }
        var envelope = IMV2Envelope(); envelope.requestID = 0; envelope.protocolVersion = UInt32(version)
        envelope.presenceChanged.roomID = state.roomID.rawValue
        envelope.presenceChanged.targetUserID = state.targetUserID.rawValue
        envelope.presenceChanged.isOnline = state.isOnline
        envelope.presenceChanged.expiresAtMs = milliseconds
        guard let frame = try? V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version),
              let bytes = try? V2FrameCodec.encode(frame, limits: frameLimits) else { return nil }
        return bytes
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
        if liveStatePrimaryAuthentication.withLock({ $0 != nil }) {
            guard let scopedNotificationWriter else { return }
            _ = await scopedNotificationWriter(connectionFencedNotification(bytes: bytes, permit: liveStatePermit { enqueue in enqueue(); return true }))
        } else { await outboundWriter(bytes) }
    }

    /// 成功只确认传输写入，不代表客户端已持久化。
    /// 返回 false 时，通知所有者必须停止排空。
    func sendAccountRoomNotification(_ notification: V2AccountRoomNotification,
        enqueueIfCurrent: (@Sendable (@Sendable () -> Void) -> Bool)? = nil) async -> Bool {
        guard await admitPendingRecovering(kind: IMV2RealtimeCoverage.Scope.directory.rawValue) else { return false }
        guard let identity = registeredIdentity, let writer = requiredNotificationWriter,
              !transportClosed, let contract = await session.authenticatedFrameContract(),
              registeredIdentity == identity, !transportClosed else { return false }
        var envelope = notification.envelope()
        envelope.requestID = 0
        envelope.protocolVersion = UInt32(contract.protocolVersion)
        guard let frame = try? V2ServerProtobufFrameCodec.encode(envelope,
                frameVersion: contract.protocolVersion, compression: contract.compression),
              let bytes = try? V2FrameCodec.encode(frame, limits: frameLimits) else { return false }
        let written: Bool
        if let enqueueIfCurrent {
            guard let scopedNotificationWriter else { return false }
            written = await scopedNotificationWriter(connectionFencedNotification(bytes: bytes, permit: enqueueIfCurrent))
        } else { written = await writer(bytes) }
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
        await drainRecoveryOutboundWork()
    }

    /// Revoke physical connection ownership before joining request tasks.
    /// Those tasks may still be waiting for the coverage this connection owns.
    func retireTransportConnection() async {
        beginClosing()
        await session.close()
        await unregisterAuthenticatedDevice()
    }

    private func beginClosing() {
        revokeRoomSubscriptionConnection()
        recoveryOutbound.revoke()
        notificationsReady = false; authenticatedResponseWritten = false
        // Cancellation is only a request. Keep this actual handle until its
        // writer await and terminal defer finish; closing joins it below.
        recoveryNotificationRetry?.cancel()
        roomSubscriptionWriter?.cancel(); roomSubscriptionState = nil; roomSubscriptionReportedProgress = nil
        pendingSyncRecovery.withLock { $0 = nil }; pendingCoverage.removeAll()
        coverageWriteFences.withLock { $0.removeAll() }
        coverageGenerations.removeAll(); activeCoverageScopes.removeAll()
        invalidateForegroundAuthorization()
        detachTransport()
        for task in messageSendTasks.values { task.cancel() }
    }

    private func canRespondToMessageSend() -> Bool {
        !transportClosed && registeredIdentity != nil && !Task.isCancelled && connectionAllowsDispatch()
    }

    private func closeAfterMessageSendFailure() {
        guard !transportClosed else { return }
        let close = requiredNotificationClose
        beginClosing()
        if let close { Task { await close() } }
    }

    private func finishMessageSend(requestID: UInt64, bytes: Int, hasExecutionSlot: Bool, budget: V2GatewayMessageSendBudget) {
        if hasExecutionSlot { messageSendExecutingRequests -= 1 }
        messageSendTasks.removeValue(forKey: requestID)
        messageSendReservedBytes -= bytes
        budget.release(bytes)
    }

    private func drainMessageSends() async {
        let tasks = Array(messageSendTasks.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    private func drainRecoveryOutboundWork() async {
        if V2RecoveryNotificationWorkerContext.connectionID == connectionID || recoveryOutbound.isCurrentWorker {
            // Closing from a writer callback must return to that callback so
            // its actual owner can settle. Writer handles remain owned; an
            // external close joins them normally.
            await recoveryOutbound.requestCancellation()
            recoveryNotificationRetry?.cancel()
            roomSubscriptionWriter?.cancel()
            return
        }
        await recoveryOutbound.drain()
        let actual = recoveryNotificationRetry
        actual?.cancel()
        await actual?.value
        let local = roomSubscriptionWriter
        local?.cancel(); await local?.value
    }

    private func detachTransport() {
        transportClosed = true
        deviceRevocationHandler = nil
        outboundWriter = nil
        scopedNotificationWriter = nil
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
        suppressesInitialPresencePublication = await session.initialPresencePublicationSuppressed()
        let accepted = try await registry.register(self, connectionID: connectionID, identity: identity,
            publicationSuppressed: suppressesInitialPresencePublication)
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
                        await self?.sendAuthorPresentation(bytes, deadline: deadline) ?? .discarded
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
            await session.setAuthorPresentationRegistrationAvailable(authorRegistered)
        }
        foregroundTransport.activate(
            protocolVersion: contract.protocolVersion,
            compression: contract.compression,
            sessionIsLive: { [weak self] in
                guard let self else { return false }
                return self.connectionAllowsDispatch() && sessionIsLive()
            }
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
        guard case .authorPresentationStart(let request) = inbound.body,
              case .authorPresentationStarted(let started) = response.body else { return }
        guard authorPresentationRegistered else { return }
        guard request == started, !transportClosed, registeredIdentity != nil else {
            throw V2GatewaySessionError.unsupportedCommand
        }
        let start = try request.domain()
        let activated = await authorPresentationDispatcher?.activateView(connectionID: connectionID, start: start) ?? false
        guard activated, registeredIdentity != nil, !transportClosed else { throw V2GatewaySessionError.unsupportedCommand }
        authorPresentationView = (Set(start.messageRoomIDs), start.viewID)
        authorPresentationTransport.activate(viewID: start.viewID, messageRoomIDs: Set(start.messageRoomIDs))
    }

    /// Called only after the registry selected this recipient using the body
    /// event's membership fence and submitted its shared frame. Never await here.
    nonisolated func offerAuthorPresentation(_ hints: V2AuthorPresentationHints, to ingress: V2AuthorPresentationIngress) {
        guard let viewID = authorPresentationTransport.selectedView(in: hints.roomID) else { return }
        ingress.submit(connectionID: connectionID, roomID: hints.roomID, viewID: viewID, authors: hints.authors)
    }

    private func offerPageAuthors(_ exchange: V2GatewaySessionExchange,
                                 capturedView: (messageRoomIDs: Set<RoomID>, viewID: UUID)?) {
        guard !Task.isCancelled, !transportClosed, authorPresentationRegistered,
              let ingress = authorPresentationIngress, let view = capturedView,
              !view.messageRoomIDs.isEmpty else { return }
        switch (exchange.request.body, exchange.responseEnvelope.body) {
        case (.groupEventPull(let pull), .groupEventPage(let page)):
            guard let room = try? RoomID(pull.roomID), view.messageRoomIDs.contains(room),
                  authorPresentationTransport.selectedView(in: room) == view.viewID,
                  (try? RoomID(page.roomID)) == room,
                  let sample = exchange.authorSample, sample.roomID == room,
                  let hints = V2AuthorPresentationHints(page: sample) else { return }
            ingress.submit(connectionID: connectionID, roomID: room,
                           viewID: view.viewID, authors: hints.authors)
        case (.roomLatestVisibleBatch(let request), .roomLatestVisibleBatchResult(let response)):
            guard let authors = V2AuthorPresentationLatestVisibleAuthors(request: request, response: response,
                selectedRooms: view.messageRoomIDs) else { return }
            for (room, user) in authors.values where authorPresentationTransport.selectedView(in: room) == view.viewID {
                ingress.submit(connectionID: connectionID, roomID: room, viewID: view.viewID, authors: [user])
            }
        default: break
        }
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
              UUID(uuidString: request.viewID) == view.viewID else { return }
        await clearAuthorPresentationView()
    }

    /// Called by the bounded dispatcher, never by the message/ACK writer.
    private func sendAuthorPresentation(_ payload: Data, deadline: ContinuousClock.Instant) async -> V2AuthorPresentationWriteResult {
        guard !authorPresentationWriting, !Task.isCancelled, .now < deadline,
              let identity = registeredIdentity, let view = authorPresentationView,
              let writer = authorPresentationWriter, !transportClosed else { return .discarded }
        authorPresentationWriting = true
        defer { authorPresentationWriting = false }
        do {
            guard let frame = try await session.authorPresentationFrame(payload, viewID: view.viewID),
                  let sessionIsLive = await session.authorPresentationSessionCheck(),
                  registeredIdentity == identity, authorPresentationView?.viewID == view.viewID,
                  !transportClosed, !Task.isCancelled else { return .discarded }
            let bytes = try V2FrameCodec.encode(frame, limits: frameLimits)
            guard let write = authorPresentationTransport.prepare(bytes: bytes, viewID: view.viewID,
                    deadline: deadline, sessionIsLive: { [weak self] in
                        self?.connectionAllowsDispatch() == true && sessionIsLive()
                    }) else { return .discarded }
            return await withTaskCancellationHandler(operation: { await writer(write) }, onCancel: { write.cancel() })
        } catch { return .discarded }
    }

    private func updateAcknowledgedConnectionControls(inbound: IMV2Envelope, response: IMV2Envelope) async throws {
        switch inbound.body {
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
            try await registry.subscribeTyping(self, connectionID: connectionID, roomID: try .init(request.roomID))
        case .unsubscribeTyping(let request):
            guard case .acknowledged? = response.body else { return }
            await registry.unsubscribeTyping(connectionID: connectionID, roomID: try .init(request.roomID))
        case .setTypingState(let request):
            guard case .acknowledged? = response.body,
                  let identity = registeredIdentity
            else { return }
            await registry.notifyTyping(roomID: try .init(request.roomID), actorUserID: identity.userID, isTyping: request.isTyping, expiresAt: request.isTyping ? Date().addingTimeInterval(6) : Date(), sourceConnectionID: connectionID)
        case .heartbeat:
            V2GatewayHeartbeatDiagnostics.current?.mark(.registrySubmitted)
            guard await registry.refreshLivePresence(connectionID: connectionID)
            else { throw V2GatewaySessionError.authenticatedConnectionLimit }
            V2GatewayHeartbeatDiagnostics.current?.mark(.registryReturned)
        default:
            return
        }
    }
}
