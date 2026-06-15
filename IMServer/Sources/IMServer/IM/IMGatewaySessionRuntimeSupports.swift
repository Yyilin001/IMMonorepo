import Fluent
import Foundation
import Kafka
import NIOCore
import Vapor

enum IMGatewayDomainEventFanoutIntent: String, Codable, Sendable {
    case unspecified
    case preSplitActiveFull
    case preSplitActiveCompact
    case preSplitInactiveHint
}

struct IMGatewayDomainEventPayloadBatch: Sendable {
    let payload: IMTCPChatDomainEventPayload
    let recipientUserIDs: [UUID]
    let fanoutIntent: IMGatewayDomainEventFanoutIntent

    init(
        payload: IMTCPChatDomainEventPayload,
        recipientUserIDs: [UUID],
        fanoutIntent: IMGatewayDomainEventFanoutIntent = .unspecified
    ) {
        self.payload = payload
        self.recipientUserIDs = recipientUserIDs
        self.fanoutIntent = fanoutIntent
    }
}

protocol GatewaySessionTransport: Sendable {
    func sendDomainEventDelivery(
        ownerUserID: UUID,
        eventID: UUID,
        requestID: UUID?
    ) async
    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        ownerUserID: UUID,
        requestID: UUID?
    ) async
    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async
    func sendDomainEventPayloadBatches(
        _ batches: [IMGatewayDomainEventPayloadBatch],
        requestID: UUID?
    ) async
    func sendDomainEventPayloads(
        _ deliveries: [IMCanonicalDomainEventDelivery],
        requestID: UUID?
    ) async
    func sendStreamSignal(
        _ payload: IMTCPMessageStreamSignalPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async
    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async
    func kickConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async
    func activeConnectionCounts(forSessionIDs sessionIDs: [UUID]) async -> [UUID: Int]
}

protocol SessionDirectory: Sendable {
    func routeNodeIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>]
    func activeNodeIDs() async throws -> Set<String>
}

protocol GatewayDispatchBus: Sendable {
    func dispatch(_ envelope: NodeMessageDispatchEnvelope, toNodeID nodeID: String) async throws
}

struct ConnectionRoutingSessionDirectory: SessionDirectory {
    let presenceStore: any PresenceStore

    func routeNodeIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>] {
        try await presenceStore.routeNodeIDs(forUserIDs: userIDs)
    }

    func activeNodeIDs() async throws -> Set<String> {
        try await presenceStore.activeNodeIDs()
    }
}

struct ConnectionRoutingGatewayDispatchBus: GatewayDispatchBus {
    let dispatchService: any NodeMessageDispatchService

    func dispatch(_ envelope: NodeMessageDispatchEnvelope, toNodeID nodeID: String) async throws {
        try await dispatchService.dispatch(envelope, toNodeID: nodeID)
    }
}

struct LocalGatewaySessionTransport: GatewaySessionTransport {
    let routingService: ConnectionRoutingService

    func sendDomainEventDelivery(
        ownerUserID: UUID,
        eventID: UUID,
        requestID: UUID?
    ) async {
        await routingService.sendDomainEventDelivery(ownerUserID: ownerUserID, eventID: eventID, requestID: requestID)
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        ownerUserID: UUID,
        requestID: UUID?
    ) async {
        await routingService.sendDomainEventPayload(payload, ownerUserID: ownerUserID, requestID: requestID)
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async {
        await routingService.sendDomainEventPayload(payload, toUserIDs: userIDs, requestID: requestID)
    }

    func sendDomainEventPayloadBatches(
        _ batches: [IMGatewayDomainEventPayloadBatch],
        requestID: UUID?
    ) async {
        await routingService.sendDomainEventPayloadBatches(batches, requestID: requestID)
    }

    func sendDomainEventPayloads(
        _ deliveries: [IMCanonicalDomainEventDelivery],
        requestID: UUID?
    ) async {
        await routingService.sendDomainEventPayloads(deliveries, requestID: requestID)
    }

    func sendStreamSignal(
        _ payload: IMTCPMessageStreamSignalPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async {
        await routingService.sendStreamSignal(payload, toUserIDs: userIDs, requestID: requestID)
    }

    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await routingService.kickConnections(forSessionID: sessionID, reason: reason, message: message)
    }

    func kickConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await routingService.kickConnections(forUserID: userID, reason: reason, message: message)
    }

    func activeConnectionCounts(forSessionIDs sessionIDs: [UUID]) async -> [UUID: Int] {
        await routingService.activeConnectionCounts(forSessionIDs: sessionIDs)
    }
}

struct HTTPGatewaySessionTransport: GatewaySessionTransport {
    private struct ReusableDomainEventPacketKey: Hashable, Sendable {
        let eventID: UUID
        let eventType: IMTCPChatDomainEventType
        let aggregateID: UUID
        let aggregateSequence: UInt64
    }

    private struct ReusableDomainEventPayloadGroup: Sendable {
        var payload: IMTCPChatDomainEventPayload
        var userIDs: [UUID]
    }

    let app: Application
    let configuration: IMGatewayRelayConfiguration

    func sendDomainEventDelivery(
        ownerUserID: UUID,
        eventID: UUID,
        requestID: UUID?
    ) async {
        await postOrLog(
            path: "/internal/gateway/realtime/domain-event",
            payload: GatewayRelayDomainEventDeliveryRequest(
                ownerUserID: ownerUserID,
                eventID: eventID,
                requestID: requestID
            )
        )
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        ownerUserID: UUID,
        requestID: UUID?
    ) async {
        await sendDomainEventPayload(payload, toUserIDs: [ownerUserID], requestID: requestID)
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async {
        guard !userIDs.isEmpty,
              let payloadData = domainEventPayloadData(payload)
        else {
            return
        }
        await relayDomainEventPayloadWorkItem(
            .groupedBinary(
                payloadData: payloadData,
                recipientUserIDs: userIDs,
                fanoutIntent: .unspecified
            ),
            requestID: requestID
        )
    }

    func sendDomainEventPayloadBatches(
        _ batches: [IMGatewayDomainEventPayloadBatch],
        requestID: UUID?
    ) async {
        let nonEmptyBatches = batches.filter { !$0.recipientUserIDs.isEmpty }
        guard !nonEmptyBatches.isEmpty else {
            return
        }

        let startedAt = Date()
        let relayBatchSize = max(1, app.streamConsumerConfiguration.domainDeliveryRelayBatchSize)
        let groupedRecipientBatchSize = max(relayBatchSize, relayBatchSize * 64)
        let relayConcurrency = max(1, app.streamConsumerConfiguration.domainDeliveryFanoutConcurrency)
        let workPlan = makeDomainEventPayloadBatchWorkPlan(
            nonEmptyBatches,
            recipientBatchSize: groupedRecipientBatchSize,
            maxBinaryBodyBytes: configuration.domainEventPacketBinaryMaxBodyBytes
        )
        await app.routingMetrics.recordGatewayHTTPRelay(
            workItemCount: workPlan.workItems.count,
            payloadBatchCount: workPlan.payloadBatchCount,
            recipientCount: workPlan.recipientCount,
            skippedRecipientCount: workPlan.skippedRecipientCount,
            encodedPayloadBytes: workPlan.encodedPayloadBytes,
            maxRecipientsPerWorkItem: workPlan.maxRecipientsPerWorkItem
        )

        let prepareMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        let relayStartedAt = Date()
        await relayDomainEventPayloadWorkItems(workPlan.workItems, requestID: requestID, concurrency: relayConcurrency)
        let relayMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: relayStartedAt)
        let totalMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        let slowLogMilliseconds = app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
        if IMRealtimeDeliveryDiagnostics.shouldLogAny(
            [prepareMilliseconds, relayMilliseconds, totalMilliseconds],
            thresholdMilliseconds: slowLogMilliseconds
        ) {
            app.logger.info("Gateway HTTP relay direct payload batches slow.", metadata: [
                "request_id": .string(requestID?.uuidString ?? ""),
                "payload_batch_count": .stringConvertible(workPlan.payloadBatchCount),
                "recipient_count": .stringConvertible(workPlan.recipientCount),
                "work_item_count": .stringConvertible(workPlan.workItems.count),
                "max_recipients_per_work_item": .stringConvertible(workPlan.maxRecipientsPerWorkItem),
                "skipped_recipient_count": .stringConvertible(workPlan.skippedRecipientCount),
                "encoded_payload_bytes": .stringConvertible(workPlan.encodedPayloadBytes),
                "prepare_ms": .stringConvertible(prepareMilliseconds),
                "relay_ms": .stringConvertible(relayMilliseconds),
                "total_ms": .stringConvertible(totalMilliseconds),
                "relay_concurrency": .stringConvertible(relayConcurrency),
                "recipient_batch_size": .stringConvertible(groupedRecipientBatchSize)
            ])
        }
    }

    func makeDomainEventPayloadBatchWorkPlan(
        _ batches: [IMGatewayDomainEventPayloadBatch],
        recipientBatchSize: Int,
        maxBinaryBodyBytes: Int = IMGatewayRelayConfiguration.defaultDomainEventPacketBinaryMaxBodyBytes
    ) -> GatewayRelayDomainEventPayloadBatchWorkPlan {
        let recipientBatchSize = max(1, recipientBatchSize)
        let maxBinaryBodyBytes = max(1, maxBinaryBodyBytes)
        let nonEmptyBatches = batches.filter { !$0.recipientUserIDs.isEmpty }
        var workItems: [GatewayRelayDomainEventPayloadWorkItem] = []
        var binaryEntries: [GatewayRelayDomainEventPayloadBinaryEntry] = []
        var encodedPayloadBytes = 0
        var skippedRecipientCount = 0
        var recipientCount = 0
        var maxRecipientsPerWorkItem = 0

        for batch in nonEmptyBatches {
            guard let payloadData = domainEventPayloadData(batch.payload) else {
                skippedRecipientCount += batch.recipientUserIDs.count
                continue
            }
            encodedPayloadBytes += payloadData.count
            let effectiveRecipientBatchSize = binaryRecipientBatchSize(
                preferredBatchSize: recipientBatchSize,
                payloadByteCount: payloadData.count,
                maxBinaryBodyBytes: maxBinaryBodyBytes
            )
            guard effectiveRecipientBatchSize > 0 else {
                skippedRecipientCount += batch.recipientUserIDs.count
                continue
            }

            var startIndex = batch.recipientUserIDs.startIndex
            while startIndex < batch.recipientUserIDs.endIndex {
                let endIndex = batch.recipientUserIDs.index(
                    startIndex,
                    offsetBy: effectiveRecipientBatchSize,
                    limitedBy: batch.recipientUserIDs.endIndex
                ) ?? batch.recipientUserIDs.endIndex
                let recipientUserIDs = Array(batch.recipientUserIDs[startIndex..<endIndex])
                recipientCount += recipientUserIDs.count
                maxRecipientsPerWorkItem = max(maxRecipientsPerWorkItem, recipientUserIDs.count)
                binaryEntries.append(
                    GatewayRelayDomainEventPayloadBinaryEntry(
                        payloadData: payloadData,
                        recipientUserIDs: recipientUserIDs,
                        fanoutIntent: batch.fanoutIntent
                    )
                )
                startIndex = endIndex
            }
        }
        let binaryBatchWorkItems = makeBinaryBatchWorkItems(
            binaryEntries,
            maxBodyBytes: maxBinaryBodyBytes
        )
        workItems.append(contentsOf: binaryBatchWorkItems)
        maxRecipientsPerWorkItem = max(
            maxRecipientsPerWorkItem,
            binaryBatchWorkItems.map(\.recipientCount).max() ?? 0
        )

        return GatewayRelayDomainEventPayloadBatchWorkPlan(
            workItems: workItems,
            payloadBatchCount: nonEmptyBatches.count,
            recipientCount: recipientCount,
            skippedRecipientCount: skippedRecipientCount,
            encodedPayloadBytes: encodedPayloadBytes,
            maxRecipientsPerWorkItem: maxRecipientsPerWorkItem
        )
    }

    private func binaryRecipientBatchSize(
        preferredBatchSize: Int,
        payloadByteCount: Int,
        maxBinaryBodyBytes: Int
    ) -> Int {
        let maxBinaryBodyBytes = max(1, maxBinaryBodyBytes)
        let fixedBodyBytes = IMGatewayRelayBinaryCodec.encodedDomainEventPacketByteCount(
            payloadByteCount: payloadByteCount,
            recipientCount: 0,
            includesRequestID: true
        )
        let recipientByteCount = IMGatewayRelayBinaryCodec.encodedDomainEventPacketByteCount(
            payloadByteCount: payloadByteCount,
            recipientCount: 1,
            includesRequestID: true
        ) - fixedBodyBytes
        let availableRecipientBytes = maxBinaryBodyBytes - fixedBodyBytes
        guard recipientByteCount > 0,
              availableRecipientBytes >= recipientByteCount
        else {
            return 0
        }
        return min(max(1, preferredBatchSize), max(1, availableRecipientBytes / recipientByteCount))
    }

    private func makeBinaryBatchWorkItems(
        _ entries: [GatewayRelayDomainEventPayloadBinaryEntry],
        maxBodyBytes: Int
    ) -> [GatewayRelayDomainEventPayloadWorkItem] {
        let maxBodyBytes = max(1, maxBodyBytes)
        var workItems: [GatewayRelayDomainEventPayloadWorkItem] = []
        var currentEntries: [GatewayRelayDomainEventPayloadBinaryEntry] = []

        for entry in entries {
            if binaryBatchBodyByteCount([entry]) > maxBodyBytes {
                if !currentEntries.isEmpty {
                    workItems.append(.groupedBinaryBatch(currentEntries))
                    currentEntries.removeAll(keepingCapacity: true)
                }
                workItems.append(.groupedBinary(
                    payloadData: entry.payloadData,
                    recipientUserIDs: entry.recipientUserIDs,
                    fanoutIntent: entry.fanoutIntent
                ))
                continue
            }

            var candidateEntries = currentEntries
            candidateEntries.append(entry)
            if binaryBatchBodyByteCount(candidateEntries) <= maxBodyBytes {
                currentEntries = candidateEntries
            } else {
                workItems.append(.groupedBinaryBatch(currentEntries))
                currentEntries = [entry]
            }
        }
        if !currentEntries.isEmpty {
            workItems.append(.groupedBinaryBatch(currentEntries))
        }
        return workItems
    }

    private func binaryBatchBodyByteCount(_ entries: [GatewayRelayDomainEventPayloadBinaryEntry]) -> Int {
        IMGatewayRelayBinaryCodec.encodedDomainEventPacketBatchByteCount(
            entries: entries.map {
                (payloadByteCount: $0.payloadData.count, recipientCount: $0.recipientUserIDs.count)
            },
            includesRequestID: true
        )
    }

    func makeGatewayRelayPayloadRecipientChunks(
        payloadBase64: String,
        recipientUserIDs: [UUID],
        requestID: UUID?,
        maxBodyBytes: Int
    ) -> [[UUID]] {
        let maxBodyBytes = max(1, maxBodyBytes)
        var chunks: [[UUID]] = []
        var current: [UUID] = []
        for recipientUserID in recipientUserIDs {
            var candidate = current
            candidate.append(recipientUserID)
            let request = GatewayRelayDomainEventPayloadRequest(
                payloadBase64: payloadBase64,
                recipientUserIDs: candidate,
                requestID: requestID
            )
            if current.isEmpty || jsonEncodedByteCount(request) <= maxBodyBytes {
                current = candidate
            } else {
                chunks.append(current)
                current = [recipientUserID]
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    func makeGatewayRelayPayloadBatchEntryChunks(
        _ entries: [GatewayRelayDomainEventPayloadBatchEntry],
        requestID: UUID?,
        maxBodyBytes: Int
    ) -> [[GatewayRelayDomainEventPayloadBatchEntry]] {
        let maxBodyBytes = max(1, maxBodyBytes)
        var chunks: [[GatewayRelayDomainEventPayloadBatchEntry]] = []
        var current: [GatewayRelayDomainEventPayloadBatchEntry] = []
        for entry in entries {
            var candidate = current
            candidate.append(entry)
            let request = GatewayRelayDomainEventPayloadBatchRequest(
                deliveries: candidate,
                requestID: requestID
            )
            if current.isEmpty || jsonEncodedByteCount(request) <= maxBodyBytes {
                current = candidate
            } else {
                chunks.append(current)
                current = [entry]
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func jsonEncodedByteCount<Payload: Encodable>(_ payload: Payload) -> Int {
        (try? JSONEncoder().encode(payload).count) ?? Int.max
    }

    func sendDomainEventPayloads(
        _ deliveries: [IMCanonicalDomainEventDelivery],
        requestID: UUID?
    ) async {
        let startedAt = Date()
        var encodedPayloadBytes = 0
        var skippedEncodeCount = 0
        let groupedDeliveries = groupReusableDomainEventPayloads(deliveries)
        guard !groupedDeliveries.reusable.isEmpty || !groupedDeliveries.fallback.isEmpty else {
            return
        }

        let batchSize = max(1, app.streamConsumerConfiguration.domainDeliveryRelayBatchSize)
        let groupedRecipientBatchSize = max(batchSize, batchSize * 64)
        let relayConcurrency = max(1, app.streamConsumerConfiguration.domainDeliveryFanoutConcurrency)

        var workItems: [GatewayRelayDomainEventPayloadWorkItem] = []
        var binaryEntries: [GatewayRelayDomainEventPayloadBinaryEntry] = []
        var singleEntries: [GatewayRelayDomainEventPayloadBatchEntry] = []
        var binaryEntryCount = 0
        for group in groupedDeliveries.reusable {
            guard let payloadData = domainEventPayloadData(group.payload) else {
                skippedEncodeCount += group.userIDs.count
                continue
            }
            encodedPayloadBytes += payloadData.count
            let effectiveGroupedRecipientBatchSize = binaryRecipientBatchSize(
                preferredBatchSize: groupedRecipientBatchSize,
                payloadByteCount: payloadData.count,
                maxBinaryBodyBytes: configuration.domainEventPacketBinaryMaxBodyBytes
            )
            guard effectiveGroupedRecipientBatchSize > 0 else {
                skippedEncodeCount += group.userIDs.count
                continue
            }

            var startIndex = group.userIDs.startIndex
            while startIndex < group.userIDs.endIndex {
                let endIndex = group.userIDs.index(
                    startIndex,
                    offsetBy: effectiveGroupedRecipientBatchSize,
                    limitedBy: group.userIDs.endIndex
                ) ?? group.userIDs.endIndex
                binaryEntries.append(
                    GatewayRelayDomainEventPayloadBinaryEntry(
                        payloadData: payloadData,
                        recipientUserIDs: Array(group.userIDs[startIndex..<endIndex]),
                        fanoutIntent: .unspecified
                    )
                )
                binaryEntryCount += 1
                startIndex = endIndex
            }
        }

        for delivery in groupedDeliveries.fallback {
            guard let payloadData = domainEventPayloadData(delivery.payload) else {
                skippedEncodeCount += 1
                continue
            }
            encodedPayloadBytes += payloadData.count
            if binaryRecipientBatchSize(
                preferredBatchSize: 1,
                payloadByteCount: payloadData.count,
                maxBinaryBodyBytes: configuration.domainEventPacketBinaryMaxBodyBytes
            ) > 0 {
                binaryEntries.append(
                    GatewayRelayDomainEventPayloadBinaryEntry(
                        payloadData: payloadData,
                        recipientUserIDs: [delivery.ownerUserID],
                        fanoutIntent: .unspecified
                    )
                )
                binaryEntryCount += 1
            } else {
                singleEntries.append(
                    GatewayRelayDomainEventPayloadBatchEntry(
                        ownerUserID: delivery.ownerUserID,
                        payloadBase64: payloadData.base64EncodedString()
                    )
                )
            }
        }

        workItems.append(contentsOf: makeBinaryBatchWorkItems(
            binaryEntries,
            maxBodyBytes: configuration.domainEventPacketBinaryMaxBodyBytes
        ))

        var startIndex = singleEntries.startIndex
        while startIndex < singleEntries.endIndex {
            let endIndex = singleEntries.index(
                startIndex,
                offsetBy: batchSize,
                limitedBy: singleEntries.endIndex
            ) ?? singleEntries.endIndex
            workItems.append(.batch(Array(singleEntries[startIndex..<endIndex])))
            startIndex = endIndex
        }

        await app.routingMetrics.recordGatewayHTTPRelay(
            workItemCount: workItems.count,
            payloadBatchCount: groupedDeliveries.reusable.count + groupedDeliveries.fallback.count,
            recipientCount: workItems.reduce(0) { $0 + $1.recipientCount },
            skippedRecipientCount: skippedEncodeCount,
            encodedPayloadBytes: encodedPayloadBytes,
            maxRecipientsPerWorkItem: workItems.map(\.recipientCount).max() ?? 0
        )

        let prepareMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        let relayStartedAt = Date()
        await relayDomainEventPayloadWorkItems(workItems, requestID: requestID, concurrency: relayConcurrency)
        let relayMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: relayStartedAt)
        let totalMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        let slowLogMilliseconds = app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
        if IMRealtimeDeliveryDiagnostics.shouldLogAny(
            [prepareMilliseconds, relayMilliseconds, totalMilliseconds],
            thresholdMilliseconds: slowLogMilliseconds
        ) {
            app.logger.info("Gateway HTTP relay payload batch slow.", metadata: [
                "request_id": .string(requestID?.uuidString ?? ""),
                "delivery_count": .stringConvertible(deliveries.count),
                "unique_payload_count": .stringConvertible(
                    groupedDeliveries.reusable.count + groupedDeliveries.fallback.count
                ),
                "work_item_count": .stringConvertible(workItems.count),
                "binary_entry_count": .stringConvertible(binaryEntryCount),
                "json_fallback_entry_count": .stringConvertible(singleEntries.count),
                "skipped_encode_count": .stringConvertible(skippedEncodeCount),
                "encoded_payload_bytes": .stringConvertible(encodedPayloadBytes),
                "prepare_ms": .stringConvertible(prepareMilliseconds),
                "relay_ms": .stringConvertible(relayMilliseconds),
                "total_ms": .stringConvertible(totalMilliseconds),
                "relay_concurrency": .stringConvertible(relayConcurrency),
                "batch_size": .stringConvertible(batchSize)
            ])
        }
    }

    private func relayDomainEventPayloadWorkItems(
        _ workItems: [GatewayRelayDomainEventPayloadWorkItem],
        requestID: UUID?,
        concurrency: Int
    ) async {
        guard !workItems.isEmpty else {
            return
        }
        guard concurrency > 1, workItems.count > 1 else {
            for workItem in workItems {
                await relayDomainEventPayloadWorkItem(workItem, requestID: requestID)
            }
            return
        }

        await withTaskGroup(of: Void.self) { group in
            var nextIndex = workItems.startIndex
            let initialCount = min(concurrency, workItems.count)
            for _ in 0..<initialCount {
                let workItem = workItems[nextIndex]
                group.addTask {
                    await relayDomainEventPayloadWorkItem(workItem, requestID: requestID)
                }
                nextIndex += 1
            }

            while await group.next() != nil {
                guard nextIndex < workItems.endIndex else {
                    continue
                }
                let workItem = workItems[nextIndex]
                group.addTask {
                    await relayDomainEventPayloadWorkItem(workItem, requestID: requestID)
                }
                nextIndex += 1
            }
        }
    }

    private func relayDomainEventPayloadWorkItem(
        _ workItem: GatewayRelayDomainEventPayloadWorkItem,
        requestID: UUID?
    ) async {
        switch workItem {
        case .groupedBinary(let payloadData, let recipientUserIDs, let fanoutIntent):
            do {
                let body = try IMGatewayRelayBinaryCodec.encodeDomainEventPacket(
                    payloadData: payloadData,
                    recipientUserIDs: recipientUserIDs,
                    requestID: requestID
                )
                try await postRaw(
                    path: "/internal/gateway/realtime/domain-event-packet-bin",
                    body: body,
                    fanoutIntent: fanoutIntent
                )
            } catch {
                await app.routingMetrics.recordGatewayHTTPRelayBinaryFallback()
                await app.routingMetrics.recordCrossNodeDispatchFailed()
                app.logger.warning(
                    "Gateway binary relay failed; falling back to JSON relay.",
                    metadata: [
                        "node_id": .string(app.imNodeID),
                        "recipient_count": .stringConvertible(recipientUserIDs.count),
                        "error": .string(String(describing: error))
                    ]
                )
                await relayDomainEventPayloadJSONFallback(
                    payloadBase64: payloadData.base64EncodedString(),
                    recipientUserIDs: recipientUserIDs,
                    requestID: requestID,
                    fanoutIntent: fanoutIntent
                )
            }
        case .groupedBinaryBatch(let entries):
            do {
                let body = try IMGatewayRelayBinaryCodec.encodeDomainEventPacketBatch(
                    entries: entries.map {
                        IMGatewayRelayBinaryCodec.DomainEventPacketBatchEntry(
                            payloadData: $0.payloadData,
                            recipientUserIDs: $0.recipientUserIDs,
                            fanoutIntent: $0.fanoutIntent
                        )
                    },
                    requestID: requestID
                )
                try await postRaw(
                    path: "/internal/gateway/realtime/domain-event-packets-bin",
                    body: body
                )
            } catch {
                await app.routingMetrics.recordGatewayHTTPRelayBinaryFallback()
                await app.routingMetrics.recordCrossNodeDispatchFailed()
                app.logger.warning(
                    "Gateway binary batch relay failed; falling back to single binary relay.",
                    metadata: [
                        "node_id": .string(app.imNodeID),
                        "entry_count": .stringConvertible(entries.count),
                        "recipient_count": .stringConvertible(entries.reduce(0) { $0 + $1.recipientUserIDs.count }),
                        "error": .string(String(describing: error))
                    ]
                )
                for entry in entries {
                    await relayDomainEventPayloadWorkItem(
                        .groupedBinary(
                            payloadData: entry.payloadData,
                            recipientUserIDs: entry.recipientUserIDs,
                            fanoutIntent: entry.fanoutIntent
                        ),
                        requestID: requestID
                    )
                }
            }
        case .batch(let batch):
            await relayDomainEventPayloadBatch(batch, requestID: requestID)
        }
    }

    private func relayDomainEventPayloadJSONFallback(
        payloadBase64: String,
        recipientUserIDs: [UUID],
        requestID: UUID?,
        fanoutIntent: IMGatewayDomainEventFanoutIntent = .unspecified
    ) async {
        for chunk in makeGatewayRelayPayloadRecipientChunks(
            payloadBase64: payloadBase64,
            recipientUserIDs: recipientUserIDs,
            requestID: requestID,
            maxBodyBytes: configuration.domainEventPacketMaxBodyBytes
        ) {
            await postOrLog(
                path: "/internal/gateway/realtime/domain-event-packet",
                payload: GatewayRelayDomainEventPayloadRequest(
                    payloadBase64: payloadBase64,
                    recipientUserIDs: chunk,
                    requestID: requestID,
                    fanoutIntent: fanoutIntent
                )
            )
        }
    }

    private func relayDomainEventPayloadBatch(
        _ batch: [GatewayRelayDomainEventPayloadBatchEntry],
        requestID: UUID?
    ) async {
        guard !batch.isEmpty else {
            return
        }
        for chunk in makeGatewayRelayPayloadBatchEntryChunks(
            batch,
            requestID: requestID,
            maxBodyBytes: configuration.domainEventPacketsMaxBodyBytes
        ) {
            if chunk.count == 1, let entry = chunk.first {
                await relayDomainEventPayloadJSONFallback(
                    payloadBase64: entry.payloadBase64,
                    recipientUserIDs: [entry.ownerUserID],
                    requestID: requestID
                )
            } else {
                await postOrLog(
                    path: "/internal/gateway/realtime/domain-event-packets",
                    payload: GatewayRelayDomainEventPayloadBatchRequest(
                        deliveries: chunk,
                        requestID: requestID
                    )
                )
            }
        }
    }

    func sendStreamSignal(
        _ payload: IMTCPMessageStreamSignalPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async {
        guard let packetBase64 = packetBase64(type: .streamSignal, requestID: requestID, payload: payload) else {
            return
        }
        await postOrLog(
            path: "/internal/gateway/realtime/stream-signal",
            payload: GatewayRelayMessageRequest(
                packetBase64: packetBase64,
                recipientUserIDs: userIDs,
                requestID: requestID
            )
        )
    }

    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await postOrLog(
            path: "/internal/gateway/realtime/kick-session",
            payload: GatewayRelayKickSessionRequest(
                sessionID: sessionID,
                reason: reason,
                message: message
            )
        )
    }

    func kickConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await postOrLog(
            path: "/internal/gateway/realtime/kick-user",
            payload: GatewayRelayKickUserRequest(
                userID: userID,
                reason: reason,
                message: message
            )
        )
    }

    func activeConnectionCounts(forSessionIDs sessionIDs: [UUID]) async -> [UUID: Int] {
        guard !sessionIDs.isEmpty else { return [:] }

        do {
            let response: GatewayRelaySessionCountsResponse = try await post(
                path: "/internal/gateway/realtime/session-counts",
                payload: GatewayRelaySessionCountsRequest(sessionIDs: sessionIDs)
            )
            return response.counts
        } catch {
            await app.routingMetrics.recordSessionCountQueryFailed()
            app.logger.warning(
                "Gateway relay session count request failed",
                metadata: [
                    "node_id": .string(app.imNodeID),
                    "path": .string("/internal/gateway/realtime/session-counts"),
                    "session_count": .stringConvertible(sessionIDs.count),
                    "error": .string(String(describing: error))
                ]
            )
            return [:]
        }
    }

    private func post<Payload: Content>(path: String, payload: Payload) async throws {
        let _: EmptyGatewayRelayResponse = try await post(path: path, payload: payload)
    }

    private func postOrLog<Payload: Content>(path: String, payload: Payload) async {
        do {
            try await post(path: path, payload: payload)
        } catch {
            await app.routingMetrics.recordCrossNodeDispatchFailed()
            app.logger.warning(
                "Gateway relay request failed",
                metadata: [
                    "node_id": .string(app.imNodeID),
                    "path": .string(path),
                    "error": .string(String(describing: error))
                ]
            )
        }
    }

    private func post<Payload: Content, Response: Content>(path: String, payload: Payload) async throws -> Response {
        guard let baseURL = configuration.baseURL else {
            throw GatewayRelayTransportError.missingBaseURL
        }

        let bodyBytes = jsonEncodedByteCount(payload)
        let startedAt = Date()
        let response: ClientResponse
        do {
            response = try await app.client.post(URI(string: "\(baseURL)\(path)")) { request in
                if let sharedSecret = configuration.sharedSecret, !sharedSecret.isEmpty {
                    request.headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: sharedSecret)
                }
                try request.content.encode(payload)
            }
        } catch {
            let postMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
            await app.routingMetrics.recordGatewayHTTPRelayRequest(
                didSucceed: false,
                latencyMilliseconds: postMilliseconds,
                bodyBytes: bodyBytes
            )
            throw error
        }
        let postMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        let slowLogMilliseconds = app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
        if IMRealtimeDeliveryDiagnostics.shouldLog(
            durationMilliseconds: postMilliseconds,
            thresholdMilliseconds: slowLogMilliseconds
        ) {
            app.logger.info("Gateway HTTP relay POST slow.", metadata: [
                "node_id": .string(app.imNodeID),
                "path": .string(path),
                "status": .string(response.status.code.description),
                "duration_ms": .stringConvertible(postMilliseconds),
                "body_bytes": .stringConvertible(bodyBytes)
            ])
        }

        guard response.status == .ok else {
            await app.routingMetrics.recordGatewayHTTPRelayRequest(
                didSucceed: false,
                latencyMilliseconds: postMilliseconds,
                bodyBytes: bodyBytes
            )
            app.logger.warning(
                "Gateway relay request failed",
                metadata: [
                    "node_id": .string(app.imNodeID),
                    "path": .string(path),
                    "status": .string(response.status.code.description)
                ]
            )
            throw GatewayRelayTransportError.unexpectedStatus(response.status)
        }

        await app.routingMetrics.recordGatewayHTTPRelayRequest(
            didSucceed: true,
            latencyMilliseconds: postMilliseconds,
            bodyBytes: bodyBytes
        )
        if Response.self == EmptyGatewayRelayResponse.self {
            return EmptyGatewayRelayResponse() as! Response
        }

        return try response.content.decode(Response.self)
    }

    private func postRaw(
        path: String,
        body: Data,
        fanoutIntent: IMGatewayDomainEventFanoutIntent = .unspecified
    ) async throws {
        guard let baseURL = configuration.baseURL else {
            throw GatewayRelayTransportError.missingBaseURL
        }

        let startedAt = Date()
        let response: ClientResponse
        do {
            response = try await app.client.post(URI(string: "\(baseURL)\(path)")) { request in
                if let sharedSecret = configuration.sharedSecret, !sharedSecret.isEmpty {
                    request.headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: sharedSecret)
                }
                if fanoutIntent != .unspecified {
                    request.headers.replaceOrAdd(name: "X-IM-Fanout-Intent", value: fanoutIntent.rawValue)
                }
                request.headers.contentType = HTTPMediaType(type: "application", subType: "octet-stream")
                request.body = .init(data: body)
            }
        } catch {
            let postMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
            await app.routingMetrics.recordGatewayHTTPRelayRequest(
                didSucceed: false,
                latencyMilliseconds: postMilliseconds,
                bodyBytes: body.count
            )
            throw error
        }
        let postMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        let slowLogMilliseconds = app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
        if IMRealtimeDeliveryDiagnostics.shouldLog(
            durationMilliseconds: postMilliseconds,
            thresholdMilliseconds: slowLogMilliseconds
        ) {
            app.logger.info("Gateway HTTP binary relay POST slow.", metadata: [
                "node_id": .string(app.imNodeID),
                "path": .string(path),
                "status": .string(response.status.code.description),
                "duration_ms": .stringConvertible(postMilliseconds),
                "body_bytes": .stringConvertible(body.count)
            ])
        }

        guard response.status == .ok else {
            await app.routingMetrics.recordGatewayHTTPRelayRequest(
                didSucceed: false,
                latencyMilliseconds: postMilliseconds,
                bodyBytes: body.count
            )
            throw GatewayRelayTransportError.unexpectedStatus(response.status)
        }
        await app.routingMetrics.recordGatewayHTTPRelayRequest(
            didSucceed: true,
            latencyMilliseconds: postMilliseconds,
            bodyBytes: body.count
        )
    }

    private func packetBase64<Payload: Sendable>(
        type: IMTCPPacketType,
        requestID: UUID?,
        payload: Payload
    ) -> String? {
        do {
            return try IMTCPProtobufCodec.encode(type: type, requestID: requestID, payload: payload)
                .base64EncodedString()
        } catch {
            app.logger.warning(
                "Gateway relay packet encode failed",
                metadata: [
                    "node_id": .string(app.imNodeID),
                    "packet_type": .string(type.rawValue),
                    "error": .string(String(describing: error))
                ]
            )
            return nil
        }
    }

    private func domainEventPayloadData(_ payload: IMTCPChatDomainEventPayload) -> Data? {
        do {
            return try IMTCPProtobufCodec.encodeDomainEvent(
                payload,
                requireDeliveryMetadata: false
            )
        } catch {
            app.logger.warning(
                "Gateway relay domain-event payload encode failed",
                metadata: [
                    "node_id": .string(app.imNodeID),
                    "event_id": .string(payload.eventID.uuidString),
                    "error": .string(String(describing: error))
                ]
            )
            return nil
        }
    }

    private func groupReusableDomainEventPayloads(
        _ deliveries: [IMCanonicalDomainEventDelivery]
    ) -> (reusable: [ReusableDomainEventPayloadGroup], fallback: [IMCanonicalDomainEventDelivery]) {
        var reusableGroups: [ReusableDomainEventPacketKey: ReusableDomainEventPayloadGroup] = [:]
        var fallbackDeliveries: [IMCanonicalDomainEventDelivery] = []
        fallbackDeliveries.reserveCapacity(deliveries.count)

        for delivery in deliveries {
            guard let key = reusablePacketKey(for: delivery.payload) else {
                fallbackDeliveries.append(delivery)
                continue
            }
            if reusableGroups[key] == nil {
                reusableGroups[key] = ReusableDomainEventPayloadGroup(payload: delivery.payload, userIDs: [])
            }
            reusableGroups[key]?.userIDs.append(delivery.ownerUserID)
        }

        return (Array(reusableGroups.values), fallbackDeliveries)
    }

    private func reusablePacketKey(for payload: IMTCPChatDomainEventPayload) -> ReusableDomainEventPacketKey? {
        guard payload.eventType == .messageCreated,
              payload.conversation == nil,
              payload.timelineNotice == nil,
              payload.requiresTimelineNotice == false,
              payload.ownerCursor == nil,
              payload.ownerAggregateSequence == nil
        else {
            return nil
        }

        return ReusableDomainEventPacketKey(
            eventID: payload.eventID,
            eventType: payload.eventType,
            aggregateID: payload.aggregateID,
            aggregateSequence: payload.aggregateSequence
        )
    }
}

private struct EmptyGatewayRelayResponse: Content {}

enum GatewayRelayDomainEventPayloadWorkItem: Sendable {
    case groupedBinary(
        payloadData: Data,
        recipientUserIDs: [UUID],
        fanoutIntent: IMGatewayDomainEventFanoutIntent
    )
    case groupedBinaryBatch([GatewayRelayDomainEventPayloadBinaryEntry])
    case batch([GatewayRelayDomainEventPayloadBatchEntry])

    var recipientCount: Int {
        switch self {
        case .groupedBinary(_, let recipientUserIDs, _):
            return recipientUserIDs.count
        case .groupedBinaryBatch(let entries):
            return entries.reduce(0) { $0 + $1.recipientUserIDs.count }
        case .batch(let entries):
            return entries.count
        }
    }
}

struct GatewayRelayDomainEventPayloadBinaryEntry: Sendable {
    let payloadData: Data
    let recipientUserIDs: [UUID]
    let fanoutIntent: IMGatewayDomainEventFanoutIntent
}

struct GatewayRelayDomainEventPayloadBatchWorkPlan: Sendable {
    let workItems: [GatewayRelayDomainEventPayloadWorkItem]
    let payloadBatchCount: Int
    let recipientCount: Int
    let skippedRecipientCount: Int
    let encodedPayloadBytes: Int
    let maxRecipientsPerWorkItem: Int
}

private enum GatewayRelayTransportError: Error {
    case missingBaseURL
    case unexpectedStatus(HTTPResponseStatus)
}

struct LoggingUnavailableGatewaySessionTransport: GatewaySessionTransport {
    let logger: Logger
    let role: IMRuntimeRole

    func sendDomainEventDelivery(
        ownerUserID: UUID,
        eventID: UUID,
        requestID: UUID?
    ) async {
        logUnavailable()
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        ownerUserID: UUID,
        requestID: UUID?
    ) async {
        logUnavailable()
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async {
        logUnavailable()
    }

    func sendDomainEventPayloadBatches(
        _ batches: [IMGatewayDomainEventPayloadBatch],
        requestID: UUID?
    ) async {
        logUnavailable()
    }

    func sendDomainEventPayloads(
        _ deliveries: [IMCanonicalDomainEventDelivery],
        requestID: UUID?
    ) async {
        logUnavailable()
    }

    func sendStreamSignal(
        _ payload: IMTCPMessageStreamSignalPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async {
        logUnavailable()
    }

    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        logUnavailable()
    }

    func kickConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        logUnavailable()
    }

    func activeConnectionCounts(forSessionIDs sessionIDs: [UUID]) async -> [UUID: Int] {
        [:]
    }

    private func logUnavailable() {
        logger.warning(
            "Gateway session transport unavailable; realtime relay skipped",
            metadata: ["role": .string(role.rawValue)]
        )
    }
}

struct GatewaySessionService {
    let transport: any GatewaySessionTransport
    let routingMetrics: RoutingMetrics?

    init(
        transport: any GatewaySessionTransport,
        routingMetrics: RoutingMetrics? = nil
    ) {
        self.transport = transport
        self.routingMetrics = routingMetrics
    }

    func bind(_ connection: IMAuthenticatedConnection, control: IMConnectionControl) async throws {
        if let transport = transport as? LocalGatewaySessionTransport {
            try await transport.routingService.bind(connection, control: control)
        }
    }

    func remove(connectionID: UUID) async {
        if let transport = transport as? LocalGatewaySessionTransport {
            await transport.routingService.remove(connectionID: connectionID)
        }
    }

    func sendDomainEventDelivery(
        ownerUserID: UUID,
        eventID: UUID,
        requestID: UUID? = UUID()
    ) async {
        await transport.sendDomainEventDelivery(ownerUserID: ownerUserID, eventID: eventID, requestID: requestID)
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        ownerUserID: UUID,
        requestID: UUID? = UUID()
    ) async {
        await recordRealtimePayloadMetrics([
            RealtimePayloadMetricBatch(
                payload: payload,
                recipientCount: 1
            )
        ])
        await transport.sendDomainEventPayload(payload, ownerUserID: ownerUserID, requestID: requestID)
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID? = UUID()
    ) async {
        await recordRealtimePayloadMetrics([
            RealtimePayloadMetricBatch(
                payload: payload,
                recipientCount: userIDs.count
            )
        ])
        await transport.sendDomainEventPayload(payload, toUserIDs: userIDs, requestID: requestID)
    }

    func sendDomainEventPayloadBatches(
        _ batches: [IMGatewayDomainEventPayloadBatch],
        requestID: UUID? = UUID()
    ) async {
        await recordRealtimePayloadMetrics(
            batches.map {
                RealtimePayloadMetricBatch(
                    payload: $0.payload,
                    recipientCount: $0.recipientUserIDs.count
                )
            }
        )
        await transport.sendDomainEventPayloadBatches(batches, requestID: requestID)
    }

    func sendDomainEventPayloads(
        _ deliveries: [IMCanonicalDomainEventDelivery],
        requestID: UUID? = UUID()
    ) async {
        await recordRealtimePayloadMetrics(
            deliveries.map {
                RealtimePayloadMetricBatch(
                    payload: $0.payload,
                    recipientCount: 1
                )
            }
        )
        await transport.sendDomainEventPayloads(deliveries, requestID: requestID)
    }

    func sendStreamSignal(
        _ payload: IMTCPMessageStreamSignalPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID? = UUID()
    ) async {
        await transport.sendStreamSignal(payload, toUserIDs: userIDs, requestID: requestID)
    }

    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await transport.kickConnections(forSessionID: sessionID, reason: reason, message: message)
    }

    func kickConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await transport.kickConnections(forUserID: userID, reason: reason, message: message)
    }

    func activeConnectionCounts(forSessionIDs sessionIDs: [UUID]) async -> [UUID: Int] {
        await transport.activeConnectionCounts(forSessionIDs: sessionIDs)
    }

    private struct RealtimePayloadMetricBatch {
        let payload: IMTCPChatDomainEventPayload
        let recipientCount: Int
    }

    private func recordRealtimePayloadMetrics(_ batches: [RealtimePayloadMetricBatch]) async {
        guard let routingMetrics, !batches.isEmpty else {
            return
        }

        var payloadCount = 0
        var recipientDeliveryCount = 0
        var conversationSummaryCount = 0
        var omittedSummaryMemberIDPayloadCount = 0
        var omittedSummaryMemberIDTotalMembers = 0
        var emittedSummaryMemberIDPayloadCount = 0
        var emittedSummaryMemberIDTotalMembers = 0

        for batch in batches {
            payloadCount += 1
            recipientDeliveryCount += max(0, batch.recipientCount)
            guard let conversation = batch.payload.conversation else {
                continue
            }
            conversationSummaryCount += 1
            if conversation.memberCount > 0, conversation.memberUserIDs.isEmpty {
                omittedSummaryMemberIDPayloadCount += 1
                omittedSummaryMemberIDTotalMembers += conversation.memberCount
            } else if !conversation.memberUserIDs.isEmpty {
                emittedSummaryMemberIDPayloadCount += 1
                emittedSummaryMemberIDTotalMembers += conversation.memberUserIDs.count
            }
        }

        await routingMetrics.recordRealtimePayloadBuilt(
            payloadCount: payloadCount,
            recipientDeliveryCount: recipientDeliveryCount,
            conversationSummaryCount: conversationSummaryCount,
            omittedSummaryMemberIDPayloadCount: omittedSummaryMemberIDPayloadCount,
            omittedSummaryMemberIDTotalMembers: omittedSummaryMemberIDTotalMembers,
            emittedSummaryMemberIDPayloadCount: emittedSummaryMemberIDPayloadCount,
            emittedSummaryMemberIDTotalMembers: emittedSummaryMemberIDTotalMembers
        )
    }
}

protocol ConversationEventBus: Sendable {
    func publish(
        type: ConversationDomainEventType,
        conversationID: UUID,
        actorUserID: UUID?,
        payload: ConversationDomainEventPayload,
        recipientSnapshotUserIDs: [UUID]?,
        recipientSnapshotDeduplicationThreshold: Int,
        on database: (any Database)?
    ) async throws -> ConversationDomainEvent
}

protocol ConversationEventStreamProducer: Sendable {
    var driverName: String { get }
    func publish(_ envelope: ConversationEventStreamEnvelope) async throws
    func shutdown() async
}

extension ConversationEventStreamProducer {
    func shutdown() async {}
}
