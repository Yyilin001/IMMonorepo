import Foundation
import IMV2Compression
import IMV2Core
#if canImport(Network) && canImport(Security)
import Network
import Security
import Synchronization
#endif

/// 实时连接的主机与端口配置；不包含凭证或自定义信任策略。
public struct V2RealtimeEndpoint: Equatable, Sendable {
    /// 原样保存的主机字符串，初始化只检查去除首尾空白后非空。
    public let host: String
    /// 非零目标端口。
    public let port: UInt16

    /// 创建实时连接端点。
    ///
    /// - Parameters:
    ///   - host: 非空主机，检查时去除首尾空白但保存原值。
    ///   - port: 非零端口。
    /// - Throws: 空主机或零端口时抛出 invalidEndpoint。
    ///
    /// 不在此解析 DNS、验证地址语法或建立网络连接。
    public init(host: String, port: UInt16) throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, port > 0 else {
            throw V2TLSFrameConnectionError.invalidEndpoint
        }
        self.host = host
        self.port = port
    }
}

/// 连接握手后返回的身份与协商结果快照；初始化仅保存字段，不执行认证或版本校验。
public struct V2AuthenticatedClientSession: Equatable, Sendable {
    /// 服务器认证的用户。
    public let userID: UserID
    /// 本次绑定设备。
    public let deviceID: DeviceID
    /// 协商版本。
    public let protocolVersion: UInt8
    /// 协商能力配置。
    public let capabilityProfile: String
    /// 协商压缩算法，nil 表示未启用。
    public let frameCompression: V2NegotiatedFrameCompression?
    /// 可选进程内连接代际身份，用于使旧任务失效。
    public let connectionID: UUID?
    /// Nil unless both peers explicitly negotiated author supplements.
    public let authorPresentationStreamID: UUID?

    /// 保存连接或提示快照，不执行字段范围及跨字段一致性校验。
    ///
    /// - Parameters:
    ///   - userID: 服务器认证的用户。
    ///   - deviceID: 本次绑定设备。
    ///   - protocolVersion: 协商版本。
    ///   - capabilityProfile: 协商能力配置。
    ///   - frameCompression: 协商压缩算法，nil 表示未启用。
    ///   - connectionID: 可选进程内连接代际身份，用于使旧任务失效。
    public init(
        userID: UserID,
        deviceID: DeviceID,
        protocolVersion: UInt8,
        capabilityProfile: String,
        frameCompression: V2NegotiatedFrameCompression? = nil,
        connectionID: UUID? = nil,
        authorPresentationStreamID: UUID? = nil
    ) {
        self.userID = userID
        self.deviceID = deviceID
        self.protocolVersion = protocolVersion
        self.capabilityProfile = capabilityProfile
        self.frameCompression = frameCompression
        self.connectionID = connectionID
        self.authorPresentationStreamID = authorPresentationStreamID
    }
}

/// 连接配置、握手、请求关联和提示消费的错误分类。
public enum V2TLSFrameConnectionError: Error, Equatable, Sendable {
    /// 主机为空或端口为零。
    case invalidEndpoint
    /// 未建立可用于当前操作的已认证连接。
    case notConnected
    /// 底层连接启动失败。
    case connectionFailed
    /// 连接关闭或操作所属连接代际已失效。
    case connectionClosed
    /// 关联请求在期限内未收到响应。
    case requestTimedOut
    /// 握手版本不在允许范围。
    case unsupportedVersion
    /// 认证未成功。
    case authenticationFailed
    /// 握手响应或协商字段不满足要求。
    case invalidHandshake
    /// 压缩协商不受支持。
    case unsupportedCompression
    /// 帧标志与连接合同不符。
    case unsupportedFrameFlags
    /// 响应类型、关联或内容不符合预期。
    case unexpectedResponse
    /// 同类提示已有等待者，不允许另一个并发消费者。
    case concurrentAvailabilityConsumer
    /// 在途请求达到连接预算。
    case tooManyPendingRequests
}

/// 用户同步可用性提示，只用于唤醒正常拉取，不证明对应水位已投递或落盘。
public struct V2SyncAvailabilityHint: Equatable, Sendable {
    /// 提示事件编号，不是消息已应用的凭证。
    public let eventID: UInt64
    /// 服务端提示的用户同步高水位。
    public let highWatermark: UInt64

    /// 保存连接或提示快照，不执行字段范围及跨字段一致性校验。
    ///
    /// - Parameters:
    ///   - eventID: 提示事件编号，不是消息已应用的凭证。
    ///   - highWatermark: 服务端提示的用户同步高水位。
    public init(eventID: UInt64, highWatermark: UInt64) {
        self.eventID = eventID
        self.highWatermark = highWatermark
    }
}

/// 房间事件的非权威前台提示，可附带用于加速的事件批次。
///
/// 连续私聊事件可由上层即时应用；缺失、重复或间隔仍应使用持久化房间游标恢复。
public struct V2GroupEventAvailabilityHint: Equatable, Sendable {
    /// 提示所属房间。
    public let roomID: RoomID
    /// 提示的房间高水位。
    public let highWatermark: UInt64
    /// 可选加速事件批次，可靠恢复仍以持久化游标为准。
    public let liveEvents: [V2ClientGroupEvent]

    /// 保存连接或提示快照，不执行字段范围及跨字段一致性校验。
    ///
    /// - Parameters:
    ///   - roomID: 提示所属房间。
    ///   - highWatermark: 提示的房间高水位。
    ///   - liveEvents: 可选加速事件批次，可靠恢复仍以持久化游标为准。
    public init(
        roomID: RoomID,
        highWatermark: UInt64,
        liveEvents: [V2ClientGroupEvent] = []
    ) {
        self.roomID = roomID
        self.highWatermark = highWatermark
        self.liveEvents = liveEvents
    }

    /// 合并同房间提示，尽量保留有界且连续的加速事件。
    ///
    /// - Parameter newer: 后收到的提示。
    /// - Returns: 合并提示，或只保留高水位以要求正常补拉。
    ///
    /// 不同房间采用新提示；较低水位保留旧提示；相同水位仅在旧批次为空时采用新批次。
    /// 水位推进但任一批次为空、追加序列有间隔、超过页上限或尾序列未抵达新水位时丢弃加速载荷。
    /// 既有批次的内部顺序依赖来源验证，此方法不重新验证整个输入。
    func coalescing(with newer: Self) -> Self {
        guard roomID == newer.roomID else { return newer }
        guard newer.highWatermark >= highWatermark else { return self }
        guard newer.highWatermark > highWatermark else {
            return liveEvents.isEmpty && !newer.liveEvents.isEmpty ? newer : self
        }
        guard !liveEvents.isEmpty, !newer.liveEvents.isEmpty else {
            return .init(roomID: roomID, highWatermark: newer.highWatermark)
        }
        var merged = liveEvents
        var lastSequence = merged.last!.roomSequence
        for event in newer.liveEvents where event.roomSequence > lastSequence {
            guard event.roomSequence == lastSequence + 1,
                  merged.count < V2GroupEventLogLimits.maximumPageSize
            else {
                return .init(roomID: roomID, highWatermark: newer.highWatermark)
            }
            merged.append(event)
            lastSequence = event.roomSequence
        }
        guard lastSequence == newer.highWatermark else {
            return .init(roomID: roomID, highWatermark: newer.highWatermark)
        }
        return .init(
            roomID: roomID,
            highWatermark: newer.highWatermark,
            liveEvents: merged
        )
    }
}

/// 供单个应用所属消费者等待的尽力同步提示来源；收到提示后仍须执行正常拉取与确认。
public protocol V2SyncAvailabilityHintSource: Sendable {
    /// 等待下一个用户同步提示；要求单消费者，取消和连接错误通过抛出报告。
    func nextAvailabilityHint() async throws -> V2SyncAvailabilityHint
}

/// 每连接单个前台房间详情消费者的提示来源，与用户同步提示分离，避免一次房间唤醒触发全账户同步。
public protocol V2GroupEventAvailabilityHintSource: Sendable {
    /// 等待下一个房间提示；要求单消费者，不保证每个提示单独送达。
    func nextGroupEventAvailabilityHint() async throws -> V2GroupEventAvailabilityHint
}

/// 在线与输入状态的临时展示事件，不属于持久化消息同步。
public enum V2LiveActivityEvent: Equatable, Sendable {
    /// 在线状态及其有效期。
    case presence(V2PresenceState)
    /// 输入状态及其有效期。
    case typing(V2TypingState)
}

/// 由前台会话拥有单个消费者的活动事件来源；允许丢失的租约提示不能替代可靠消息同步。
public protocol V2LiveActivityEventSource: Sendable {
    /// 等待临时在线或输入事件；单消费者持有其前台生命周期，错误通过抛出报告。
    func nextLiveActivityEvent() async throws -> V2LiveActivityEvent
}

/// 面向应用协调器的连接与认证生命周期边界。
///
/// 凭证选择和 Keychain 策略由上层负责，接口可用于不打开 socket 的身份处理测试。
public protocol V2RealtimeConnection: Sendable {
    /// 建立连接并执行能力协商和设备认证。
    ///
    /// - Parameters:
    ///   - accessToken: 上层提供的访问令牌。
    ///   - deviceID: 要绑定的设备。
    ///   - supportedCapabilityProfiles: 客户端可接受的能力配置。
    /// - Returns: 认证身份与协商结果。
    /// - Throws: 连接、协商、认证或取消错误。
    ///
    /// 调用方仍需按账户上下文核对身份并管理后续会话生命周期。
    func connectAndAuthenticate(
        accessToken: String,
        deviceID: DeviceID,
        supportedCapabilityProfiles: Set<String>
    ) async throws -> V2AuthenticatedClientSession
    /// 结束当前连接生命周期；具体实现负责取消请求与通知等待者，不表示删除持久化凭证或本地数据。
    func disconnect() async
}

/// 运行时使用的会话连接边界，凭证准备由实现封装，与发送单帧请求的能力分离。
public protocol V2RealtimeSessionConnecting: Sendable {
    /// 建立会话并返回认证结果，凭证策略由具体实现负责，失败通过抛出报告。
    func connect() async throws -> V2AuthenticatedClientSession
    /// 结束当前连接生命周期；具体实现负责取消请求与通知等待者，不表示删除持久化凭证或本地数据。
    func disconnect() async
}

#if canImport(Network) && canImport(Security)
/// 可注入的异步字节连接边界。
///
/// 生产实现使用 TLS 1.3 与平台信任校验，测试实现可控制旧连接回调时机。此接口不解析 IM 帧或认证载荷。
protocol V2TLSByteConnection: Sendable {
    /// 启动连接并等待可发送字节；连接失败通过错误报告。
    func start() async throws
    /// 发送字节并等待底层完成回调，不代表服务端业务已确认。
    func send(_ data: Data) async throws
    /// 读取不超过请求上限的一段字节，不保证包含完整协议帧。
    func receive(maximumLength: Int) async throws -> Data
    /// 请求终止底层连接，不要求同步等待所有回调结束。
    func cancel()
}

/// 把 Network.framework 回调桥接为异步字节读写。
///
/// 端点构造路径限定 TLS 1.3，沿用平台信任校验；内部连接注入路径由调用者提供正确配置。
/// 异步方法不自行安装 Task 取消处理器，连接所有者通过 cancel 终止底层连接。
struct V2NetworkTLSByteConnection: V2TLSByteConnection {
    /// 底层网络连接，生产端点路径配置了 TLS 1.3。
    let connection: NWConnection
    /// 用于启动连接及接收网络回调的队列。
    private let queue: DispatchQueue
    /// 按端点创建仅允许 TLS 1.3 的 TCP 连接，使用平台默认信任验证与 utility 队列；不立即启动连接。
    init(endpoint: V2RealtimeEndpoint) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        let parameters = NWParameters(tls: tls, tcp: .init())
        connection = NWConnection(host: .init(endpoint.host), port: .init(rawValue: endpoint.port)!, using: parameters)
        queue = .global(qos: .utility)
    }
    // Internal byte-boundary injection for Network.framework callback tests.
    // The public endpoint initializer above always configures validated TLS.
    /// 注入已配置的连接与队列以支持回调测试；此初始化方法不重新配置 TLS 或验证其参数。
    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }
    /// 启动连接并等待 ready，failed 或 cancelled 映射为 connectionFailed。
    ///
    /// 使用互斥保护的可选 continuation 保证完成一次；已排队的后续状态回调不能重复恢复等待者。
    /// waiting 等中间状态继续等待，本层不设置启动超时。
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pending = Mutex<CheckedContinuation<Void, Error>?>(continuation)
            connection.stateUpdateHandler = { state in
                let result: Result<Void, Error>
                switch state {
                case .ready: result = .success(())
                case .failed, .cancelled: result = .failure(V2TLSFrameConnectionError.connectionFailed)
                default: return
                }
                // Framework state callbacks can already be queued when the
                // handler is cleared. Complete this readiness bridge once.
                let waiter = pending.withLock { value in
                    let waiter = value
                    value = nil
                    return waiter
                }
                connection.stateUpdateHandler = nil
                waiter?.resume(with: result)
            }
            connection.start(queue: queue)
        }
    }
    /// 等待 contentProcessed 回调，非空错误映射为 connectionFailed。
    ///
    /// 成功仅表示底层发送处理完成，不表示对端应用收到或事务提交。Task 取消本身不会在本方法中主动取消网络连接。
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: V2TLSFrameConnectionError.connectionFailed) }
            })
        }
    }
    /// 请求至少一个、不超过上限的字节片段。
    ///
    /// - Parameter maximumLength: 交给 Network.framework 的读取上限，此处不另行验证。
    /// - Returns: 非空字节片段；分帧与跨读取缓冲由上层处理。
    /// - Throws: 回调错误映射为 connectionFailed，无错误但没有非空字节时映射为 connectionClosed。
    ///
    /// 若回调同时标记流结束并带有字节，此方法仍先返回字节，不独立报告结束标志。
    func receive(maximumLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { bytes, _, _, error in
                if error != nil { continuation.resume(throwing: V2TLSFrameConnectionError.connectionFailed) }
                else if let bytes, !bytes.isEmpty { continuation.resume(returning: bytes) }
                else { continuation.resume(throwing: V2TLSFrameConnectionError.connectionClosed) }
            }
        }
    }
    /// 调用底层连接取消，不等待取消回调，也不直接处理上层请求关联状态。
    func cancel() { connection.cancel() }
}

/// Apple 平台的已认证 TLS 帧连接，拥有请求关联、读取任务与提示缓冲。
///
/// 连接工厂的生产实现使用 TLS 1.3 和平台信任校验，网络进入 `.ready` 后才发送握手。
/// 每轮连接持有独立代际与接收缓冲，异步操作恢复时核对代际，防止旧回调影响替换连接。
public actor V2TLSFrameConnection: V2AuthenticatedFrameTransport, V2SyncAvailabilityHintSource, V2GroupEventAvailabilityHintSource, V2AccountRoomChangeSource, V2LiveActivityEventSource, V2AuthorPresentationSource, V2RealtimeConnection {
    /// 每代创建新字节连接的工厂。
    private let connectionFactory: @Sendable () -> any V2TLSByteConnection
    /// 当前连接允许占用的在途关联槽位上限。
    private let maximumPendingRequests: Int
    /// 帧与缓冲预算。
    private let limits: V2FrameLimits
    /// 握手及运行期 protobuf 解码深度上限。
    private let maximumProtobufMessageDepth: Int
    /// 连接启动与单请求等待的独立期限。
    private let requestTimeout: Duration
    /// 仅在连接 actor 内使用的单代接收缓冲。
    ///
    /// 挂起读取持有自身代际的对象，替换连接会使用新对象，旧字节不能追加到新的解码器。
    private final class InboundState {
        /// 此缓冲所属的连接代际。
        let generation: UUID
        /// 处理分片与拼接的增量帧解码器。
        var decoder: V2FrameDecoder
        /// 已拆出但尚未交付的同代帧。
        var frames: [V2Frame] = []
        /// 创建指定代际的独立解码器，使用连接帧预算。
        init(generation: UUID, limits: V2FrameLimits) {
            self.generation = generation
            decoder = .init(limits: limits)
        }
    }
    /// 当前连接的增量缓冲对象，断开时分离。
    private var inboundState: InboundState?
    /// 当前底层字节连接。
    private var connection: (any V2TLSByteConnection)?
    /// 当前连接代际，关闭前先清空以阻止旧回调。
    private var connectionID: UUID?
    /// 认证成功后才设置的协商版本。
    private var authenticatedVersion: UInt8?
    /// 握手选定的压缩方式，关闭时清空。
    private var negotiatedFrameCompression: V2NegotiatedFrameCompression?
    private let supportsAuthorPresentationDelta: Bool
    private var authorPresentationInbox: V2AuthorPresentationInbox?
    private var authorPresentationWaiter: Waiter<V2ReceivedAuthorPresentationDelta>?
    /// 关联请求的内部身份、可选等待者及发送和超时任务。
    private struct PendingResponse {
        /// 区分相同请求号不同生命周期的内部身份。
        let id: UUID
        let command: V2FrameCommand
        let authorView: V2AuthorPresentationView?
        /// 调用者等待句柄；nil 表示调用者已取消但线上请求仍占位。
        var continuation: CheckedContinuation<V2Frame, Error>?
        /// 独立超时任务，取消等待者后仍保留。
        let deadline: Task<Void, Never>
        /// 底层发送任务，由响应清理或连接关闭结束其所有权。
        let sendTask: Task<Void, Never>
    }
    /// 带内部身份的单次提示等待句柄，供取消回调核对并避免误取消后来的等待。
    private struct Waiter<Value: Sendable> {
        /// 单次等待的唯一身份。
        let id: UUID
        /// 交付事件或错误的 continuation。
        let continuation: CheckedContinuation<Value, Error>
        /// 用事件恢复等待者；调用方必须先移除持有引用以保证只完成一次。
        func resume(returning value: Value) { continuation.resume(returning: value) }
        /// 用错误恢复等待者；一次性完成由持有此值的 actor 状态保证。
        func resume(throwing error: any Error) { continuation.resume(throwing: error) }
    }
    // A nil continuation means cancelledOnWire. Its deadline and capacity
    // slot remain owned by this connection until the reply or generation close.
    /// 按协议请求号保存关联记录，包括 continuation 已清空的取消请求；这些记录仍占用容量。
    private var responseWaiters: [UInt64: PendingResponse] = [:]
    private var accountRoomInbox = V2AccountRoomChangeInbox()
    private var accountRoomWaiter: Waiter<V2AccountRoomChange>?
    /// 唯一用户同步提示等待者。
    private var availabilityWaiter: Waiter<V2SyncAvailabilityHint>?
    /// 待消费的用户同步提示，保留较高水位。
    private var pendingAvailabilityHint: V2SyncAvailabilityHint?
    /// 唯一房间提示等待者。
    private var groupEventAvailabilityWaiter: Waiter<V2GroupEventAvailabilityHint>?
    /// 合并后的待消费房间提示。
    private var pendingGroupEventAvailabilityHint: V2GroupEventAvailabilityHint?
    /// 唯一活动事件等待者。
    private var liveActivityWaiter: Waiter<V2LiveActivityEvent>?
    /// 待消费的活动事件队列，最多保留最新 16 项。
    private var pendingLiveActivityEvents: [V2LiveActivityEvent] = []
    /// 当前代际的常驻读取任务。
    private var readerTask: Task<Void, Never>?

    /// 配置生产 TLS 连接，不立即建立网络会话。
    ///
    /// - Parameters:
    ///   - endpoint: 主机和非零端口。
    ///   - frameLimits: 帧及接收缓冲预算。
    ///   - maximumProtobufMessageDepth: 正的 protobuf 嵌套深度上限。
    ///   - requestTimeout: 正的连接或单次请求超时，默认 20 秒，不是整个多阶段握手的总预算。
    ///   - maximumPendingRequests: 正的在途请求上限，默认 256。
    ///   - supportsAuthorPresentationDelta: 前台所有者负责 nonce 续期及展示消费后才启用，默认关闭。
    ///
    /// 非法深度、超时或请求上限触发前置条件失败。
    public init(
        endpoint: V2RealtimeEndpoint,
        frameLimits: V2FrameLimits,
        maximumProtobufMessageDepth: Int = V2ProtobufFrameCodec.defaultMaximumMessageDepth,
        requestTimeout: Duration = .seconds(20),
        maximumPendingRequests: Int = 256,
        supportsAuthorPresentationDelta: Bool = false
    ) {
        precondition(maximumProtobufMessageDepth > 0)
        self.connectionFactory = { V2NetworkTLSByteConnection(endpoint: endpoint) }
        precondition(maximumPendingRequests > 0 && requestTimeout > .zero)
        self.maximumPendingRequests = maximumPendingRequests
        self.supportsAuthorPresentationDelta = supportsAuthorPresentationDelta
        self.limits = frameLimits
        self.maximumProtobufMessageDepth = maximumProtobufMessageDepth
        self.requestTimeout = requestTimeout
    }

    /// 注入可控字节连接以测试网络生命周期；使用默认 protobuf 深度，超时与在途上限必须为正。
    init(
        connectionFactory: @escaping @Sendable () -> any V2TLSByteConnection,
        frameLimits: V2FrameLimits,
        requestTimeout: Duration = .seconds(20),
        maximumPendingRequests: Int = 256,
        supportsAuthorPresentationDelta: Bool = false
    ) {
        precondition(maximumPendingRequests > 0 && requestTimeout > .zero)
        self.connectionFactory = connectionFactory
        self.maximumPendingRequests = maximumPendingRequests
        self.supportsAuthorPresentationDelta = supportsAuthorPresentationDelta
        limits = frameLimits
        maximumProtobufMessageDepth = V2ProtobufFrameCodec.defaultMaximumMessageDepth
        self.requestTimeout = requestTimeout
    }

    /// 建立新连接，协商当前协议版本并认证设备。
    ///
    /// - Parameters:
    ///   - accessToken: 非空访问令牌。
    ///   - deviceID: 握手和认证均使用的设备身份。
    ///   - supportedCapabilityProfiles: 非空的可接受能力集合，握手按排序后发送。
    /// - Returns: 通过设备、能力配置和压缩回显校验的身份及连接代际。
    /// - Throws: 输入无效、已有连接、网络、协商、认证或取消错误。
    ///
    /// 握手只提供当前协议版本并声明支持 zlib；认证响应必须重复相同的设备与协商结果。
    /// 用户身份由响应构造，上层仍需与账户上下文核对。认证完成后才启动常驻读取任务。
    /// 异常会按本次代际关闭连接，不清理已经替换的新连接。
    public func connectAndAuthenticate(accessToken: String, deviceID: DeviceID, supportedCapabilityProfiles: Set<String>) async throws -> V2AuthenticatedClientSession {
        guard !accessToken.isEmpty, !supportedCapabilityProfiles.isEmpty else { throw V2TLSFrameConnectionError.authenticationFailed }
        guard connection == nil else { throw V2TLSFrameConnectionError.connectionFailed }
        let generation = UUID()
        do {
            try await connect(generation: generation)
            var hello = IMV2Envelope()
            hello.requestID = 1
            hello.clientHello = .init()
            hello.clientHello.supportedProtocolVersions = [UInt32(IMV2ProtocolVersion.current)]
            hello.clientHello.supportedCapabilityProfiles = Array(supportedCapabilityProfiles).sorted()
            hello.clientHello.deviceID = deviceID.rawValue
            hello.clientHello.supportedFrameCompressions = [.zlib]
            hello.clientHello.supportsAuthorPresentationDelta = supportsAuthorPresentationDelta
            let helloResponse = try await sendBootstrap(hello, version: 0, generation: generation)
            guard case .serverHello(let serverHello)? = helloResponse.body,
                  let version = UInt8(exactly: serverHello.selectedProtocolVersion),
                  version == UInt8(IMV2ProtocolVersion.current),
                  supportedCapabilityProfiles.contains(serverHello.selectedCapabilityProfile)
            else { throw V2TLSFrameConnectionError.unsupportedVersion }
            try requireGeneration(generation)
            switch serverHello.selectedFrameCompression {
            case .unspecified:
                negotiatedFrameCompression = nil
            case .zlib:
                negotiatedFrameCompression = .zlib
            case .UNRECOGNIZED:
                throw V2TLSFrameConnectionError.unsupportedCompression
            }

            let authorStreamID: UUID?
            if serverHello.authorPresentationStreamID.isEmpty {
                authorStreamID = nil
            } else {
                guard supportsAuthorPresentationDelta, version >= 31,
                      let streamID = UUID(uuidString: serverHello.authorPresentationStreamID) else {
                    throw V2TLSFrameConnectionError.invalidHandshake
                }
                authorStreamID = streamID
            }

            var authenticate = IMV2Envelope()
            authenticate.requestID = 2
            authenticate.protocolVersion = UInt32(version)
            authenticate.authenticate = .init()
            authenticate.authenticate.accessToken = accessToken
            authenticate.authenticate.deviceID = deviceID.rawValue
            let authenticated = try await sendBootstrap(authenticate, version: version, generation: generation)
            guard case .authenticated(let response)? = authenticated.body,
                  response.deviceID == deviceID.rawValue,
                  response.selectedCapabilityProfile == serverHello.selectedCapabilityProfile,
                  response.selectedFrameCompression == serverHello.selectedFrameCompression,
                  response.authorPresentationStreamID == serverHello.authorPresentationStreamID,
                  let userID = try? UserID(response.userID)
            else { throw V2TLSFrameConnectionError.authenticationFailed }
            try requireGeneration(generation)
            authenticatedVersion = version
            if let authorStreamID {
                guard userID.uuidValue != nil, deviceID.uuidValue != nil else { throw V2TLSFrameConnectionError.invalidHandshake }
                authorPresentationInbox = .init(streamID: authorStreamID, actorUserID: userID, deviceID: deviceID)
            }
            guard let connection else { throw V2TLSFrameConnectionError.connectionClosed }
            startReader(connection, generation: generation)
            return .init(
                userID: userID,
                deviceID: deviceID,
                protocolVersion: version,
                capabilityProfile: response.selectedCapabilityProfile,
                frameCompression: negotiatedFrameCompression,
                connectionID: generation,
                authorPresentationStreamID: authorStreamID
            )
        } catch {
            closeTransport(error: error, expectedGeneration: generation)
            throw error
        }
    }

    /// 要求已认证且帧版本匹配后发送关联请求；请求预算、取消及超时由内部关联流程处理，失败通过错误报告。
    public func request(_ frame: V2Frame) async throws -> V2Frame {
        guard let version = authenticatedVersion, frame.version == version else { throw V2TLSFrameConnectionError.notConnected }
        return try await sendAndAwaitResponse(frame)
    }

    public func beginAuthorPresentationView(roomID: RoomID) throws -> V2AuthorPresentationView {
        try Task.checkCancellation()
        try requireAuthorPresentationConnection()
        guard let view = try authorPresentationInbox?.begin(roomID: roomID) else { throw V2TLSFrameConnectionError.notConnected }
        authorPresentationWaiter?.resume(throwing: V2ProfilePresentationError.inactive)
        authorPresentationWaiter = nil
        return view
    }

    public func endAuthorPresentationView(_ view: V2AuthorPresentationView) {
        guard authorPresentationInbox?.view == view else { return }
        authorPresentationInbox?.end(view)
        authorPresentationWaiter?.resume(throwing: V2ProfilePresentationError.inactive)
        authorPresentationWaiter = nil
    }

    public func nextAuthorPresentationDelta(for view: V2AuthorPresentationView) async throws -> V2ReceivedAuthorPresentationDelta {
        try Task.checkCancellation()
        try requireAuthorPresentationConnection()
        guard authorPresentationInbox != nil else { throw V2TLSFrameConnectionError.notConnected }
        if let value = try authorPresentationInbox?.next(for: view) { return value }
        let id = UUID(), generation = connectionID
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard authorPresentationWaiter == nil else {
                    continuation.resume(throwing: V2TLSFrameConnectionError.concurrentAvailabilityConsumer); return
                }
                authorPresentationWaiter = .init(id: id, continuation: continuation)
            }
        }, onCancel: { Task { await self.cancelAuthorPresentationWait(id: id, generation: generation) } })
    }

    private func requireAuthorPresentationConnection() throws {
        if let expected = V2ConnectionRequestScope.connectionID, expected != connectionID {
            throw V2TLSFrameConnectionError.connectionClosed
        }
        guard authenticatedVersion != nil, connection != nil else { throw V2TLSFrameConnectionError.notConnected }
    }

    private func cancelAuthorPresentationWait(id: UUID, generation: UUID?) {
        guard connectionID == generation, authorPresentationWaiter?.id == id else { return }
        authorPresentationWaiter?.resume(throwing: CancellationError()); authorPresentationWaiter = nil
    }

    /// 等待用户同步提示，优先消费已合并的缓存并清空该缓存。
    ///
    /// - Returns: 当前连接的下一次提示或事件，不代表可靠投影已经更新。
    /// - Throws: 已取消、任务绑定的连接代际不匹配、未连接或同类已有等待者时抛出错误。
    ///
    /// 没有缓存时登记一个带身份与代际的等待者；取消只移除匹配的等待，不断开整个连接。
    /// 单消费者检查发生在登记等待时，调用方仍需保持只有一个长期消费循环。
    public func nextAvailabilityHint() async throws -> V2SyncAvailabilityHint {
        try Task.checkCancellation()
        if let expected = V2ConnectionRequestScope.connectionID, expected != connectionID {
            throw V2TLSFrameConnectionError.connectionClosed
        }
        guard authenticatedVersion != nil, connection != nil else { throw V2TLSFrameConnectionError.notConnected }
        if let pendingAvailabilityHint {
            self.pendingAvailabilityHint = nil
            return pendingAvailabilityHint
        }
        let waiterID = UUID()
        let generation = connectionID
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard availabilityWaiter == nil else {
                    continuation.resume(throwing: V2TLSFrameConnectionError.concurrentAvailabilityConsumer)
                    return
                }
                availabilityWaiter = .init(id: waiterID, continuation: continuation)
            }
        }, onCancel: {
            Task { await self.cancelAvailabilityWait(id: waiterID, generation: generation) }
        })
    }

    /// 等待临时活动事件，优先从有界队列头部取出最早尚未消费的一项。
    ///
    /// - Returns: 当前连接的下一次提示或事件，不代表可靠投影已经更新。
    /// - Throws: 已取消、任务绑定的连接代际不匹配、未连接或同类已有等待者时抛出错误。
    ///
    /// 没有缓存时登记一个带身份与代际的等待者；取消只移除匹配的等待，不断开整个连接。
    /// 单消费者检查发生在登记等待时，调用方仍需保持只有一个长期消费循环。
    public func nextLiveActivityEvent() async throws -> V2LiveActivityEvent {
        try Task.checkCancellation()
        if let expected = V2ConnectionRequestScope.connectionID, expected != connectionID {
            throw V2TLSFrameConnectionError.connectionClosed
        }
        guard authenticatedVersion != nil, connection != nil else { throw V2TLSFrameConnectionError.notConnected }
        if !pendingLiveActivityEvents.isEmpty { return pendingLiveActivityEvents.removeFirst() }
        let waiterID = UUID()
        let generation = connectionID
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard liveActivityWaiter == nil else {
                    continuation.resume(throwing: V2TLSFrameConnectionError.concurrentAvailabilityConsumer)
                    return
                }
                liveActivityWaiter = .init(id: waiterID, continuation: continuation)
            }
        }, onCancel: {
            Task { await self.cancelLiveActivityWait(id: waiterID, generation: generation) }
        })
    }

    /// 等待房间事件提示，优先消费已合并的房间缓存并清空该缓存。
    ///
    /// - Returns: 当前连接的下一次提示或事件，不代表可靠投影已经更新。
    /// - Throws: 已取消、任务绑定的连接代际不匹配、未连接或同类已有等待者时抛出错误。
    ///
    /// 没有缓存时登记一个带身份与代际的等待者；取消只移除匹配的等待，不断开整个连接。
    /// 单消费者检查发生在登记等待时，调用方仍需保持只有一个长期消费循环。
    public func nextGroupEventAvailabilityHint() async throws -> V2GroupEventAvailabilityHint {
        try Task.checkCancellation()
        if let expected = V2ConnectionRequestScope.connectionID, expected != connectionID {
            throw V2TLSFrameConnectionError.connectionClosed
        }
        guard authenticatedVersion != nil, connection != nil else { throw V2TLSFrameConnectionError.notConnected }
        if let pendingGroupEventAvailabilityHint {
            self.pendingGroupEventAvailabilityHint = nil
            return pendingGroupEventAvailabilityHint
        }
        let waiterID = UUID()
        let generation = connectionID
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard groupEventAvailabilityWaiter == nil else {
                    continuation.resume(throwing: V2TLSFrameConnectionError.concurrentAvailabilityConsumer)
                    return
                }
                groupEventAvailabilityWaiter = .init(id: waiterID, continuation: continuation)
            }
        }, onCancel: {
            Task { await self.cancelGroupEventAvailabilityWait(id: waiterID, generation: generation) }
        })
    }

    public func nextAccountRoomChange() async throws -> V2AccountRoomChange {
        try Task.checkCancellation()
        if let expected = V2ConnectionRequestScope.connectionID, expected != connectionID {
            throw V2TLSFrameConnectionError.connectionClosed
        }
        guard authenticatedVersion != nil, connection != nil else { throw V2TLSFrameConnectionError.notConnected }
        guard accountRoomInbox.epoch != nil else { throw V2AccountRoomChangeError.notStarted }
        guard accountRoomWaiter == nil else { throw V2TLSFrameConnectionError.concurrentAvailabilityConsumer }
        if let value = accountRoomInbox.next() { return value }
        let id = UUID()
        let generation = connectionID
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                accountRoomWaiter = .init(id: id, continuation: continuation)
            }
        }, onCancel: {
            Task { await self.cancelAccountRoomWait(id: id, generation: generation) }
        })
    }

    private func cancelAccountRoomWait(id: UUID, generation: UUID?) {
        guard connectionID == generation, accountRoomWaiter?.id == id else { return }
        let waiter = accountRoomWaiter
        accountRoomWaiter = nil
        waiter?.resume(throwing: CancellationError())
    }

    private func deliverAccountRoomChange() {
        guard let waiter = accountRoomWaiter, let value = accountRoomInbox.next() else { return }
        accountRoomWaiter = nil
        waiter.resume(returning: value)
    }

    /// 先分离连接状态并请求取消，再等待捕获的读取与发送任务退出。
    ///
    /// 等待在清理函数之外进行，避免读取任务因失败关闭连接时等待自己。分离后新连接可以开始，
    /// 本次等待仅针对断开时捕获的旧任务，不等待后来创建的任务，也不删除凭证或本地数据。
    public func disconnect() async {
        let reader = readerTask
        let sends = responseWaiters.values.map(\.sendTask)
        closeTransport(error: V2TLSFrameConnectionError.connectionClosed)
        // State is already detached. Drain outside closeTransport so a reader
        // failure never waits for its own task and a replacement may proceed.
        await reader?.value
        for send in sends { await send.value }
    }

    /// 检查任务取消与连接代际，只有同代且仍有底层连接才允许继续；否则抛出连接关闭错误。
    private func requireGeneration(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard connectionID == generation, connection != nil else { throw V2TLSFrameConnectionError.connectionClosed }
    }

    /// 建立独立接收缓冲并启动字节连接，与超时任务竞争。
    ///
    /// 超时或调用取消会取消底层连接，以使 continuation 等待退出。任务组返回后再次核对代际，
    /// 不能把旧连接的成功回调当作当前连接已就绪。
    private func connect(generation: UUID) async throws {
        try Task.checkCancellation()
        let connection = connectionFactory()
        self.connection = connection
        connectionID = generation
        inboundState = .init(generation: generation, limits: limits)
        try await withTaskCancellationHandler(operation: {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await connection.start() }
                group.addTask { [requestTimeout] in
                    try await Task.sleep(for: requestTimeout)
                    connection.cancel()
                    throw V2TLSFrameConnectionError.requestTimedOut
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        }, onCancel: { connection.cancel() })
        try requireGeneration(generation)
    }

    /// 编码一次握手请求并解码响应，核对请求号；任何 error 消息体统一映射为 authenticationFailed，不保留具体业务错误代码。
    private func sendBootstrap(_ envelope: IMV2Envelope, version: UInt8, generation: UUID) async throws -> IMV2Envelope {
        let response = try await exchangeBootstrap(try V2ProtobufFrameCodec.encode(envelope, frameVersion: version), generation: generation)
        let decoded = try V2ProtobufFrameCodec.decode(response, maximumMessageDepth: maximumProtobufMessageDepth)
        guard decoded.requestID == envelope.requestID else { throw V2TLSFrameConnectionError.unexpectedResponse }
        if case .error = decoded.body { throw V2TLSFrameConnectionError.authenticationFailed }
        return decoded
    }

    /// 执行带独立超时的单次握手交换；超时先按代际关闭底层连接以唤醒挂起读取，再传播错误。
    private func exchangeBootstrap(_ frame: V2Frame, generation: UUID) async throws -> V2Frame {
        do {
            return try await withThrowingTaskGroup(of: V2Frame.self) { group in
                group.addTask { [self] in
                    try await exchangeBootstrapWithoutDeadline(frame, generation: generation)
                }
                group.addTask { [requestTimeout, weak self] in
                    try await Task.sleep(for: requestTimeout)
                    // `nextFrame` is continuation-based. Closing transport
                    // is what makes its pending receive complete promptly.
                    await self?.closeTransport(error: V2TLSFrameConnectionError.requestTimedOut, expectedGeneration: generation)
                    throw V2TLSFrameConnectionError.requestTimedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw V2TLSFrameConnectionError.connectionFailed
                }
                return result
            }
        } catch let error as V2TLSFrameConnectionError where error == .requestTimedOut {
            closeTransport(error: error, expectedGeneration: generation)
            throw error
        }
    }

    /// 发送并读取本次握手响应，跨发送和读取检查代际；只接受无标志且请求号匹配的帧，不把其他帧当作异步通知。
    private func exchangeBootstrapWithoutDeadline(_ frame: V2Frame, generation: UUID) async throws -> V2Frame {
        guard let connection else { throw V2TLSFrameConnectionError.notConnected }
        try requireGeneration(generation)
        try await send(frame, on: connection)
        try requireGeneration(generation)
        while true {
            let response = try await nextFrame(connection: connection, generation: generation)
            guard response.flags.isEmpty else { throw V2TLSFrameConnectionError.unsupportedFrameFlags }
            if response.requestID == frame.requestID { return response }
            throw V2TLSFrameConnectionError.unexpectedResponse
        }
    }

    /// 为已认证请求建立关联槽位、发送任务和独立超时任务。
    ///
    /// 检查任务绑定的连接代际、非零且未占用请求号及容量预算，登记后等待响应。
    /// 调用者取消只结束其等待，发送任务、请求号与容量仍保留到响应返回或连接关闭，避免晚到响应误配新请求。
    /// 请求发送失败或超时会关闭整条同代连接，而不是只回收单个请求号。
    private func sendAndAwaitResponse(_ frame: V2Frame) async throws -> V2Frame {
        guard let connection, let generation = connectionID else { throw V2TLSFrameConnectionError.notConnected }
        if let expected = V2ConnectionRequestScope.connectionID, expected != generation {
            throw V2TLSFrameConnectionError.connectionClosed
        }
        try Task.checkCancellation()
        let bytes = try V2FrameCodec.encode(frame, limits: limits)
        if frame.command == .authorPresentationEnd {
            let ending = try V2ProtobufFrameCodec.decode(frame).authorPresentationEnd
            guard let inbox = authorPresentationInbox,
                  UUID(uuidString: ending.streamID) == inbox.streamID,
                  UUID(uuidString: ending.viewID) != nil, UUID(uuidString: ending.roomID) != nil else {
                throw V2TLSFrameConnectionError.unexpectedResponse
            }
            // Cancellation can release the subscribe caller before its socket
            // write completes. Retain that operation and order cleanup after it,
            // so the old subscribe cannot arrive after its matching stop.
            let sends = responseWaiters.values.filter {
                $0.authorView?.viewID == UUID(uuidString: ending.viewID)
                    && $0.authorView?.streamID == inbox.streamID
                    && $0.authorView?.roomID == (try? RoomID(ending.roomID))
            }.map(\.sendTask)
            for send in sends { await send.value }
            try requireGeneration(generation)
            try Task.checkCancellation()
        }
        var authorView: V2AuthorPresentationView?
        if frame.command == .groupEventSubscribe {
            let envelope = try V2ProtobufFrameCodec.decode(frame)
            let request = envelope.groupEventSubscribe
            if !request.authorPresentationViewID.isEmpty {
                guard let inbox = authorPresentationInbox else { throw V2TLSFrameConnectionError.unexpectedResponse }
                authorView = try inbox.requestedView(request)
            } else if let current = authorPresentationInbox?.view,
                      (try? RoomID(request.roomID)) == current.roomID {
                endAuthorPresentationView(current)
            }
        } else if frame.command == .groupEventUnsubscribe,
                  let current = authorPresentationInbox?.view {
            let envelope = try V2ProtobufFrameCodec.decode(frame)
            if (try? RoomID(envelope.groupEventUnsubscribe.roomID)) == current.roomID { endAuthorPresentationView(current) }
        }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard responseWaiters[frame.requestID] == nil, frame.requestID != 0 else {
                    continuation.resume(throwing: V2TLSFrameConnectionError.unexpectedResponse)
                    return
                }
                guard responseWaiters.count < maximumPendingRequests else {
                    continuation.resume(throwing: V2TLSFrameConnectionError.tooManyPendingRequests)
                    return
                }
                let deadline = Task { [weak self, requestTimeout] in
                    do { try await Task.sleep(for: requestTimeout) } catch { return }
                    await self?.expireRequest(frame.requestID, id: id, generation: generation)
                }
                let sendTask = Task { [weak self] in
                    do { try await connection.send(bytes) }
                    catch { await self?.failRequest(frame.requestID, id: id, generation: generation) }
                }
                responseWaiters[frame.requestID] = .init(id: id, command: frame.command, authorView: authorView, continuation: continuation, deadline: deadline, sendTask: sendTask)
            }
        }, onCancel: {
            Task { await self.cancelRequest(frame.requestID, id: id, generation: generation) }
        })
    }

    /// 编码并发送握手帧；调用取消时取消底层连接，以结束网络回调等待。此路径不创建已认证请求关联槽位。
    private func send(_ frame: V2Frame, on connection: any V2TLSByteConnection) async throws {
        let bytes = try V2FrameCodec.encode(frame, limits: limits)
        try await withTaskCancellationHandler(operation: {
            try await connection.send(bytes)
        }, onCancel: { connection.cancel() })
    }

    /// 取消旧读取任务并启动绑定指定连接代际的新读取循环；不在此等待旧任务完全退出。
    private func startReader(_ connection: any V2TLSByteConnection, generation: UUID) {
        readerTask?.cancel()
        readerTask = Task { await receiveLoop(connection: connection, generation: generation) }
    }

    /// 持续提取并分派同代入站帧。
    ///
    /// 取消错误由显式断开路径完成等待者清理；其他读取或分派错误统一按 connectionClosed 关闭对应代际。
    /// 旧循环不能清除后来替换的连接。
    private func receiveLoop(connection: any V2TLSByteConnection, generation: UUID) async {
        do {
            while !Task.isCancelled {
                let frame = try await nextFrame(connection: connection, generation: generation)
                try requireGeneration(generation)
                try acceptInbound(frame)
            }
        } catch is CancellationError {
            // Explicit disconnect owns continuation completion.
        } catch {
            closeTransport(error: V2TLSFrameConnectionError.connectionClosed, expectedGeneration: generation)
        }
    }

    /// 按请求号区分通知与关联响应并交付等待者。
    ///
    /// 零请求号只允许无标志通知，支持用户同步、房间事件、在线和输入状态；未知消息体抛出错误。
    /// 用户同步提示保留较高水位，房间提示使用有界合并，活动事件使用有限缓冲。
    /// 非零请求号要求已有关联项，移除后取消其发送和期限任务；已取消调用者的晚到响应只负责释放占位。
    /// 此时压缩标志已由前面的规范化步骤处理，请求号绑定标志留给上层 protobuf 解码验证。
    private func acceptInbound(_ frame: V2Frame) throws {
        if frame.requestID == 0 {
            guard frame.flags.isEmpty else {
                throw V2TLSFrameConnectionError.unsupportedFrameFlags
            }
            let envelope = try V2ProtobufFrameCodec.decode(frame, maximumMessageDepth: maximumProtobufMessageDepth)
            switch envelope.body {
            case .authorPresentationDelta(let delta):
                guard authorPresentationInbox != nil,
                      frame.payload.count <= V2AuthorPresentationDelta.maximumFrameBytes - V2Frame.headerLength else {
                    throw V2TLSFrameConnectionError.unexpectedResponse
                }
                try authorPresentationInbox?.accept(delta.payload)
                if let waiter = authorPresentationWaiter, let view = authorPresentationInbox?.view {
                    do {
                        if let value = try authorPresentationInbox?.next(for: view) {
                            authorPresentationWaiter = nil; waiter.resume(returning: value)
                        }
                    } catch V2ProfilePresentationError.inactive {
                        endAuthorPresentationView(view)
                    }
                }
            case .syncAvailable(let hint):
                let value = V2SyncAvailabilityHint(eventID: hint.eventID, highWatermark: hint.highWatermark)
                if let availabilityWaiter {
                    self.availabilityWaiter = nil
                    availabilityWaiter.resume(returning: value)
                } else if pendingAvailabilityHint == nil || value.highWatermark >= pendingAvailabilityHint!.highWatermark {
                    pendingAvailabilityHint = value
                }
            case .groupEventAvailable(let hint):
                let value = try V2GroupEventAvailabilityHint(
                    roomID: .init(hint.roomID),
                    highWatermark: hint.highWatermark,
                    liveEvents: Self.liveGroupEvents(from: hint)
                )
                if let groupEventAvailabilityWaiter {
                    self.groupEventAvailabilityWaiter = nil
                    groupEventAvailabilityWaiter.resume(returning: value)
                } else if let pendingGroupEventAvailabilityHint {
                    self.pendingGroupEventAvailabilityHint = pendingGroupEventAvailabilityHint
                        .coalescing(with: value)
                } else {
                    pendingGroupEventAvailabilityHint = value
                }
            case .accountRoomChanged(let change):
                try accountRoomInbox.accept(change)
                deliverAccountRoomChange()
            case .accountRoomResyncRequired(let reset):
                try accountRoomInbox.accept(reset)
                deliverAccountRoomChange()
            case .presenceChanged(let state):
                let value = try V2LiveActivityEvent.presence(.init(roomID: .init(state.roomID), targetUserID: .init(state.targetUserID), isOnline: state.isOnline, expiresAt: Date(timeIntervalSince1970: TimeInterval(state.expiresAtMs) / 1_000)))
                acceptLiveActivityEvent(value)
            case .typingStateChanged(let state):
                let value = try V2LiveActivityEvent.typing(.init(roomID: .init(state.roomID), userID: .init(state.userID), isTyping: state.isTyping, expiresAt: Date(timeIntervalSince1970: TimeInterval(state.expiresAtMs) / 1_000)))
                acceptLiveActivityEvent(value)
            default:
                throw V2TLSFrameConnectionError.unexpectedResponse
            }
            return
        }
        guard frame.flags.isEmpty || frame.flags == [.headerBoundRequestID] else {
            throw V2TLSFrameConnectionError.unsupportedFrameFlags
        }
        guard let waiter = responseWaiters[frame.requestID] else {
            throw V2TLSFrameConnectionError.unexpectedResponse
        }
        if waiter.command == .groupEventSubscribe {
            let envelope = try V2ProtobufFrameCodec.decode(frame, maximumMessageDepth: maximumProtobufMessageDepth)
            switch envelope.body {
            case .groupEventSubscribed(let response):
                if let view = waiter.authorView {
                    // Install before a delta coalesced in this same socket read.
                    if waiter.continuation != nil { try authorPresentationInbox?.confirm(view, response: response) }
                } else if !response.authorPresentationViewID.isEmpty {
                    throw V2TLSFrameConnectionError.unexpectedResponse
                }
            case .error:
                if let view = waiter.authorView { endAuthorPresentationView(view) }
            default: throw V2TLSFrameConnectionError.unexpectedResponse
            }
        }
        if waiter.command == .accountRoomChangesStart {
            let envelope = try V2ProtobufFrameCodec.decode(frame, maximumMessageDepth: maximumProtobufMessageDepth)
            switch envelope.body {
            case .accountRoomChangesReady(let ready):
                // Install before resuming the caller: the next frame may already
                // be buffered in this same read, ahead of its consumer task.
                guard waiter.continuation != nil else { throw V2TLSFrameConnectionError.connectionClosed }
                try accountRoomInbox.begin(epoch: ready.connectionEpoch)
            case .error: break
            default: throw V2TLSFrameConnectionError.unexpectedResponse
            }
        }
        responseWaiters.removeValue(forKey: frame.requestID)
        waiter.deadline.cancel()
        waiter.sendTask.cancel()
        waiter.continuation?.resume(returning: frame)
    }

    /// 从可选加速载荷提取连续事件批次，失败时返回空数组而不使连接报错。
    ///
    /// 群批量字段要求所有事件可构造、相邻序列连续且尾序列等于提示高水位。
    /// 没有批量字段时读取私聊单事件字段，要求其序列等于提示高水位。
    /// 无效加速内容降级为普通唤醒，由可靠日志补拉恢复。
    static func liveGroupEvents(from hint: IMV2GroupEventAvailable) -> [V2ClientGroupEvent] {
        if !hint.liveEvents.isEmpty {
            let events = hint.liveEvents.compactMap(Self.liveGroupEvent(from:))
            guard events.count == hint.liveEvents.count,
                  events.last?.roomSequence == hint.highWatermark,
                  zip(events, events.dropFirst()).allSatisfy({
                      $1.roomSequence == $0.roomSequence + 1
                  })
            else { return [] }
            return events
        }
        guard hint.roomSequence == hint.highWatermark else { return [] }
        return Self.liveGroupEvent(
            sourceEventID: hint.sourceEventID,
            roomSequence: hint.roomSequence,
            projectionKind: hint.projectionKind,
            payload: hint.eventPayload
        ).map { [$0] } ?? []
    }

    /// 把单个 protobuf 群事件委托给可失败的加速事件构造；不解析业务投影载荷。
    private static func liveGroupEvent(from event: IMV2GroupEvent) -> V2ClientGroupEvent? {
        liveGroupEvent(
            sourceEventID: event.sourceEventID,
            roomSequence: event.roomSequence,
            projectionKind: event.projectionKind,
            payload: event.payload
        )
    }

    /// 验证加速事件源身份、正序列、非空类型与载荷，并尝试构造领域事件。
    ///
    /// 类型只检查空字符串，不清理空白；失败返回 nil，不能据此推进持久化游标。
    private static func liveGroupEvent(
        sourceEventID: String,
        roomSequence: UInt64,
        projectionKind: String,
        payload: Data
    ) -> V2ClientGroupEvent? {
        guard !sourceEventID.isEmpty,
              roomSequence > 0,
              !projectionKind.isEmpty,
              !payload.isEmpty,
              let sourceEventID = try? EventID(sourceEventID)
        else { return nil }
        return try? .init(
            sourceEventID: sourceEventID,
            roomSequence: roomSequence,
            projectionKind: projectionKind,
            payload: payload
        )
    }

    /// 仅当请求内部身份与连接代际仍匹配时，把发送失败升级为整连接失败并结束等待者。
    private func failRequest(_ requestID: UInt64, id: UUID, generation: UUID) {
        guard connectionID == generation, responseWaiters[requestID]?.id == id else { return }
        closeTransport(error: V2TLSFrameConnectionError.connectionFailed, expectedGeneration: generation)
    }

    /// 请求超时后关闭同代连接，包括调用者已取消但仍在线上的请求。
    ///
    /// 不能在旧响应仍可能到达的同一字节流上回收超时请求号。
    private func expireRequest(_ requestID: UInt64, id: UUID, generation: UUID) {
        guard connectionID == generation, responseWaiters[requestID]?.id == id else { return }
        // Includes cancelledOnWire entries. Never recycle an expired request
        // ID while the same stream can still deliver its old response.
        closeTransport(error: V2TLSFrameConnectionError.requestTimedOut, expectedGeneration: generation)
    }

    /// 以取消错误恢复匹配请求的调用者，并将 continuation 清空。
    ///
    /// 不删除关联项、不取消发送任务或期限，不立即释放在途容量；晚到响应或连接关闭负责最终清理。
    private func cancelRequest(_ requestID: UInt64, id: UUID, generation: UUID) {
        guard connectionID == generation, responseWaiters[requestID]?.id == id else { return }
        let continuation = responseWaiters[requestID]?.continuation
        responseWaiters[requestID]?.continuation = nil
        if let view = responseWaiters[requestID]?.authorView { endAuthorPresentationView(view) }
        continuation?.resume(throwing: CancellationError())
    }

    /// 仅取消指定连接代际和身份的用户同步提示等待，不影响其他消费者或新连接。
    private func cancelAvailabilityWait(id: UUID, generation: UUID?) {
        guard connectionID == generation, availabilityWaiter?.id == id else { return }
        availabilityWaiter?.resume(throwing: CancellationError())
        availabilityWaiter = nil
    }

    /// 仅取消指定连接代际和身份的房间提示等待。
    private func cancelGroupEventAvailabilityWait(id: UUID, generation: UUID?) {
        guard connectionID == generation, groupEventAvailabilityWaiter?.id == id else { return }
        groupEventAvailabilityWaiter?.resume(throwing: CancellationError())
        groupEventAvailabilityWaiter = nil
    }

    /// 仅取消指定连接代际和身份的活动事件等待。
    private func cancelLiveActivityWait(id: UUID, generation: UUID?) {
        guard connectionID == generation, liveActivityWaiter?.id == id else { return }
        liveActivityWaiter?.resume(throwing: CancellationError())
        liveActivityWaiter = nil
    }

    /// 优先直接恢复活动事件等待者，否则追加到最多 16 项的缓冲；超限丢弃最旧项，体现活动提示可丢失语义。
    private func acceptLiveActivityEvent(_ event: V2LiveActivityEvent) {
        if let liveActivityWaiter {
            self.liveActivityWaiter = nil
            liveActivityWaiter.resume(returning: event)
        } else {
            pendingLiveActivityEvents.append(event)
            if pendingLiveActivityEvents.count > 16 { pendingLiveActivityEvents.removeFirst(pendingLiveActivityEvents.count - 16) }
        }
    }

    /// 按可选预期代际断开状态、取消任务并恢复所有等待者。
    ///
    /// 先清空连接代际再取消 socket，防止旧工作影响替换连接；清除认证、压缩和提示缓冲，
    /// 取消请求超时与发送任务，用指定错误结束尚在等待的请求。此方法不等待任务退出，显式 disconnect 另行排空。
    private func closeTransport(error: Error, expectedGeneration: UUID? = nil) {
        if let expectedGeneration, connectionID != expectedGeneration { return }
        // Fence callbacks before cancelling their socket/tasks. Old work may
        // finish later, but cannot observe or clear a replacement generation.
        connectionID = nil
        readerTask?.cancel()
        readerTask = nil
        connection?.cancel()
        connection = nil
        authenticatedVersion = nil
        negotiatedFrameCompression = nil
        inboundState = nil
        let waiters = responseWaiters.values
        responseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.deadline.cancel()
            waiter.sendTask.cancel()
            waiter.continuation?.resume(throwing: error)
        }
        availabilityWaiter?.resume(throwing: error)
        availabilityWaiter = nil
        pendingAvailabilityHint = nil
        groupEventAvailabilityWaiter?.resume(throwing: error)
        groupEventAvailabilityWaiter = nil
        pendingGroupEventAvailabilityHint = nil
        accountRoomWaiter?.resume(throwing: error)
        accountRoomWaiter = nil
        accountRoomInbox = .init()
        liveActivityWaiter?.resume(throwing: error)
        liveActivityWaiter = nil
        pendingLiveActivityEvents.removeAll(keepingCapacity: false)
        authorPresentationWaiter?.resume(throwing: error)
        authorPresentationWaiter = nil
        authorPresentationInbox = nil
    }

    /// 从指定代际独占的接收缓冲读取下一帧，并规范化压缩表示。
    ///
    /// 优先返回已拆出的帧；解码器还有缓存时先用空追加提取完整帧，再决定是否读取新字节。
    /// 网络等待返回后先核对代际，才把字节追加到捕获的旧缓冲，避免旧回调写入替换连接。
    /// 同批多余帧暂存在该代际对象内；帧格式、预算、取消或连接错误向上传播。
    private func nextFrame(connection: any V2TLSByteConnection, generation: UUID) async throws -> V2Frame {
        try requireGeneration(generation)
        guard let state = inboundState, state.generation == generation else {
            throw V2TLSFrameConnectionError.connectionClosed
        }
        if !state.frames.isEmpty { return try normalizeInboundFrame(state.frames.removeFirst()) }
        while true {
            let frames: [V2Frame]
            if state.decoder.hasBufferedBytes {
                let bufferedFrames = try state.decoder.append(Data())
                if bufferedFrames.isEmpty {
                    let chunk = try await receiveChunk(connection: connection)
                    try requireGeneration(generation)
                    frames = try state.decoder.append(chunk)
                } else {
                    frames = bufferedFrames
                }
            } else {
                let chunk = try await receiveChunk(connection: connection)
                try requireGeneration(generation)
                frames = try state.decoder.append(chunk)
            }
            if let first = frames.first {
                state.frames.append(contentsOf: frames.dropFirst())
                return try normalizeInboundFrame(first)
            }
        }
    }

    /// 按当前协商解压一次入站载荷，并移除 compressed 标志。
    ///
    /// 未知标志被拒绝；压缩帧要求已协商 zlib，使用连接载荷预算和默认扩展比上限。
    /// 解压失败统一映射为 unsupportedCompression。headerBoundRequestID 保留给上层验证与恢复请求号。
    /// 无标志帧直接返回，此方法不解析 protobuf 或检查业务授权。
    private func normalizeInboundFrame(_ frame: V2Frame) throws -> V2Frame {
        guard !frame.flags.isEmpty else { return frame }
        let knownFlags: V2FrameFlags = [.compressed, .headerBoundRequestID]
        guard frame.flags.subtracting(knownFlags).isEmpty else {
            throw V2TLSFrameConnectionError.unsupportedFrameFlags
        }
        guard frame.flags.contains(.compressed) else { return frame }
        guard negotiatedFrameCompression == .zlib else {
            if frame.flags.contains(.compressed) {
                throw V2TLSFrameConnectionError.unsupportedCompression
            }
            throw V2TLSFrameConnectionError.unsupportedFrameFlags
        }
        let payload: Data
        do {
            payload = try V2ZlibFrameCompression.decompress(
                frame.payload,
                maximumOutputBytes: limits.maximumPayloadBytes,
                maximumExpansionRatio: V2ZlibFrameCompression.defaultMaximumExpansionRatio
            )
        } catch {
            throw V2TLSFrameConnectionError.unsupportedCompression
        }
        return .init(
            version: frame.version,
            flags: frame.flags.subtracting(.compressed),
            command: frame.command,
            requestID: frame.requestID,
            payload: payload
        )
    }

    /// 读取最多一个最大载荷加帧头大小的字节片段；调用取消时取消底层连接，完成后由 nextFrame 核对代际。
    private func receiveChunk(connection: any V2TLSByteConnection) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await connection.receive(maximumLength: limits.maximumPayloadBytes + V2Frame.headerLength)
        }, onCancel: { connection.cancel() })
    }

}
#else
/// 缺少 Apple Network 或 Security 框架时的占位连接实现。
///
/// 保留纯协议与持久化测试所需的接口，所有网络操作明确报告未连接，不降级到非 TLS 传输。
public actor V2TLSFrameConnection: V2AuthenticatedFrameTransport, V2SyncAvailabilityHintSource, V2GroupEventAvailabilityHintSource, V2AccountRoomChangeSource, V2AuthorPresentationSource, V2RealtimeConnection {
    /// 创建占位实现，只检查 protobuf 深度为正，不创建 socket 或保存端点配置。
    public init(
        endpoint _: V2RealtimeEndpoint,
        frameLimits _: V2FrameLimits,
        maximumProtobufMessageDepth: Int = V2ProtobufFrameCodec.defaultMaximumMessageDepth,
        supportsAuthorPresentationDelta _: Bool = false
    ) {
        precondition(maximumProtobufMessageDepth > 0)
    }

    /// 此平台不提供生产 TLS 连接，始终抛出 notConnected。
    public func connectAndAuthenticate(accessToken _: String, deviceID _: DeviceID, supportedCapabilityProfiles _: Set<String>) async throws -> V2AuthenticatedClientSession {
        throw V2TLSFrameConnectionError.notConnected
    }

    /// 占位实现不发送帧，始终抛出 notConnected。
    public func request(_: V2Frame) async throws -> V2Frame {
        throw V2TLSFrameConnectionError.notConnected
    }

    /// 占位实现没有用户同步提示来源，始终抛出 notConnected。
    public func nextAvailabilityHint() async throws -> V2SyncAvailabilityHint {
        throw V2TLSFrameConnectionError.notConnected
    }

    /// 占位实现没有房间事件提示来源，始终抛出 notConnected。
    public func nextGroupEventAvailabilityHint() async throws -> V2GroupEventAvailabilityHint {
        throw V2TLSFrameConnectionError.notConnected
    }

    public func nextAccountRoomChange() async throws -> V2AccountRoomChange {
        throw V2TLSFrameConnectionError.notConnected
    }

    public func beginAuthorPresentationView(roomID: RoomID) throws -> V2AuthorPresentationView { throw V2TLSFrameConnectionError.notConnected }
    public func endAuthorPresentationView(_ view: V2AuthorPresentationView) {}
    public func nextAuthorPresentationDelta(for view: V2AuthorPresentationView) throws -> V2ReceivedAuthorPresentationDelta { throw V2TLSFrameConnectionError.notConnected }

    /// 占位实现没有连接资源，断开为空操作。
    public func disconnect() {}
}
#endif
