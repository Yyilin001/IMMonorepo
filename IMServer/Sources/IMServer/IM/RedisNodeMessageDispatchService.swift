import Foundation
import RediStack
import Vapor

final class RedisNodeMessageDispatchService: NodeMessageDispatchService, @unchecked Sendable {
    private let pool: RedisConnectionPool
    private let nodeID: String
    private let keyspace: IMRealtimeRedisKeyspace
    private let dispatchChannel: RedisChannelName
    private let logger: Logger

    init(
        pool: RedisConnectionPool,
        nodeID: String,
        cellID: String = IMRealtimeCellConfiguration.defaultCellID,
        logger: Logger
    ) {
        self.pool = pool
        self.nodeID = nodeID
        let keyspace = IMRealtimeRedisKeyspace(cellID: cellID)
        self.keyspace = keyspace
        self.dispatchChannel = RedisChannelName(keyspace.key("dispatch:node:\(nodeID)"))
        self.logger = logger
    }

    func start(app: Application) async throws {
        try await pool.subscribe(
            to: [dispatchChannel],
            messageReceiver: { [weak app] _, message in
                guard let app, let rawEnvelope = message.string else {
                    return
                }
                Task {
                    do {
                        let envelope = try JSONDecoder().decode(NodeMessageDispatchEnvelope.self, from: Data(rawEnvelope.utf8))
                        try await app.connectionRoutingService.handleRemoteDispatch(envelope)
                    } catch {
                        app.logger.warning(
                            "Failed to decode remote IM dispatch envelope",
                            metadata: [
                                "node_id": .string(app.imNodeID),
                                "route_backend": .string("redis"),
                                "error": .string(String(describing: error))
                            ]
                        )
                    }
                }
            }
        ).get()
    }

    func shutdown() async {}

    func dispatch(_ envelope: NodeMessageDispatchEnvelope, toNodeID nodeID: String) async throws {
        let payload = try JSONEncoder().encode(envelope)
        guard let encoded = String(data: payload, encoding: .utf8) else {
            throw RedisRoutingError.invalidDispatchPayload
        }
        _ = try await pool.publish(
            encoded,
            to: RedisChannelName(keyspace.key("dispatch:node:\(nodeID)"))
        ).get()
    }
}
