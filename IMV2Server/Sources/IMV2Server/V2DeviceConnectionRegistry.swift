import Foundation
import IMV2Compression
import IMV2Core
import Synchronization

/// 已认证实时连接的进程本地索引。
///
/// 持久吊销消费者会在每个网关副本上调用该注册表。
public actor V2DeviceConnectionRegistry {
    /// 前台通知属于高频路径。
    ///
    /// 把它们的不可变路由快照放在注册表 actor 之外，
    /// 使无关房间不会排在连接生命周期与在线状态工作之后。
    private nonisolated let foregroundRoutes = V2ForegroundConnectionRoutes()
    /// 同一 Gateway 创建的每条流都使用这套进程级帧契约。
    ///
    /// 提供之后，前台广播只编码一次并共享不可变字节；
    /// 测试与替代嵌入可以省略它，从而保留逐流的兼容路径。
    private let foregroundFrameLimits: V2FrameLimits?
    private let foregroundFrameCompression: V2NegotiatedFrameCompression?
    private let foregroundMaximumUncompressedPayloadBytes: Int
    private let foregroundCompressionThresholdBytes: Int
    private let foregroundMaximumCompressionExpansionRatio: Int
    private nonisolated let authorIngress = Mutex<V2AuthorPresentationIngress?>(nil)
    private nonisolated var authorPresentationIngress: V2AuthorPresentationIngress? { authorIngress.withLock { $0 } }
    private let connectionAdmissionPolicy: V2AuthenticatedConnectionAdmissionPolicy
    private let livePresenceRenewalConfiguration: V2LivePresenceRenewalBatcher.Configuration
    private var streamsByDevice: [DeviceID: [UUID: V2GatewayByteStream]] = [:]
    private var streamsByUser: [UserID: [UUID: V2GatewayByteStream]] = [:]
    private var identityByConnection: [UUID: V2AuthenticatedConnection] = [:]
    private var hasStartedRegistrations = false
    private var accountChangeService: V2AccountRoomChangeService?
    private var accountChangeTickets: [UUID: V2AccountRoomCoverageIndex.Ticket] = [:]
    /// 每次注册都会获得一个新令牌。
    ///
    /// actor 方法会在外部 await 之后重新校验它，
    /// 使较早的续体无法在注销之后、或同一连接 ID 再次注册之后复活状态。
    private typealias Generation = UInt64
    private var lifecycleByConnection: [UUID: Generation] = [:]
    /// 前台群组观看关系刻意是进程本地的软状态。
    ///
    /// 在进程或连接失败之后，持久房间事件日志与常规的每用户同步仍是恢复来源。
    private var streamsByForegroundGroup: [RoomID: [UUID: V2GatewayByteStream]] = [:]
    private var foregroundGroupByConnection: [UUID: RoomID] = [:]
    private var foregroundMutationByConnection: [UUID: Generation] = [:]
    private var foregroundGroupInterestManager: (any V2GroupEventWakeInterestManaging)?
    private var livePresenceLeases: (any V2LivePresenceLeaseManaging)?
    private var livePresenceRenewals: V2LivePresenceRenewalBatcher?
    private var liveActivityObservationAuthorizer: (any V2LiveActivityObservationAuthorizing)?
    private var liveActivityBroker: (any V2LiveActivityInterestManaging & V2LiveActivityPublishing)?
    private var publicationSuppressedByConnection:[UUID:Bool]=[:]
    private var presenceByConnection: [UUID: (roomID: RoomID, targetUserID: UserID)] = [:]
    private var presenceMutationByConnection: [UUID: Generation] = [:]
    private var presenceWatchersByTarget: [UserID: [UUID: V2GatewayByteStream]] = [:]
    private var typingRoomByConnection: [UUID: RoomID] = [:]
    private var typingMutationByConnection: [UUID: Generation] = [:]
    /// 这些值是 actor 本地的可重入围栏，而不是公开身份或安全能力。
    ///
    /// 单调递增的代次已经够用，并可避免在连接频繁变动时打开平台随机源。
    private var nextGeneration: Generation = 0
    private var typingWatchersByRoom: [RoomID: [UUID: V2GatewayByteStream]] = [:]

    public init(
        connectionAdmissionPolicy: V2AuthenticatedConnectionAdmissionPolicy = .init(
            maximumConnectionsPerDevice: 2,
            maximumConnectionsPerUser: 8
        ),
        livePresenceRenewalConfiguration: V2LivePresenceRenewalBatcher.Configuration = .init(),
        foregroundFrameLimits: V2FrameLimits? = nil,
        foregroundFrameCompression: V2NegotiatedFrameCompression? = nil,
        foregroundMaximumUncompressedPayloadBytes: Int = V2ServerProtobufFrameCodec
            .defaultMaximumUncompressedPayloadBytes,
        foregroundCompressionThresholdBytes: Int = V2ServerProtobufFrameCodec
            .defaultCompressionThresholdBytes,
        foregroundMaximumCompressionExpansionRatio: Int = V2ZlibFrameCompression
            .defaultMaximumExpansionRatio,
        authorPresentationIngress: V2AuthorPresentationIngress? = nil
    ) {
        precondition(
            foregroundMaximumUncompressedPayloadBytes > 0
                && foregroundCompressionThresholdBytes >= 0
                && foregroundMaximumCompressionExpansionRatio > 0
        )
        self.connectionAdmissionPolicy = connectionAdmissionPolicy
        authorIngress.withLock { $0 = authorPresentationIngress }
        self.livePresenceRenewalConfiguration = livePresenceRenewalConfiguration
        self.foregroundFrameLimits = foregroundFrameLimits
        self.foregroundFrameCompression = foregroundFrameCompression
        self.foregroundMaximumUncompressedPayloadBytes =
            foregroundMaximumUncompressedPayloadBytes
        self.foregroundCompressionThresholdBytes = foregroundCompressionThresholdBytes
        self.foregroundMaximumCompressionExpansionRatio =
            foregroundMaximumCompressionExpansionRatio
    }

    /// The composition root builds its room authorization reader after Actors
    /// start. Install its sole ingress before accepting authenticated sockets.
    /// Replacing a running dependency is deliberately unsupported.
    public func installAuthorPresentationIngress(_ ingress: V2AuthorPresentationIngress) throws {
        guard !hasStartedRegistrations, !ingress.statistics().closed else { throw V2ResourceProviderError.configurationInvalid }
        try authorIngress.withLock {
            guard $0 == nil else { throw V2ResourceProviderError.configurationInvalid }
            $0 = ingress
        }
    }

    @discardableResult
    public func register(_ stream: V2GatewayByteStream, connectionID: UUID, identity: V2AuthenticatedConnection, publicationSuppressed:Bool) async throws -> Bool {
        hasStartedRegistrations = true
        // 连接 ID 是单次生命周期的令牌，不是幂等键。
        // 首次注册挂起期间若接受重复 ID，另一条流就可能继承其身份和租约。
        if identityByConnection[connectionID] != nil { return false }
        guard (streamsByDevice[identity.deviceID]?.count ?? 0) < connectionAdmissionPolicy.maximumConnectionsPerDevice,
              (streamsByUser[identity.userID]?.count ?? 0) < connectionAdmissionPolicy.maximumConnectionsPerUser
        else { return false }
        let lifecycle = makeGeneration()
        lifecycleByConnection[connectionID] = lifecycle
        identityByConnection[connectionID] = identity
        publicationSuppressedByConnection[connectionID] = publicationSuppressed
        streamsByDevice[identity.deviceID, default: [:]][connectionID] = stream
        streamsByUser[identity.userID, default: [:]][connectionID] = stream
        guard let livePresenceLeases else { return true }
        let lease: V2AuthenticatedConnectionLeaseOutcome
        do {
            lease = try await livePresenceLeases.admitConnection(
                identity: identity,
                connectionID: connectionID,
                publicationSuppressed:publicationSuppressed,
                policy: connectionAdmissionPolicy,
                now: Date()
            )
        } catch {
            rollbackRegistration(connectionID: connectionID, identity: identity, lifecycle: lifecycle)
            // 存储或连接池故障并非连接数限制决策。
            // 保留原始错误，让传输遥测能够定位故障依赖，
            // 而不是错误报告配额已满。
            throw error
        }
        guard lifecycleByConnection[connectionID] == lifecycle else {
            await compensateStalePresence(connectionID: connectionID, identity: identity)
            return false
        }
        guard case .accepted(let expiresAt) = lease else {
            rollbackRegistration(connectionID: connectionID, identity: identity, lifecycle: lifecycle)
            return false
        }
        let allowsOnlinePresence = (
            try? await livePresenceLeases.allowsOnlinePresence(userID: identity.userID)
        ) == true
        guard lifecycleByConnection[connectionID] == lifecycle else {
            await compensateStalePresence(connectionID: connectionID, identity: identity)
            return false
        }
        guard allowsOnlinePresence && !publicationSuppressed else {
            // 持久化记录也是跨副本的已认证连接准入租约。
            // 在线状态隐私只控制该租约是否可见，不控制它是否存在。
            // 若在此删除租约，隐藏在线状态的用户就能绕过全局的
            // 单用户和单设备连接数限制。
            return true
        }
        await routePresence(targetUserID: identity.userID, isOnline: true, expiresAt: expiresAt)
        if lifecycleByConnection[connectionID] != lifecycle {
            await compensateStalePresence(connectionID: connectionID, identity: identity)
            return false
        }
        return true
    }

    public func setPresencePublication(connectionID:UUID,identity:V2AuthenticatedConnection,
        mode:V2PresencePublicationMode) async throws {
        guard identityByConnection[connectionID]==identity,let lifecycle=lifecycleByConnection[connectionID],let leases=livePresenceLeases else {throw V2GatewaySessionError.unsupportedCommand}
        let suppressed=mode == .suppressed
        // The durable lease flag precedes the acknowledgement. All account,
        // device and connection fields are matched in the persistence boundary.
        let observation=try await leases.setPresencePublication(identity:identity,connectionID:connectionID,suppressed:suppressed,now:Date())
        guard lifecycleByConnection[connectionID]==lifecycle,identityByConnection[connectionID]==identity else {throw V2GatewaySessionError.unsupportedCommand}
        publicationSuppressedByConnection[connectionID]=suppressed
        await routePresence(targetUserID:identity.userID,isOnline:observation.isOnline,expiresAt:observation.expiresAt)
    }

    public func unregister(connectionID: UUID) async {
        guard let identity = identityByConnection.removeValue(forKey: connectionID) else { return }
        publicationSuppressedByConnection.removeValue(forKey:connectionID)
        lifecycleByConnection.removeValue(forKey: connectionID)
        streamsByDevice[identity.deviceID]?.removeValue(forKey: connectionID)
        if streamsByDevice[identity.deviceID]?.isEmpty == true { streamsByDevice.removeValue(forKey: identity.deviceID) }
        streamsByUser[identity.userID]?.removeValue(forKey: connectionID)
        if streamsByUser[identity.userID]?.isEmpty == true { streamsByUser.removeValue(forKey: identity.userID) }
        if let ticket = accountChangeTickets.removeValue(forKey: connectionID), let accountChangeService {
            await accountChangeService.stop(ticket)
        }
        guard lifecycleByConnection[connectionID] == nil else { return }
        do {
            let mutation = makeGeneration()
            foregroundMutationByConnection[connectionID] = mutation
            defer {
                if foregroundMutationByConnection[connectionID] == mutation {
                    foregroundMutationByConnection.removeValue(forKey: connectionID)
                }
            }
            await removeForegroundGroupSubscription(connectionID: connectionID)
        }
        guard lifecycleByConnection[connectionID] == nil else { return }
        do {
            let mutation = makeGeneration()
            presenceMutationByConnection[connectionID] = mutation
            defer {
                if presenceMutationByConnection[connectionID] == mutation {
                    presenceMutationByConnection.removeValue(forKey: connectionID)
                }
            }
            await removePresenceSubscription(connectionID: connectionID)
        }
        guard lifecycleByConnection[connectionID] == nil else { return }
        do {
            let mutation = makeGeneration()
            typingMutationByConnection[connectionID] = mutation
            defer {
                if typingMutationByConnection[connectionID] == mutation {
                    typingMutationByConnection.removeValue(forKey: connectionID)
                }
            }
            await removeTypingSubscription(connectionID: connectionID)
        }
        // 消息代理拆除等待期间，后续注册可能复用了该 ID。
        // 旧续体不能删除新注册的租约。
        guard lifecycleByConnection[connectionID] == nil else { return }
        guard let remainsOnline = await removePresenceLease(
            identity: identity,
            connectionID: connectionID
        ) else {
            // 跨副本查询失败不能证明用户离线。
            // 短期数据库租约会自行收敛，无须在故障期间发出误导性的全局状态转换。
            return
        }
        if !remainsOnline, lifecycleByConnection[connectionID] == nil {
            await routePresence(targetUserID: identity.userID, isOnline: false, expiresAt: Date())
        }
    }

    public func revoke(deviceID: DeviceID) async {
        let connections = streamsByDevice[deviceID].map { Array($0) } ?? []
        // Invalidate every queued foreground write before any cleanup can suspend.
        // A slow lease or broker teardown must not leave another socket authorized.
        for (_, stream) in connections { stream.invalidateForegroundAuthorization() }

        // The stream waits for its transport's close promise before returning.
        // Keep the worker's durable cursor behind all local socket closures, while
        // allowing one slow cleanup to make progress alongside the other sockets.
        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            let maximumConcurrency = min(16, connections.count)
            for index in 0..<maximumConcurrency {
                let (connectionID, stream) = connections[index]
                group.addTask {
                    await stream.revokeDevice()
                    await self.unregisterRevokedConnection(connectionID: connectionID, deviceID: deviceID, stream: stream)
                }
                nextIndex += 1
            }
            while await group.next() != nil {
                if nextIndex < connections.count {
                    let (connectionID, stream) = connections[nextIndex]
                    group.addTask {
                        await stream.revokeDevice()
                        await self.unregisterRevokedConnection(connectionID: connectionID, deviceID: deviceID, stream: stream)
                    }
                    nextIndex += 1
                }
            }
        }
    }

    private func unregisterRevokedConnection(
        connectionID: UUID,
        deviceID: DeviceID,
        stream: V2GatewayByteStream
    ) async {
        // An old close continuation must not remove a new registration using
        // the same connection ID after this revocation snapshot was taken.
        guard streamsByDevice[deviceID]?[connectionID] === stream else { return }
        await unregister(connectionID: connectionID)
    }

    public func notifySyncAvailable(userID: UserID, eventID: UInt64, highWatermark: UInt64) async {
        let streams = streamsByUser[userID].map { Array($0.values) } ?? []
        for stream in streams { await stream.sendSyncAvailable(eventID: eventID, highWatermark: highWatermark) }
    }

    /// 配置前台群组兴趣管理器。
    ///
    /// 调用前领域处理器已校验过群组成员关系。一个前台连接只能观看一个详情房间；
    /// 切换房间会原子地拆除此前的本地兴趣。
    ///
    /// - Parameter manager: 群事件唤醒兴趣管理器。
    public func configureForegroundGroupInterestManager(_ manager: any V2GroupEventWakeInterestManaging) async {
        foregroundGroupInterestManager = manager
        for roomID in Array(streamsByForegroundGroup.keys) {
            try? await manager.activate(roomID: roomID)
            if streamsByForegroundGroup[roomID] == nil {
                await manager.deactivate(roomID: roomID)
            }
        }
    }

    public func detachForegroundGroupInterestManager() {
        foregroundGroupInterestManager = nil
    }

    public func subscribeForegroundGroup(
        _ stream: V2GatewayByteStream,
        connectionID: UUID,
        roomID: RoomID,
        membershipRevision: UInt64 = 0
    ) async {
        guard let identity = identityByConnection[connectionID],
              let lifecycle = lifecycleByConnection[connectionID]
        else { return }
        let mutation = makeGeneration()
        foregroundMutationByConnection[connectionID] = mutation
        defer {
            if foregroundMutationByConnection[connectionID] == mutation {
                foregroundMutationByConnection.removeValue(forKey: connectionID)
            }
        }
        if foregroundGroupByConnection[connectionID] == roomID {
            streamsByForegroundGroup[roomID, default: [:]][connectionID] = stream
            foregroundRoutes.upsert(
                connectionID: connectionID,
                roomID: roomID,
                userID: identity.userID,
                membershipRevision: membershipRevision,
                stream: stream
            )
            return
        }
        await removeForegroundGroupSubscription(connectionID: connectionID)
        guard lifecycleByConnection[connectionID] == lifecycle,
              foregroundMutationByConnection[connectionID] == mutation
        else { return }
        foregroundGroupByConnection[connectionID] = roomID
        let wasInactive = streamsByForegroundGroup[roomID] == nil
        streamsByForegroundGroup[roomID, default: [:]][connectionID] = stream
        foregroundRoutes.upsert(
            connectionID: connectionID,
            roomID: roomID,
            userID: identity.userID,
            membershipRevision: membershipRevision,
            stream: stream
        )
        if wasInactive, let foregroundGroupInterestManager {
            try? await foregroundGroupInterestManager.activate(roomID: roomID)
            if streamsByForegroundGroup[roomID] == nil {
                await foregroundGroupInterestManager.deactivate(roomID: roomID)
            }
        }
    }

    public func unsubscribeForegroundGroup(connectionID: UUID, roomID: RoomID) async {
        guard foregroundGroupByConnection[connectionID] == roomID else { return }
        let mutation = makeGeneration()
        foregroundMutationByConnection[connectionID] = mutation
        defer {
            if foregroundMutationByConnection[connectionID] == mutation {
                foregroundMutationByConnection.removeValue(forKey: connectionID)
            }
        }
        await removeForegroundGroupSubscription(connectionID: connectionID)
    }

    /// 通知前台群组可用性。
    ///
    /// 核心路由允许重复或丢失该提示。
    /// 每条流只会收到一个房间水位线，必须自行游标拉取持久事件。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间标识。
    ///   - highWatermark: 该房间当前的高水位。
    public nonisolated func notifyForegroundGroupAvailable(
        roomID: RoomID,
        highWatermark: UInt64
    ) async {
        await notifyAccountRoomAvailable(roomID: roomID)
        let streams = foregroundRoutes.streams(roomID: roomID)
        let prepared = foregroundFrameLimits.flatMap {
            V2PreparedGatewayGroupEventAvailable(
                roomID: roomID,
                highWatermark: highWatermark,
                directEvent: nil,
                frameLimits: $0,
                compression: foregroundFrameCompression,
                maximumUncompressedPayloadBytes:
                    foregroundMaximumUncompressedPayloadBytes,
                compressionThresholdBytes: foregroundCompressionThresholdBytes,
                maximumExpansionRatio: foregroundMaximumCompressionExpansionRatio
            )
        }
        await Self.publishForeground(
            streams,
            roomID: roomID,
            highWatermark: highWatermark,
            prepared: prepared
        )
    }

    /// 只把私聊事件加速载荷路由到这样的前台流：
    /// 其已认证身份属于提交事务所捕获的成员集合。
    ///
    /// 单单一条订阅永远不构成权威。
    ///
    /// - Parameter event: 待路由的私聊实时事件。
    public nonisolated func notifyForegroundDirectEvent(
        _ event: V2DirectRoomLiveEvent
    ) async {
        await notifyAccountRoomAvailable(roomID: event.roomID)
        let streams = foregroundRoutes.streams(for: event)
        let prepared = foregroundFrameLimits.flatMap {
            V2PreparedGatewayGroupEventAvailable(
                roomID: event.roomID,
                highWatermark: event.highWatermark,
                directEvent: event,
                frameLimits: $0,
                compression: foregroundFrameCompression,
                maximumUncompressedPayloadBytes:
                    foregroundMaximumUncompressedPayloadBytes,
                compressionThresholdBytes: foregroundCompressionThresholdBytes,
                maximumExpansionRatio: foregroundMaximumCompressionExpansionRatio
            )
        }
        await Self.publishForeground(
            streams,
            roomID: event.roomID,
            highWatermark: event.highWatermark,
            directEvent: event,
            prepared: prepared,
            hints: authorPresentationIngress.flatMap { _ in V2AuthorPresentationHints(directEvent: event) },
            ingress: authorPresentationIngress
        )
    }

    /// 在不新建 Swift 子任务、也不穿越该注册表 actor 的前提下，
    /// 完成生产环境的纯本地私聊事件路由。
    ///
    /// 不可变帧只编码一次，每个受众成员仍由已认证路由快照选出，
    /// 且每条流的传输栅栏会再次校验认证与生命周期。
    ///
    /// 若该注册表创建时没有进程级帧契约，则在发布之前返回 `false`。
    /// 一旦发布开始，部分传输生命周期未命中也会返回 `false`；投递器随后改走兼容路径。
    /// 在已入队流上出现重复显式安全，因为前台事件是幂等加速器，而房间日志游标仍是权威。
    ///
    /// - Parameter event: 待提交的私聊实时事件。
    /// - Returns: 是否已通过快速路径完成本地路由。
    nonisolated func submitForegroundDirectEvent(
        _ event: V2DirectRoomLiveEvent
    ) -> Bool {
        guard let foregroundFrameLimits,
              let prepared = V2PreparedGatewayGroupEventAvailable(
                  roomID: event.roomID,
                  highWatermark: event.highWatermark,
                  directEvent: event,
                  frameLimits: foregroundFrameLimits,
                  compression: foregroundFrameCompression,
                  maximumUncompressedPayloadBytes:
                      foregroundMaximumUncompressedPayloadBytes,
                  compressionThresholdBytes: foregroundCompressionThresholdBytes,
                  maximumExpansionRatio: foregroundMaximumCompressionExpansionRatio
              )
        else { return false }
        let streams = foregroundRoutes.streams(for: event)
        let hints = authorPresentationIngress.flatMap { _ in V2AuthorPresentationHints(directEvent: event) }
        return Self.submitPreparedForeground(prepared, to: streams, hints: hints, ingress: authorPresentationIngress)
    }

    /// 私聊事件快速路径在有序混合群组微批上的对应实现。
    ///
    /// 以首个事件的成员任期选出受众，每个条目都由已准备帧构造器重新校验，
    /// 所有套接字收到同一份共享不可变帧，而不是每个事件一帧。
    ///
    /// - Parameter events: 本批有序群组实时事件。
    /// - Returns: 是否已通过快速路径提交。
    nonisolated func submitForegroundGroupEvents(
        _ events: [V2DirectRoomLiveEvent]
    ) -> Bool {
        guard let first = events.first,
              first.groupMembershipRevision != nil,
              let foregroundFrameLimits,
              let prepared = V2PreparedGatewayGroupEventAvailable(
                  groupEvents: events,
                  frameLimits: foregroundFrameLimits,
                  compression: foregroundFrameCompression,
                  maximumUncompressedPayloadBytes:
                      foregroundMaximumUncompressedPayloadBytes,
                  compressionThresholdBytes: foregroundCompressionThresholdBytes,
                  maximumExpansionRatio: foregroundMaximumCompressionExpansionRatio
              )
        else { return false }
        let streams = foregroundRoutes.streams(for: first)
        let hints = authorPresentationIngress.flatMap { _ in V2AuthorPresentationHints(events: events) }
        return Self.submitPreparedForeground(prepared, to: streams, hints: hints, ingress: authorPresentationIngress)
    }

    /// 在保留逐流认证/生命周期栅栏的同时，
    /// 把进程级调度器交接从「每个接收者一次锁」降为「每个 EventLoop 一批」。
    /// 基于回调的测试与替代传输仍沿用既有的即时提交路径。
    ///
    /// - Parameters:
    ///   - prepared: 已准备的群事件帧。
    ///   - streams: 本次投递的已授权目标流。
    /// - Returns: 是否已通过快速路径完成提交。
    private nonisolated static func submitPreparedForeground(
        _ prepared: V2PreparedGatewayGroupEventAvailable,
        to streams: [V2GatewayByteStream],
        hints: V2AuthorPresentationHints? = nil,
        ingress: V2AuthorPresentationIngress? = nil
    ) -> Bool {
        var completed = true
        var nioSubmissions: [V2NIOGatewayForegroundWriteSubmission] = []
        var supplementTargets: [V2GatewayByteStream] = []
        nioSubmissions.reserveCapacity(streams.count)
        for stream in streams {
            if let submission = stream.prepareNIOGroupEventAvailable(prepared) {
                nioSubmissions.append(submission)
                if hints != nil { supplementTargets.append(stream) }
            } else if !stream.submitGroupEventAvailable(prepared) {
                completed = false
            } else if let hints, let ingress {
                stream.offerAuthorPresentation(hints, to: ingress)
            }
        }
        V2NIOGatewayForegroundWriter.submitBatch(nioSubmissions)
        if let hints, let ingress {
            for stream in supplementTargets { stream.offerAuthorPresentation(hints, to: ingress) }
        }
        return completed
    }

    /// 由 actor 支撑的兼容路径，供测试、替代传输，
    /// 以及任何无法使用 NIO 同步写者的流使用。
    ///
    /// - Parameter events: 本批有序群组实时事件。
    public nonisolated func notifyForegroundGroupEvents(
        _ events: [V2DirectRoomLiveEvent]
    ) async {
        if let roomID = events.first?.roomID { await notifyAccountRoomAvailable(roomID: roomID) }
        guard let first = events.first,
              first.groupMembershipRevision != nil,
              let foregroundFrameLimits,
              let prepared = V2PreparedGatewayGroupEventAvailable(
                  groupEvents: events,
                  frameLimits: foregroundFrameLimits,
                  compression: foregroundFrameCompression,
                  maximumUncompressedPayloadBytes:
                      foregroundMaximumUncompressedPayloadBytes,
                  compressionThresholdBytes: foregroundCompressionThresholdBytes,
                  maximumExpansionRatio: foregroundMaximumCompressionExpansionRatio
              )
        else { return }
        let streams = foregroundRoutes.streams(for: first)
        let hints = authorPresentationIngress.flatMap { _ in V2AuthorPresentationHints(events: events) }
        var nioSubmissions: [V2NIOGatewayForegroundWriteSubmission] = []
        var supplementTargets: [V2GatewayByteStream] = []
        nioSubmissions.reserveCapacity(streams.count)
        var actorFallbacks: [V2GatewayByteStream] = []
        for stream in streams {
            if let submission = stream.prepareNIOGroupEventAvailable(prepared) {
                nioSubmissions.append(submission)
                if hints != nil { supplementTargets.append(stream) }
            } else if !stream.submitGroupEventAvailable(prepared) {
                actorFallbacks.append(stream)
            } else if let hints, let authorPresentationIngress {
                stream.offerAuthorPresentation(hints, to: authorPresentationIngress)
            }
        }
        V2NIOGatewayForegroundWriter.submitBatch(nioSubmissions)
        if let hints, let authorPresentationIngress {
            for stream in supplementTargets { stream.offerAuthorPresentation(hints, to: authorPresentationIngress) }
        }
        for stream in actorFallbacks {
            let submitted = await stream.sendGroupEventAvailable(prepared)
            if submitted, let hints, let authorPresentationIngress {
                stream.offerAuthorPresentation(hints, to: authorPresentationIngress)
            }
        }
    }

    public func connectionCount(for deviceID: DeviceID) -> Int { streamsByDevice[deviceID]?.count ?? 0 }

    public func connectionMetricsSnapshot() -> V2ConnectionMetricsSnapshot {
        .init(activeDevices: streamsByDevice.count, activeConnections: identityByConnection.count)
    }

    public func activeForegroundGroupMetrics() -> (rooms: Int, viewers: Int) {
        (streamsByForegroundGroup.count, foregroundGroupByConnection.count)
    }

    public func configureLivePresenceLeases(_ leases: any V2LivePresenceLeaseManaging) {
        livePresenceLeases = leases
        livePresenceRenewals = .init(
            leases: leases,
            configuration: livePresenceRenewalConfiguration
        )
    }

    public func livePresenceRenewalMetrics() async -> V2LivePresenceRenewalBatcher.Snapshot? {
        await livePresenceRenewals?.snapshot()
    }

    public func finishLivePresenceRenewals() async {
        await livePresenceRenewals?.finish()
        livePresenceRenewals = nil
    }

    public func configureLiveActivityObservationAuthorizer(_ authorizer: any V2LiveActivityObservationAuthorizing) {
        liveActivityObservationAuthorizer = authorizer
    }

    public func configureLiveActivityBroker(_ broker: any V2LiveActivityInterestManaging & V2LiveActivityPublishing) async {
        liveActivityBroker = broker
        for userID in Array(presenceWatchersByTarget.keys) {
            try? await broker.activatePresence(targetUserID: userID)
            if presenceWatchersByTarget[userID] == nil { await broker.deactivatePresence(targetUserID: userID) }
        }
        for roomID in Array(typingWatchersByRoom.keys) {
            try? await broker.activateTyping(roomID: roomID)
            if typingWatchersByRoom[roomID] == nil { await broker.deactivateTyping(roomID: roomID) }
        }
    }

    public func detachLiveActivityBroker() {
        liveActivityBroker = nil
    }

    @discardableResult
    public func refreshLivePresence(connectionID: UUID) async -> Bool {
        guard let identity = identityByConnection[connectionID],
              let lifecycle = lifecycleByConnection[connectionID]
        else { return false }
        guard let livePresenceLeases else { return true }
        let refresh: V2LivePresenceLeaseRefresh
        do {
            if let livePresenceRenewals {
                refresh = try await livePresenceRenewals.renew(
                    identity: identity,
                    connectionID: connectionID,
                    now: Date()
                )
            } else {
                let now = Date()
                let outcome = try await livePresenceLeases.renewConnection(
                    identity: identity,
                    connectionID: connectionID,
                    now: now
                )
                refresh = .init(
                    outcome: outcome,
                    allowsOnlinePresence: try await livePresenceLeases.allowsOnlinePresence(
                        userID: identity.userID
                    )
                )
            }
        } catch {
            await unregister(connectionID: connectionID)
            return false
        }
        guard lifecycleByConnection[connectionID] == lifecycle else {
            await compensateStalePresence(connectionID: connectionID, identity: identity)
            return false
        }
        guard case .accepted(let expiresAt) = refresh.outcome else {
            await unregister(connectionID: connectionID)
            return false
        }
        if refresh.allowsOnlinePresence, publicationSuppressedByConnection[connectionID] == false,
           lifecycleByConnection[connectionID] == lifecycle {
            await routePresence(targetUserID: identity.userID, isOnline: true, expiresAt: expiresAt)
        }
        if lifecycleByConnection[connectionID] != lifecycle {
            await compensateStalePresence(connectionID: connectionID, identity: identity)
            return false
        }
        return true
    }

    public func subscribePresence(_ stream: V2GatewayByteStream, connectionID: UUID, roomID: RoomID, targetUserID: UserID) async {
        guard identityByConnection[connectionID] != nil,
              let lifecycle = lifecycleByConnection[connectionID]
        else { return }
        let mutation = makeGeneration()
        presenceMutationByConnection[connectionID] = mutation
        defer {
            if presenceMutationByConnection[connectionID] == mutation {
                presenceMutationByConnection.removeValue(forKey: connectionID)
            }
        }
        await removePresenceSubscription(connectionID: connectionID)
        guard lifecycleByConnection[connectionID] == lifecycle,
              presenceMutationByConnection[connectionID] == mutation
        else { return }
        presenceByConnection[connectionID] = (roomID, targetUserID)
        presenceWatchersByTarget[targetUserID, default: [:]][connectionID] = stream
        if presenceWatchersByTarget[targetUserID]?.count == 1, let liveActivityBroker {
            try? await liveActivityBroker.activatePresence(targetUserID: targetUserID)
            if presenceWatchersByTarget[targetUserID] == nil {
                await liveActivityBroker.deactivatePresence(targetUserID: targetUserID)
            }
        }
    }

    public func unsubscribePresence(connectionID: UUID, roomID: RoomID) async {
        guard presenceByConnection[connectionID]?.roomID == roomID else { return }
        let mutation = makeGeneration()
        presenceMutationByConnection[connectionID] = mutation
        defer {
            if presenceMutationByConnection[connectionID] == mutation {
                presenceMutationByConnection.removeValue(forKey: connectionID)
            }
        }
        await removePresenceSubscription(connectionID: connectionID)
    }

    public func subscribeTyping(_ stream: V2GatewayByteStream, connectionID: UUID, roomID: RoomID) async {
        guard identityByConnection[connectionID] != nil,
              let lifecycle = lifecycleByConnection[connectionID]
        else { return }
        let mutation = makeGeneration()
        typingMutationByConnection[connectionID] = mutation
        defer {
            if typingMutationByConnection[connectionID] == mutation {
                typingMutationByConnection.removeValue(forKey: connectionID)
            }
        }
        await removeTypingSubscription(connectionID: connectionID)
        guard lifecycleByConnection[connectionID] == lifecycle,
              typingMutationByConnection[connectionID] == mutation
        else { return }
        typingRoomByConnection[connectionID] = roomID
        typingWatchersByRoom[roomID, default: [:]][connectionID] = stream
        if typingWatchersByRoom[roomID]?.count == 1, let liveActivityBroker {
            try? await liveActivityBroker.activateTyping(roomID: roomID)
            if typingWatchersByRoom[roomID] == nil {
                await liveActivityBroker.deactivateTyping(roomID: roomID)
            }
        }
    }

    public func unsubscribeTyping(connectionID: UUID, roomID: RoomID) async {
        guard typingRoomByConnection[connectionID] == roomID else { return }
        let mutation = makeGeneration()
        typingMutationByConnection[connectionID] = mutation
        defer {
            if typingMutationByConnection[connectionID] == mutation {
                typingMutationByConnection.removeValue(forKey: connectionID)
            }
        }
        await removeTypingSubscription(connectionID: connectionID)
    }

    public func notifyTyping(roomID: RoomID, actorUserID: UserID, isTyping: Bool, expiresAt: Date) async {
        let state = V2TypingState(roomID: roomID, userID: actorUserID, isTyping: isTyping, expiresAt: expiresAt)
        await notifyTypingWatchers(state)
        await liveActivityBroker?.publishTyping(state)
    }

    public func receivePresence(targetUserID: UserID, isOnline: Bool, expiresAt: Date) async {
        await notifyPresenceWatchers(targetUserID: targetUserID, isOnline: isOnline, expiresAt: expiresAt)
    }

    public func receiveTyping(_ state: V2TypingState) async {
        await notifyTypingWatchers(state)
    }

    @discardableResult
    public func applyLiveActivityPreferences(connectionID: UUID, allowsOnlinePresence: Bool) async -> Bool {
        guard let identity = identityByConnection[connectionID],
              let lifecycle = lifecycleByConnection[connectionID]
        else { return false }
        if allowsOnlinePresence {
            return await refreshLivePresence(connectionID: connectionID)
        } else {
            // 保持每份连接准入租约有效。数据库读取与刷新广播
            // 都会应用隐私偏好，因此租约虽不可见，仍可在网关副本间限制连接数。
            guard lifecycleByConnection[connectionID] == lifecycle else { return false }
            await routePresence(targetUserID: identity.userID, isOnline: false, expiresAt: Date())
            return lifecycleByConnection[connectionID] == lifecycle
        }
    }

    private func notifyTypingWatchers(_ state: V2TypingState) async {
        let streams = typingWatchersByRoom[state.roomID].map { Array($0) } ?? []
        let candidates = streams.compactMap { connectionID, stream -> (V2LiveObservationKey, V2GatewayByteStream)? in
            guard let observer = identityByConnection[connectionID]?.userID, observer != state.userID else { return nil }
            return (.init(roomID: state.roomID, observerUserID: observer, subjectUserID: state.userID), stream)
        }
        let authorized = await authorizedObservationKeys(Set(candidates.map(\.0)))
        for (key, stream) in candidates where authorized.contains(key) {
            guard typingWatchersByRoom[state.roomID]?.values.contains(where: { $0 === stream }) == true else { continue }
            await stream.sendTypingState(state)
        }
    }

    private func routePresence(targetUserID: UserID, isOnline: Bool, expiresAt: Date) async {
        await notifyPresenceWatchers(targetUserID: targetUserID, isOnline: isOnline, expiresAt: expiresAt)
        await liveActivityBroker?.publishPresence(targetUserID: targetUserID, isOnline: isOnline, expiresAt: expiresAt)
    }

    private func compensateStalePresence(connectionID: UUID, identity: V2AuthenticatedConnection) async {
        // 较新的生命周期可能有意复用此 UUID，并已拥有数据库记录。
        // 过期续体不能删除它。
        guard lifecycleByConnection[connectionID] == nil else { return }
        guard let remainsOnline = await removePresenceLease(
            identity: identity,
            connectionID: connectionID
        ) else { return }
        guard !remainsOnline,
              identityByConnection[connectionID] == nil
        else { return }
        await routePresence(targetUserID: identity.userID, isOnline: false, expiresAt: Date())
    }

    private func removePresenceLease(
        identity: V2AuthenticatedConnection,
        connectionID: UUID
    ) async -> Bool? {
        guard let livePresenceLeases else {
            return streamsByUser[identity.userID] != nil
        }
        return try? await livePresenceLeases.removePresence(
            identity: identity,
            connectionID: connectionID,
            now: Date()
        )
    }

    private func notifyPresenceWatchers(targetUserID: UserID, isOnline: Bool, expiresAt: Date) async {
        let streams = presenceWatchersByTarget[targetUserID].map { Array($0) } ?? []
        let candidates = streams.compactMap { connectionID, stream -> (V2LiveObservationKey, V2GatewayByteStream)? in
            guard let watch = presenceByConnection[connectionID],
                  let observer = identityByConnection[connectionID]?.userID,
                  watch.targetUserID == targetUserID
            else { return nil }
            return (.init(roomID: watch.roomID, observerUserID: observer, subjectUserID: targetUserID), stream)
        }
        let authorized = await authorizedObservationKeys(Set(candidates.map(\.0)))
        for (key, stream) in candidates where authorized.contains(key) {
            guard presenceWatchersByTarget[targetUserID]?.values.contains(where: { $0 === stream }) == true else { continue }
            await stream.sendPresenceState(.init(roomID: key.roomID, targetUserID: targetUserID, isOnline: isOnline, expiresAt: expiresAt))
        }
    }

    /// 同一个观察者拥有的所有设备，其授权判断都相同。
    ///
    /// 因此对每个唯一的数据库检查只执行一次，并以较小的并发上限控制，
    /// 而不是把每个观察者都串行推到这个注册表 actor 之后。
    ///
    /// - Parameter keys: 待授权的观察键集合。
    /// - Returns: 通过授权的观察键集合。
    private func authorizedObservationKeys(_ keys: Set<V2LiveObservationKey>) async -> Set<V2LiveObservationKey> {
        guard let liveActivityObservationAuthorizer else { return keys }
        let values = Array(keys)
        return await withTaskGroup(of: (V2LiveObservationKey, Bool).self) { group in
            var nextIndex = 0
            let maximumConcurrency = min(8, values.count)
            for index in 0..<maximumConcurrency {
                let key = values[index]
                group.addTask {
                    do {
                        try await liveActivityObservationAuthorizer.authorizeObservation(
                            roomID: key.roomID,
                            viewerUserID: key.observerUserID,
                            subjectUserID: key.subjectUserID,
                            now: Date()
                        )
                        return (key, true)
                    } catch { return (key, false) }
                }
                nextIndex += 1
            }
            var allowed: Set<V2LiveObservationKey> = []
            while let (key, isAllowed) = await group.next() {
                if isAllowed { allowed.insert(key) }
                if nextIndex < values.count {
                    let key = values[nextIndex]
                    group.addTask {
                        do {
                            try await liveActivityObservationAuthorizer.authorizeObservation(
                                roomID: key.roomID,
                                viewerUserID: key.observerUserID,
                                subjectUserID: key.subjectUserID,
                                now: Date()
                            )
                            return (key, true)
                        } catch { return (key, false) }
                    }
                    nextIndex += 1
                }
            }
            return allowed
        }
    }

    private func removePresenceSubscription(connectionID: UUID) async {
        guard let previous = presenceByConnection.removeValue(forKey: connectionID) else { return }
        presenceWatchersByTarget[previous.targetUserID]?.removeValue(forKey: connectionID)
        if presenceWatchersByTarget[previous.targetUserID]?.isEmpty == true {
            presenceWatchersByTarget.removeValue(forKey: previous.targetUserID)
            if let liveActivityBroker {
                await liveActivityBroker.deactivatePresence(targetUserID: previous.targetUserID)
                if presenceWatchersByTarget[previous.targetUserID] != nil {
                    try? await liveActivityBroker.activatePresence(targetUserID: previous.targetUserID)
                }
            }
        }
    }

    private func removeTypingSubscription(connectionID: UUID) async {
        guard let roomID = typingRoomByConnection.removeValue(forKey: connectionID) else { return }
        typingWatchersByRoom[roomID]?.removeValue(forKey: connectionID)
        if typingWatchersByRoom[roomID]?.isEmpty == true {
            typingWatchersByRoom.removeValue(forKey: roomID)
            if let liveActivityBroker {
                await liveActivityBroker.deactivateTyping(roomID: roomID)
                if typingWatchersByRoom[roomID] != nil {
                    try? await liveActivityBroker.activateTyping(roomID: roomID)
                }
            }
        }
    }

    private func removeForegroundGroupSubscription(connectionID: UUID) async {
        guard let roomID = foregroundGroupByConnection.removeValue(forKey: connectionID) else { return }
        foregroundRoutes.remove(connectionID: connectionID, roomID: roomID)
        streamsByForegroundGroup[roomID]?.removeValue(forKey: connectionID)
        if streamsByForegroundGroup[roomID]?.isEmpty == true {
            streamsByForegroundGroup.removeValue(forKey: roomID)
            if let foregroundGroupInterestManager {
                await foregroundGroupInterestManager.deactivate(roomID: roomID)
                if streamsByForegroundGroup[roomID] != nil {
                    try? await foregroundGroupInterestManager.activate(roomID: roomID)
                }
            }
        }
    }

    /// 一旦捕获到已授权的流快照，各套接字 actor 便彼此独立。
    ///
    /// 单聊房间通常只有一两条本地流；为每条消息都建任务组，
    /// 其开销高于那几个顺序 actor 跳转，还会在高消息速率下造成调度压力。
    /// 更大的群组仍以有界波次发布，
    /// 使一条慢流无法串行化整个房间，网关也不会制造无界的任务突发。
    ///
    /// - Parameters:
    ///   - streams: 目标流列表。
    ///   - roomID: 目标房间标识。
    ///   - highWatermark: 当前高水位。
    ///   - directEvent: 可选的私聊实时事件。
    ///   - prepared: 可选的已准备群事件帧。
    private nonisolated static func publishForeground(
        _ streams: [V2GatewayByteStream],
        roomID: RoomID,
        highWatermark: UInt64,
        directEvent: V2DirectRoomLiveEvent? = nil,
        prepared: V2PreparedGatewayGroupEventAvailable? = nil,
        hints: V2AuthorPresentationHints? = nil,
        ingress: V2AuthorPresentationIngress? = nil
    ) async {
        let sequentialWriteLimit = 4
        if streams.count <= sequentialWriteLimit {
            for stream in streams {
                if Task.isCancelled { return }
                let submitted: Bool
                if let prepared, stream.submitGroupEventAvailable(prepared) {
                    submitted = true
                } else if let prepared {
                    submitted = await stream.sendGroupEventAvailable(prepared)
                } else {
                    submitted = await stream.sendGroupEventAvailable(
                        roomID: roomID,
                        highWatermark: highWatermark,
                        directEvent: directEvent
                    )
                }
                if submitted, let hints, let ingress { stream.offerAuthorPresentation(hints, to: ingress) }
            }
            return
        }

        let maximumConcurrentWrites = 16
        var lowerBound = 0
        while lowerBound < streams.count {
            if Task.isCancelled { return }
            let upperBound = min(lowerBound + maximumConcurrentWrites, streams.count)
            await withTaskGroup(of: Void.self) { group in
                for stream in streams[lowerBound..<upperBound] {
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        let submitted: Bool
                        if let prepared, stream.submitGroupEventAvailable(prepared) {
                            submitted = true
                        } else if let prepared {
                            submitted = await stream.sendGroupEventAvailable(prepared)
                        } else {
                            submitted = await stream.sendGroupEventAvailable(
                                roomID: roomID,
                                highWatermark: highWatermark,
                                directEvent: directEvent
                            )
                        }
                        if submitted, let hints, let ingress { stream.offerAuthorPresentation(hints, to: ingress) }
                    }
                }
            }
            lowerBound = upperBound
        }
    }

    private func rollbackRegistration(
        connectionID: UUID,
        identity: V2AuthenticatedConnection,
        lifecycle: Generation
    ) {
        guard lifecycleByConnection[connectionID] == lifecycle,
              identityByConnection[connectionID] == identity
        else { return }
        publicationSuppressedByConnection.removeValue(forKey:connectionID)
        lifecycleByConnection.removeValue(forKey: connectionID)
        identityByConnection.removeValue(forKey: connectionID)
        streamsByDevice[identity.deviceID]?.removeValue(forKey: connectionID)
        if streamsByDevice[identity.deviceID]?.isEmpty == true {
            streamsByDevice.removeValue(forKey: identity.deviceID)
        }
        streamsByUser[identity.userID]?.removeValue(forKey: connectionID)
        if streamsByUser[identity.userID]?.isEmpty == true {
            streamsByUser.removeValue(forKey: identity.userID)
        }
    }

    /// 供高频变动测试使用的内部不变量探针。
    ///
    /// 变更代次只是短暂的可重入围栏，绝不能演变成一份连接历史台账。
    ///
    /// - Returns: 当前暂存的可重入围栏数量。
    func transientMutationTokenCount() -> Int {
        foregroundMutationByConnection.count
            + presenceMutationByConnection.count
            + typingMutationByConnection.count
    }

    private func makeGeneration() -> Generation {
        nextGeneration &+= 1
        precondition(nextGeneration != 0, "connection registry generation exhausted")
        return nextGeneration
    }

}

/// 分片的、基于锁的前台路由快照。
///
/// 订阅权威仍由 `V2DeviceConnectionRegistry` 确立；
/// 这里的条目只包含为私聊实时载荷建立围栏所需的已认证用户身份，
/// 以及用于尽力而为提示的进程本地流引用。
private final class V2ForegroundConnectionRoutes: Sendable {
    private struct Entry: Sendable {
        let userID: UserID
        let membershipRevision: UInt64
        let stream: V2GatewayByteStream
    }

    private struct State: Sendable {
        var entriesByRoom: [RoomID: [UUID: Entry]] = [:]
        /// 群组发布的频率远高于订阅变更。
        ///
        /// 在变更时构建受修订围栏保护的不可变数组，
        /// 使热房间无需为每个前台批次重新分配并保留全部流。
        /// 查找时复制一个数组值只保留其写时复制存储；并发变更会发布一份新快照。
        var groupStreamsByRoomRevision:
            [RoomID: [UInt64: [V2GatewayByteStream]]] = [:]
        /// 一次大规模重连潮可能在首个实时事件之前加入大量观看者。
        ///
        /// 在这波之后惰性重建一次，
        /// 而不是把 N 次订阅变成 O(N²) 次快照复制。
        var dirtyGroupStreamRooms: Set<RoomID> = []
    }

    private final class Shard: Sendable {
        let state = Mutex(State())
    }

    private let shards: [Shard]

    init(shardCount: Int = 16) {
        precondition(shardCount > 0)
        shards = (0..<shardCount).map { _ in Shard() }
    }

    func upsert(
        connectionID: UUID,
        roomID: RoomID,
        userID: UserID,
        membershipRevision: UInt64,
        stream: V2GatewayByteStream
    ) {
        shard(for: roomID).state.withLock { state in
            state.entriesByRoom[roomID, default: [:]][connectionID] = .init(
                userID: userID,
                membershipRevision: membershipRevision,
                stream: stream
            )
            state.dirtyGroupStreamRooms.insert(roomID)
        }
    }

    func remove(connectionID: UUID, roomID: RoomID) {
        shard(for: roomID).state.withLock { state in
            state.entriesByRoom[roomID]?.removeValue(forKey: connectionID)
            if state.entriesByRoom[roomID]?.isEmpty == true {
                state.entriesByRoom.removeValue(forKey: roomID)
                state.groupStreamsByRoomRevision.removeValue(forKey: roomID)
                state.dirtyGroupStreamRooms.remove(roomID)
            } else {
                state.dirtyGroupStreamRooms.insert(roomID)
            }
        }
    }

    func streams(roomID: RoomID) -> [V2GatewayByteStream] {
        shard(for: roomID).state.withLock {
            $0.entriesByRoom[roomID].map { Array($0.values.map(\.stream)) } ?? []
        }
    }

    func streams(
        roomID: RoomID,
        recipientUserIDs: Set<UserID>,
        excludingConnectionID: UUID? = nil
    ) -> [V2GatewayByteStream] {
        shard(for: roomID).state.withLock { state in
            guard let entries = state.entriesByRoom[roomID] else { return [] }
            return entries.compactMap { connectionID, entry in
                guard connectionID != excludingConnectionID,
                      recipientUserIDs.contains(entry.userID)
                else { return nil }
                return entry.stream
            }
        }
    }

    /// 从不可变的、已认证的订阅状态中选出受众。
    ///
    /// 群组事件绝不只凭房间兴趣就下判断：
    /// 订阅与提交事务必须指向同一个持久成员任期。
    ///
    /// - Parameter event: 待路由的实时事件。
    /// - Returns: 匹配该事件的已授权流。
    func streams(for event: V2DirectRoomLiveEvent) -> [V2GatewayByteStream] {
        shard(for: event.roomID).state.withLock { state in
            if let membershipRevision = event.groupMembershipRevision {
                guard event.recipientUserIDs.isEmpty else { return [] }
                if event.excludedConnectionID == nil {
                    if state.dirtyGroupStreamRooms.remove(event.roomID) != nil {
                        Self.rebuildGroupStreams(roomID: event.roomID, state: &state)
                    }
                    return (
                        state.groupStreamsByRoomRevision[event.roomID]?[membershipRevision]
                    ) ?? []
                }
                guard let entries = state.entriesByRoom[event.roomID] else { return [] }
                return entries.compactMap { connectionID, entry in
                    guard connectionID != event.excludedConnectionID,
                          entry.membershipRevision == membershipRevision
                    else { return nil }
                    return entry.stream
                }
            }
            guard let entries = state.entriesByRoom[event.roomID] else { return [] }
            guard !event.recipientUserIDs.isEmpty else { return [] }
            return entries.compactMap { connectionID, entry in
                guard connectionID != event.excludedConnectionID,
                      event.recipientUserIDs.contains(entry.userID)
                else { return nil }
                return entry.stream
            }
        }
    }

    private static func rebuildGroupStreams(roomID: RoomID, state: inout State) {
        guard let entries = state.entriesByRoom[roomID], !entries.isEmpty else {
            state.groupStreamsByRoomRevision.removeValue(forKey: roomID)
            return
        }
        var streamsByRevision: [UInt64: [V2GatewayByteStream]] = [:]
        streamsByRevision.reserveCapacity(min(entries.count, 4))
        for entry in entries.values {
            streamsByRevision[entry.membershipRevision, default: []].append(entry.stream)
        }
        state.groupStreamsByRoomRevision[roomID] = streamsByRevision
    }

    private func shard(for roomID: RoomID) -> Shard {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in roomID.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return shards[Int(hash % UInt64(shards.count))]
    }
}

private struct V2LiveObservationKey: Hashable, Sendable {
    let roomID: RoomID
    let observerUserID: UserID
    let subjectUserID: UserID
}

extension V2DeviceConnectionRegistry: V2LiveSyncNotifier {}
extension V2DeviceConnectionRegistry: V2ConnectionMetricsSource {}

extension V2DeviceConnectionRegistry: V2AccountRoomChangesStarting {
    public func invalidateAccountRoomCoverage() async {
        await accountChangeService?.invalidateCoverage()
    }

    public func configureAccountRoomChanges(_ service: V2AccountRoomChangeService) {
        precondition(accountChangeService == nil)
        accountChangeService = service
    }

    public func startAccountRoomChanges(connectionID: UUID, userID: UserID) async throws -> String {
        guard let service = accountChangeService,
              let identity = identityByConnection[connectionID], identity.userID == userID,
              let lifecycle = lifecycleByConnection[connectionID],
              let stream = streamsByUser[userID]?[connectionID],
              accountChangeTickets[connectionID] == nil else {
            throw V2AccountRoomChangeService.Failure.staleConnection
        }
        guard await stream.supportsRequiredNotifications(), lifecycleByConnection[connectionID] == lifecycle else {
            throw V2AccountRoomChangeService.Failure.staleConnection
        }
        let ticket = try await service.begin(userID: userID, connectionID: connectionID,
            send: { [weak stream] notification in
                guard let stream else { return false }
                return await stream.sendAccountRoomNotification(notification)
            }, close: { [weak stream] in await stream?.closeForAccountRecovery() })
        guard lifecycleByConnection[connectionID] == lifecycle else {
            await service.stop(ticket)
            throw V2AccountRoomChangeService.Failure.staleConnection
        }
        accountChangeTickets[connectionID] = ticket
        return ticket.epoch.uuidString.lowercased()
    }

    func accountRoomChangesReadyWritten(connectionID: UUID, epoch: String) async throws {
        guard let ticket = accountChangeTickets[connectionID], UUID(uuidString: epoch) == ticket.epoch,
              let service = accountChangeService else { throw V2AccountRoomChangeService.Failure.staleConnection }
        await service.resume(ticket)
    }

    func installAccountRoomDirectory(connectionID: UUID, page: IMV2UserRoomDirectoryPage) async throws {
        guard let ticket = accountChangeTickets[connectionID], let service = accountChangeService else {
            throw V2AccountRoomChangeService.Failure.staleConnection
        }
        let entries = try page.rooms.map { room -> V2UserRoomDirectoryEntry in
            guard let kind = V2RoomKind(rawValue: room.roomKind) else { throw V2RoomRecoveryReadError.corruptPersistence }
            return try .init(roomID: RoomID(room.roomID), roomKind: kind,
                viewerMembershipRevision: room.viewerMembershipRevision, ownerEpoch: room.ownerEpoch)
        }
        try await service.install(entries, ticket: ticket)
    }

    func refreshAccountRoomMemberships(connectionID: UUID, batch: IMV2SyncBatch) async throws {
        // 尚未开始账号覆盖的连接保留普通个人同步行为。
        // 一旦开始，发现结果会先于响应安装。
        guard let ticket = accountChangeTickets[connectionID], let service = accountChangeService else { return }
        let changes = try batch.records.compactMap { try V2AccountRoomMembershipChange.decode($0, userID: ticket.userID) }
        for start in stride(from: 0, to: changes.count, by: 100) {
            try await service.refreshMemberships(Array(changes[start..<min(start + 100, changes.count)]), ticket: ticket)
        }
    }

    func refreshAccountRoomSnapshotMemberships(connectionID: UUID, page: IMV2SnapshotPage) async throws {
        guard let ticket = accountChangeTickets[connectionID], let service = accountChangeService else { return }
        let decoded = try V2SnapshotProjectionV3Codec.decode(page.payload)
        let changes = try decoded.items.compactMap { try V2AccountRoomMembershipChange.decode($0, userID: ticket.userID) }
        for start in stride(from: 0, to: changes.count, by: 100) {
            try await service.refreshMemberships(Array(changes[start..<min(start + 100, changes.count)]), ticket: ticket)
        }
    }

    func notifyAccountRoomAvailable(roomID: RoomID) async {
        await accountChangeService?.notify(roomID: roomID)
    }
}
