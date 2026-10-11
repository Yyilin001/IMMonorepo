import IMV2ActorContracts
import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Compression
import IMV2Core
import Synchronization

public struct V2GatewayJournalUserControlInterest: Hashable, Sendable {
    public let connectionID: UUID
    public let userID: UserID
    public let deviceID: DeviceID
    public let lifecycle: UInt64
    public init(connectionID: UUID, userID: UserID, deviceID: DeviceID, lifecycle: UInt64) {
        self.connectionID = connectionID; self.userID = userID; self.deviceID = deviceID; self.lifecycle = lifecycle
    }
}

public struct V2GatewayJournalUserControlApplied: Sendable {
    public let source: V2RealtimeJournalSource
    public let versions: [UserID: UInt64]
}

/// 已认证实时连接的进程本地索引。
///
/// 持久吊销消费者会在每个网关副本上调用该注册表。
public actor V2DeviceConnectionRegistry {
    /// 前台通知属于高频路径。
    ///
    /// 把它们的不可变路由快照放在注册表 actor 之外，
    /// 使无关房间不会排在连接生命周期与在线状态工作之后。
    private nonisolated let foregroundRoutes = V2ForegroundConnectionRoutes()
    private nonisolated let journalUserBaseline = Mutex<V2CallbackBox<@Sendable (UserID) async throws -> V2GatewayJournalUserBaselineProof>?>(nil)
    private var journalDeviceFloors: [V2RealtimeJournalSource: [V2RealtimeJournalDeviceKey: Int64]] = [:]
    private var journalUserFloors: [V2RealtimeJournalSource: [UUID: V2RealtimeJournalUserControl]] = [:]
    private nonisolated let journalInterestChanged = Mutex<V2CallbackBox<@Sendable () -> Void>?>(nil)
    private nonisolated let journalReceiver = Mutex<V2GatewayJournalProjectionReceiver?>(nil)
    private nonisolated let roomSubscriptionAuthority = Mutex<V2GatewayRoomSubscriptionAuthority?>(nil)
    private nonisolated let roomSubscriptionHeadWorker = Mutex<V2GatewayRoomSubscriptionHeadWorker?>(nil)
    private struct RoomSubscriptionConnection {
        let lifecycle: UUID
        var scopeGeneration: UInt64?
        var reference: UUID?
    }
    private var roomSubscriptionConnections: [UUID: RoomSubscriptionConnection] = [:]
    private var roomSubscriptionCoordinator: V2GatewayRoomSubscriptionCoordinator?
    /// 同一 Gateway 创建的每条流都使用这套进程级帧契约。
    ///
    /// 提供之后，前台广播只编码一次并共享不可变字节；
    private let foregroundFrameLimits: V2FrameLimits
    private let foregroundFrameCompression: V2NegotiatedFrameCompression?
    private let foregroundMaximumUncompressedPayloadBytes: Int
    private let foregroundCompressionThresholdBytes: Int
    private let foregroundMaximumCompressionExpansionRatio: Int
    private nonisolated let authorIngress = Mutex<V2AuthorPresentationIngress?>(nil)
    private nonisolated var authorPresentationIngress: V2AuthorPresentationIngress? { authorIngress.withLock { $0 } }
    private let connectionAdmissionPolicy: V2AuthenticatedConnectionAdmissionPolicy
    private let livePresenceRenewalConfiguration: V2LivePresenceRenewalBatcher.Configuration
    private var directory = V2ConnectionDirectory()
    private nonisolated let onlineRoomStreams = Mutex<[UUID: V2GatewayByteStream]>([:])
    private var subscriptions = V2ConnectionSubscriptionState()
    private var hasStartedRegistrations = false
    private var accountChangeService: V2AccountRoomChangeService?
    private var directoryGenerations: [UUID: UInt64] = [:]
    private nonisolated let directoryDeliveryFences = Mutex<[UUID: UInt64]>([:])
    private var accountCoverageInstallations: [UUID: UInt64] = [:]
    private var accountChangeTickets: [UUID: V2AccountRoomCoverageIndex.Ticket] = [:]
    /// 每次注册都会获得一个新令牌。
    ///
    /// actor 方法会在外部 await 之后重新校验它，
    /// 使较早的续体无法在注销之后、或同一连接 ID 再次注册之后复活状态。
    private typealias Generation = UInt64
    // A physical connection ID cannot be rebound while an older database
    // admit/renew/remove is still actually settling (including compensation).

    /// 前台群组观看关系刻意是进程本地的软状态。
    ///
    /// 在进程或连接失败之后，持久房间事件日志与常规的每用户同步仍是恢复来源。
    private var livePresenceLeases: (any V2LivePresenceLeaseManaging)?
    private var leaseController: V2ConnectionLeaseController?
    private let maximumConnections: Int
    private var deviceRoomProgressStore: (any V2DeviceRoomProgressStoring)?

    public func installDeviceRoomProgressStore(_ store: any V2DeviceRoomProgressStoring) throws {
        guard !hasStartedRegistrations, deviceRoomProgressStore == nil else {
            throw V2ResourceProviderError.configurationInvalid
        }
        deviceRoomProgressStore = store
    }

    func handleDeviceRoomProgress(_ envelope: IMV2Envelope, connectionID: UUID,
        identity: V2AuthenticatedConnection) async -> IMV2Envelope? {
        guard case .deviceRoomProgressReport(let report) = envelope.body else { return nil }
        var response = IMV2Envelope()
        do {
            guard !report.rooms.isEmpty, report.rooms.count <= 64,
                  report.rooms.allSatisfy({ UUID(uuidString: $0.roomID) != nil && $0.appliedThrough <= UInt64(Int64.max) }) else {
                throw V2RoomRecoveryReadError.invalidRequest
            }
            guard let store = deviceRoomProgressStore,
                  let authority = roomSubscriptionAuthority.withLock({ $0 }),
                  let lifecycle = directory.lifecycleByConnection[connectionID],
                  directory.identityByConnection[connectionID]?.userID == identity.userID,
                  directory.identityByConnection[connectionID]?.deviceID == identity.deviceID else {
                throw V2RoomRecoveryReadError.invalidCursor
            }
            let progress = try await authority.validateDeviceProgress(connectionID: connectionID, userID: identity.userID,
                reports: report.rooms.map { (try RoomID($0.roomID), $0.appliedThrough) })
            try await store.record(userID: identity.userID, deviceID: identity.deviceID, progress: progress)
            guard directory.lifecycleByConnection[connectionID] == lifecycle else { throw CancellationError() }
            response.deviceRoomProgressRecorded = .init()
            response.deviceRoomProgressRecorded.rooms = report.rooms
        } catch {
            response.error = .init()
            switch error as? V2RoomRecoveryReadError {
            case .invalidRequest: response.error.code = "INVALID_ARGUMENT"
            case .invalidCursor: response.error.code = "FORBIDDEN"
            default: response.error.code = "UNAVAILABLE"
            }
            response.error.retryable = response.error.code == "UNAVAILABLE"
        }
        return response
    }
    private var leaseRenewalsClosed = false
    private var liveActivityObservationAuthorizer: (any V2LiveActivityObservationAuthorizing)?
    private var userSyncInterests: V2SharedGroupEventWakeInterests?
    private var userSyncScopes: [UUID: UUID] = [:]
    private typealias RecoveryKey = V2RealtimeRecoveryKey
    private let recoveryCoordinator: V2RealtimeRecoveryCoordinator
    private var recoveryPortsConfigured = false
    private var realtimeRecoveryClosed = false
    private var realtimeRecoveryShutdown: Task<Void, Never>?
    private let lifecycleSupervisor: V2GatewayLifecycleSupervisor
    private var dirtyPresence: [UserID: (Bool, Date)] = [:]
    private var dirtyPresenceWorker: Task<Void, Never>?
    private let maximumDirtyPresenceUsers = 1_024

    private var brokerRoutesLocalActivity = false
    private var liveActivityBroker: (any V2LiveActivityInterestManaging & V2LiveActivityPublishing)?
    private typealias PresenceRefreshTarget = V2PresenceRefreshTarget
    private var presenceRefreshCoordinator: V2PresenceRefreshCoordinator?

    /// 这些值是 actor 本地的可重入围栏，而不是公开身份或安全能力。
    ///
    /// 单调递增的代次已经够用，并可避免在连接频繁变动时打开平台随机源。
    private var nextGeneration: Generation = 0

    public init(
        connectionAdmissionPolicy: V2AuthenticatedConnectionAdmissionPolicy = .init(
            maximumConnectionsPerDevice: 2,
            maximumConnectionsPerUser: 8
        ),
        livePresenceRenewalConfiguration: V2LivePresenceRenewalBatcher.Configuration = .init(),
        maximumConnections: Int = 100_000,
        foregroundFrameLimits: V2FrameLimits,
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
        precondition(maximumConnections > 0)
        self.maximumConnections = maximumConnections
        self.lifecycleSupervisor = V2GatewayLifecycleSupervisor(maximumRetained: maximumConnections)
        self.recoveryCoordinator = V2RealtimeRecoveryCoordinator(maximumConnections: maximumConnections)
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

    /// Composition opts in before sockets start. RPC ingress, local subscriber
    /// selection and actual socket gates share this one room-local authority.
    /// Foreground room interest requires this authority.
    public func configureRoomSubscriptionIngress(authority: V2GatewayRoomSubscriptionAuthority,
        maximumRooms: Int = 256) throws -> V2GatewayRoomSubscriptionIngress {
        guard !hasStartedRegistrations, !realtimeRecoveryClosed,
              roomSubscriptionAuthority.withLock({ $0 == nil }), maximumRooms > 0 else {
            throw V2ResourceProviderError.configurationInvalid
        }
        let worker = V2GatewayRoomSubscriptionHeadWorker(maximumRooms: maximumRooms) { [weak self] room, head in
            await self?.publishRoomSubscriptionHead(roomID: room, highWatermark: head)
        }
        roomSubscriptionAuthority.withLock { $0 = authority }
        roomSubscriptionHeadWorker.withLock { $0 = worker }
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority, maximumRooms: maximumRooms,
            offerEvent: { [weak self] event, permits in self?.submitRoomSubscriptionEvent(event, permits: permits) },
            offerHead: { [weak worker] room, head in _ = worker?.offer(roomID: room, highWatermark: head) })
        worker.start()
        return ingress
    }

    /// Inject closures backed by the signed RoomClient and trusted Directory.
    /// This opts actual groupEventSubscribe commands into the room-local owner.
    public func configureRoomSubscriptionPorts(_ ports: V2GatewayRoomSubscriptionPorts,
        ingress: V2GatewayRoomSubscriptionIngress, maximumRelations: Int = 4096,
        maximumConcurrentCalls: Int = 16,
        onCleanupFailure: @escaping @Sendable (RoomID, UserID, any Error) -> Void = { _, _, _ in }) async throws {
        guard !hasStartedRegistrations, !realtimeRecoveryClosed, roomSubscriptionCoordinator == nil,
              roomSubscriptionAuthority.withLock({ $0 === ingress.authority }) else {
            throw V2ResourceProviderError.configurationInvalid
        }
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            maximumRelations: maximumRelations, maximumReferences: max(maximumConnections, maximumRelations),
            maximumConcurrentCalls: maximumConcurrentCalls, onCleanupFailure: onCleanupFailure)
        roomSubscriptionCoordinator = coordinator
        await coordinator.start()
    }

    public func acquireAccountRoomDelivery(userID: UserID, roomID: RoomID, reference: UUID) async throws {
        guard !realtimeRecoveryClosed, let coordinator = roomSubscriptionCoordinator else {
            throw V2GatewayRoomSubscriptionCoordinationError.closed
        }
        // Physical removal precedes the account ticket's asynchronous cleanup.
        // That short gap is online unavailability, not a closed coordinator.
        guard directory.streamsByUser[userID]?.isEmpty == false else {
            throw V2GatewayRoomSubscriptionCoordinationError.refused(.unavailable)
        }
        _ = try await coordinator.acquire(roomID: roomID, userID: userID, reference: reference)
        guard !realtimeRecoveryClosed, directory.streamsByUser[userID]?.isEmpty == false else {
            await coordinator.release(reference: reference)
            if realtimeRecoveryClosed { throw V2GatewayRoomSubscriptionCoordinationError.closed }
            throw V2GatewayRoomSubscriptionCoordinationError.refused(.unavailable)
        }
        // A later device may reuse the existing account grant without a new
        // Owner callback. Resignal its persisted baseline for unopened recovery.
        await roomSubscriptionBaselineInstalled(roomID: roomID)
    }

    public func releaseAccountRoomDelivery(reference: UUID) async {
        await roomSubscriptionCoordinator?.release(reference: reference)
    }

    /// Room subscription commands belong to the connection registry.
    /// There is one signed authoritative subscribe, not an old database/Journal
    /// barrier followed by another new room subscribe.
    func handleRoomSubscriptionCommand(_ envelope: IMV2Envelope, connectionID: UUID,
        identity: V2AuthenticatedConnection) async -> IMV2Envelope? {
        switch envelope.body {
        case .groupEventSubscribe(let request):
            guard roomSubscriptionCoordinator != nil else { return nil }
            guard let room = try? RoomID(request.roomID), directory.identityByConnection[connectionID] == identity,
                  let stream = directory.streamsByUser[identity.userID]?[connectionID] else {
                return v2GatewayErrorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
            }
            do {
                guard let grant = try await subscribeForegroundRoom(stream, connectionID: connectionID, roomID: room) else {
                    return v2GatewayErrorEnvelope(code: "UNAVAILABLE", retryable: true)
                }
                var response = IMV2Envelope(); response.groupEventSubscribed = .init()
                response.groupEventSubscribed.roomID = room.rawValue
                response.groupEventSubscribed.highWatermark = grant.userBaselineSequence
                response.groupEventSubscribed.membershipRevision = grant.memberRevision
                return response
            } catch V2GatewayRoomSubscriptionCoordinationError.refused(.unauthorized) {
                return v2GatewayErrorEnvelope(code: "FORBIDDEN", retryable: false)
            } catch { return v2GatewayErrorEnvelope(code: "UNAVAILABLE", retryable: true) }
        case .groupEventUnsubscribe(let request):
            guard let room = try? RoomID(request.roomID), directory.identityByConnection[connectionID] == identity else {
                return v2GatewayErrorEnvelope(code: "INVALID_ARGUMENT", retryable: false)
            }
            await unsubscribeForegroundGroup(connectionID: connectionID, roomID: room)
            return v2GatewaySuccessEnvelope()
        default: return nil
        }
    }

    /// Baseline/lease refresh composition can resignal local scopes without
    /// manufacturing a Ready from H or from an old partition confirmation.
    public nonisolated func roomSubscriptionBaselineInstalled(roomID: RoomID) async {
        guard let authority = roomSubscriptionAuthority.withLock({ $0 }),
              let highWatermark = await authority.recoveryHighWatermark(roomID: roomID) else { return }
        roomSubscriptionHeadWorker.withLock { $0 }?.offer(roomID: roomID, highWatermark: highWatermark)
    }
    nonisolated func roomSubscriptionProgressSnapshot(connectionID: UUID) async
        -> (authorization: V2GatewayRoomSubscriptionAuthority.Permit, highWatermark: UInt64)? {
        await roomSubscriptionAuthority.withLock { $0 }?.progressSnapshot(connectionID: connectionID)
    }

    private func requestRoomSubscriptionRepair(roomID: RoomID) async {
        await roomSubscriptionCoordinator?.requestBaselineIfRequired(roomID: roomID)
    }

    private nonisolated func publishRoomSubscriptionHead(roomID: RoomID, highWatermark: UInt64) async {
        await requestRoomSubscriptionRepair(roomID: roomID)
        guard let authority = roomSubscriptionAuthority.withLock({ $0 }) else { return }
        // Authority owns durable progress across publishes and stale local offers.
        let highWatermark = max(highWatermark, await authority.recoveryHighWatermark(roomID: roomID) ?? 0)
        let detailPermits = Dictionary(uniqueKeysWithValues: (await authority.capturePermits(roomID: roomID)).map { ($0.connectionID, $0) })
        var backgroundPermits: [V2GatewayRoomSubscriptionAuthority.Permit] = []
        for authorization in await authority.captureOnlinePermits(roomID: roomID) {
            guard let target = foregroundRoutes.target(roomID: roomID, connectionID: authorization.connectionID),
                  target.userID == authorization.userID, let detail = detailPermits[authorization.connectionID] else {
                // Installation H does not prove this device has persisted it.
                // A nonempty baseline must also wake unopened-room recovery.
                if highWatermark > 0 { backgroundPermits.append(authorization) }
                continue
            }
            _ = await target.stream.offerRoomSubscriptionHead(detail, highWatermark: highWatermark,
                permit: { enqueue in authority.enqueueIfCurrent(detail, enqueue: enqueue) })
        }
        guard !backgroundPermits.isEmpty,
              let prepared = V2PreparedGatewayGroupEventAvailable(roomID: roomID,
                highWatermark: highWatermark, directEvent: nil,
                frameLimits: foregroundFrameLimits, compression: foregroundFrameCompression,
                maximumUncompressedPayloadBytes: foregroundMaximumUncompressedPayloadBytes,
                compressionThresholdBytes: foregroundCompressionThresholdBytes,
                maximumExpansionRatio: foregroundMaximumCompressionExpansionRatio) else { return }
        submitRoomSubscriptionFrame(prepared, permits: backgroundPermits, authority: authority)
    }
    private nonisolated func submitRoomSubscriptionEvent(_ event: V2RealtimeRoomEvent,
        permits: [V2GatewayRoomSubscriptionAuthority.Permit]) {
        guard let authority = roomSubscriptionAuthority.withLock({ $0 }),
              let prepared = V2PreparedGatewayGroupEventAvailable(roomID: event.roomID,
                highWatermark: event.highWatermark, directEvent: event.localEvent,
                frameLimits: foregroundFrameLimits, compression: foregroundFrameCompression,
                maximumUncompressedPayloadBytes: foregroundMaximumUncompressedPayloadBytes,
                compressionThresholdBytes: foregroundCompressionThresholdBytes,
                maximumExpansionRatio: foregroundMaximumCompressionExpansionRatio) else { return }
        submitRoomSubscriptionFrame(prepared, permits: permits, authority: authority,
            hints: authorPresentationIngress.flatMap { _ in
                event.groupMembershipRevision == nil
                    ? V2AuthorPresentationHints(directEvent: event.localEvent)
                    : V2AuthorPresentationHints(events: [event.localEvent])
            })
    }
    private nonisolated func submitRoomSubscriptionFrame(_ prepared: V2PreparedGatewayGroupEventAvailable,
        permits: [V2GatewayRoomSubscriptionAuthority.Permit], authority: V2GatewayRoomSubscriptionAuthority,
        hints: V2AuthorPresentationHints? = nil) {
        var submissions: [V2NIOGatewayForegroundWriteSubmission] = []
        var supplementTargets: [V2GatewayByteStream] = []
        for authorization in permits {
            guard let stream = onlineRoomStreams.withLock({ $0[authorization.connectionID] }) else { continue }
            let permit: @Sendable (@Sendable () -> Void) -> Bool = { enqueue in
                authority.enqueueIfCurrent(authorization, enqueue: enqueue)
            }
            if let submission = stream.prepareNIOGroupEventAvailable(prepared, enqueueIfCurrent: permit) {
                submissions.append(submission)
                if hints != nil { supplementTargets.append(stream) }
            }
        }
        // Channel owners retain their existing bounded best-effort budgets;
        // every delayed NIO submission checks the exact local room nonce again.
        V2NIOGatewayForegroundWriter.submitBatch(submissions)
        if let hints, let ingress = authorPresentationIngress {
            for stream in supplementTargets { stream.offerAuthorPresentation(hints, to: ingress) }
        }
    }
    @discardableResult
    private func removeRoomSubscriptionConnection(_ connectionID: UUID) -> UUID? {
        _ = onlineRoomStreams.withLock { $0.removeValue(forKey: connectionID) }
        guard let connection = roomSubscriptionConnections.removeValue(forKey: connectionID) else { return nil }
        roomSubscriptionAuthority.withLock { $0 }?.removeConnection(connectionID, lifecycle: connection.lifecycle)
        return connection.reference
    }

    @discardableResult
    public func register(_ stream: V2GatewayByteStream, connectionID: UUID, identity: V2AuthenticatedConnection, publicationSuppressed:Bool) async throws -> Bool {
        hasStartedRegistrations = true
        // 连接 ID 是单次生命周期的令牌，不是幂等键。
        // 首次注册挂起期间若接受重复 ID，另一条流就可能继承其身份和租约。
        let lifecycle = makeGeneration()
        guard !realtimeRecoveryClosed, !leaseRenewalsClosed, identity.credentialControlVersion >= 0,
              directory.reserve(stream, connectionID: connectionID, identity: identity,
                lifecycle: lifecycle, maximumConnections: maximumConnections,
                policy: connectionAdmissionPolicy) else { return false }
        defer { directory.endOperation(connectionID) }
        if let authority = roomSubscriptionAuthority.withLock({ $0 }) {
            let localLifecycle = UUID()
            guard authority.registerConnection(connectionID, userID: identity.userID, lifecycle: localLifecycle) else {
                _ = directory.remove(connectionID, lifecycle: lifecycle); return false
            }
            if let gate = await stream.roomSubscriptionSocketGate {
                await authority.bindSocket(connectionID, lifecycle: localLifecycle, gate: gate)
            }
            guard !realtimeRecoveryClosed, directory.lifecycleByConnection[connectionID] == lifecycle else {
                authority.removeConnection(connectionID, lifecycle: localLifecycle)
                _ = directory.remove(connectionID, lifecycle: lifecycle)
                return false
            }
            roomSubscriptionConnections[connectionID] = .init(lifecycle: localLifecycle)
            onlineRoomStreams.withLock { $0[connectionID] = stream }
            stream.configureRoomSubscriptionConnectionRevocation {
                authority.removeConnection(connectionID, lifecycle: localLifecycle)
            }
        }
        journalInterestChanged.withLock { $0?.callback }?()
        if journalUserBaseline.withLock({ $0 != nil }) {
            stream.configureLiveStatePrimaryAuthentication { [weak self] enqueue in
                guard let self, let receiver = self.journalReceiver.withLock({ $0 }),
                      let binding = receiver.authenticationBinding(userID: identity.userID) else { return false }
                return receiver.enqueueUserAuthorized(userID: identity.userID, expectedSource: binding.source,
                    expectedFence: binding.fence, enqueue: enqueue)
            }
        }
        if userSyncInterests != nil { userSyncScopes[connectionID] = UUID() }
        recoveryCoordinator.installConnection(.init(handle: directory.handle(connectionID)!,
            accountScope: userSyncScopes[connectionID], registeredAt: directory.registrationTimes[connectionID]!))
        configureRecoveryPortsIfNeeded()
        guard directory.lifecycleByConnection[connectionID] == lifecycle else { return false }
        guard let leaseController else { return true }
        let lease: V2LivePresenceLeaseRefresh?
        do {
            lease = try await leaseController.admit(connectionID: connectionID,
                identity: identity, lifecycle: lifecycle, publicationSuppressed: publicationSuppressed,
                policy: connectionAdmissionPolicy)
        } catch {
            await rollbackRegistration(connectionID: connectionID, identity: identity, lifecycle: lifecycle)
            // 存储或连接池故障并非连接数限制决策。
            // 保留原始错误，让传输遥测能够定位故障依赖，
            // 而不是错误报告配额已满。
            throw error
        }
        guard directory.lifecycleByConnection[connectionID] == lifecycle else {
            await leaseController.revoke(connectionID: connectionID, lifecycle: lifecycle)
            await compensateStalePresence(connectionID: connectionID, identity: identity)
            return false
        }
        guard let lease, case .accepted(let expiresAt) = lease.outcome else {
            await rollbackRegistration(connectionID: connectionID, identity: identity, lifecycle: lifecycle)
            return false
        }
        guard !publicationSuppressed else { return true }
        await routePresence(targetUserID: identity.userID, isOnline: true, expiresAt: expiresAt)
        if directory.lifecycleByConnection[connectionID] != lifecycle {
            await compensateStalePresence(connectionID: connectionID, identity: identity)
            return false
        }
        return true
    }

    public func setPresencePublication(connectionID:UUID,identity:V2AuthenticatedConnection,
        mode:V2PresencePublicationMode) async throws {
        guard directory.identityByConnection[connectionID]==identity,let lifecycle=directory.lifecycleByConnection[connectionID],let controller=leaseController else {throw V2GatewaySessionError.unsupportedCommand}
        let suppressed=mode == .suppressed
        // The durable lease flag precedes the acknowledgement. All account,
        // device and connection fields are matched in the persistence boundary.
        guard let observation=try await controller.setPresencePublication(connectionID:connectionID,
            lifecycle:lifecycle,identity:identity,suppressed:suppressed) else {throw V2GatewaySessionError.unsupportedCommand}
        guard directory.lifecycleByConnection[connectionID]==lifecycle,directory.identityByConnection[connectionID]==identity else {throw V2GatewaySessionError.unsupportedCommand}
        await routePresence(targetUserID:identity.userID,isOnline:observation.isOnline,expiresAt:observation.expiresAt)
    }

    public func unregister(connectionID: UUID) async {
        guard let removed = directory.remove(connectionID) else { return }
        let roomReference = removeRoomSubscriptionConnection(connectionID)
        journalInterestChanged.withLock { $0?.callback }?()
        removed.stream.invalidateForegroundAuthorization()
        removed.stream.revokeRecoveryWorkImmediately()
        directory.beginRetirementOperation(connectionID, lifecycle: removed.lifecycle)
        lifecycleSupervisor.retain(connectionID: connectionID, lifecycle: removed.lifecycle, stream: removed.stream) { id, lifecycle in
            await self.completeRetiredRecoveryWork(connectionID: id, lifecycle: lifecycle)
        }
        let identity = removed.identity, revokedLifecycle = removed.lifecycle
        defer { directory.endOperation(connectionID) }
        let syncScope = userSyncScopes.removeValue(forKey: connectionID)
        // Admission ownership ends with the physical connection. Room release
        // and recovery-task joins must not keep a closed socket in the durable
        // connection quota while its replacement authenticates.
        await leaseController?.revoke(connectionID: connectionID, lifecycle: revokedLifecycle)
        let remainsOnline = await removePresenceLease(identity: identity, connectionID: connectionID)
        if let roomReference { await roomSubscriptionCoordinator?.release(reference: roomReference) }
        let revokedScopes = recoveryCoordinator.revokeConnection(connectionID, lifecycle: revokedLifecycle)
        directoryGenerations.removeValue(forKey: connectionID)
        directoryDeliveryFences.withLock { $0.removeValue(forKey: connectionID) }
        await presenceRefreshCoordinator?.revoke(connection: connectionID, lifecycle: revokedLifecycle)
        await recoveryCoordinator.detachConnection(connectionID, revokedScopes: revokedScopes)
        if let scope = syncScope {
            await deactivateUserSyncInterest(userID: identity.userID, scope: scope)
        }
        if let ticket = accountChangeTickets.removeValue(forKey: connectionID), let accountChangeService {
            await accountChangeService.stop(ticket)
        }
        guard directory.lifecycleByConnection[connectionID] == nil else { return }
        do {
            let mutation = makeGeneration()
            subscriptions.foregroundMutationByConnection[connectionID] = mutation
            defer {
                if subscriptions.foregroundMutationByConnection[connectionID] == mutation {
                    subscriptions.foregroundMutationByConnection.removeValue(forKey: connectionID)
                }
            }
            await removeForegroundGroupSubscription(connectionID: connectionID)
        }
        guard directory.lifecycleByConnection[connectionID] == nil else { return }
        do {
            let mutation = makeGeneration()
            subscriptions.presenceMutationByConnection[connectionID] = mutation
            defer {
                if subscriptions.presenceMutationByConnection[connectionID] == mutation {
                    subscriptions.presenceMutationByConnection.removeValue(forKey: connectionID)
                }
            }
            await removePresenceSubscription(connectionID: connectionID)
        }
        guard directory.lifecycleByConnection[connectionID] == nil else { return }
        do {
            let mutation = makeGeneration()
            subscriptions.typingMutationByConnection[connectionID] = mutation
            defer {
                if subscriptions.typingMutationByConnection[connectionID] == mutation {
                    subscriptions.typingMutationByConnection.removeValue(forKey: connectionID)
                }
            }
            await removeTypingSubscription(connectionID: connectionID)
        }
        // 消息代理拆除等待期间，后续注册可能复用了该 ID。
        // 旧续体不能删除新注册的租约。
        guard directory.lifecycleByConnection[connectionID] == nil else { return }
        guard let remainsOnline else {
            // 跨副本查询失败不能证明用户离线。
            // 短期数据库租约会自行收敛，无须在故障期间发出误导性的全局状态转换。
            return
        }
        if !remainsOnline, directory.lifecycleByConnection[connectionID] == nil {
            await routePresence(targetUserID: identity.userID, isOnline: false, expiresAt: Date())
        }
    }

    private func completeRetiredRecoveryWork(connectionID: UUID, lifecycle: UInt64) {
        lifecycleSupervisor.settle(connectionID: connectionID, lifecycle: lifecycle)
        directory.endRetirementOperation(connectionID, lifecycle: lifecycle)
    }

    public func revoke(deviceID: DeviceID) async {
        let connections = directory.streamsByDevice[deviceID].map { Array($0) } ?? []
        // Invalidate every queued foreground write before any cleanup can suspend.
        // A slow lease or broker teardown must not leave another socket authorized.
        var roomReferences: [UUID] = []
        for (connectionID, stream) in connections {
            if let reference = removeRoomSubscriptionConnection(connectionID) { roomReferences.append(reference) }
            stream.invalidateForegroundAuthorization()
        }
        func visitConnections(_ operation: @escaping @Sendable (UUID, V2GatewayByteStream) async -> Void) async {
            await withTaskGroup(of: Void.self) { group in
                var nextIndex = 0
                let maximumConcurrency = min(16, connections.count)
                for index in 0..<maximumConcurrency {
                    let (connectionID, stream) = connections[index]
                    group.addTask {
                        await operation(connectionID, stream)
                    }
                    nextIndex += 1
                }
                while await group.next() != nil {
                    if nextIndex < connections.count {
                        let (connectionID, stream) = connections[nextIndex]
                        group.addTask {
                            await operation(connectionID, stream)
                        }
                        nextIndex += 1
                    }
                }
            }
        }
        // All physical closures finish before cleanup can occupy worker slots.
        // The durable control cursor still waits for both owned phases.
        await visitConnections { _, stream in await stream.closeTransportForDeviceRevocation() }
        await visitConnections { connectionID, stream in
            await stream.revokeDevice()
            await self.unregisterRevokedConnection(connectionID: connectionID, deviceID: deviceID, stream: stream)
        }
        // Remote room cleanup must not delay physical credential revocation.
        // These exact references were detached before any suspension above.
        for reference in roomReferences { await roomSubscriptionCoordinator?.release(reference: reference) }
    }

    private func unregisterRevokedConnection(
        connectionID: UUID,
        deviceID: DeviceID,
        stream: V2GatewayByteStream
    ) async {
        // An old close continuation must not remove a new registration using
        // the same connection ID after this revocation snapshot was taken.
        guard directory.streamsByDevice[deviceID]?[connectionID] === stream else { return }
        await unregister(connectionID: connectionID)
    }

    private func deactivateUserSyncInterest(userID: UserID, scope: UUID) async {
        guard let room = try? RoomID(userID.rawValue), let interests = userSyncInterests else { return }
        await interests.manager(for: .account(scope)).deactivate(roomID: room)
    }

    /// Called only after the authenticated response has actually been written.
    public func authenticationResponseWritten(connectionID: UUID) async {
        guard let lifecycle = directory.lifecycleByConnection[connectionID] else { return }
        await recoveryCoordinator.authenticationResponseWritten(connectionID: connectionID, lifecycle: lifecycle)
    }

    private func beginScopeRecovery(connection: UUID, kind: V2RealtimeTopicKind, id: String) async {
        guard let lifecycle = directory.lifecycleByConnection[connection] else { return }
        let key = RecoveryKey(connection: connection, kind: kind, id: id)
        guard let generation = recoveryCoordinator.requestScope(key, lifecycle: lifecycle) else { return }
        await recoveryCoordinator.beginScopeRecovery(connection: connection, kind: kind, id: id,
            scopeGeneration: generation, lifecycle: lifecycle)
    }

    private func endScope(connection: UUID, kind: V2RealtimeTopicKind, id: String, stream: V2GatewayByteStream?) async {
        let key = RecoveryKey(connection: connection, kind: kind, id: id)
        guard let generation = recoveryCoordinator.generation(for: key),
              recoveryCoordinator.revokeScope(key, generation: generation) else { return }
        if kind == .userPresence {
            await presenceRefreshCoordinator?.revoke(connection: connection,
                lifecycle: directory.lifecycleByConnection[connection], generation: generation)
        }
        await recoveryCoordinator.endScope(connection: connection, kind: kind, id: id, stream: stream,
            expectedGeneration: generation)
    }

    /// Transfer a selected scope to the connection-owned bounded writer. The
    /// caller's actual scheduling slot ends after offer, while this exact ticket
    /// keeps the scope fenced and its work capacity reserved until settlement.

    private func compensateStaleScope(key: RecoveryKey, lifecycle: UInt64, accountScope: UUID?, user: UserID) async {
        switch key.kind {
        case .userSync:
            if let scope = accountScope { await deactivateUserSyncInterest(userID: user, scope: scope) }
        case .roomEvents, .userPresence, .roomTyping:
            break // Exact recovery ticket release belongs to the Coordinator.

        }
    }

    private nonisolated func directoryWritePermit(_ connection: UUID, generation: UInt64)
        -> @Sendable (@Sendable () -> Void) -> Bool {
        return { enqueue in
            self.directoryDeliveryFences.withLock { current in
                guard current[connection] == generation else { return false }
                enqueue(); return true
            }
        }
    }

    public nonisolated func recoverySchedulingMetricsSnapshot() -> V2RecoverySchedulingSnapshot {
        recoveryCoordinator.schedulingTelemetrySnapshot()
    }

    public func registryRecoveryMetricsSnapshot() async -> V2RegistryRecoveryMetricsSnapshot {
        var snapshot = await recoveryCoordinator.registryRecoveryMetricsSnapshot()
        snapshot.presenceObservationStages = await presenceRefreshCoordinator?.metricsSnapshot() ?? [:]
        snapshot.retiredRecoveryWriterStages = lifecycleSupervisor.metricsSnapshot()
        return snapshot
    }

    func realtimeRecoverySnapshot() async -> (desired: Int, queued: Int, actual: Int, closed: Bool, control: Int, positions: Int, interest: Int, queryRoots: Int) {
        return await recoveryCoordinator.realtimeRecoverySnapshot()
    }

    public func shutdownRealtimeRecovery() async {
        if let shutdown = realtimeRecoveryShutdown { await shutdown.value; return }
        realtimeRecoveryClosed = true
        recoveryCoordinator.revokeAllWrites()
        await roomSubscriptionAuthority.withLock { $0 }?.shutdown()
        onlineRoomStreams.withLock { $0.removeAll() }
        let localHeads = roomSubscriptionHeadWorker.withLock { $0 }
        let localSubscriptions = roomSubscriptionCoordinator
        roomSubscriptionConnections.removeAll()
        var streams: [V2GatewayByteStream] = []
        var seen: Set<ObjectIdentifier> = []
        for bucket in directory.streamsByUser.values {
            for stream in bucket.values where seen.insert(ObjectIdentifier(stream)).inserted {
                stream.revokeRecoveryWorkImmediately()
                streams.append(stream)
            }
        }
        let drainingStreams = streams
        // Revoke actual enqueue permits before awaiting submitted work. Late
        // handoffs cannot advertise Ready while shutdown drains their ownership.
        dirtyPresence.removeAll()
        let presence = dirtyPresenceWorker
        let observations = presenceRefreshCoordinator
        // Both owners close admission and join actual query/write responsibility.
        let shutdown = Task.detached {
            let nextStream = Mutex(0)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await observations?.finish() }
                group.addTask { await self.recoveryCoordinator.shutdown() }
                group.addTask { await self.lifecycleSupervisor.finish() }
                for _ in 0..<min(16, drainingStreams.count) {
                    group.addTask {
                        while true {
                            let index = nextStream.withLock { next -> Int? in
                                guard next < drainingStreams.count else { return nil }
                                defer { next += 1 }
                                return next
                            }
                            guard let index else { return }
                            await drainingStreams[index].drainRecoveryWork()
                        }
                    }
                }
                await group.waitForAll()
            }
            // Concurrent unregisters can transfer a snapshotted active stream
            // while those physical roots drain. Join their final callbacks too.
            await self.lifecycleSupervisor.finish()
            await presence?.value
            await localHeads?.shutdown()
            await localSubscriptions?.shutdown()
            await self.clearRealtimeScopes()
        }
        realtimeRecoveryShutdown = shutdown
        await shutdown.value
    }

    private func clearRealtimeScopes() async {
        liveActivityBroker = nil
        brokerRoutesLocalActivity = false
        let scopes = userSyncScopes.compactMap { connection, scope -> (UserID, UUID)? in
            directory.identityByConnection[connection].map { ($0.userID, scope) }
        }
        let tickets = Array(accountChangeTickets.values)
        userSyncScopes.removeAll()
        accountChangeTickets.removeAll(); directoryGenerations.removeAll(); directoryDeliveryFences.withLock { $0.removeAll() }
        for (user, scope) in scopes { await deactivateUserSyncInterest(userID: user, scope: scope) }
        if let service = accountChangeService { for ticket in tickets { await service.stop(ticket) } }
    }

    public func configureRealtimeCoverageValidation(
        current: @escaping @Sendable (V2RealtimeTopicKind, String) -> V2RealtimeCoverageConfirmation?,
        confirms: @escaping @Sendable (V2RealtimeTopicKind, String, V2RealtimeCoverageConfirmation) -> Bool) async {
        precondition(!hasStartedRegistrations)
        await recoveryCoordinator.configureCoverage(current: current, confirms: confirms)
    }

    public func configureUserSyncInterests(_ interests: V2SharedGroupEventWakeInterests) async {
        precondition(!hasStartedRegistrations)
        userSyncInterests = interests
        await recoveryCoordinator.configureUserSync(interests)
    }

    /// Accepted durable RPC work transfers its responsibility to current local
    /// scopes before attempting sockets. Receipts prove enqueue, never delivery.
    public func retainDurableRealtimeDelivery(_ delivery: V2RealtimeDelivery,
        isCurrent: @escaping @Sendable () -> Bool) async {
        await recoveryCoordinator.retainDurableRealtimeDelivery(delivery, isCurrent: isCurrent)
    }

    /// The ingress submits already-authorized live bodies before this control
    /// handoff. Until a continuous authorization projection is installed, use
    /// the existing permission-fenced recovery path for watermarks; an interest
    /// or a journal position alone is not a viewer authorization grant.
    public func applySharedRealtimeDelivery(_ delivery: V2RealtimeDelivery,
        isCurrent: @escaping @Sendable () -> Bool) async {
        switch delivery.payload {
        case .roomWake, .roomEvents, .userSync:
            await recoveryCoordinator.retainDurableRealtimeDelivery(delivery, isCurrent: isCurrent)
        case .presence, .typing:
            break
        }
    }

    /// Production Journal owns account/session/device control only. Room-local
    /// subscriptions and account durable reads retain separate authority.
    public func configureJournalUserControlReceiver(_ receiver: V2GatewayJournalProjectionReceiver) {
        precondition(!hasStartedRegistrations)
        journalReceiver.withLock { $0 = receiver }
    }

    /// Install the trusted cold worker before accepting authenticated sockets.
    public func configureJournalUserBaselineBarrier(
        _ barrier: @escaping @Sendable (UserID) async throws -> V2GatewayJournalUserBaselineProof
    ) async {
        precondition(!hasStartedRegistrations)
        journalUserBaseline.withLock { $0 = V2CallbackBox(barrier) }
        await recoveryCoordinator.configureJournalUserBaseline { [weak self] user in
            guard let self else { throw CancellationError() }
            return try await self.authorizeJournalUserBaseline(user)
        }
    }

    private nonisolated func authorizeJournalUserBaseline(_ user: UserID) async throws -> V2GatewayJournalReadyAuthorization {
        guard let barrier = journalUserBaseline.withLock({ $0?.callback }), let receiver = journalReceiver.withLock({ $0 }) else {
            throw V2RealtimePublicationBackpressure.receiverQueue
        }
        let proof = try await barrier(user)
        guard proof.userID == user, let binding = receiver.authenticationBinding(userID: user),
              binding.source == proof.source, binding.fence.sameGeneration(as: proof.fence),
              binding.controlVersion >= proof.controlVersion else { throw V2RealtimePublicationBackpressure.receiverQueue }
        return .init(highWatermark: 0, permit: { enqueue in
            receiver.enqueueUserAuthorized(userID: user, expectedSource: proof.source,
                expectedFence: proof.fence, enqueue: enqueue)
        })
    }

    /// Runtime owns coalescing and cold snapshot tasks; subscription changes
    /// only signal that owner and never create an independent background task.
    public func configureJournalInterestChanges(_ changed: @escaping @Sendable () -> Void) async {
        journalInterestChanged.withLock { $0 = V2CallbackBox(changed) }
    }

    /// Capture lifecycle tickets before the authority read. A snapshot cannot
    /// close a later connection that reused the same account/device identity.
    public func journalUserControlInterests() -> Set<V2GatewayJournalUserControlInterest> {
        Set(directory.identityByConnection.compactMap { id, identity in
            guard let lifecycle = directory.lifecycleByConnection[id] else { return nil }
            return .init(connectionID: id, userID: identity.userID, deviceID: identity.deviceID, lifecycle: lifecycle)
        })
    }

    /// This port is called only by the trusted source-DB cold reader. The remote
    /// control stream supplies hints, never this snapshot or its current witness.
    public func applyAuthoritativeUserControl(
        _ snapshot: V2RealtimeJournalUserSnapshot,
        source: V2RealtimeJournalSource,
        expectedIdentity: V2RealtimeJournalSourceIdentity,
        isAuthenticationSource: Bool,
        minimumControlVersions: [UserID: UInt64],
        credentialChangedDeviceKeys: Set<V2RealtimeJournalDeviceKey>,
        membershipChangedRooms: [UserID: Set<RoomID>] = [:],
        membershipChangeVersions: [UserID: UInt64] = [:],
        requested: Set<V2GatewayJournalUserControlInterest>,
        requestedAt: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant,
        isCurrent: @escaping @Sendable () -> Bool
    ) async -> V2GatewayJournalUserControlApplied? {
        let requestedUsers = Set(requested.compactMap { $0.userID.uuidValue })
        let requestedDevices = Set(requested.compactMap { interest -> V2RealtimeJournalDeviceKey? in
            guard let user = interest.userID.uuidValue, let device = interest.deviceID.uuidValue else { return nil }
            return .init(userID: user, deviceID: device)
        })
        guard deadline > .now, isCurrent(), snapshot.identity == expectedIdentity,
              source.incarnationID == expectedIdentity.databaseIncarnation,
              requestedUsers.count <= 128, requestedDevices.count <= 128,
              Set(snapshot.requestedUserIDs) == requestedUsers, snapshot.requestedUserIDs.count == requestedUsers.count,
              Set(snapshot.requestedDeviceKeys) == requestedDevices, snapshot.requestedDeviceKeys.count == requestedDevices.count,
              Set(snapshot.users.map(\.userID)) == requestedUsers, snapshot.users.count == requestedUsers.count,
              Set(snapshot.devices.map { V2RealtimeJournalDeviceKey(userID: $0.userID, deviceID: $0.deviceID) }) == requestedDevices,
              snapshot.devices.count == requestedDevices.count,
              snapshot.cuts.count <= 128, Set(snapshot.cuts.map(\.partitionID)).count == snapshot.cuts.count,
              snapshot.cuts.allSatisfy({ $0.partitionID >= 0 && $0.publishedThrough >= 0 && $0.trimmedThrough >= 0 && $0.trimmedThrough <= $0.publishedThrough }),
              snapshot.cuts.contains(where: { $0.partitionID == source.partitionID && $0.publishedThrough >= 0 && $0.trimmedThrough >= 0 && $0.trimmedThrough <= $0.publishedThrough }),
              snapshot.users.allSatisfy({ $0.controlVersion >= 0 && $0.membershipDiscoveryVersion >= 0 && $0.sessionControlVersion >= 0 && $0.membershipDiscoveryVersion <= $0.controlVersion && $0.sessionControlVersion <= $0.controlVersion }),
              journalUserFloors[source] != nil || journalUserFloors.count < 256 else { return nil }
        let userControls = Dictionary(uniqueKeysWithValues: snapshot.users.map { (UserID(uuid: $0.userID), $0) })
        guard credentialChangedDeviceKeys.isSubset(of: requestedDevices), minimumControlVersions.allSatisfy({ user, version in
            guard let control = userControls[user] else { return false }
            return UInt64(control.controlVersion) >= version
        }) else { return nil }
        let oldDevices = journalDeviceFloors[source] ?? [:]
        guard snapshot.devices.allSatisfy({ state in
            state.latestChangeVersion >= 0 && state.latestChangeVersion <= (userControls[UserID(uuid: state.userID)]?.controlVersion ?? -1) && state.latestChangeVersion >= (oldDevices[.init(userID: state.userID, deviceID: state.deviceID)] ?? 0)
        }) else { return nil }
        let old = journalUserFloors[source] ?? [:]
        guard snapshot.users.allSatisfy({ user in
            guard let floor = old[user.userID] else { return true }
            return user.controlVersion >= floor.controlVersion && user.membershipDiscoveryVersion >= floor.membershipDiscoveryVersion && user.sessionControlVersion >= floor.sessionControlVersion
        }) else { return nil }
        let devices = Dictionary(uniqueKeysWithValues: snapshot.devices.map { (V2RealtimeJournalDeviceKey(userID: $0.userID, deviceID: $0.deviceID), $0) })
        var revoked: [(V2GatewayJournalUserControlInterest, V2GatewayByteStream)] = []
        for interest in requested {
            guard directory.lifecycleByConnection[interest.connectionID] == interest.lifecycle,
                  directory.identityByConnection[interest.connectionID]?.userID == interest.userID,
                  directory.identityByConnection[interest.connectionID]?.deviceID == interest.deviceID,
                  let stream = directory.streamsByUser[interest.userID]?[interest.connectionID],
                  let user = interest.userID.uuidValue, let device = interest.deviceID.uuidValue,
                  let state = devices[.init(userID: user, deviceID: device)], userControls[interest.userID] != nil,
                  let authenticated = directory.identityByConnection[interest.connectionID] else { continue }
            let deviceKey = V2RealtimeJournalDeviceKey(userID: user, deviceID: device)
            // A first baseline also detects revocation between authentication
            // and control subscription. A reauthenticated successor carries its
            // own newer cut and must not be closed by a replayed older hint.
            let credentialChanged = state.latestChangeVersion > authenticated.credentialControlVersion
            if isAuthenticationSource && credentialChanged {
                // Every selected socket loses actual write authority before any
                // lease, recovery, or close cleanup can suspend.
                stream.invalidateForegroundAuthorization()
                stream.revokeRecoveryWorkImmediately()
                revoked.append((interest, stream))
            }
        }
        var membershipUsers: Set<UserID> = []
        for control in snapshot.users {
            // A satisfied control floor is not a new membership change. Replayed
            // cuts and session-only changes must reuse the account's coverage.
            let advanced = control.membershipDiscoveryVersion > (old[control.userID]?.membershipDiscoveryVersion ?? 0)
            if advanced {
                membershipUsers.insert(UserID(uuid: control.userID))
            }
        }
        for (interest, stream) in revoked {
            await stream.closeForAccountRecovery()
            if directory.lifecycleByConnection[interest.connectionID] == interest.lifecycle { await unregister(connectionID: interest.connectionID) }
        }
        guard deadline > .now, isCurrent(), snapshot.users.allSatisfy({ user in
            guard let floor = journalUserFloors[source]?[user.userID] else { return true }
            return user.controlVersion >= floor.controlVersion && user.membershipDiscoveryVersion >= floor.membershipDiscoveryVersion && user.sessionControlVersion >= floor.sessionControlVersion
        }), snapshot.devices.allSatisfy({ state in
            state.latestChangeVersion >= (journalDeviceFloors[source]?[.init(userID: state.userID, deviceID: state.deviceID)] ?? 0)
        }) else { return nil }
        // Preserve floors for still-local users only; each source stores at most
        // one shared control record per viewer, never one record per device.
        let localUsers = Set(directory.identityByConnection.values.compactMap { $0.userID.uuidValue })
        var installed = (journalUserFloors[source] ?? [:]).filter { localUsers.contains($0.key) }
        for control in snapshot.users where localUsers.contains(control.userID) { installed[control.userID] = control }
        journalUserFloors[source] = installed
        if isAuthenticationSource {
            let localDevices = Set(directory.identityByConnection.values.compactMap { identity -> V2RealtimeJournalDeviceKey? in
                guard let user = identity.userID.uuidValue, let device = identity.deviceID.uuidValue else { return nil }
                return .init(userID: user, deviceID: device)
            })
            var installedDevices = (journalDeviceFloors[source] ?? [:]).filter { localDevices.contains($0.key) }
            for state in snapshot.devices {
                let key = V2RealtimeJournalDeviceKey(userID: state.userID, deviceID: state.deviceID)
                if localDevices.contains(key) { installedDevices[key] = state.latestChangeVersion }
            }
            journalDeviceFloors[source] = installedDevices
        }
        for user in membershipUsers {
            let version = userControls[user]?.membershipDiscoveryVersion
            let exact = version.flatMap { UInt64(exactly: $0) } == membershipChangeVersions[user]
            await accountChangeService?.requestServerMembershipRefresh(userID: user,
                rooms: exact ? membershipChangedRooms[user] : nil)
        }
        return .init(source: source, versions: Dictionary(uniqueKeysWithValues: snapshot.users.map { (UserID(uuid: $0.userID), UInt64($0.controlVersion)) }))
    }

    /// Old delivery authority cannot migrate across a new owner/session. It can
    /// only request a fresh authoritative head for scopes still requested now.
    public func invalidateDurableRealtimeDelivery(_ delivery: V2RealtimeDelivery) async {
        await recoveryCoordinator.invalidateDurableRealtimeDelivery(delivery)
    }

    /// Lost routing coverage changes only acceleration state. Authentication,
    /// durable cursors and local desired scopes remain available for recovery.
    public func invalidateRealtimeCoverage(topics: Set<V2RealtimeTopic>, registeredThrough cutoff: ContinuousClock.Instant) async {
        await recoveryCoordinator.invalidateRealtimeCoverage(topics: topics, registeredThrough: cutoff)
    }

    /// The caller supplies an exact, current coordinator confirmation. No Ready
    /// is inferred from head delivery or an idempotent desired-interest activate.
    public func realtimeCoverageReady(confirmations: [V2RealtimeTopic: V2RealtimeCoverageConfirmation],
        confirms: @escaping @Sendable (V2RealtimeTopic, V2RealtimeCoverageConfirmation) -> Bool) async {
        await recoveryCoordinator.realtimeCoverageReady(confirmations: confirmations, confirms: confirms)
    }

    public func configurePresenceReader(_ reader: any V2LiveActivityStore) async {
        guard !realtimeRecoveryClosed else { return }
        if let coordinator = presenceRefreshCoordinator { await coordinator.configure(reader: reader) }
        else {
            presenceRefreshCoordinator = .init(reader: reader, recoveryCoordinator: recoveryCoordinator,
                isCurrent: { [weak self] target in await self?.presenceTargetIsCurrent(target) ?? false })
        }
    }

    private func presenceRefreshTargets(targetUsers: Set<UserID>? = nil) -> [PresenceRefreshTarget] {
        var targets: [PresenceRefreshTarget] = []
        for (user, watchers) in subscriptions.presenceWatchersByTarget {
            if let targetUsers, !targetUsers.contains(user) { continue }
            for (connection, stream) in watchers {
                let key = RecoveryKey(connection: connection, kind: .userPresence, id: user.rawValue)
                guard let watch = subscriptions.presenceByConnection[connection], watch.targetUserID == user,
                      let identity = directory.identityByConnection[connection], let lifecycle = directory.lifecycleByConnection[connection],
                      let scopeGeneration = recoveryCoordinator.generation(for: key) else { continue }
                targets.append(.init(connection: connection, lifecycle: lifecycle, scopeGeneration: scopeGeneration,
                    request: .init(roomID: watch.roomID, viewerUserID: identity.userID, targetUserID: user), stream: stream))
            }
        }
        return targets
    }

    public func refreshObservedPresence(targetUserID: UserID) async {
        try? await refreshPresence(presenceRefreshTargets(targetUsers: [targetUserID]), strict: false)
    }

    private func refreshPresence(_ targets: [PresenceRefreshTarget], strict: Bool) async throws {
        guard let coordinator = presenceRefreshCoordinator else { throw V2PresenceRefreshCoordinator.Failure.closed }
        try await coordinator.refresh(targets, strict: strict)
    }

    private func presenceTargetIsCurrent(_ target: PresenceRefreshTarget) -> Bool {
        let request = target.request
        let key = RecoveryKey(connection: target.connection, kind: .userPresence, id: request.targetUserID.rawValue)
        return directory.lifecycleByConnection[target.connection] == target.lifecycle && recoveryCoordinator.generation(for: key) == target.scopeGeneration
            && directory.identityByConnection[target.connection]?.userID == request.viewerUserID
            && subscriptions.presenceByConnection[target.connection]?.roomID == request.roomID
            && subscriptions.presenceByConnection[target.connection]?.targetUserID == request.targetUserID
            && subscriptions.presenceWatchersByTarget[request.targetUserID]?[target.connection] === target.stream
    }

    /// Confirming global interest coverage schedules bounded local recovery.
    /// Every connection independently proves its actual hint/state handoff before
    /// Ready; one slow socket never holds this partition's head barrier open.
    public func arrangeRealtimeRecoveryHeads(_ heads: [V2RealtimeTopic: UInt64]) async throws -> Set<V2RealtimeTopic> {
        return try await recoveryCoordinator.arrangeRealtimeRecoveryHeads(heads)
    }

    public func refreshAllObservedPresence() async {
        try? await refreshPresence(presenceRefreshTargets(), strict: false)
    }

    public func notifySyncAvailable(userID: UserID, eventID: UInt64, highWatermark: UInt64) async {
        let streams = directory.streamsByUser[userID].map { Array($0.values) } ?? []
        for stream in streams { await stream.sendSyncAvailable(eventID: eventID, highWatermark: highWatermark) }
    }

    @discardableResult
    public func subscribeForegroundRoom(
        _ stream: V2GatewayByteStream,
        connectionID: UUID,
        roomID: RoomID
    ) async throws -> V2RoomSubscriptionGrant? {
        guard let identity = directory.identityByConnection[connectionID],
              let lifecycle = directory.lifecycleByConnection[connectionID]
        else { return nil }
        guard let authority = roomSubscriptionAuthority.withLock({ $0 }) else {
            throw V2ResourceProviderError.configurationInvalid
        }
        guard directory.streamsByUser[identity.userID]?[connectionID] === stream,
              let localLifecycle = roomSubscriptionConnections[connectionID]?.lifecycle else { return nil }
        if let coordinator = roomSubscriptionCoordinator, subscriptions.foregroundGroupByConnection[connectionID] == roomID,
           let reference = roomSubscriptionConnections[connectionID]?.reference {
            let grant = try await coordinator.acquire(roomID: roomID, userID: identity.userID, reference: reference)
            guard directory.lifecycleByConnection[connectionID] == lifecycle,
                  roomSubscriptionConnections[connectionID]?.reference == reference,
                  subscriptions.foregroundGroupByConnection[connectionID] == roomID else {
                await coordinator.release(reference: reference)
                throw V2GatewayRoomSubscriptionCoordinationError.superseded
            }
            return grant
        }
        let mutation = makeGeneration()
        subscriptions.foregroundMutationByConnection[connectionID] = mutation
        defer {
            if subscriptions.foregroundMutationByConnection[connectionID] == mutation {
                subscriptions.foregroundMutationByConnection.removeValue(forKey: connectionID)
            }
        }
        if subscriptions.foregroundGroupByConnection[connectionID] != roomID {
            await removeForegroundGroupSubscription(connectionID: connectionID)
            guard directory.lifecycleByConnection[connectionID] == lifecycle,
                  subscriptions.foregroundMutationByConnection[connectionID] == mutation else { return nil }
            subscriptions.foregroundGroupByConnection[connectionID] = roomID
        }
        foregroundRoutes.upsert(
            connectionID: connectionID,
            roomID: roomID,
            userID: identity.userID,
            stream: stream
        )
        guard directory.streamsByUser[identity.userID]?[connectionID] === stream,
              await authority.registerRoomInterest(connectionID: connectionID, lifecycle: localLifecycle,
                roomID: roomID, scopeGeneration: mutation) else {
            _ = subscriptions.detachForeground(connectionID: connectionID)
            foregroundRoutes.remove(connectionID: connectionID, roomID: roomID)
            return nil
        }
        roomSubscriptionConnections[connectionID]?.scopeGeneration = mutation
        let interestPermit = authority.interestPermit(connectionID: connectionID, lifecycle: localLifecycle,
            roomID: roomID, generation: mutation)
        await stream.beginRoomSubscription(roomID: roomID, scopeGeneration: mutation, permit: interestPermit)
        guard directory.lifecycleByConnection[connectionID] == lifecycle,
              roomSubscriptionConnections[connectionID]?.lifecycle == localLifecycle,
              roomSubscriptionConnections[connectionID]?.scopeGeneration == mutation,
              subscriptions.foregroundGroupByConnection[connectionID] == roomID else {
            throw V2GatewayRoomSubscriptionCoordinationError.superseded
        }
        if let coordinator = roomSubscriptionCoordinator {
            let reference = UUID(); roomSubscriptionConnections[connectionID]?.reference = reference
            do {
                let grant = try await coordinator.acquire(roomID: roomID, userID: identity.userID, reference: reference)
                guard directory.lifecycleByConnection[connectionID] == lifecycle,
                      roomSubscriptionConnections[connectionID]?.reference == reference,
                      roomSubscriptionConnections[connectionID]?.scopeGeneration == mutation,
                      subscriptions.foregroundGroupByConnection[connectionID] == roomID else {
                    await coordinator.release(reference: reference)
                    throw V2GatewayRoomSubscriptionCoordinationError.superseded
                }
                await roomSubscriptionBaselineInstalled(roomID: roomID)
                return grant
            } catch {
                if roomSubscriptionConnections[connectionID]?.reference == reference {
                    await removeForegroundGroupSubscription(connectionID: connectionID)
                }
                await coordinator.release(reference: reference)
                throw error
            }
        }
        await roomSubscriptionBaselineInstalled(roomID: roomID)
        return nil
    }

    public func unsubscribeForegroundGroup(connectionID: UUID, roomID: RoomID) async {
        guard subscriptions.foregroundGroupByConnection[connectionID] == roomID else { return }
        let mutation = makeGeneration()
        subscriptions.foregroundMutationByConnection[connectionID] = mutation
        defer {
            if subscriptions.foregroundMutationByConnection[connectionID] == mutation {
                subscriptions.foregroundMutationByConnection.removeValue(forKey: connectionID)
            }
        }
        await removeForegroundGroupSubscription(connectionID: connectionID)
    }

    public func connectionCount(for deviceID: DeviceID) -> Int { directory.streamsByDevice[deviceID]?.count ?? 0 }

    public func connectionMetricsSnapshot() -> V2ConnectionMetricsSnapshot {
        .init(activeDevices: directory.streamsByDevice.count, activeConnections: directory.identityByConnection.count)
    }

    public func activeForegroundGroupMetrics() -> (rooms: Int, viewers: Int) {
        (Set(subscriptions.foregroundGroupByConnection.values).count, subscriptions.foregroundGroupByConnection.count)
    }

    public func configureLivePresenceLeases(_ leases: any V2LivePresenceLeaseManaging) {
        precondition(!hasStartedRegistrations, "lease controller must be installed before connections")
        livePresenceLeases = leases
        leaseController = .init(leases: leases, configuration: livePresenceRenewalConfiguration,
            maximumConnections: maximumConnections, onRemoved: { [weak self] connection, identity, remainsOnline in
                await self?.presenceLeaseCleanupCompleted(connectionID: connection, identity: identity,
                    remainsOnline: remainsOnline)
            })
    }

    public func livePresenceRenewalMetrics() async -> V2LivePresenceRenewalBatcherSnapshot? {
        await leaseController?.metrics()
    }

    public func finishLivePresenceRenewals() async {
        leaseRenewalsClosed = true
        await leaseController?.finish()
    }

    public func configureLiveActivityObservationAuthorizer(_ authorizer: any V2LiveActivityObservationAuthorizing) {
        liveActivityObservationAuthorizer = authorizer
    }

    public func configureLiveActivityBroker(_ broker: any V2LiveActivityInterestManaging & V2LiveActivityPublishing, routesLocalActivity: Bool = false) async {
        precondition(!hasStartedRegistrations && !realtimeRecoveryClosed && liveActivityBroker == nil)
        liveActivityBroker = broker
        await recoveryCoordinator.configureLiveActivity(broker)
        brokerRoutesLocalActivity = routesLocalActivity

    }

    func presenceLeaseSnapshot(connectionID: UUID) async -> (deadline: ContinuousClock.Instant?, renewing: Bool, renewAt: ContinuousClock.Instant?) {
        guard let leaseController else { return (nil, false, nil) }
        return await leaseController.snapshot(connectionID: connectionID)
    }

    /// Local heartbeats only update liveness; the controller owns SQL renewal.
    @discardableResult
    public func refreshLivePresence(connectionID: UUID) async -> Bool {
        guard !leaseRenewalsClosed, directory.identityByConnection[connectionID] != nil,
              let lifecycle = directory.lifecycleByConnection[connectionID] else { return false }
        guard let leaseController else { return true }
        let accepted = await leaseController.heartbeat(connectionID: connectionID, lifecycle: lifecycle)
        return accepted && directory.lifecycleByConnection[connectionID] == lifecycle
    }

    private func presenceLeaseCleanupCompleted(connectionID: UUID, identity: V2AuthenticatedConnection,
        remainsOnline: Bool) async {
        guard !remainsOnline, directory.lifecycleByConnection[connectionID] == nil,
              directory.streamsByUser[identity.userID] == nil else { return }
        await routePresence(targetUserID: identity.userID, isOnline: false, expiresAt: Date())
    }

    @discardableResult
    private func refreshPersistedPresence(connectionID: UUID) async -> Bool {
        guard directory.identityByConnection[connectionID] != nil, let lifecycle = directory.lifecycleByConnection[connectionID],
              !leaseRenewalsClosed else { return false }
        guard let leaseController else { return true }
        let accepted = await leaseController.refreshProjection(connectionID: connectionID, lifecycle: lifecycle)
        return accepted && directory.lifecycleByConnection[connectionID] == lifecycle
    }

    public func subscribePresence(_ stream: V2GatewayByteStream, connectionID: UUID, roomID: RoomID, targetUserID: UserID) async {
        guard directory.identityByConnection[connectionID] != nil,
              let lifecycle = directory.lifecycleByConnection[connectionID]
        else { return }
        let mutation = makeGeneration()
        subscriptions.presenceMutationByConnection[connectionID] = mutation
        defer {
            if subscriptions.presenceMutationByConnection[connectionID] == mutation {
                subscriptions.presenceMutationByConnection.removeValue(forKey: connectionID)
            }
        }
        await removePresenceSubscription(connectionID: connectionID)
        guard directory.lifecycleByConnection[connectionID] == lifecycle,
              subscriptions.presenceMutationByConnection[connectionID] == mutation
        else { return }
        subscriptions.presenceByConnection[connectionID] = (roomID, targetUserID)
        subscriptions.presenceWatchersByTarget[targetUserID, default: [:]][connectionID] = stream
        await beginScopeRecovery(connection: connectionID, kind: .userPresence, id: targetUserID.rawValue)
    }

    public func unsubscribePresence(connectionID: UUID, roomID: RoomID) async {
        guard subscriptions.presenceByConnection[connectionID]?.roomID == roomID else { return }
        let mutation = makeGeneration()
        subscriptions.presenceMutationByConnection[connectionID] = mutation
        defer {
            if subscriptions.presenceMutationByConnection[connectionID] == mutation {
                subscriptions.presenceMutationByConnection.removeValue(forKey: connectionID)
            }
        }
        await removePresenceSubscription(connectionID: connectionID)
    }

    public func subscribeTyping(_ stream: V2GatewayByteStream, connectionID: UUID, roomID: RoomID) async throws {
        guard directory.identityByConnection[connectionID] != nil,
              let lifecycle = directory.lifecycleByConnection[connectionID]
        else { throw CancellationError() }
        let mutation = makeGeneration()
        subscriptions.typingMutationByConnection[connectionID] = mutation
        defer {
            if subscriptions.typingMutationByConnection[connectionID] == mutation {
                subscriptions.typingMutationByConnection.removeValue(forKey: connectionID)
            }
        }
        await removeTypingSubscription(connectionID: connectionID)
        guard directory.lifecycleByConnection[connectionID] == lifecycle,
              subscriptions.typingMutationByConnection[connectionID] == mutation
        else { throw CancellationError() }
        subscriptions.typingRoomByConnection[connectionID] = roomID
        subscriptions.typingWatchersByRoom[roomID, default: [:]][connectionID] = stream
        let key = RecoveryKey(connection: connectionID, kind: .roomTyping, id: roomID.rawValue)
        guard let generation = recoveryCoordinator.requestScope(key, lifecycle: lifecycle) else {
            await removeTypingSubscription(connectionID: connectionID)
            throw V2RealtimePublicationBackpressure.receiverQueue
        }
        do {
            try await recoveryCoordinator.acquireTypingInterestBeforeAcknowledgement(connection: connectionID,
                roomID: roomID, generation: generation, lifecycle: lifecycle)
            guard directory.lifecycleByConnection[connectionID] == lifecycle,
                  subscriptions.typingMutationByConnection[connectionID] == mutation else { throw CancellationError() }
            await recoveryCoordinator.beginScopeRecovery(connection: connectionID, kind: .roomTyping, id: roomID.rawValue,
                scopeGeneration: generation, lifecycle: lifecycle)
            guard directory.lifecycleByConnection[connectionID] == lifecycle,
                  subscriptions.typingMutationByConnection[connectionID] == mutation,
                  recoveryCoordinator.generation(for: key) == generation else { throw CancellationError() }
        } catch {
            if subscriptions.typingMutationByConnection[connectionID] == mutation {
                await removeTypingSubscription(connectionID: connectionID)
            }
            throw error
        }
    }

    public func unsubscribeTyping(connectionID: UUID, roomID: RoomID) async {
        guard subscriptions.typingRoomByConnection[connectionID] == roomID else { return }
        let mutation = makeGeneration()
        subscriptions.typingMutationByConnection[connectionID] = mutation
        defer {
            if subscriptions.typingMutationByConnection[connectionID] == mutation {
                subscriptions.typingMutationByConnection.removeValue(forKey: connectionID)
            }
        }
        await removeTypingSubscription(connectionID: connectionID)
    }

    public func notifyTyping(roomID: RoomID, actorUserID: UserID, isTyping: Bool, expiresAt: Date, sourceConnectionID: UUID? = nil) async {
        let state = V2TypingState(roomID: roomID, userID: actorUserID, isTyping: isTyping, expiresAt: expiresAt)
        if let publisher = liveActivityBroker as? any V2LifecycleTypingPublishing, let sourceConnectionID {
            guard directory.identityByConnection[sourceConnectionID]?.userID == actorUserID else { return }
            await publisher.publishTyping(state, sourceConnectionID: sourceConnectionID)
        } else {
            await notifyTypingWatchers(state)
            await liveActivityBroker?.publishTyping(state)
        }
    }

    public func receivePresence(targetUserID: UserID, isOnline: Bool, expiresAt: Date) async {
        await notifyPresenceWatchers(targetUserID: targetUserID, isOnline: isOnline, expiresAt: expiresAt)
    }

    public func receiveTyping(_ state: V2TypingState) async {
        await notifyTypingWatchers(state)
    }

    @discardableResult
    public func applyLiveActivityPreferences(connectionID: UUID, allowsOnlinePresence: Bool) async -> Bool {
        guard let identity = directory.identityByConnection[connectionID],
              let lifecycle = directory.lifecycleByConnection[connectionID]
        else { return false }
        if allowsOnlinePresence {
            return await refreshPersistedPresence(connectionID: connectionID)
        } else {
            // 保持每份连接准入租约有效。数据库读取与刷新广播
            // 都会应用隐私偏好，因此租约虽不可见，仍可在网关副本间限制连接数。
            guard directory.lifecycleByConnection[connectionID] == lifecycle else { return false }
            await routePresence(targetUserID: identity.userID, isOnline: false, expiresAt: Date())
            return directory.lifecycleByConnection[connectionID] == lifecycle
        }
    }

    private func notifyTypingWatchers(_ state: V2TypingState) async {
        let streams = subscriptions.typingWatchersByRoom[state.roomID].map { Array($0) } ?? []
        let candidates = streams.compactMap { connectionID, stream -> (V2LiveObservationKey, V2GatewayByteStream)? in
            guard let observer = directory.identityByConnection[connectionID]?.userID, observer != state.userID else { return nil }
            return (.init(roomID: state.roomID, observerUserID: observer, subjectUserID: state.userID), stream)
        }
        let authorized = await authorizedObservationKeys(Set(candidates.map(\.0)))
        for (key, stream) in candidates where authorized.contains(key) {
            guard subscriptions.typingWatchersByRoom[state.roomID]?.values.contains(where: { $0 === stream }) == true else { continue }
            await stream.sendTypingState(state)
        }
    }

    private func routePresence(targetUserID: UserID, isOnline: Bool, expiresAt: Date) async {
        guard !realtimeRecoveryClosed else { return }
        // Payload is only an invalidation hint; a departing local connection
        // never establishes global offline state. The observer reads authority.
        if dirtyPresence[targetUserID] == nil, dirtyPresence.count >= maximumDirtyPresenceUsers {
            // Transient invalidations are bounded; visible targets also refresh
            // authority periodically, independently of this coalescing queue.
            return
        }
        dirtyPresence[targetUserID] = (isOnline, expiresAt)
        if dirtyPresenceWorker == nil {
            // This coalesced lifecycle worker has no caller authorization/SQL context.
            dirtyPresenceWorker = Task.detached { await self.drainDirtyPresence() }
        }
    }

    private func drainDirtyPresence() async {
        while !realtimeRecoveryClosed, let user = dirtyPresence.keys.first,
              let state = dirtyPresence.removeValue(forKey: user) {
            if !brokerRoutesLocalActivity {
                if presenceRefreshCoordinator != nil { await refreshObservedPresence(targetUserID: user) }
                else {
                    let allowed = (try? await livePresenceLeases?.allowsOnlinePresence(userID: user)) == true
                    let visible = state.0 && allowed
                    await notifyPresenceWatchers(targetUserID: user, isOnline: visible, expiresAt: state.1)
                }
            }
            await liveActivityBroker?.publishPresence(targetUserID: user, isOnline: state.0, expiresAt: state.1)
        }
        dirtyPresenceWorker = nil
    }

    private func compensateStalePresence(connectionID: UUID, identity: V2AuthenticatedConnection) async {
        // 较新的生命周期可能有意复用此 UUID，并已拥有数据库记录。
        // 过期续体不能删除它。
        guard directory.lifecycleByConnection[connectionID] == nil else { return }
        guard let remainsOnline = await removePresenceLease(
            identity: identity,
            connectionID: connectionID
        ) else { return }
        guard !remainsOnline,
              directory.identityByConnection[connectionID] == nil
        else { return }
        await routePresence(targetUserID: identity.userID, isOnline: false, expiresAt: Date())
    }

    private func removePresenceLease(
        identity: V2AuthenticatedConnection,
        connectionID: UUID
    ) async -> Bool? {
        guard let leaseController else { return directory.streamsByUser[identity.userID] != nil }
        return await leaseController.removePresence(identity: identity, connectionID: connectionID)
    }

    private func notifyPresenceWatchers(targetUserID: UserID, isOnline: Bool, expiresAt: Date) async {
        let streams = subscriptions.presenceWatchersByTarget[targetUserID].map { Array($0) } ?? []
        let candidates = streams.compactMap { connectionID, stream -> (V2LiveObservationKey, V2GatewayByteStream)? in
            guard let watch = subscriptions.presenceByConnection[connectionID],
                  let observer = directory.identityByConnection[connectionID]?.userID,
                  watch.targetUserID == targetUserID
            else { return nil }
            return (.init(roomID: watch.roomID, observerUserID: observer, subjectUserID: targetUserID), stream)
        }
        let authorized = await authorizedObservationKeys(Set(candidates.map(\.0)))
        for (key, stream) in candidates where authorized.contains(key) {
            guard subscriptions.presenceWatchersByTarget[targetUserID]?.values.contains(where: { $0 === stream }) == true else { continue }
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
        guard let previous = subscriptions.detachPresence(connectionID: connectionID) else { return }
        await endScope(connection: connectionID, kind: .userPresence,
            id: previous.targetUserID.rawValue, stream: previous.stream)
    }

    private func removeTypingSubscription(connectionID: UUID) async {
        guard let previous = subscriptions.detachTyping(connectionID: connectionID) else { return }
        await endScope(connection: connectionID, kind: .roomTyping,
            id: previous.roomID.rawValue, stream: previous.stream)
    }

    private func removeForegroundGroupSubscription(connectionID: UUID) async {
        guard let roomID = subscriptions.detachForeground(connectionID: connectionID) else { return }
        let stream = foregroundRoutes.target(roomID: roomID, connectionID: connectionID)?.stream
        if let authority = roomSubscriptionAuthority.withLock({ $0 }) {
            if let lifecycle = roomSubscriptionConnections[connectionID]?.lifecycle {
                await authority.removeRoomInterest(connectionID: connectionID, lifecycle: lifecycle, roomID: roomID)
            }
            foregroundRoutes.remove(connectionID: connectionID, roomID: roomID)
            let generation = roomSubscriptionConnections[connectionID]?.scopeGeneration
            roomSubscriptionConnections[connectionID]?.scopeGeneration = nil
            if let reference = roomSubscriptionConnections[connectionID]?.reference {
                roomSubscriptionConnections[connectionID]?.reference = nil
                await roomSubscriptionCoordinator?.release(reference: reference)
            }
            if let generation {
                await stream?.endRoomSubscription(roomID: roomID, scopeGeneration: generation)
            }
            return
        }
        foregroundRoutes.remove(connectionID: connectionID, roomID: roomID)
    }

    private func rollbackRegistration(
        connectionID: UUID,
        identity: V2AuthenticatedConnection,
        lifecycle: Generation
    ) async {
        guard directory.identityByConnection[connectionID] == identity,
              directory.remove(connectionID, lifecycle: lifecycle) != nil else { return }
        let roomReference = removeRoomSubscriptionConnection(connectionID)
        if let roomReference { await roomSubscriptionCoordinator?.release(reference: roomReference) }
        journalInterestChanged.withLock { $0?.callback }?()
        defer { directory.endOperation(connectionID) }
        let scope = userSyncScopes.removeValue(forKey: connectionID)
        let revokedScopes = recoveryCoordinator.revokeConnection(connectionID, lifecycle: lifecycle)
        await recoveryCoordinator.detachConnection(connectionID, revokedScopes: revokedScopes)
        await leaseController?.revoke(connectionID: connectionID, lifecycle: lifecycle)
        if let scope {
            await deactivateUserSyncInterest(userID: identity.userID, scope: scope)
        }
    }

    /// 供高频变动测试使用的内部不变量探针。
    ///
    /// 变更代次只是短暂的可重入围栏，绝不能演变成一份连接历史台账。
    ///
    /// - Returns: 当前暂存的可重入围栏数量。
    func transientMutationTokenCount() -> Int {
        subscriptions.foregroundMutationByConnection.count
            + subscriptions.presenceMutationByConnection.count
            + subscriptions.typingMutationByConnection.count
    }

    private func configureRecoveryPortsIfNeeded() {
        guard !recoveryPortsConfigured else { return }
        recoveryPortsConfigured = true
        recoveryCoordinator.configurePorts(.init(preparePresence: { [weak self] key, lifecycle, generation in
            guard let self else { throw CancellationError() }
            return try await self.prepareRecoveryPresence(key, lifecycle: lifecycle, generation: generation)
        }, compensateScope: { [weak self] key, lifecycle, scope, user in
            await self?.compensateStaleScope(key: key, lifecycle: lifecycle, accountScope: scope, user: user)
        }))
    }

    private func prepareRecoveryPresence(_ key: RecoveryKey, lifecycle: UInt64, generation: UInt64) async throws -> V2PreparedPresenceHandoff {
        guard let coordinator = presenceRefreshCoordinator,
              let target = presenceRefreshTargets(targetUsers: [try UserID(key.id)]).first(where: {
                  $0.connection == key.connection && $0.lifecycle == lifecycle && $0.scopeGeneration == generation
              }) else { throw V2RealtimePublicationBackpressure.receiverQueue }
        return try await coordinator.prepare(target)
    }

    private func makeGeneration() -> Generation {
        nextGeneration &+= 1
        precondition(nextGeneration != 0, "connection registry generation exhausted")
        return nextGeneration
    }

}

/// 分片的、基于锁的前台路由快照。
///
/// 这里只索引详情兴趣对应的连接和本地流。
/// 成员任期与实际写入许可由房间订阅 Authority 持有。
private final class V2ForegroundConnectionRoutes: Sendable {
    struct Target: Sendable {
        let connectionID: UUID
        let userID: UserID
        let stream: V2GatewayByteStream
    }
    private struct Entry: Sendable {
        let userID: UserID
        let stream: V2GatewayByteStream
    }

    private struct State: Sendable {
        var entriesByRoom: [RoomID: [UUID: Entry]] = [:]
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
        stream: V2GatewayByteStream
    ) {
        shard(for: roomID).state.withLock { state in
            state.entriesByRoom[roomID, default: [:]][connectionID] = .init(
                userID: userID,
                stream: stream
            )
        }
    }

    func remove(connectionID: UUID, roomID: RoomID) {
        shard(for: roomID).state.withLock { state in
            state.entriesByRoom[roomID]?.removeValue(forKey: connectionID)
            if state.entriesByRoom[roomID]?.isEmpty == true {
                state.entriesByRoom.removeValue(forKey: roomID)
            }
        }
    }

    func target(roomID: RoomID, connectionID: UUID) -> Target? {
        shard(for: roomID).state.withLock { value in
            guard let entry = value.entriesByRoom[roomID]?[connectionID] else { return nil }
            return Target(connectionID: connectionID, userID: entry.userID,
                stream: entry.stream)
        }
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
extension V2DeviceConnectionRegistry: V2DeviceConnectionRevoking {}

extension V2DeviceConnectionRegistry: V2AccountRoomChangesStarting {
    public func invalidateAccountRoomCoverage() async {
        await accountChangeService?.invalidateCoverage()
    }

    public func configureAccountRoomChanges(_ service: V2AccountRoomChangeService) async {
        precondition(accountChangeService == nil)
        accountChangeService = service
    }

    public func startAccountRoomChanges(connectionID: UUID, userID: UserID) async throws -> String {
        try await startAccountRoomChanges(connectionID: connectionID, userID: userID, requiresReady: true)
    }

    private func startAccountRoomChanges(connectionID: UUID, userID: UserID, requiresReady: Bool) async throws -> String {
        if let ticket = accountChangeTickets[connectionID], ticket.userID == userID,
           directory.identityByConnection[connectionID]?.userID == userID, let service = accountChangeService {
            try await service.bootstrap(ticket, waitForCompletion: false)
            if requiresReady { try await service.requireBootstrapReady(ticket) }
            guard accountChangeTickets[connectionID]?.epoch == ticket.epoch,
                  directory.identityByConnection[connectionID]?.userID == userID else {
                throw V2AccountRoomChangeService.Failure.staleConnection
            }
            if requiresReady { try await service.reserveReadyResponse(ticket) }
            return ticket.epoch.uuidString.lowercased()
        }
        guard let service = accountChangeService,
              let identity = directory.identityByConnection[connectionID], identity.userID == userID,
              let lifecycle = directory.lifecycleByConnection[connectionID],
              let stream = directory.streamsByUser[userID]?[connectionID],
              accountChangeTickets[connectionID] == nil else {
            throw V2AccountRoomChangeService.Failure.staleConnection
        }
        guard accountCoverageInstallations[connectionID] != lifecycle else {
            throw V2RealtimePublicationBackpressure.receiverQueue
        }
        accountCoverageInstallations[connectionID] = lifecycle
        defer {
            if accountCoverageInstallations[connectionID] == lifecycle {
                accountCoverageInstallations.removeValue(forKey: connectionID)
            }
        }
        guard await stream.supportsRequiredNotifications(), directory.lifecycleByConnection[connectionID] == lifecycle else {
            throw V2AccountRoomChangeService.Failure.staleConnection
        }
        let directoryGeneration = makeGeneration()
        directoryGenerations[connectionID] = directoryGeneration
        directoryDeliveryFences.withLock { $0[connectionID] = directoryGeneration }
        await stream.sendRealtimeCoverage(scope: .directory, scopeID: userID.rawValue,
            scopeGeneration: directoryGeneration, ready: false, reason: .installing,
            scopePermit: directoryWritePermit(connectionID, generation: directoryGeneration))
        let ticket = try await service.begin(userID: userID, connectionID: connectionID,
            send: { [weak self, weak stream] notification in
                guard let self, let stream else { return false }
                let directoryPermit = self.directoryWritePermit(connectionID, generation: directoryGeneration)
                return await stream.sendAccountRoomNotification(notification, enqueueIfCurrent: directoryPermit)
            }, close: { [weak self] in
                await self?.accountRoomCoverageLost(connectionID: connectionID, lifecycle: lifecycle,
                    directoryGeneration: directoryGeneration)
            })
        guard directory.lifecycleByConnection[connectionID] == lifecycle else {
            await service.stop(ticket)
            throw V2AccountRoomChangeService.Failure.staleConnection
        }
        accountChangeTickets[connectionID] = ticket
        do {
            try await service.bootstrap(ticket, waitForCompletion: false)
            guard accountChangeTickets[connectionID]?.epoch == ticket.epoch,
                  directory.lifecycleByConnection[connectionID] == lifecycle else {
                throw V2AccountRoomChangeService.Failure.staleConnection
            }
        } catch {
            if accountChangeTickets[connectionID]?.epoch == ticket.epoch {
                accountChangeTickets.removeValue(forKey: connectionID)
            }
            await service.stop(ticket)
            throw error
        }
        if requiresReady { try await service.requireBootstrapReady(ticket) }
        if requiresReady { try await service.reserveReadyResponse(ticket) }
        return ticket.epoch.uuidString.lowercased()
    }

    /// Authentication establishes message coverage even before the client starts
    /// consuming directory changes. That consumer's Ready still gates its notifications.
    func installAuthenticatedAccountCoverage(connectionID: UUID) async throws {
        guard accountChangeService != nil,
              let identity = directory.identityByConnection[connectionID] else { return }
        do {
            _ = try await startAccountRoomChanges(connectionID: connectionID, userID: identity.userID, requiresReady: false)
        } catch V2RealtimePublicationBackpressure.receiverQueue {
            // A concurrent listener already owns installation for this lifecycle.
            // Its owned bootstrap continues independently of the auth callback.
        }
    }

    func accountRoomChangesReadyWritten(connectionID: UUID, epoch: String) async throws {
        guard let ticket = accountChangeTickets[connectionID], UUID(uuidString: epoch) == ticket.epoch,
              accountChangeService != nil else { throw V2AccountRoomChangeService.Failure.staleConnection }
        guard accountChangeTickets[connectionID]?.epoch == ticket.epoch,
              let generation = directoryGenerations[connectionID],
              let stream = directory.streamsByUser[ticket.userID]?[connectionID] else { return }
        let scopePermit = directoryWritePermit(connectionID, generation: generation)
        await stream.sendRealtimeCoverage(scope: .directory, scopeID: ticket.userID.rawValue,
            scopeGeneration: generation, connectionEpoch: epoch, ready: true, reason: .unspecified,
            confirms: { true }, scopePermit: scopePermit, onReadyAdmitted: { [weak self] in
                await self?.resumeAccountRoomChangesAfterReady(ticket, generation: generation)
            })
    }

    private func resumeAccountRoomChangesAfterReady(_ ticket: V2AccountRoomChangeService.Ticket,
                                                   generation: UInt64) async {
        guard accountChangeTickets[ticket.connectionID]?.epoch == ticket.epoch,
              directoryGenerations[ticket.connectionID] == generation,
              let service = accountChangeService else { return }
        await service.resume(ticket)
    }

    private func accountRoomCoverageLost(connectionID: UUID, lifecycle: UInt64, directoryGeneration: UInt64) async {
        guard directory.lifecycleByConnection[connectionID] == lifecycle,
              directoryGenerations[connectionID] == directoryGeneration,
              let identity = directory.identityByConnection[connectionID],
              let stream = directory.streamsByUser[identity.userID]?[connectionID] else { return }
        accountChangeTickets.removeValue(forKey: connectionID)
        let next = makeGeneration(); directoryGenerations[connectionID] = next
        directoryDeliveryFences.withLock { $0[connectionID] = next }
        await stream.sendRealtimeCoverage(scope: .directory, scopeID: identity.userID.rawValue,
            scopeGeneration: next, ready: false, reason: .coverageLost,
            scopePermit: directoryWritePermit(connectionID, generation: next))
        // Coverage retirement does not revoke the authenticated transport.
        // The next account listener request establishes a new coverage epoch.
    }

}
