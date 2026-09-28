import Foundation
import IMV2Compression
import IMV2Core

/// 认证适配器返回的可信用户身份与会话有效期。
///
/// 用户身份来自注入的认证边界，不能直接从未认证的 protobuf 载荷读取。构造此值本身不执行凭证校验。
public struct V2GatewayAuthentication: Equatable, Sendable {
    /// 认证后的用户身份。
    public let userID: UserID
    /// 会话失效时间；`nil` 仅供明确允许永不过期的适配器使用。
    public let expiresAt: Date?

    /// 保存一次认证读取的结果。
    ///
    /// - Parameters:
    ///   - userID: 经认证确定的用户。
    ///   - expiresAt: 同一次撤销一致性读取所得的期限，`nil` 表示适配器明确不设置期限。
    public init(userID: UserID, expiresAt: Date?) {
        self.userID = userID
        self.expiresAt = expiresAt
    }
}

/// Gateway 的认证依赖，负责将访问令牌和设备绑定转换为可信会话结果。
public protocol V2GatewayAuthenticator: Sendable {
    /// 认证访问令牌及其设备绑定。
    ///
    /// - Parameters:
    ///   - accessToken: 客户端提交的访问令牌，不应进入日志或业务命令载荷。
    ///   - deviceID: 本次连接请求绑定的设备。
    /// - Returns: 必须来自同一次撤销一致性读取的身份与有效期。
    /// - Throws: 确定凭证无效时抛出 `V2GatewayAuthenticationError.unauthenticated`；基础设施错误应保留独立错误语义。
    ///
    /// Gateway 对确定的凭证拒绝生成不可重试响应；数据库暂时失败不能被伪装成凭证失效。
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication
}

/// Gateway 会话协商、生命周期与服务器时间错误。
public enum V2GatewaySessionError: Error, Equatable, Sendable {
    /// 客户端握手中没有有效版本，或提供的设备标识无效。
    case invalidClientHello
    /// 认证载荷缺少令牌，或设备与握手绑定不一致。
    case invalidAuthenticatePayload
    /// 客户端不支持服务器要求的能力配置。
    case unsupportedCapabilityProfile
    /// 当前阶段不支持命令，或预制响应与请求合同不匹配。
    case unsupportedCommand
    /// 认证会话已到期，到期瞬间也视为无效。
    case sessionExpired
    /// 已认证连接数量达到上限，供连接准入边界报告。
    case authenticatedConnectionLimit
    /// 服务器日期无法安全转换为协议要求的有符号 64 位 Unix 毫秒。
    case invalidServerClock
}

/// 已认证业务命令的路由边界。
///
/// 接收经过解码验证的 envelope 和已认证连接身份，不处理 TLS 字节或访问凭证。
/// 会话身份不能代替具体业务所需的房间权限和事务内检查。
public protocol V2GatewayCommandHandler: Sendable {
    /// 处理已认证业务命令。
    ///
    /// - Parameters:
    ///   - envelope: 已验证的请求 envelope。
    ///   - identity: Gateway 绑定的连接身份。
    /// - Returns: 业务响应；会话层会统一设置关联请求号与协商版本。
    /// - Throws: 业务处理或持久化错误，由外层决定响应映射与连接处置。
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope
    /// 处理业务命令并接收可选的进程内来源连接提示。
    ///
    /// - Parameters:
    ///   - envelope: 已验证的请求。
    ///   - identity: 已认证连接身份。
    ///   - originatingConnectionID: 精确识别请求来源连接，便于只抑制该连接的提交后回声，不影响发送者其他设备。
    /// - Returns: 业务响应。
    /// - Throws: 业务或持久化错误。
    ///
    /// 领域正确性不能依赖此提示，默认实现忽略它并调用基础处理方法。
    func handle(
        envelope: IMV2Envelope,
        identity: V2AuthenticatedConnection,
        originatingConnectionID: UUID?
    ) async throws -> IMV2Envelope
}

extension V2GatewayCommandHandler {
    /// 默认忽略来源连接提示，将业务处理委托给基础方法。
    public func handle(
        envelope: IMV2Envelope,
        identity: V2AuthenticatedConnection,
        originatingConnectionID _: UUID?
    ) async throws -> IMV2Envelope {
        try await handle(envelope: envelope, identity: identity)
    }
}

/// 群事件拉取预制响应所需的连接编码合同和共享缓存。
struct V2PreparedGroupEventCommandContext: Sendable {
    /// 待关联的原请求号。
    let requestID: UInt64
    /// 本连接协商的帧版本。
    let frameVersion: UInt8
    /// 本连接允许的压缩算法。
    let compression: V2NegotiatedFrameCompression?
    /// 响应未压缩载荷预算。
    let maximumUncompressedPayloadBytes: Int
    /// 响应压缩大小阈值。
    let compressionThresholdBytes: Int
    /// 允许的压缩扩展比。
    let maximumExpansionRatio: Int
    /// 可复用编码页面的共享缓存。
    let cache: V2PreparedGroupEventPageCache
    var captureAuthorSample: Bool = false
}

/// 当前有效认证连接的版本与压缩协商快照。
struct V2AuthenticatedGatewayFrameContract: Sendable {
    /// 当前认证会话协商的协议版本。
    let protocolVersion: UInt8
    /// 当前连接协商的压缩算法。
    let compression: V2NegotiatedFrameCompression?
}

/// 群事件拉取的普通 envelope 或已完成编码的共享页面响应。
enum V2PreparedGroupEventGatewayResponse: Sendable {
    /// 普通业务 envelope，仍需由会话层编码。
    case envelope(IMV2Envelope)
    /// 已按请求号、版本和编码合同构造的帧及页面摘要。
    case prepared(V2PreparedGroupEventPageResponse)
}

/// 可使用预制群事件页面缓存的可选业务处理能力。
protocol V2PreparedGroupEventCommandHandling: Sendable {
    /// 按当前连接编码合同处理群事件拉取。
    ///
    /// - Parameters:
    ///   - request: 已解码的拉取请求。
    ///   - identity: 已认证连接身份，具体房间读取权限仍需处理器检查。
    ///   - originatingConnectionID: 可选的请求来源连接提示。
    ///   - context: 当前请求号、编码限制与共享页面缓存。
    /// - Returns: 普通响应或预制帧；后者必须匹配当前版本、请求号和群页面命令。
    /// - Throws: 读取、授权或编码错误。
    func handlePreparedGroupEventPull(
        _ request: IMV2GroupEventPull,
        identity: V2AuthenticatedConnection,
        originatingConnectionID: UUID?,
        context: V2PreparedGroupEventCommandContext
    ) async throws -> V2PreparedGroupEventGatewayResponse
}

/// 一次完成会话校验与业务处理的请求响应交换。
///
/// 请求只解码一次，传输层可复用它做订阅和生命周期记账。预制页面路径的响应 envelope 只保留游标摘要，
/// 完整客户端数据位于响应帧中。
struct V2GatewaySessionExchange: Sendable {
    /// 仅解码一次且已完成会话处理的请求。
    let request: IMV2Envelope
    /// 响应内容；预制页面路径仅含页面游标摘要。
    let responseEnvelope: IMV2Envelope
    /// 实际向客户端发送的完整响应帧。
    let response: V2Frame
    /// 明确的终止认证原因；传输层应先发送关联拒绝响应，再结束连接。
    var terminalAuthenticationError: V2GatewayAuthenticationError? = nil
    var authorSample: V2AuthorPresentationPageSample? = nil
}

/// 会话内部生成的响应及可要求传输层在发送后终止连接的认证错误。
private struct V2GatewaySessionResponse: Sendable {
    /// 用于内部记账的响应内容或摘要。
    let envelope: IMV2Envelope
    /// 待发送的完整响应帧。
    let frame: V2Frame
    /// 明确的终止认证原因；传输层应先发送关联拒绝响应，再结束连接。
    var terminalAuthenticationError: V2GatewayAuthenticationError? = nil
    var authorSample: V2AuthorPresentationPageSample? = nil
}

/// 管理单条 Gateway 连接的握手、认证、请求关联与响应编码。
///
/// 传输层负责实际收发和关闭 socket；本 actor 在进入业务路径前校验连接阶段、期限和帧合同。
/// 异步认证结束后通过状态机完成认证，业务响应编码后通过状态机释放请求关联。
/// 这些状态检查不撤销已发生的业务副作用，也不替代领域存储的权威检查。
public actor V2GatewaySession {
    /// 本连接的握手阶段、身份和在途请求关联状态。
    private var presencePublicationSuppressed=true
    public func initialPresencePublicationSuppressed()->Bool {presencePublicationSuppressed}
    private var state: V2ConnectionStateMachine
    /// 可信的令牌与设备认证边界。
    private let authenticator: any V2GatewayAuthenticator
    /// 允许协商的协议版本集合。
    private let supportedVersions: Set<UInt8>
    /// 会话固定要求的能力配置。
    private let capabilityProfile: String
    /// 解码 protobuf 嵌套深度上限。
    private let maximumProtobufMessageDepth: Int
    /// 服务端可协商的压缩算法。
    private let supportedFrameCompression: V2NegotiatedFrameCompression?
    /// 解压与编码使用的未压缩载荷预算。
    private let maximumUncompressedPayloadBytes: Int
    /// 响应压缩的大小阈值。
    private let compressionThresholdBytes: Int
    /// 解压扩展比上限。
    private let maximumCompressionExpansionRatio: Int
    /// 群事件响应可选共享编码缓存。
    private let preparedGroupEventPageCache: V2PreparedGroupEventPageCache?
    /// 已认证命令的进程内流量准入依赖。
    private let commandAdmission: any V2AuthenticatedGatewayCommandAdmitting
    /// 服务器时间读取闭包。
    private let now: @Sendable () -> Date
    /// 认证成功后保存的期限，终止或撤销时清除。
    private var authenticatedSessionExpiresAt: Date?
    /// 握手选定的压缩算法，未协商时为空。
    private var negotiatedFrameCompression: V2NegotiatedFrameCompression?
    /// 握手中可选绑定的设备，认证时若存在则必须匹配。
    private var helloDeviceID: DeviceID?
    private let supportsAuthorPresentationDelta: Bool
    private var authorPresentationStreamID: UUID?

    /// 创建尚未握手的 Gateway 会话，不在初始化时执行认证或网络操作。
    ///
    /// - Parameters:
    ///   - limits: 状态机的连接与在途请求限制。
    ///   - authenticator: 令牌与设备认证边界。
    ///   - supportedVersions: 服务端可协商的协议版本集合。
    ///   - capabilityProfile: 客户端必须支持的能力配置标识。
    ///   - maximumProtobufMessageDepth: protobuf 递归深度上限，必须大于零。
    ///   - supportedFrameCompression: 可提供的压缩算法，默认不提供。
    ///   - maximumUncompressedPayloadBytes: 解压后载荷预算，必须大于零。
    ///   - compressionThresholdBytes: 启用压缩的大小阈值，必须非负。
    ///   - maximumCompressionExpansionRatio: 最大解压扩展比，必须大于零。
    ///   - preparedGroupEventPageCache: 可选的共享群事件页面缓存。
    ///   - supportsAuthorPresentationDelta: 仅在分发器、授权 reader 与可选 writer 完整组装后启用，默认关闭。
    ///   - commandAdmission: 已认证命令的准入策略。
    ///   - now: 可注入的服务器墙上时钟。
    ///
    /// 非法的深度、大小、阈值或扩展比会触发前置条件失败。
    public init(
        limits: V2ConnectionLimits,
        authenticator: any V2GatewayAuthenticator,
        supportedVersions: Set<UInt8> = [UInt8(IMV2ProtocolVersion.current)],
        capabilityProfile: String,
        maximumProtobufMessageDepth: Int = V2ServerProtobufFrameCodec.defaultMaximumMessageDepth,
        supportedFrameCompression: V2NegotiatedFrameCompression? = nil,
        maximumUncompressedPayloadBytes: Int = V2ServerProtobufFrameCodec.defaultMaximumUncompressedPayloadBytes,
        compressionThresholdBytes: Int = V2ServerProtobufFrameCodec.defaultCompressionThresholdBytes,
        maximumCompressionExpansionRatio: Int = V2ZlibFrameCompression.defaultMaximumExpansionRatio,
        preparedGroupEventPageCache: V2PreparedGroupEventPageCache? = nil,
        supportsAuthorPresentationDelta: Bool = false,
        commandAdmission: any V2AuthenticatedGatewayCommandAdmitting,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.state = .init(limits: limits)
        self.authenticator = authenticator
        self.supportedVersions = supportedVersions
        self.capabilityProfile = capabilityProfile
        precondition(maximumProtobufMessageDepth > 0)
        precondition(maximumUncompressedPayloadBytes > 0)
        precondition(compressionThresholdBytes >= 0)
        precondition(maximumCompressionExpansionRatio > 0)
        self.maximumProtobufMessageDepth = maximumProtobufMessageDepth
        self.supportedFrameCompression = supportedFrameCompression
        self.maximumUncompressedPayloadBytes = maximumUncompressedPayloadBytes
        self.compressionThresholdBytes = compressionThresholdBytes
        self.maximumCompressionExpansionRatio = maximumCompressionExpansionRatio
        self.preparedGroupEventPageCache = preparedGroupEventPageCache
        self.commandAdmission = commandAdmission
        self.supportsAuthorPresentationDelta = supportsAuthorPresentationDelta
        self.now = now
    }

    /// 解码一次请求，并按当前会话阶段分派握手或已认证业务处理。
    ///
    /// - Parameters:
    ///   - frame: 传输层读取的完整帧。
    ///   - handler: 已认证业务处理器。
    ///   - originatingConnectionID: 进程内连接身份，用于提交后通知优化。
    /// - Returns: 已验证请求、响应 envelope、实际响应帧和可选终止原因，供传输层完成记账与发送。
    /// - Throws: 解码、会话校验、认证或业务错误。
    func receive(
        _ frame: V2Frame,
        handler: any V2GatewayCommandHandler,
        originatingConnectionID: UUID? = nil,
        captureAuthorSample: Bool = false
    ) async throws -> V2GatewaySessionExchange {
        let envelope = try decode(frame)
        let response: V2GatewaySessionResponse
        switch state.phase {
        case .authenticated:
            response = try await receiveAuthenticated(
                frame,
                envelope: envelope,
                handler: handler,
                originatingConnectionID: originatingConnectionID,
                captureAuthorSample: captureAuthorSample
            )
        default:
            response = try await receiveBootstrap(frame, envelope: envelope)
        }
        return .init(
            request: envelope,
            responseEnvelope: response.envelope,
            response: response.frame,
            terminalAuthenticationError: response.terminalAuthenticationError,
            authorSample: response.authorSample
        )
    }

    /// 处理握手或认证帧，返回待发送响应。
    ///
    /// - Parameter frame: 完整握手阶段帧。
    /// - Returns: 握手响应、认证成功响应或明确的不可重试认证拒绝帧。
    /// - Throws: 解码、协商、状态校验或认证基础设施错误。
    ///
    /// 此入口不返回额外的终止认证错误标记；生产传输层使用内部交换入口统一处理响应后的连接生命周期。
    public func receiveBootstrap(_ frame: V2Frame) async throws -> V2Frame {
        try await receiveBootstrap(frame, envelope: decode(frame)).frame
    }

    /// 按已解码载荷执行版本协商或认证。
    ///
    /// 握手响应使用安全转换的服务器时间，认证开始前与适配器返回后分别校验服务器时间。
    /// 明确凭证拒绝会先关闭会话状态，再生成关联请求的拒绝帧；其他适配器错误直接传播。
    /// 认证成功需由状态机确认仍处于可完成的阶段，不能因 actor 在等待期间被关闭而重新激活。
    private func receiveBootstrap(
        _ frame: V2Frame,
        envelope: IMV2Envelope
    ) async throws -> V2GatewaySessionResponse {
        switch envelope.body {
        case .clientHello(let hello):
            let versions = Set(hello.supportedProtocolVersions.compactMap { UInt8(exactly: $0) })
            guard !versions.isEmpty else { throw V2GatewaySessionError.invalidClientHello }
            let profiles = Set(hello.supportedCapabilityProfiles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            guard profiles.contains(capabilityProfile) else { throw V2GatewaySessionError.unsupportedCapabilityProfile }
            let clock = try currentServerTime()
            guard let deviceID = try? DeviceID(hello.deviceID), deviceID.uuidValue != nil else {
                throw V2GatewaySessionError.invalidClientHello
            }
            helloDeviceID = deviceID
            let selected = try state.receiveClientHello(frame, clientSupportedVersions: versions, serverSupportedVersions: supportedVersions)
            if supportedFrameCompression == .zlib,
               hello.supportedFrameCompressions.contains(.zlib) {
                negotiatedFrameCompression = .zlib
            } else {
                negotiatedFrameCompression = nil
            }
            var response = IMV2Envelope()
            response.requestID = envelope.requestID
            response.protocolVersion = UInt32(selected)
            response.serverHello = .init()
            response.serverHello.selectedProtocolVersion = UInt32(selected)
            response.serverHello.selectedCapabilityProfile = capabilityProfile
            response.serverHello.serverTimeMs = clock.milliseconds
            response.serverHello.selectedFrameCompression = negotiatedFrameCompression == .zlib ? .zlib : .unspecified
            if selected >= 31, supportsAuthorPresentationDelta, hello.supportsAuthorPresentationDelta,
               helloDeviceID?.uuidValue != nil {
                authorPresentationStreamID = UUID()
                response.serverHello.authorPresentationStreamID = authorPresentationStreamID!.uuidString
            }
            return try .init(
                envelope: response,
                frame: V2ServerProtobufFrameCodec.encode(response, frameVersion: selected)
            )

        case .authenticate(let request):
            // 预留握手状态或启动异步适配器操作前，先拒绝不可用的时钟。
            _ = try currentServerTime()
            try state.receiveAuthenticate(frame)
            guard !request.accessToken.isEmpty else { throw V2GatewaySessionError.invalidAuthenticatePayload }
            let deviceID = try DeviceID(request.deviceID)
            guard helloDeviceID == deviceID else {
                throw V2GatewaySessionError.invalidAuthenticatePayload
            }
            let authentication: V2GatewayAuthentication
            do {
                authentication = try await authenticator.authenticateSession(
                    accessToken: request.accessToken,
                    deviceID: deviceID
                )
            } catch V2GatewayAuthenticationError.unauthenticated {
                // 单独的 EOF 在客户端看来像可重试网络故障。
                // 关闭前先发送关联请求的拒绝响应。只有明确的凭据拒绝进入此路径；
                // 数据库故障绝不能让客户端删除凭据。
                state.close()
                var response = IMV2Envelope()
                response.requestID = envelope.requestID
                response.protocolVersion = UInt32(frame.version)
                response.error = .init()
                response.error.code = "UNAUTHENTICATED"
                response.error.retryable = false
                return try .init(
                    envelope: response,
                    frame: V2ServerProtobufFrameCodec.encode(response, frameVersion: frame.version),
                    terminalAuthenticationError: .unauthenticated
                )
            }
            let userID = authentication.userID
            let expiresAt = authentication.expiresAt
            let clock = try currentServerTime()
            guard expiresAt.map({ $0 > clock.date }) ?? true else { throw V2GatewaySessionError.sessionExpired }
            try state.completeAuthentication(.init(userID: userID, deviceID: deviceID, capabilityProfile: capabilityProfile))
            presencePublicationSuppressed=request.presencePublicationSuppressed
            authenticatedSessionExpiresAt = expiresAt
            guard case .authenticated(let version, _) = state.phase else { throw V2GatewaySessionError.unsupportedCommand }
            var response = IMV2Envelope()
            response.requestID = envelope.requestID
            response.protocolVersion = UInt32(version)
            response.authenticated = .init()
            response.authenticated.userID = userID.rawValue
            response.authenticated.deviceID = deviceID.rawValue
            response.authenticated.selectedCapabilityProfile = capabilityProfile
            response.authenticated.selectedFrameCompression = negotiatedFrameCompression == .zlib ? .zlib : .unspecified
            response.authenticated.authorPresentationStreamID = authorPresentationStreamID?.uuidString ?? ""
            return try .init(
                envelope: response,
                frame: V2ServerProtobufFrameCodec.encode(response, frameVersion: version)
            )

        default:
            throw V2GatewaySessionError.unsupportedCommand
        }
    }

    /// 当前状态允许时返回已认证连接身份；尚未认证或连接终止时为 nil。
    public func authenticatedIdentity() -> V2AuthenticatedConnection? {
        currentAuthenticatedConnection()?.identity
    }

    /// 返回当前有效认证连接的协议版本；未认证、到期、终止或服务器时钟无效时返回 `nil`。
    public func authenticatedProtocolVersion() -> UInt8? {
        currentAuthenticatedConnection()?.version
    }

    /// 读取当前有效认证连接的版本与压缩合同；结果是调用时快照，不保证后续异步操作期间持续有效。
    func authenticatedFrameContract() -> V2AuthenticatedGatewayFrameContract? {
        guard let connection = currentAuthenticatedConnection() else { return nil }
        return .init(
            protocolVersion: connection.version,
            compression: negotiatedFrameCompression
        )
    }

    /// Negotiation is usable only while this exact authenticated session is live.
    func authenticatedAuthorPresentationStreamID() -> UUID? {
        guard currentAuthenticatedConnection() != nil else { return nil }
        return authorPresentationStreamID
    }

    /// Capture the current authentication expiry check for actual socket enqueue.
    /// Page/connection revocation is separately fenced by the transport gate.
    func authorPresentationSessionCheck() -> (@Sendable () -> Bool)? {
        guard currentAuthenticatedConnection() != nil, authorPresentationStreamID != nil else { return nil }
        let expiry = authenticatedSessionExpiresAt
        return { [now] in expiry.map { $0 > now() } ?? true }
    }

    /// Encode an optional supplement independently of shared message frames.
    /// The transport still checks its generation/view/deadline at actual enqueue.
    func authorPresentationFrame(_ payload: Data) throws -> V2Frame? {
        guard let connection = currentAuthenticatedConnection(), let streamID = authorPresentationStreamID else { return nil }
        let delta = try V2AuthorPresentationDelta.decode(payload)
        guard delta.streamID == streamID, delta.actorUserID == connection.identity.userID,
              delta.deviceID == connection.identity.deviceID else { throw V2GatewaySessionError.unsupportedCommand }
        var envelope = IMV2Envelope()
        envelope.protocolVersion = UInt32(connection.version)
        envelope.authorPresentationDelta = .init()
        envelope.authorPresentationDelta.payload = payload
        return try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: connection.version,
            maximumUncompressedPayloadBytes: min(maximumUncompressedPayloadBytes,
                V2AuthorPresentationDelta.maximumFrameBytes - V2Frame.headerLength))
    }

    /// 检查阶段、当前时间及会话期限，返回有效连接快照；检查失败返回 `nil`，不在此修改连接阶段。
    private func currentAuthenticatedConnection() -> (version: UInt8, identity: V2AuthenticatedConnection)? {
        guard case .authenticated(let version, let identity) = state.phase,
              let clock = try? currentServerTime(),
              authenticatedSessionExpiresAt.map({ $0 > clock.date }) ?? true else { return nil }
        return (version, identity)
    }

    /// 处理已认证帧并返回编码响应。
    ///
    /// - Parameters:
    ///   - frame: 待解码和验证的完整请求帧。
    ///   - handler: 处理非心跳业务的路由器。
    /// - Returns: 携带原请求号和协商版本的响应帧。
    /// - Throws: 帧错误、会话到期、无效时间、业务或编码错误。
    ///
    /// 此入口没有来源连接提示；需要精确抑制同连接回声的生产路径使用内部交换入口。
    public func receiveAuthenticated(_ frame: V2Frame, handler: any V2GatewayCommandHandler) async throws -> V2Frame {
        try await receiveAuthenticated(
            frame,
            envelope: decode(frame),
            handler: handler,
            originatingConnectionID: nil
        ).frame
    }

    /// 校验期限、登记请求关联，并执行准入、心跳或业务处理。
    ///
    /// 准入拒绝生成可重试的限流响应。心跳使用处理时重新读取的服务器时间；符合版本与缓存条件的群事件拉取可返回预制帧。
    /// 只有群事件页面响应使用协商压缩。成功或异常都会尝试释放请求关联。
    ///
    /// 会话期限在进入准入前检查；本方法不在每个异步挂起点后重新认证。业务执行之后的状态失败不能回滚已经提交的领域事务。
    private func receiveAuthenticated(
        _ frame: V2Frame,
        envelope: IMV2Envelope,
        handler: any V2GatewayCommandHandler,
        originatingConnectionID: UUID?,
        captureAuthorSample: Bool = false
    ) async throws -> V2GatewaySessionResponse {
        guard case .authenticated(let version, let identity) = state.phase else {
            throw V2GatewaySessionError.unsupportedCommand
        }
        let clock = try currentServerTime()
        guard authenticatedSessionExpiresAt.map({ $0 > clock.date }) ?? true else {
            state.close()
            throw V2GatewaySessionError.sessionExpired
        }
        guard frame.command != .authorPresentationDelta, frame.command != .authorPresentationEnded else {
            throw V2GatewaySessionError.unsupportedCommand
        }
        if case .authorPresentationEnd(let request) = envelope.body {
            guard let streamID = authorPresentationStreamID, UUID(uuidString: request.streamID) == streamID,
                  UUID(uuidString: request.roomID) != nil, UUID(uuidString: request.viewID) != nil else {
                throw V2GatewaySessionError.unsupportedCommand
            }
        }
        if case .groupEventSubscribe(let request) = envelope.body, !request.authorPresentationViewID.isEmpty {
            guard authorPresentationStreamID != nil, UUID(uuidString: request.authorPresentationViewID) != nil,
                  UUID(uuidString: request.roomID) != nil else { throw V2GatewaySessionError.unsupportedCommand }
        }
        try state.receiveAuthenticatedRequest(frame)
        do {
            var response: IMV2Envelope
            var preparedFrame: V2Frame?
            var authorSample: V2AuthorPresentationPageSample?
            if case .authorPresentationEnd(let request) = envelope.body {
                // Cleanup consumes normal frame/request budgets but needs no
                // domain I/O or rate-limit token after access has been revoked.
                response = IMV2Envelope()
                response.authorPresentationEnded.streamID = request.streamID
                response.authorPresentationEnded.roomID = request.roomID
                response.authorPresentationEnded.viewID = request.viewID
            } else if !(await commandAdmission.admit(
                identity: identity,
                cost: commandAdmissionCost(for: envelope),
                now: clock.date
            )) {
                response = IMV2Envelope()
                response.error = .init()
                response.error.code = "RATE_LIMITED"
                response.error.retryable = true
                response.error.retryAfterSeconds = 1
            } else if case .heartbeat = envelope.body {
                response = IMV2Envelope()
                response.heartbeatAck = .init()
                response.heartbeatAck.serverTimeMs = try currentServerTime().milliseconds
            } else if case .groupEventPull(let request) = envelope.body,
                      version >= 21,
                      let preparedGroupEventPageCache,
                      let preparedHandler = handler as? any V2PreparedGroupEventCommandHandling {
                switch try await preparedHandler.handlePreparedGroupEventPull(
                    request,
                    identity: identity,
                    originatingConnectionID: originatingConnectionID,
                    context: .init(
                        requestID: envelope.requestID,
                        frameVersion: version,
                        compression: negotiatedFrameCompression,
                        maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
                        compressionThresholdBytes: compressionThresholdBytes,
                        maximumExpansionRatio: maximumCompressionExpansionRatio,
                        cache: preparedGroupEventPageCache,
                        captureAuthorSample: captureAuthorSample && authorPresentationStreamID != nil
                    )
                ) {
                case .envelope(let ordinary):
                    response = ordinary
                case .prepared(let prepared):
                    guard prepared.frame.version == version,
                          prepared.frame.requestID == envelope.requestID,
                          prepared.frame.command == .groupEventPage
                    else { throw V2GatewaySessionError.unsupportedCommand }
                    preparedFrame = prepared.frame
                    authorSample = prepared.authorSample
                    // 生命周期簿记不会检查拉取响应。此处只保留公开的游标摘要；
                    // 实际客户端帧包含完整的共享事件页面。
                    response = IMV2Envelope()
                    response.groupEventPage = .init()
                    response.groupEventPage.roomID = prepared.roomID.rawValue
                    response.groupEventPage.nextRoomSequence = prepared.nextRoomSequence
                    response.groupEventPage.hasMore_p = prepared.hasMore
                }
            } else {
                response = try await handler.handle(
                    envelope: envelope,
                    identity: identity,
                    originatingConnectionID: originatingConnectionID
                )
            }
            if case .groupEventSubscribe(let request) = envelope.body,
               case .groupEventSubscribed(var subscribed) = response.body {
                guard let requestedRoom = try? RoomID(request.roomID),
                      let subscribedRoom = try? RoomID(subscribed.roomID), requestedRoom == subscribedRoom else {
                    throw V2GatewaySessionError.unsupportedCommand
                }
                subscribed.authorPresentationViewID = request.authorPresentationViewID
                response.groupEventSubscribed = subscribed
            }
            response.requestID = envelope.requestID
            response.protocolVersion = UInt32(version)
            let responseCompression: V2NegotiatedFrameCompression? = if case .groupEventPage? = response.body {
                negotiatedFrameCompression
            } else {
                nil
            }
            let encoded = try preparedFrame ?? preparedGroupEventPageCache?.frame(
                for: response,
                frameVersion: version,
                compression: responseCompression,
                maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
                compressionThresholdBytes: compressionThresholdBytes,
                maximumExpansionRatio: maximumCompressionExpansionRatio
            ) ?? V2ServerProtobufFrameCodec.encode(
                response,
                frameVersion: version,
                compression: responseCompression,
                maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
                compressionThresholdBytes: compressionThresholdBytes,
                maximumExpansionRatio: maximumCompressionExpansionRatio
            )
            try state.completeResponse(requestID: envelope.requestID)
            if captureAuthorSample, authorPresentationStreamID != nil, preparedFrame == nil,
               case .groupEventPull = envelope.body, case .groupEventPage(let page) = response.body {
                authorSample = .init(page: page)
            }
            return .init(envelope: response, frame: encoded, authorSample: authorSample)
        } catch {
            // 处理器尚未生成响应；在连接决定重试或关闭前，
            // 先释放请求关联信息。
            try? state.completeResponse(requestID: envelope.requestID)
            throw error
        }
    }

    /// 读取一次服务器时间，并安全转换为协议毫秒值。
    ///
    /// - Returns: 同一时刻的原始日期与向零舍入的 Unix 毫秒。
    /// - Throws: 非有限值或不能由 `Int64` 精确表示的舍入结果会抛出无效服务器时钟错误。
    ///
    /// 可表示的负时间在此允许通过；此转换不负责校准时钟或保证时间单调。
    private func currentServerTime() throws -> (date: Date, milliseconds: Int64) {
        let date = now()
        guard let milliseconds = Int64(exactly: (date.timeIntervalSince1970 * 1_000).rounded(.towardZero)) else {
            throw V2GatewaySessionError.invalidServerClock
        }
        return (date, milliseconds)
    }

    /// 估算已认证命令的准入成本，采用固定上限而不读取数据库。
    ///
    /// 心跳成本为零；转发按源与目标组合数，成员追加按成员数，分页读取按请求页大小计算；其他命令使用固定成本。
    /// 这是流量调度权重，不能代替具体业务的数量校验或容量事务。
    private func commandAdmissionCost(for envelope: IMV2Envelope) -> Int {
        switch envelope.body {
        case .heartbeat:
            // 客户端自身的前台工作不能饿死存活性检查。
            return 0
        case .getGroupRolePolicyBaseline:
            return 2
        case .listRoomMembers(let request):
            return min(8, max(1, 1 + Int(request.pageSize) / 100))
        case .groupEventPull(let request):
            return min(8, max(1, 1 + Int(request.pageSize) / 100))
        case .listReadReceiptReaders(let request):
            return min(4, max(1, 1 + Int(request.pageSize) / 50))
        case .syncPull(let request):
            return min(8, max(1, 1 + Int(request.maxRecords) / 100))
        default:
            return 1
        }
    }

    /// 使用当前协商压缩、protobuf 深度与解压预算解码完整帧；传播载荷或资源限制错误。
    private func decode(_ frame: V2Frame) throws -> IMV2Envelope {
        try V2ServerProtobufFrameCodec.decode(
            frame,
            maximumMessageDepth: maximumProtobufMessageDepth,
            compression: negotiatedFrameCompression,
            maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
            maximumExpansionRatio: maximumCompressionExpansionRatio
        )
    }

    /// 撤销本连接的设备会话并清除缓存的会话到期时间。
    public func revokeDevice() { state.revokeDevice(); authenticatedSessionExpiresAt = nil; authorPresentationStreamID = nil }
    /// 终止本连接状态并清除会话期限；socket 资源由外层连接所有者关闭。
    public func close() { state.close(); authenticatedSessionExpiresAt = nil; authorPresentationStreamID = nil }
}
