import Fluent
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Vapor

struct IMTCPConfiguration: Sendable {
    let enabled: Bool
    let host: String
    let port: Int
    let protocolVersion: Int
    let authTimeout: TimeInterval
    let heartbeatInterval: TimeInterval
    let idleTimeout: TimeInterval
    let listenBacklog: Int
    let maxFrameBytes: Int
    let writeBufferWaterMarkLow: Int
    let writeBufferWaterMarkHigh: Int
    let slowWriteThresholdMilliseconds: Int
    let slowWriteCloseConsecutiveCount: Int
    let dropsRealtimeWhenNotWritable: Bool
    let requiresTLSTermination: Bool

    static func load(from environment: Environment) -> IMTCPConfiguration {
        let enabled = Environment.get("IM_TCP_ENABLED").flatMap(Bool.init(_:)) ?? (environment != .testing)
        let writeBufferLow = max(1, Environment.get("IM_TCP_WRITE_BUFFER_LOW_WATERMARK").flatMap(Int.init(_:)) ?? 512 * 1024)
        let writeBufferHigh = max(
            writeBufferLow,
            Environment.get("IM_TCP_WRITE_BUFFER_HIGH_WATERMARK").flatMap(Int.init(_:)) ?? 1024 * 1024
        )

        return IMTCPConfiguration(
            enabled: enabled,
            host: Environment.get("IM_TCP_HOST") ?? "0.0.0.0",
            port: Environment.get("IM_TCP_PORT").flatMap(Int.init(_:)) ?? 9000,
            protocolVersion: IMRealtimeProtocolVersion.currentInt,
            authTimeout: Environment.get("IM_TCP_AUTH_TIMEOUT").flatMap(TimeInterval.init(_:)) ?? 10,
            heartbeatInterval: Environment.get("IM_TCP_HEARTBEAT_INTERVAL").flatMap(TimeInterval.init(_:)) ?? 30,
            idleTimeout: Environment.get("IM_TCP_IDLE_TIMEOUT").flatMap(TimeInterval.init(_:)) ?? 90,
            listenBacklog: Environment.get("IM_TCP_LISTEN_BACKLOG").flatMap(Int.init(_:)) ?? 1024,
            maxFrameBytes: Environment.get("IM_TCP_MAX_FRAME_BYTES").flatMap(Int.init(_:)) ?? 64 * 1024,
            writeBufferWaterMarkLow: writeBufferLow,
            writeBufferWaterMarkHigh: writeBufferHigh,
            slowWriteThresholdMilliseconds: max(
                0,
                Environment.get("IM_TCP_SLOW_WRITE_THRESHOLD_MS").flatMap(Int.init(_:)) ?? 1000
            ),
            slowWriteCloseConsecutiveCount: max(
                0,
                Environment.get("IM_TCP_SLOW_WRITE_CLOSE_CONSECUTIVE_COUNT").flatMap(Int.init(_:)) ?? 3
            ),
            dropsRealtimeWhenNotWritable: parseBooleanEnvironment(
                "IM_TCP_DROP_REALTIME_WHEN_NOT_WRITABLE",
                defaultValue: true
            ),
            requiresTLSTermination: parseBooleanEnvironment("IM_TCP_REQUIRES_TLS_TERMINATION", defaultValue: false)
        )
    }
}

struct IMGatewayLocalFanoutConfiguration: Sendable {
    let batchSize: Int
    let eventLoopYieldChunkCount: Int
    let activeConversationFanoutEnabled: Bool
    let activeConversationFanoutRecipientThreshold: Int

    init(
        batchSize: Int,
        eventLoopYieldChunkCount: Int,
        activeConversationFanoutEnabled: Bool,
        activeConversationFanoutRecipientThreshold: Int
    ) {
        self.batchSize = batchSize
        self.eventLoopYieldChunkCount = eventLoopYieldChunkCount
        self.activeConversationFanoutEnabled = activeConversationFanoutEnabled
        self.activeConversationFanoutRecipientThreshold = activeConversationFanoutRecipientThreshold
    }

    static func load() -> IMGatewayLocalFanoutConfiguration {
        return IMGatewayLocalFanoutConfiguration(
            batchSize: max(1, Environment.get("IM_GATEWAY_LOCAL_FANOUT_BATCH_SIZE").flatMap(Int.init(_:)) ?? 64),
            eventLoopYieldChunkCount: max(
                1,
                Environment.get("IM_GATEWAY_LOCAL_FANOUT_EVENT_LOOP_YIELD_CHUNKS")
                    .flatMap(Int.init(_:)) ?? 64
            ),
            activeConversationFanoutEnabled: parseBooleanEnvironment(
                "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED",
                defaultValue: false
            ),
            activeConversationFanoutRecipientThreshold: max(
                1,
                Environment.get("IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD")
                    .flatMap(Int.init(_:)) ?? 500
            )
        )
    }
}

struct IMTCPConnectionCloseReasonEvent: Sendable {
    let reason: String

    static let slowWrite = IMTCPConnectionCloseReasonEvent(reason: "slow_write")
}

final class IMConnectionControl: @unchecked Sendable {
    let connectionID: UUID

    private let channel: any Channel
    private let metrics: RoutingMetrics?
    private let slowWriteThresholdMilliseconds: Int
    private let slowWriteCloseConsecutiveCount: Int
    private var consecutiveSlowWriteCount = 0

    init(
        connectionID: UUID,
        channel: any Channel,
        metrics: RoutingMetrics? = nil,
        slowWriteThresholdMilliseconds: Int = 1000,
        slowWriteCloseConsecutiveCount: Int = 3
    ) {
        self.connectionID = connectionID
        self.channel = channel
        self.metrics = metrics
        self.slowWriteThresholdMilliseconds = max(0, slowWriteThresholdMilliseconds)
        self.slowWriteCloseConsecutiveCount = max(0, slowWriteCloseConsecutiveCount)
    }

    var eventLoop: any EventLoop {
        channel.eventLoop
    }

    var eventLoopIdentifier: ObjectIdentifier {
        ObjectIdentifier(channel.eventLoop as AnyObject)
    }

    var isWritable: Bool {
        channel.isWritable
    }

    func sendPacket<Payload: Sendable>(
        type: IMTCPPacketType,
        requestID: UUID?,
        payload: Payload,
        dropWhenNotWritable: Bool = false
    ) {
        let channel = self.channel
        channel.eventLoop.execute {
            guard channel.isActive else {
                return
            }
            IMTCPChannelWriter.writePacket(
                type: type,
                requestID: requestID,
                payload: payload,
                on: channel,
                metrics: self.metrics,
                dropWhenNotWritable: dropWhenNotWritable,
                slowWriteThresholdMilliseconds: self.slowWriteThresholdMilliseconds,
                slowWriteHandler: { [weak self] latencyMilliseconds in
                    self?.handleSlowWriteOnEventLoop(latencyMilliseconds: latencyMilliseconds)
                },
                writeCompletionHandler: { [weak self] didWriteSlow in
                    self?.handleWriteCompletionOnEventLoop(didWriteSlow: didWriteSlow)
                }
            )
        }
    }

    func sendEncodedPacket(_ data: Data, dropWhenNotWritable: Bool = false) {
        let channel = self.channel
        channel.eventLoop.execute {
            guard channel.isActive else {
                return
            }
            IMTCPChannelWriter.writeEncodedPacket(
                data,
                on: channel,
                metrics: self.metrics,
                dropWhenNotWritable: dropWhenNotWritable,
                slowWriteThresholdMilliseconds: self.slowWriteThresholdMilliseconds,
                slowWriteHandler: { [weak self] latencyMilliseconds in
                    self?.handleSlowWriteOnEventLoop(latencyMilliseconds: latencyMilliseconds)
                },
                writeCompletionHandler: { [weak self] didWriteSlow in
                    self?.handleWriteCompletionOnEventLoop(didWriteSlow: didWriteSlow)
                }
            )
        }
    }

    func sendEncodedPacketOnEventLoop(_ data: Data, dropWhenNotWritable: Bool = false) {
        guard channel.isActive else {
            return
        }
        IMTCPChannelWriter.writeEncodedPacket(
            data,
            on: channel,
            metrics: metrics,
            dropWhenNotWritable: dropWhenNotWritable,
            slowWriteThresholdMilliseconds: slowWriteThresholdMilliseconds,
            slowWriteHandler: { [weak self] latencyMilliseconds in
                self?.handleSlowWriteOnEventLoop(latencyMilliseconds: latencyMilliseconds)
            },
            writeCompletionHandler: { [weak self] didWriteSlow in
                self?.handleWriteCompletionOnEventLoop(didWriteSlow: didWriteSlow)
            }
        )
    }

    func handleSlowWriteOnEventLoop(latencyMilliseconds: Int) {
        _ = latencyMilliseconds
        guard slowWriteCloseConsecutiveCount > 0 else {
            return
        }
        consecutiveSlowWriteCount += 1
        guard consecutiveSlowWriteCount >= slowWriteCloseConsecutiveCount,
              channel.isActive
        else {
            return
        }
        let metrics = self.metrics
        Task {
            await metrics?.recordTCPWriteSlowConnectionClosed()
        }
        channel.pipeline.fireUserInboundEventTriggered(IMTCPConnectionCloseReasonEvent.slowWrite)
        channel.close(promise: nil)
    }

    func handleWriteCompletionOnEventLoop(didWriteSlow: Bool) {
        if !didWriteSlow {
            consecutiveSlowWriteCount = 0
        }
    }

    func kick(reason: IMTCPKickReason, message: String) {
        let channel = self.channel
        channel.eventLoop.execute {
            guard channel.isActive else {
                return
            }
            IMTCPChannelWriter.sendKickAndClose(
                on: channel,
                reason: reason,
                message: message,
                metrics: self.metrics
            )
        }
    }

    func close() {
        let channel = self.channel
        channel.eventLoop.execute {
            channel.close(promise: nil)
        }
    }
}

struct IMAuthenticatedConnection: Sendable {
    let connectionID: UUID
    let userID: UUID
    let sessionID: UUID
    let authenticatedAt: Date
    let remoteIPAddress: String?
    let deviceID: String?
    let deviceName: String?
    let platform: String?
    let appVersion: String?
}

struct IMConnectionRemoval: Sendable {
    let connection: IMAuthenticatedConnection
    let deactivatedConversationIDs: [UUID]
}

actor IMConnectionRegistry {
    private struct Entry: Sendable {
        let connection: IMAuthenticatedConnection
        let control: IMConnectionControl
    }

    private var connectionsByID: [UUID: Entry] = [:]
    private var connectionIDsBySessionID: [UUID: Set<UUID>] = [:]
    private var connectionIDsByUserID: [UUID: Set<UUID>] = [:]
    private var connectionIDsByDeviceKey: [DeviceConnectionKey: Set<UUID>] = [:]
    private var activeConversationIDsByConnectionID: [UUID: Set<UUID>] = [:]
    private var activeConnectionIDsByConversationID: [UUID: Set<UUID>] = [:]
    private var activeUserConnectionCountsByConversationID: [UUID: [UUID: Int]] = [:]
    private var activeUserIDsByConversationID: [UUID: Set<UUID>] = [:]
    private let metrics: RoutingMetrics?
    private let dropsRealtimeWhenNotWritable: Bool
    private let localFanoutConfiguration: IMGatewayLocalFanoutConfiguration
    private let activeCompactHintPreviewMaxCharacters: Int

    init(
        metrics: RoutingMetrics? = nil,
        dropsRealtimeWhenNotWritable: Bool = true,
        localFanoutConfiguration: IMGatewayLocalFanoutConfiguration = .load(),
        activeCompactHintPreviewMaxCharacters: Int = 0
    ) {
        self.metrics = metrics
        self.dropsRealtimeWhenNotWritable = dropsRealtimeWhenNotWritable
        self.localFanoutConfiguration = localFanoutConfiguration
        self.activeCompactHintPreviewMaxCharacters = max(0, activeCompactHintPreviewMaxCharacters)
    }

    private struct DeviceConnectionKey: Hashable, Sendable {
        let userID: UUID
        let deviceID: String
    }

    private struct ReusableDomainEventPacketKey: Hashable, Sendable {
        let eventID: UUID
        let eventType: IMTCPChatDomainEventType
        let aggregateID: UUID
        let aggregateSequence: UInt64
        let bodyVariant: String
    }

    private struct ReusableDomainEventBatchCoalescingKey: Hashable, Sendable {
        let packetKey: ReusableDomainEventPacketKey
        let fanoutIntent: IMGatewayDomainEventFanoutIntent
    }

    private struct LocalFanoutChunk: Sendable {
        let data: Data
        let controls: [IMConnectionControl]
    }

    private final class LocalFanoutChunkRunner: @unchecked Sendable {
        private let eventLoop: any EventLoop
        private let chunks: [LocalFanoutChunk]
        private let maxChunksPerTick: Int
        private let dropWhenNotWritable: Bool
        private let metrics: RoutingMetrics?

        init(
            eventLoop: any EventLoop,
            chunks: [LocalFanoutChunk],
            maxChunksPerTick: Int,
            dropWhenNotWritable: Bool,
            metrics: RoutingMetrics?
        ) {
            self.eventLoop = eventLoop
            self.chunks = chunks
            self.maxChunksPerTick = max(1, maxChunksPerTick)
            self.dropWhenNotWritable = dropWhenNotWritable
            self.metrics = metrics
        }

        func start() {
            guard !chunks.isEmpty else {
                return
            }
            schedule(startIndex: chunks.startIndex)
        }

        private func schedule(startIndex: Int) {
            let scheduledAt = Date()
            eventLoop.execute { [self] in
                if let metrics {
                    let startLagMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: scheduledAt)
                    Task {
                        await metrics.recordLocalFanoutEventLoopJobStarted(
                            startLagMilliseconds: startLagMilliseconds
                        )
                    }
                }
                var index = startIndex
                let endIndex = min(chunks.endIndex, index + maxChunksPerTick)
                while index < endIndex {
                    let chunk = chunks[index]
                    for control in chunk.controls {
                        control.sendEncodedPacketOnEventLoop(
                            chunk.data,
                            dropWhenNotWritable: dropWhenNotWritable
                        )
                    }
                    index += 1
                }
                if index < chunks.endIndex {
                    schedule(startIndex: index)
                }
            }
        }
    }

    func bind(_ connection: IMAuthenticatedConnection, control: IMConnectionControl) {
        connectionsByID[connection.connectionID] = Entry(connection: connection, control: control)
        connectionIDsBySessionID[connection.sessionID, default: []].insert(connection.connectionID)
        connectionIDsByUserID[connection.userID, default: []].insert(connection.connectionID)
        if let deviceID = normalizedDeviceID(connection.deviceID) {
            connectionIDsByDeviceKey[DeviceConnectionKey(userID: connection.userID, deviceID: deviceID), default: []]
                .insert(connection.connectionID)
        }
    }

    func kickExistingConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) -> [IMConnectionRemoval] {
        let connectionIDs = connectionIDs(forSessionID: sessionID)
        var removedConnections: [IMConnectionRemoval] = []

        for connectionID in connectionIDs {
            guard let entry = connectionsByID[connectionID] else {
                continue
            }
            let control = entry.control
            control.kick(reason: reason, message: message)
            if let removed = remove(connectionID: control.connectionID) {
                removedConnections.append(removed)
            }
        }

        return removedConnections
    }

    func kickExistingConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) -> [IMConnectionRemoval] {
        let connectionIDs = connectionIDs(forUserID: userID)
        var removedConnections: [IMConnectionRemoval] = []

        for connectionID in connectionIDs {
            guard let entry = connectionsByID[connectionID] else {
                continue
            }
            let control = entry.control
            control.kick(reason: reason, message: message)
            if let removed = remove(connectionID: control.connectionID) {
                removedConnections.append(removed)
            }
        }

        return removedConnections
    }

    @discardableResult
    func remove(connectionID: UUID) -> IMConnectionRemoval? {
        guard let removed = connectionsByID.removeValue(forKey: connectionID) else {
            return nil
        }
        var deactivatedConversationIDs: [UUID] = []

        connectionIDsBySessionID[removed.connection.sessionID]?.remove(connectionID)
        if connectionIDsBySessionID[removed.connection.sessionID]?.isEmpty == true {
            connectionIDsBySessionID.removeValue(forKey: removed.connection.sessionID)
        }

        connectionIDsByUserID[removed.connection.userID]?.remove(connectionID)
        if connectionIDsByUserID[removed.connection.userID]?.isEmpty == true {
            connectionIDsByUserID.removeValue(forKey: removed.connection.userID)
        }

        if let deviceID = normalizedDeviceID(removed.connection.deviceID) {
            let key = DeviceConnectionKey(userID: removed.connection.userID, deviceID: deviceID)
            connectionIDsByDeviceKey[key]?.remove(connectionID)
            if connectionIDsByDeviceKey[key]?.isEmpty == true {
                connectionIDsByDeviceKey.removeValue(forKey: key)
            }
        }

        if let activeConversationIDs = activeConversationIDsByConnectionID.removeValue(forKey: connectionID) {
            for conversationID in activeConversationIDs {
                activeConnectionIDsByConversationID[conversationID]?.remove(connectionID)
                if activeConnectionIDsByConversationID[conversationID]?.isEmpty == true {
                    activeConnectionIDsByConversationID.removeValue(forKey: conversationID)
                }
                decrementActiveUserConnection(
                    conversationID: conversationID,
                    userID: removed.connection.userID
                )
                if localActiveConversationConnectionCount(
                    forConversationID: conversationID,
                    userID: removed.connection.userID
                ) == 0 {
                    deactivatedConversationIDs.append(conversationID)
                }
            }
        }

        return IMConnectionRemoval(
            connection: removed.connection,
            deactivatedConversationIDs: deactivatedConversationIDs
        )
    }

    func updateConversationActivity(
        connectionID: UUID,
        conversationID: UUID,
        isActive: Bool
    ) -> Bool {
        guard connectionsByID[connectionID] != nil else {
            return false
        }

        let userID = connectionsByID[connectionID]?.connection.userID
        if isActive {
            let insertResult = activeConversationIDsByConnectionID[connectionID, default: []].insert(conversationID)
            guard insertResult.inserted else {
                return true
            }
            activeConnectionIDsByConversationID[conversationID, default: []].insert(connectionID)
            if let userID {
                incrementActiveUserConnection(conversationID: conversationID, userID: userID)
            }
        } else {
            let wasActive = activeConversationIDsByConnectionID[connectionID]?.remove(conversationID) != nil
            if activeConversationIDsByConnectionID[connectionID]?.isEmpty == true {
                activeConversationIDsByConnectionID.removeValue(forKey: connectionID)
            }
            activeConnectionIDsByConversationID[conversationID]?.remove(connectionID)
            if activeConnectionIDsByConversationID[conversationID]?.isEmpty == true {
                activeConnectionIDsByConversationID.removeValue(forKey: conversationID)
            }
            if wasActive, let userID {
                decrementActiveUserConnection(conversationID: conversationID, userID: userID)
            }
        }

        return true
    }

    func connectionIDs(forSessionID sessionID: UUID) -> [UUID] {
        Array(connectionIDsBySessionID[sessionID] ?? [])
    }

    func connectionIDs(forUserID userID: UUID) -> [UUID] {
        Array(connectionIDsByUserID[userID] ?? [])
    }

    func authenticatedConnection(for connectionID: UUID) -> IMAuthenticatedConnection? {
        connectionsByID[connectionID]?.connection
    }

    func localConnectionCount(forUserID userID: UUID) -> Int {
        connectionIDsByUserID[userID]?.count ?? 0
    }

    func localConnectionCount(forSessionID sessionID: UUID) -> Int {
        connectionIDsBySessionID[sessionID]?.count ?? 0
    }

    func localConnectionCount(forUserID userID: UUID, deviceID: String) -> Int {
        connectionIDsByDeviceKey[DeviceConnectionKey(userID: userID, deviceID: deviceID)]?.count ?? 0
    }

    func activeConnectionCounts(forSessionIDs sessionIDs: [UUID]) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: Set(sessionIDs).map { sessionID in
            (sessionID, connectionIDsBySessionID[sessionID]?.count ?? 0)
        })
    }

    func localActiveConversationConnectionCount(forConversationID conversationID: UUID, userID: UUID) -> Int {
        activeUserConnectionCountsByConversationID[conversationID]?[userID] ?? 0
    }

    func activeConversationIDs(forConnectionID connectionID: UUID) -> Set<UUID> {
        activeConversationIDsByConnectionID[connectionID] ?? []
    }

    func totalConnectionCount() -> Int {
        connectionsByID.count
    }

    func sendDomainEventDelivery(
        _ delivery: IMCanonicalDomainEventDelivery,
        requestID: UUID? = UUID()
    ) async {
        await sendPacket(
            type: .domainEvent,
            payload: delivery.payload,
            toUserIDs: [delivery.ownerUserID],
            requestID: requestID,
            dropWhenNotWritable: dropsRealtimeWhenNotWritable
        )
    }

    func sendDomainEventDeliveries(
        _ deliveries: [IMCanonicalDomainEventDelivery],
        requestID: UUID? = UUID()
    ) async {
        var reusableGroups: [ReusableDomainEventPacketKey: (payload: IMTCPChatDomainEventPayload, userIDs: [UUID])] = [:]
        var fallbackDeliveries: [IMCanonicalDomainEventDelivery] = []
        fallbackDeliveries.reserveCapacity(deliveries.count)

        for delivery in deliveries {
            guard let key = reusablePacketKey(for: delivery.payload) else {
                fallbackDeliveries.append(delivery)
                continue
            }
            if reusableGroups[key] == nil {
                reusableGroups[key] = (payload: delivery.payload, userIDs: [])
            }
            reusableGroups[key]?.userIDs.append(delivery.ownerUserID)
        }

        let reusableBatches = reusableGroups.values.map { group in
            IMGatewayDomainEventPayloadBatch(payload: group.payload, recipientUserIDs: group.userIDs)
        }
        let fallbackBatches = fallbackDeliveries.map { delivery in
            IMGatewayDomainEventPayloadBatch(payload: delivery.payload, recipientUserIDs: [delivery.ownerUserID])
        }
        await sendDomainEventPayloadBatches(reusableBatches + fallbackBatches, requestID: requestID)
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID? = UUID()
    ) async {
        let controlsByEventLoop = localControlsByEventLoop(forUserIDs: userIDs)
        guard !controlsByEventLoop.isEmpty else {
            return
        }
        guard let packetData = try? IMTCPProtobufCodec.encode(
            type: .domainEvent,
            requestID: requestID,
            payload: payload
        ) else {
            await metrics?.recordLocalFanoutEncodeFailure()
            return
        }
        await sendEncodedPacket(
            packetData,
            toControlsByEventLoop: controlsByEventLoop,
            dropWhenNotWritable: dropsRealtimeWhenNotWritable,
            encodedPacketCount: 1
        )
    }

    func sendDomainEventPayloadBatches(
        _ batches: [IMGatewayDomainEventPayloadBatch],
        requestID: UUID? = UUID()
    ) async {
        let partitioned = partitionPreSplitActiveFullBatches(batches)
        if !partitioned.activeBatches.isEmpty {
            await sendPreSplitActiveBatches(partitioned.activeBatches, requestID: requestID)
        }
        let batches = await activeConversationFanoutBatches(from: partitioned.remainingBatches)
        await sendDomainEventPayloadBatchesNow(batches, requestID: requestID)
    }

    private func sendDomainEventPayloadBatchesNow(
        _ batches: [IMGatewayDomainEventPayloadBatch],
        requestID: UUID?
    ) async {
        struct EventLoopFanout {
            let eventLoop: any EventLoop
            var writes: [(data: Data, controls: [IMConnectionControl])]
        }

        var fanoutsByEventLoop: [ObjectIdentifier: EventLoopFanout] = [:]
        var encodedPacketCache: [ReusableDomainEventPacketKey: Data] = [:]
        var encodedPacketCount = 0
        var encodeCacheHitCount = 0
        var encodedPacketBytes = 0
        var maxEncodedPacketBytes = 0
        var encodeFailureCount = 0
        let batches = coalescedConsecutiveReusableDomainEventBatches(batches)
        for batch in batches {
            guard !batch.recipientUserIDs.isEmpty else {
                continue
            }
            let controlsByEventLoop = localControlsByEventLoop(forUserIDs: batch.recipientUserIDs)
            guard !controlsByEventLoop.isEmpty else {
                continue
            }
            guard let packetData = encodedDomainEventPacketData(
                for: batch.payload,
                requestID: requestID,
                cache: &encodedPacketCache,
                encodedPacketCount: &encodedPacketCount,
                encodeCacheHitCount: &encodeCacheHitCount,
                encodedPacketBytes: &encodedPacketBytes,
                maxEncodedPacketBytes: &maxEncodedPacketBytes
            ) else {
                encodeFailureCount += 1
                continue
            }

            for (eventLoopIdentifier, controls) in controlsByEventLoop {
                guard let eventLoop = controls.first?.eventLoop else {
                    continue
                }
                var fanout = fanoutsByEventLoop[eventLoopIdentifier] ?? EventLoopFanout(
                    eventLoop: eventLoop,
                    writes: []
                )
                fanout.writes.append((data: packetData, controls: controls))
                fanoutsByEventLoop[eventLoopIdentifier] = fanout
            }
        }

        let batchSize = localFanoutConfiguration.batchSize
        let eventLoopYieldChunkCount = localFanoutConfiguration.eventLoopYieldChunkCount
        let fanouts = Array(fanoutsByEventLoop.values)
        let packetCount = fanouts.reduce(0) { $0 + $1.writes.count }
        let targetConnectionCount = fanouts.reduce(0) { partial, fanout in
            partial + fanout.writes.reduce(0) { $0 + $1.controls.count }
        }
        let chunkCountsByEventLoop = fanouts.map { fanout in
            fanout.writes.reduce(0) { writePartial, write in
                writePartial + max(1, (write.controls.count + batchSize - 1) / batchSize)
            }
        }
        let totalChunkCount = chunkCountsByEventLoop.reduce(0, +)
        let eventLoopJobCount = chunkCountsByEventLoop.reduce(0) { partial, chunkCount in
            guard chunkCount > 0 else {
                return partial
            }
            return partial + max(1, (chunkCount + eventLoopYieldChunkCount - 1) / eventLoopYieldChunkCount)
        }
        let maxChunksPerEventLoopJob = chunkCountsByEventLoop.reduce(0) { partial, chunkCount in
            guard chunkCount > 0 else {
                return partial
            }
            return max(partial, min(chunkCount, eventLoopYieldChunkCount))
        }
        let maxTargetConnectionsPerPacket = fanouts
            .flatMap { $0.writes.map { $0.controls.count } }
            .max() ?? 0
        let estimatedOutboundBytes = fanouts.reduce(0) { partial, fanout in
            partial + fanout.writes.reduce(0) { writePartial, write in
                writePartial + (write.data.count * write.controls.count)
            }
        }
        let maxEstimatedOutboundBytesPerPacket = fanouts
            .flatMap { $0.writes.map { $0.data.count * $0.controls.count } }
            .max() ?? 0
        await metrics?.recordLocalFanout(
            packetCount: packetCount,
            targetConnectionCount: targetConnectionCount,
            maxTargetConnectionsPerPacket: maxTargetConnectionsPerPacket,
            eventLoopJobCount: eventLoopJobCount,
            chunkCount: totalChunkCount,
            maxChunksPerEventLoopJob: maxChunksPerEventLoopJob,
            batchSize: batchSize,
            encodedPacketCount: encodedPacketCount,
            encodeCacheHitCount: encodeCacheHitCount,
            encodedPacketBytes: encodedPacketBytes,
            maxEncodedPacketBytes: maxEncodedPacketBytes,
            estimatedOutboundBytes: estimatedOutboundBytes,
            maxEstimatedOutboundBytesPerPacket: maxEstimatedOutboundBytesPerPacket
        )
        if encodeFailureCount > 0 {
            await metrics?.recordLocalFanoutEncodeFailure(count: encodeFailureCount)
        }
        for fanout in fanouts {
            var chunks: [LocalFanoutChunk] = []
            for write in fanout.writes {
                var startIndex = write.controls.startIndex
                while startIndex < write.controls.endIndex {
                    let endIndex = write.controls.index(
                        startIndex,
                        offsetBy: batchSize,
                        limitedBy: write.controls.endIndex
                    ) ?? write.controls.endIndex
                    let controls = Array(write.controls[startIndex..<endIndex])
                    let data = write.data
                    chunks.append(LocalFanoutChunk(data: data, controls: controls))
                    startIndex = endIndex
                }
            }
            LocalFanoutChunkRunner(
                eventLoop: fanout.eventLoop,
                chunks: chunks,
                maxChunksPerTick: eventLoopYieldChunkCount,
                dropWhenNotWritable: dropsRealtimeWhenNotWritable,
                metrics: metrics
            ).start()
        }
    }

    private func partitionPreSplitActiveFullBatches(
        _ batches: [IMGatewayDomainEventPayloadBatch]
    ) -> (activeBatches: [IMGatewayDomainEventPayloadBatch], remainingBatches: [IMGatewayDomainEventPayloadBatch]) {
        guard activeConversationFanoutEnabled else {
            return ([], batches)
        }

        var activeBatches: [IMGatewayDomainEventPayloadBatch] = []
        var remainingBatches: [IMGatewayDomainEventPayloadBatch] = []
        activeBatches.reserveCapacity(batches.count)
        remainingBatches.reserveCapacity(batches.count)
        for batch in batches {
            if (batch.fanoutIntent == .preSplitActiveFull || batch.fanoutIntent == .preSplitActiveCompact),
               batch.payload.eventType == .messageCreated {
                activeBatches.append(batch)
            } else {
                remainingBatches.append(batch)
            }
        }
        return (activeBatches, remainingBatches)
    }

    private func sendPreSplitActiveBatches(
        _ batches: [IMGatewayDomainEventPayloadBatch],
        requestID: UUID?
    ) async {
        guard !batches.isEmpty else {
            return
        }

        struct EventLoopFanout {
            let eventLoop: any EventLoop
            var writes: [(data: Data, controls: [IMConnectionControl])]
        }

        var fanoutsByEventLoop: [ObjectIdentifier: EventLoopFanout] = [:]
        var encodedPacketCache: [ReusableDomainEventPacketKey: Data] = [:]
        var encodedPacketCount = 0
        var encodeCacheHitCount = 0
        var encodedPacketBytes = 0
        var maxEncodedPacketBytes = 0
        var encodeFailureCount = 0
        for batch in coalescedConsecutiveReusableDomainEventBatches(batches) {
            let controlsByEventLoop = localActiveConversationControlsByEventLoop(
                conversationID: batch.payload.aggregateID,
                amongUserIDs: batch.recipientUserIDs
            )
            guard !controlsByEventLoop.isEmpty else {
                continue
            }
            guard let packetData = encodedDomainEventPacketData(
                for: batch.payload,
                requestID: requestID,
                cache: &encodedPacketCache,
                encodedPacketCount: &encodedPacketCount,
                encodeCacheHitCount: &encodeCacheHitCount,
                encodedPacketBytes: &encodedPacketBytes,
                maxEncodedPacketBytes: &maxEncodedPacketBytes
            ) else {
                encodeFailureCount += 1
                continue
            }

            for (eventLoopIdentifier, controls) in controlsByEventLoop {
                guard let eventLoop = controls.first?.eventLoop else {
                    continue
                }
                var fanout = fanoutsByEventLoop[eventLoopIdentifier] ?? EventLoopFanout(
                    eventLoop: eventLoop,
                    writes: []
                )
                fanout.writes.append((data: packetData, controls: controls))
                fanoutsByEventLoop[eventLoopIdentifier] = fanout
            }
        }

        let batchSize = localFanoutConfiguration.batchSize
        let eventLoopYieldChunkCount = localFanoutConfiguration.eventLoopYieldChunkCount
        let fanouts = Array(fanoutsByEventLoop.values)
        let packetCount = fanouts.reduce(0) { $0 + $1.writes.count }
        let targetConnectionCount = fanouts.reduce(0) { partial, fanout in
            partial + fanout.writes.reduce(0) { $0 + $1.controls.count }
        }
        let chunkCountsByEventLoop = fanouts.map { fanout in
            fanout.writes.reduce(0) { writePartial, write in
                writePartial + max(1, (write.controls.count + batchSize - 1) / batchSize)
            }
        }
        let totalChunkCount = chunkCountsByEventLoop.reduce(0, +)
        let eventLoopJobCount = chunkCountsByEventLoop.reduce(0) { partial, chunkCount in
            guard chunkCount > 0 else {
                return partial
            }
            return partial + max(1, (chunkCount + eventLoopYieldChunkCount - 1) / eventLoopYieldChunkCount)
        }
        let maxChunksPerEventLoopJob = chunkCountsByEventLoop.reduce(0) { partial, chunkCount in
            guard chunkCount > 0 else {
                return partial
            }
            return max(partial, min(chunkCount, eventLoopYieldChunkCount))
        }
        let maxTargetConnectionsPerPacket = fanouts
            .flatMap { $0.writes.map { $0.controls.count } }
            .max() ?? 0
        let estimatedOutboundBytes = fanouts.reduce(0) { partial, fanout in
            partial + fanout.writes.reduce(0) { writePartial, write in
                writePartial + (write.data.count * write.controls.count)
            }
        }
        let maxEstimatedOutboundBytesPerPacket = fanouts
            .flatMap { $0.writes.map { $0.data.count * $0.controls.count } }
            .max() ?? 0
        await metrics?.recordLocalFanout(
            packetCount: packetCount,
            targetConnectionCount: targetConnectionCount,
            maxTargetConnectionsPerPacket: maxTargetConnectionsPerPacket,
            eventLoopJobCount: eventLoopJobCount,
            chunkCount: totalChunkCount,
            maxChunksPerEventLoopJob: maxChunksPerEventLoopJob,
            batchSize: batchSize,
            encodedPacketCount: encodedPacketCount,
            encodeCacheHitCount: encodeCacheHitCount,
            encodedPacketBytes: encodedPacketBytes,
            maxEncodedPacketBytes: maxEncodedPacketBytes,
            estimatedOutboundBytes: estimatedOutboundBytes,
            maxEstimatedOutboundBytesPerPacket: maxEstimatedOutboundBytesPerPacket
        )
        if encodeFailureCount > 0 {
            await metrics?.recordLocalFanoutEncodeFailure(count: encodeFailureCount)
        }

        for fanout in fanouts {
            var chunks: [LocalFanoutChunk] = []
            for write in fanout.writes {
                var startIndex = write.controls.startIndex
                while startIndex < write.controls.endIndex {
                    let endIndex = write.controls.index(
                        startIndex,
                        offsetBy: batchSize,
                        limitedBy: write.controls.endIndex
                    ) ?? write.controls.endIndex
                    chunks.append(
                        LocalFanoutChunk(
                            data: write.data,
                            controls: Array(write.controls[startIndex..<endIndex])
                        )
                    )
                    startIndex = endIndex
                }
            }
            LocalFanoutChunkRunner(
                eventLoop: fanout.eventLoop,
                chunks: chunks,
                maxChunksPerTick: eventLoopYieldChunkCount,
                dropWhenNotWritable: dropsRealtimeWhenNotWritable,
                metrics: metrics
            ).start()
        }
    }

    private func coalescedConsecutiveReusableDomainEventBatches(
        _ batches: [IMGatewayDomainEventPayloadBatch]
    ) -> [IMGatewayDomainEventPayloadBatch] {
        guard batches.count > 1 else {
            return batches
        }

        var coalesced: [IMGatewayDomainEventPayloadBatch] = []
        coalesced.reserveCapacity(batches.count)
        var currentKey: ReusableDomainEventBatchCoalescingKey?
        var currentPayload: IMTCPChatDomainEventPayload?
        var currentFanoutIntent: IMGatewayDomainEventFanoutIntent = .unspecified
        var currentRecipientUserIDs: [UUID] = []
        var currentRecipientSet: Set<UUID> = []

        func flushCurrent() {
            guard let payload = currentPayload,
                  !currentRecipientUserIDs.isEmpty
            else {
                currentKey = nil
                currentPayload = nil
                currentFanoutIntent = .unspecified
                currentRecipientUserIDs.removeAll(keepingCapacity: true)
                currentRecipientSet.removeAll(keepingCapacity: true)
                return
            }
            coalesced.append(
                IMGatewayDomainEventPayloadBatch(
                    payload: payload,
                    recipientUserIDs: currentRecipientUserIDs,
                    fanoutIntent: currentFanoutIntent
                )
            )
            currentKey = nil
            currentPayload = nil
            currentFanoutIntent = .unspecified
            currentRecipientUserIDs.removeAll(keepingCapacity: true)
            currentRecipientSet.removeAll(keepingCapacity: true)
        }

        for batch in batches {
            guard !batch.recipientUserIDs.isEmpty,
                  let packetKey = reusablePacketKey(for: batch.payload)
            else {
                flushCurrent()
                if !batch.recipientUserIDs.isEmpty {
                    coalesced.append(batch)
                }
                continue
            }

            let key = ReusableDomainEventBatchCoalescingKey(
                packetKey: packetKey,
                fanoutIntent: batch.fanoutIntent
            )
            if currentKey != key {
                flushCurrent()
                currentKey = key
                currentPayload = batch.payload
                currentFanoutIntent = batch.fanoutIntent
            }

            for userID in batch.recipientUserIDs where currentRecipientSet.insert(userID).inserted {
                currentRecipientUserIDs.append(userID)
            }
        }
        flushCurrent()
        return coalesced
    }

    private func encodedDomainEventPacketData(
        for payload: IMTCPChatDomainEventPayload,
        requestID: UUID?,
        cache: inout [ReusableDomainEventPacketKey: Data],
        encodedPacketCount: inout Int,
        encodeCacheHitCount: inout Int,
        encodedPacketBytes: inout Int,
        maxEncodedPacketBytes: inout Int
    ) -> Data? {
        if let cacheKey = reusablePacketKey(for: payload) {
            if let cached = cache[cacheKey] {
                encodeCacheHitCount += 1
                return cached
            }
            guard let data = try? IMTCPProtobufCodec.encode(
                type: .domainEvent,
                requestID: requestID,
                payload: payload
            ) else {
                return nil
            }
            encodedPacketCount += 1
            encodedPacketBytes += data.count
            maxEncodedPacketBytes = max(maxEncodedPacketBytes, data.count)
            cache[cacheKey] = data
            return data
        }

        guard let data = try? IMTCPProtobufCodec.encode(
            type: .domainEvent,
            requestID: requestID,
            payload: payload
        ) else {
            return nil
        }
        encodedPacketCount += 1
        encodedPacketBytes += data.count
        maxEncodedPacketBytes = max(maxEncodedPacketBytes, data.count)
        return data
    }

    func sendStreamSignal(
        _ payload: IMTCPMessageStreamSignalPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID? = UUID()
    ) async {
        await sendPacket(
            type: .streamSignal,
            payload: payload,
            toUserIDs: userIDs,
            requestID: requestID,
            dropWhenNotWritable: dropsRealtimeWhenNotWritable
        )
    }

    private func sendPacket<Payload: Sendable>(
        type: IMTCPPacketType,
        payload: Payload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?,
        dropWhenNotWritable: Bool = false
    ) async {
        let controlsByEventLoop = localControlsByEventLoop(forUserIDs: userIDs)
        guard !controlsByEventLoop.isEmpty else {
            return
        }
        guard let packetData = try? IMTCPProtobufCodec.encode(
            type: type,
            requestID: requestID,
            payload: payload
        ) else {
            await metrics?.recordLocalFanoutEncodeFailure()
            return
        }
        await sendEncodedPacket(
            packetData,
            toControlsByEventLoop: controlsByEventLoop,
            dropWhenNotWritable: dropWhenNotWritable,
            encodedPacketCount: 1,
            encodedPacketBytes: packetData.count,
            maxEncodedPacketBytes: packetData.count
        )
    }

    private func sendEncodedPacket(
        _ data: Data,
        toUserIDs userIDs: [UUID],
        dropWhenNotWritable: Bool = false,
        encodedPacketCount: Int = 0,
        encodedPacketBytes: Int = 0,
        maxEncodedPacketBytes: Int = 0
    ) async {
        let groups = localControlsByEventLoop(forUserIDs: userIDs)
        await sendEncodedPacket(
            data,
            toControlsByEventLoop: groups,
            dropWhenNotWritable: dropWhenNotWritable,
            encodedPacketCount: encodedPacketCount,
            encodedPacketBytes: encodedPacketBytes,
            maxEncodedPacketBytes: maxEncodedPacketBytes
        )
    }

    private func sendEncodedPacket(
        _ data: Data,
        toControlsByEventLoop groups: [ObjectIdentifier: [IMConnectionControl]],
        dropWhenNotWritable: Bool = false,
        encodedPacketCount: Int = 0,
        encodedPacketBytes: Int = 0,
        maxEncodedPacketBytes: Int = 0
    ) async {
        guard !groups.isEmpty else {
            return
        }
        let controls = groups.values.flatMap { $0 }
        let batchSize = localFanoutConfiguration.batchSize
        let eventLoopYieldChunkCount = localFanoutConfiguration.eventLoopYieldChunkCount
        let chunkCountsByEventLoop = groups.values.map { group in
            max(1, (group.count + batchSize - 1) / batchSize)
        }
        let totalChunkCount = chunkCountsByEventLoop.reduce(0, +)
        let eventLoopJobCount = chunkCountsByEventLoop.reduce(0) { partial, chunkCount in
            partial + max(1, (chunkCount + eventLoopYieldChunkCount - 1) / eventLoopYieldChunkCount)
        }
        let maxChunksPerEventLoopJob = chunkCountsByEventLoop.reduce(0) { partial, chunkCount in
            max(partial, min(chunkCount, eventLoopYieldChunkCount))
        }
        let estimatedOutboundBytes = data.count * controls.count
        await metrics?.recordLocalFanout(
            packetCount: groups.values.reduce(0) { $0 + ($1.isEmpty ? 0 : 1) },
            targetConnectionCount: controls.count,
            maxTargetConnectionsPerPacket: groups.values.map(\.count).max() ?? 0,
            eventLoopJobCount: eventLoopJobCount,
            chunkCount: totalChunkCount,
            maxChunksPerEventLoopJob: maxChunksPerEventLoopJob,
            batchSize: batchSize,
            encodedPacketCount: encodedPacketCount,
            encodedPacketBytes: encodedPacketBytes,
            maxEncodedPacketBytes: maxEncodedPacketBytes,
            estimatedOutboundBytes: estimatedOutboundBytes,
            maxEstimatedOutboundBytesPerPacket: estimatedOutboundBytes
        )

        for group in groups.values {
            guard let eventLoop = group.first?.eventLoop else {
                continue
            }

            var startIndex = group.startIndex
            var chunks: [LocalFanoutChunk] = []
            while startIndex < group.endIndex {
                let endIndex = group.index(
                    startIndex,
                    offsetBy: batchSize,
                    limitedBy: group.endIndex
                ) ?? group.endIndex
                let batch = Array(group[startIndex..<endIndex])
                chunks.append(LocalFanoutChunk(data: data, controls: batch))
                startIndex = endIndex
            }
            LocalFanoutChunkRunner(
                eventLoop: eventLoop,
                chunks: chunks,
                maxChunksPerTick: eventLoopYieldChunkCount,
                dropWhenNotWritable: dropWhenNotWritable,
                metrics: metrics
            ).start()
        }
    }

    private func normalizedDeviceID(_ deviceID: String?) -> String? {
        let trimmed = deviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func activeConversationFanoutBatches(
        from batches: [IMGatewayDomainEventPayloadBatch]
    ) async -> [IMGatewayDomainEventPayloadBatch] {
        var result: [IMGatewayDomainEventPayloadBatch] = []
        result.reserveCapacity(batches.count)
        let totalActiveRecipientCount = 0
        var totalCompactActiveRecipientCount = 0
        let totalInactiveHintRecipientCount = 0
        var totalDowngradedActiveRecipientCount = 0
        let totalBackpressureDowngradedActiveRecipientCount = 0
        for batch in batches {
            let localRecipientUserIDs = localRecipientUserIDs(from: batch.recipientUserIDs)
            guard !localRecipientUserIDs.isEmpty else {
                continue
            }
            guard activeConversationFanoutEnabled else {
                result.append(
                    IMGatewayDomainEventPayloadBatch(
                        payload: batch.payload,
                        recipientUserIDs: localRecipientUserIDs,
                        fanoutIntent: batch.fanoutIntent
                    )
                )
                continue
            }
            guard shouldSplitActiveConversationFanout(batch) else {
                result.append(
                    IMGatewayDomainEventPayloadBatch(
                        payload: batch.payload,
                        recipientUserIDs: localRecipientUserIDs,
                        fanoutIntent: batch.fanoutIntent
                    )
                )
                continue
            }

            let activeUserIDs = activeUserIDs(
                forConversationID: batch.payload.aggregateID,
                among: localRecipientUserIDs
            )
            let compactActiveUserIDs = activeUserIDs
            if !compactActiveUserIDs.isEmpty {
                if let compactPayload = batch.payload.activeCompactHintForActiveRecipient(
                    maxPreviewCharacters: activeCompactHintPreviewMaxCharacters,
                    eventID: imLightweightMessageCreatedHintEventID(for: batch.payload.eventID)
                ) {
                    totalCompactActiveRecipientCount += compactActiveUserIDs.count
                    totalDowngradedActiveRecipientCount += compactActiveUserIDs.count
                    result.append(
                        IMGatewayDomainEventPayloadBatch(
                            payload: compactPayload,
                            recipientUserIDs: compactActiveUserIDs,
                            fanoutIntent: .preSplitActiveCompact
                        )
                    )
                }
            }
        }

        if totalActiveRecipientCount > 0 || totalCompactActiveRecipientCount > 0 || totalInactiveHintRecipientCount > 0 {
            await metrics?.recordActiveConversationFanoutSplit(
                activeRecipientCount: totalActiveRecipientCount,
                compactActiveRecipientCount: totalCompactActiveRecipientCount,
                inactiveHintRecipientCount: totalInactiveHintRecipientCount,
                downgradedActiveRecipientCount: totalDowngradedActiveRecipientCount,
                backpressureDowngradedActiveRecipientCount: totalBackpressureDowngradedActiveRecipientCount
            )
        }
        return result
    }

    private var activeConversationFanoutEnabled: Bool {
        localFanoutConfiguration.activeConversationFanoutEnabled
    }

    private var activeConversationFanoutRecipientThreshold: Int {
        localFanoutConfiguration.activeConversationFanoutRecipientThreshold
    }

    private func shouldSplitActiveConversationFanout(_ batch: IMGatewayDomainEventPayloadBatch) -> Bool {
        guard batch.fanoutIntent == .unspecified,
              batch.payload.eventType == .messageCreated
        else {
            return false
        }

        if let conversation = batch.payload.conversation {
            guard conversation.kind == IMConversationKind.group.rawValue else {
                return false
            }
            if conversation.memberCount >= activeConversationFanoutRecipientThreshold {
                return true
            }
            return activeConnectionIDsByConversationID[batch.payload.aggregateID]?.isEmpty == false
        }

        return batch.recipientUserIDs.count >= activeConversationFanoutRecipientThreshold
    }

    private func activeUserIDs(
        forConversationID conversationID: UUID,
        among userIDs: [UUID]
    ) -> [UUID] {
        guard let activeUserIDs = activeUserIDsByConversationID[conversationID],
              !activeUserIDs.isEmpty
        else {
            return []
        }

        return userIDs.filter { activeUserIDs.contains($0) }
    }

    private func localRecipientUserIDs(from userIDs: [UUID]) -> [UUID] {
        var seenUserIDs = Set<UUID>()
        var localUserIDs: [UUID] = []
        localUserIDs.reserveCapacity(userIDs.count)
        for userID in userIDs {
            guard seenUserIDs.insert(userID).inserted,
                  connectionIDsByUserID[userID]?.isEmpty == false
            else {
                continue
            }
            localUserIDs.append(userID)
        }
        return localUserIDs
    }

    private func localControlsByEventLoop(forUserIDs userIDs: [UUID]) -> [ObjectIdentifier: [IMConnectionControl]] {
        var uniqueConnectionIDs = Set<UUID>()
        var controls: [IMConnectionControl] = []
        for userID in userIDs {
            guard let connectionIDs = connectionIDsByUserID[userID] else {
                continue
            }
            for connectionID in connectionIDs where uniqueConnectionIDs.insert(connectionID).inserted {
                guard let control = connectionsByID[connectionID]?.control else {
                    continue
                }
                controls.append(control)
            }
        }
        return Dictionary(grouping: controls, by: \.eventLoopIdentifier)
    }

    private func localActiveConversationControlsByEventLoop(
        conversationID: UUID,
        amongUserIDs userIDs: [UUID]
    ) -> [ObjectIdentifier: [IMConnectionControl]] {
        guard let activeConnectionIDs = activeConnectionIDsByConversationID[conversationID],
              !activeConnectionIDs.isEmpty
        else {
            return [:]
        }

        let allowedUserIDs = Set(userIDs)
        guard !allowedUserIDs.isEmpty else {
            return [:]
        }
        var controls: [IMConnectionControl] = []
        controls.reserveCapacity(activeConnectionIDs.count)
        for connectionID in activeConnectionIDs {
            guard let entry = connectionsByID[connectionID],
                  allowedUserIDs.contains(entry.connection.userID)
            else {
                continue
            }
            controls.append(entry.control)
        }
        return Dictionary(grouping: controls, by: \.eventLoopIdentifier)
    }

    private func incrementActiveUserConnection(conversationID: UUID, userID: UUID) {
        let nextCount = (activeUserConnectionCountsByConversationID[conversationID]?[userID] ?? 0) + 1
        activeUserConnectionCountsByConversationID[conversationID, default: [:]][userID] = nextCount
        activeUserIDsByConversationID[conversationID, default: []].insert(userID)
    }

    private func decrementActiveUserConnection(conversationID: UUID, userID: UUID) {
        guard let currentCount = activeUserConnectionCountsByConversationID[conversationID]?[userID] else {
            return
        }
        if currentCount > 1 {
            activeUserConnectionCountsByConversationID[conversationID]?[userID] = currentCount - 1
            return
        }

        activeUserConnectionCountsByConversationID[conversationID]?.removeValue(forKey: userID)
        if activeUserConnectionCountsByConversationID[conversationID]?.isEmpty == true {
            activeUserConnectionCountsByConversationID.removeValue(forKey: conversationID)
        }
        activeUserIDsByConversationID[conversationID]?.remove(userID)
        if activeUserIDsByConversationID[conversationID]?.isEmpty == true {
            activeUserIDsByConversationID.removeValue(forKey: conversationID)
        }
    }

    private func reusablePacketKey(for payload: IMTCPChatDomainEventPayload) -> ReusableDomainEventPacketKey? {
        guard payload.timelineNotice == nil,
              payload.requiresTimelineNotice == false,
              payload.ownerCursor == nil,
              payload.ownerAggregateSequence == nil
        else {
            return nil
        }
        let bodyVariant: String
        switch payload.eventType {
        case .messageCreated:
            guard payload.conversation == nil else {
                return nil
            }
            bodyVariant = "messageCreated"
        case .conversationUpdated:
            guard payload.conversation != nil,
                  case .conversationChanged = payload.body
            else {
                return nil
            }
            bodyVariant = "conversationChanged"
        case .conversationActivityHint:
            guard payload.conversation == nil,
                  case .conversationActivityHint(let hint) = payload.body
            else {
                return nil
            }
            bodyVariant = [
                "conversationActivityHint",
                hint.messageID.uuidString,
                "\(hint.serverSequence)",
                "\(hint.timelineSequence)",
                hint.previewText,
                hint.messageCreatedAt.map { "\($0.timeIntervalSince1970)" } ?? "",
                "\(hint.updatedAt.timeIntervalSince1970)"
            ].joined(separator: "|")
        case .conversationCreated,
             .conversationSettingsChanged,
             .conversationRemovedForSelf,
             .messageEdited,
             .messageRevoked,
             .messageStreamStarted,
             .messageStreamCompleted,
             .messageStreamFailed,
             .messageStreamCancelled,
             .messageVisibilityChanged,
             .messageFavoriteChanged,
             .memberAdded,
             .memberRemoved,
             .memberRoleUpdated,
             .contactRequestCreated,
             .contactRequestAccepted,
             .contactRequestUpdated,
             .conversationVisibilityChanged:
            return nil
        }

        return ReusableDomainEventPacketKey(
            eventID: payload.eventID,
            eventType: payload.eventType,
            aggregateID: payload.aggregateID,
            aggregateSequence: payload.aggregateSequence,
            bodyVariant: bodyVariant
        )
    }
}

struct IMTCPAuthenticator {
    let app: Application
    let db: any Database

    func authenticate(
        accessToken: String,
        remoteIPAddress: String?,
        deviceID: String?,
        deviceName: String?,
        platform: String?,
        appVersion: String?
    ) async throws -> IMAuthenticatedConnection {
        let (_, sessionContext) = try await AuthService(app: app, db: db)
            .authenticateAccessToken(accessToken)
        let normalizedPayloadDeviceID = normalizedDeviceID(deviceID)
        let normalizedSessionDeviceID = normalizedDeviceID(sessionContext.deviceID)

        if let normalizedSessionDeviceID,
           normalizedPayloadDeviceID != normalizedSessionDeviceID
        {
            throw AuthError.invalidToken
        }

        return IMAuthenticatedConnection(
            connectionID: UUID(),
            userID: sessionContext.userID,
            sessionID: sessionContext.sessionID,
            authenticatedAt: Date(),
            remoteIPAddress: remoteIPAddress,
            deviceID: normalizedSessionDeviceID ?? normalizedPayloadDeviceID,
            deviceName: deviceName,
            platform: platform,
            appVersion: appVersion
        )
    }

    private func normalizedDeviceID(_ deviceID: String?) -> String? {
        let trimmed = deviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

final class IMTCPServerLifecycle: LifecycleHandler, @unchecked Sendable {
    private let serverChannel = NIOLockedValueBox<(any Channel)?>(nil)

    func didBootAsync(_ application: Application) async throws {
        let configuration = application.imTCPConfiguration
        guard configuration.enabled else {
            application.logger.info("IM TCP server disabled")
            return
        }

        let bootstrap = ServerBootstrap(group: application.eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: Int32(clamping: configuration.listenBacklog))
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
            .childChannelOption(
                ChannelOptions.writeBufferWaterMark,
                value: ChannelOptions.Types.WriteBufferWaterMark(
                    low: configuration.writeBufferWaterMarkLow,
                    high: configuration.writeBufferWaterMarkHigh
                )
            )
            .childChannelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandlers(
                        IdleStateHandler(
                            readTimeout: .milliseconds(Int64(configuration.idleTimeout * 1000))
                        ),
                        ByteToMessageHandler(
                            IMTCPFrameDecoder(maxFrameBytes: configuration.maxFrameBytes)
                        ),
                        IMTCPConnectionHandler(application: application)
                    )
                    return channel.eventLoop.makeSucceededFuture(())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
        self.serverChannel.withLockedValue { $0 = channel }

        application.logger.info(
            "IM TCP server started",
            metadata: [
                "host": .string(configuration.host),
                "port": .stringConvertible(configuration.port),
                "listenBacklog": .stringConvertible(configuration.listenBacklog)
            ]
        )
    }

    func shutdownAsync(_ application: Application) async {
        let channel = self.serverChannel.withLockedValue { value in
            let channel = value
            value = nil
            return channel
        }

        guard let channel else {
            return
        }

        do {
            try await channel.close().get()
            application.logger.info("IM TCP server stopped")
        } catch {
            application.logger.warning(
                "Failed to stop IM TCP server cleanly",
                metadata: ["error": .string(String(describing: error))]
            )
        }
    }
}

private struct IMTCPConfigurationStorageKey: StorageKey {
    typealias Value = IMTCPConfiguration
}

private struct IMGatewayLocalFanoutConfigurationStorageKey: StorageKey {
    typealias Value = IMGatewayLocalFanoutConfiguration
}

private struct IMConnectionRegistryStorageKey: StorageKey {
    typealias Value = IMConnectionRegistry
}

private extension IMTCPChatDomainEventPayload {
    func activeCompactHintForActiveRecipient(
        maxPreviewCharacters: Int,
        eventID hintEventID: UUID? = nil
    ) -> IMTCPChatDomainEventPayload? {
        return conversationActivityHintForActiveRecipient(
            maxPreviewCharacters: maxPreviewCharacters,
            eventID: hintEventID
        )
    }

    func conversationActivityHintForActiveRecipient(
        maxPreviewCharacters: Int,
        eventID hintEventID: UUID? = nil
    ) -> IMTCPChatDomainEventPayload? {
        guard eventType == .messageCreated else {
            return nil
        }
        guard let activityHint = conversationActivityHint(maxPreviewCharacters: maxPreviewCharacters) else {
            return nil
        }
        return IMTCPChatDomainEventPayload(
            eventID: hintEventID ?? eventID,
            eventType: .conversationActivityHint,
            aggregateType: aggregateType,
            aggregateID: aggregateID,
            aggregateSequence: aggregateSequence,
            occurredAt: occurredAt,
            actorUserID: actorUserID,
            conversation: nil,
            timelineNotice: nil,
            requiresTimelineNotice: false,
            ownerCursor: nil,
            ownerAggregateSequence: nil,
            body: .conversationActivityHint(activityHint)
        )
    }

    func conversationActivityHintForInactiveRecipient(
        maxPreviewCharacters: Int? = nil,
        eventID hintEventID: UUID? = nil
    ) -> IMTCPChatDomainEventPayload? {
        guard eventType == .messageCreated else {
            return nil
        }
        guard let activityHint = conversationActivityHint(maxPreviewCharacters: maxPreviewCharacters) else {
            return nil
        }
        return IMTCPChatDomainEventPayload(
            eventID: hintEventID ?? eventID,
            eventType: .conversationActivityHint,
            aggregateType: aggregateType,
            aggregateID: aggregateID,
            aggregateSequence: aggregateSequence,
            occurredAt: occurredAt,
            actorUserID: actorUserID,
            conversation: nil,
            timelineNotice: nil,
            requiresTimelineNotice: false,
            ownerCursor: nil,
            ownerAggregateSequence: nil,
            body: .conversationActivityHint(activityHint)
        )
    }

    private func conversationActivityHint(maxPreviewCharacters: Int?) -> IMConversationActivityHint? {
        guard case .messageCreated(let message, _) = body else {
            return nil
        }
        let previewText: String
        if let maxPreviewCharacters {
            previewText = Self.truncatedPreview(message.content.previewText, maxCharacters: maxPreviewCharacters)
        } else {
            previewText = message.content.previewText
        }
        return IMConversationActivityHint(
            messageID: message.id,
            senderUserID: message.senderUserID,
            serverSequence: message.serverSequence,
            timelineSequence: message.timelineSequence,
            previewText: previewText,
            messageCreatedAt: previewText.isEmpty ? nil : message.createdAt,
            updatedAt: message.createdAt ?? occurredAt
        )
    }

    private static func truncatedPreview(_ preview: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0 else {
            return ""
        }
        guard preview.count > maxCharacters else {
            return preview
        }
        return String(preview.prefix(maxCharacters))
    }
}

extension Application {
    var imTCPConfiguration: IMTCPConfiguration {
        get {
            guard let configuration = storage[IMTCPConfigurationStorageKey.self] else {
                preconditionFailure("IMTCPConfiguration not configured")
            }
            return configuration
        }
        set {
            storage[IMTCPConfigurationStorageKey.self] = newValue
        }
    }

    var gatewayLocalFanoutConfiguration: IMGatewayLocalFanoutConfiguration {
        get {
            guard let configuration = storage[IMGatewayLocalFanoutConfigurationStorageKey.self] else {
                preconditionFailure("IMGatewayLocalFanoutConfiguration not configured")
            }
            return configuration
        }
        set {
            storage[IMGatewayLocalFanoutConfigurationStorageKey.self] = newValue
        }
    }

    var imConnectionRegistry: IMConnectionRegistry {
        get {
            if let registry = storage[IMConnectionRegistryStorageKey.self] {
                return registry
            }

            let registry = IMConnectionRegistry(
                metrics: routingMetrics,
                dropsRealtimeWhenNotWritable: imTCPConfiguration.dropsRealtimeWhenNotWritable,
                localFanoutConfiguration: gatewayLocalFanoutConfiguration,
                activeCompactHintPreviewMaxCharacters: streamConsumerConfiguration.realtimeActiveCompactHintPreviewMaxCharacters
            )
            storage[IMConnectionRegistryStorageKey.self] = registry
            return registry
        }
        set {
            storage[IMConnectionRegistryStorageKey.self] = newValue
        }
    }
}
