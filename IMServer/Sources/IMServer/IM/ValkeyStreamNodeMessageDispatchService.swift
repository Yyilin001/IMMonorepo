import Foundation
import Valkey
import Vapor

/// Durable node-to-node realtime dispatch for a Valkey Cluster deployment.
///
/// Every Gateway owns one hash-tagged stream. Publishers append pre-routed
/// envelopes to that stream, while the target Gateway acknowledges an entry
/// only after it has accepted the envelope for its local connection registry.
/// This preserves at-least-once delivery across a target Gateway restart.
final class ValkeyStreamNodeMessageDispatchService: NodeMessageDispatchService, @unchecked Sendable {
    private static let streamReadBlockMilliseconds = 1_000
    private static let streamReadCount = 100
    private static let pendingClaimIdleMilliseconds = 15_000
    private static let pendingClaimIntervalMilliseconds = 5_000
    private static let consumerGroupPrefix = "im-node-dispatch-v1"

    private let client: ValkeyClusterClient
    private let nodeID: String
    private let keyspace: IMRealtimeRedisKeyspace
    private let logger: Logger
    private let streamKey: ValkeyKey
    private let consumerGroup: String
    private let consumerName: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private weak var app: Application?
    private var readTask: Task<Void, Never>?

    init(
        client: ValkeyClusterClient,
        nodeID: String,
        cellID: String,
        logger: Logger
    ) {
        self.client = client
        self.nodeID = nodeID
        let keyspace = IMRealtimeRedisKeyspace(cellID: cellID)
        self.keyspace = keyspace
        self.logger = logger
        self.streamKey = ValkeyKey(keyspace.key(hashedBy: nodeID, suffix: "realtime:node-dispatch"))
        self.consumerGroup = "\(Self.consumerGroupPrefix):\(nodeID)"
        self.consumerName = "\(nodeID)-\(UUID().uuidString.lowercased())"
    }

    func start(app: Application) async throws {
        self.app = app
        try await ensureConsumerGroup()
        readTask = Task { [weak self] in
            await self?.consumeLoop()
        }
        logger.info("Valkey Stream node dispatch started.", metadata: [
            "node_id": .string(nodeID),
            "consumer_group": .string(consumerGroup),
            "transport": .string("valkey-stream")
        ])
    }

    func shutdown() async {
        readTask?.cancel()
        readTask = nil
        app = nil
    }

    func dispatch(_ envelope: NodeMessageDispatchEnvelope, toNodeID targetNodeID: String) async throws {
        let payload = try encoder.encode(envelope)
        guard let encoded = String(data: payload, encoding: .utf8) else {
            throw RedisRoutingError.invalidDispatchPayload
        }
        _ = try await client.xadd(
            streamKey(for: targetNodeID),
            idSelector: .autoId,
            data: [.init(field: "envelope", value: encoded)]
        )
        await app?.routingMetrics.recordDurableNodeDispatchEnqueued()
    }

    private func ensureConsumerGroup() async throws {
        do {
            try await client.xgroupCreate(
                streamKey,
                group: consumerGroup,
                idSelector: .id("0-0"),
                mkstream: true
            )
        } catch {
            guard String(describing: error).localizedCaseInsensitiveContains("BUSYGROUP") else {
                throw error
            }
        }
    }

    private func consumeLoop() async {
        var nextPendingClaimAt = Date.distantPast
        while !Task.isCancelled {
            do {
                if Date() >= nextPendingClaimAt {
                    try await reclaimPendingEntries()
                    nextPendingClaimAt = Date().addingTimeInterval(
                        Double(Self.pendingClaimIntervalMilliseconds) / 1_000
                    )
                }

                let response = try await client.xreadgroup(
                    groupBlock: .init(group: consumerGroup, consumer: consumerName),
                    count: Self.streamReadCount,
                    milliseconds: Self.streamReadBlockMilliseconds,
                    streams: .init(keys: [streamKey], ids: [">"])
                )
                guard let entries = response?.streams.first?.messages else {
                    continue
                }
                for entry in entries {
                    try await consume(entry)
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                await app?.routingMetrics.recordDurableNodeDispatchRetry()
                logger.warning("Valkey Stream node dispatch read failed; retaining entries for retry.", metadata: [
                    "node_id": .string(nodeID),
                    "consumer_group": .string(consumerGroup),
                    "error": .string(String(describing: error))
                ])
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func reclaimPendingEntries() async throws {
        let response = try await client.xautoclaim(
            streamKey,
            group: consumerGroup,
            consumer: consumerName,
            minIdleTime: String(Self.pendingClaimIdleMilliseconds),
            start: "0-0",
            count: Self.streamReadCount
        )
        for entry in response.messages {
            try await consume(entry)
        }
    }

    private func consume(_ entry: XREADGroupMessage) async throws {
        guard let fields = entry.fields else {
            try await acknowledge(entry.id)
            return
        }
        try await consume(entryID: entry.id, fields: fields)
    }

    private func consume(_ entry: XMessage) async throws {
        try await consume(entryID: entry.id, fields: entry.fields)
    }

    private func consume(
        entryID: String,
        fields: [(key: String, value: RESPBulkString)]
    ) async throws {
        guard let rawEnvelope = fields.first(where: { $0.key == "envelope" })?.value else {
            logger.error("Valkey Stream node dispatch entry has no envelope; acknowledging poison record.", metadata: [
                "node_id": .string(nodeID),
                "stream_entry_id": .string(entryID)
            ])
            try await acknowledge(entryID)
            return
        }

        let envelope: NodeMessageDispatchEnvelope
        do {
            envelope = try decoder.decode(
                NodeMessageDispatchEnvelope.self,
                from: Data(String(decoding: rawEnvelope, as: UTF8.self).utf8)
            )
        } catch {
            logger.error("Valkey Stream node dispatch envelope decode failed; acknowledging poison record.", metadata: [
                "node_id": .string(nodeID),
                "stream_entry_id": .string(entryID),
                "error": .string(String(describing: error))
            ])
            try await acknowledge(entryID)
            return
        }

        guard let app else {
            throw Abort(.serviceUnavailable, reason: "Valkey Stream node dispatch stopped before local delivery.")
        }
        try await app.connectionRoutingService.handleRemoteDispatch(envelope)
        try await acknowledge(entryID)
        await app.routingMetrics.recordDurableNodeDispatchAcknowledged()
    }

    private func acknowledge(_ entryID: String) async throws {
        _ = try await client.xack(streamKey, group: consumerGroup, ids: [entryID])
        _ = try await client.xdel(streamKey, ids: [entryID])
    }

    private func streamKey(for targetNodeID: String) -> ValkeyKey {
        ValkeyKey(keyspace.key(hashedBy: targetNodeID, suffix: "realtime:node-dispatch"))
    }
}
