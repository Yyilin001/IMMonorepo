import Vapor

struct IMSequenceAllocationConfiguration: Sendable {
    enum Mode: String, Sendable {
        case legacy
        case block
    }

    let mode: Mode
    let blockSize: Int

    static func load(from environment: Environment) -> IMSequenceAllocationConfiguration {
        IMSequenceAllocationConfiguration(
            mode: Environment.get("IM_SEQUENCE_ALLOCATION_MODE")
                .flatMap(Mode.init(rawValue:)) ?? .legacy,
            blockSize: max(1, Environment.get("IM_SEQUENCE_BLOCK_SIZE").flatMap(Int.init(_:)) ?? 256)
        )
    }
}

struct IMCommandOwnerRoutingConfiguration: Sendable {
    struct Node: Sendable {
        let id: String
        let baseURL: String
    }

    let nodeID: String?
    let nodes: [Node]
    let sharedSecret: String?

    var isEnabled: Bool {
        !nodes.isEmpty
    }

    static func load(from environment: Environment) -> IMCommandOwnerRoutingConfiguration {
        let nodes = (Environment.get("IM_COMMAND_NODE_URLS") ?? "")
            .split(separator: ",")
            .compactMap { raw -> Node? in
                let parts = raw.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let id = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let url = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, !url.isEmpty else { return nil }
                return Node(id: id, baseURL: url)
            }
        return IMCommandOwnerRoutingConfiguration(
            nodeID: Environment.get("IM_COMMAND_NODE_ID"),
            nodes: nodes,
            sharedSecret: Environment.get("IM_COMMAND_INTERNAL_SHARED_SECRET")
                ?? Environment.get("IM_INTERNAL_SHARED_SECRET")
        )
    }

    func owner(for conversationID: UUID) -> Node? {
        guard isEnabled else { return nil }
        let key = conversationID.uuidString.lowercased()
        return nodes.max { lhs, rhs in
            stableScore(key: key, nodeID: lhs.id) < stableScore(key: key, nodeID: rhs.id)
        }
    }

    func isLocalOwner(for conversationID: UUID) -> Bool {
        guard let owner = owner(for: conversationID) else { return true }
        return owner.id == nodeID
    }

    private func stableScore(key: String, nodeID: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(key)|\(nodeID)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

struct IMConversationMemberCacheConfiguration: Sendable {
    let ttlSeconds: Int

    var isEnabled: Bool { ttlSeconds > 0 }

    static func load(from environment: Environment) -> IMConversationMemberCacheConfiguration {
        IMConversationMemberCacheConfiguration(
            ttlSeconds: max(0, Environment.get("IM_CONVERSATION_MEMBER_CACHE_TTL_SECONDS").flatMap(Int.init(_:)) ?? 10)
        )
    }
}

struct IMMessageWriteBatchConfiguration: Sendable {
    let enabled: Bool
    let maxSize: Int
    let maxDelayMillis: Int
    let maxQueueDepthPerConversation: Int

    var isEnabled: Bool {
        enabled && maxSize > 1 && maxDelayMillis > 0
    }

    static func load(from environment: Environment) -> IMMessageWriteBatchConfiguration {
        let rawEnabled = Environment.get("IM_MESSAGE_WRITE_BATCH_ENABLED")?.lowercased()
        let enabled = rawEnabled.map { ["1", "true", "yes", "on"].contains($0) } ?? false
        return IMMessageWriteBatchConfiguration(
            enabled: enabled,
            maxSize: max(2, Environment.get("IM_MESSAGE_WRITE_BATCH_MAX_SIZE").flatMap(Int.init(_:)) ?? 32),
            maxDelayMillis: max(1, Environment.get("IM_MESSAGE_WRITE_BATCH_MAX_DELAY_MS").flatMap(Int.init(_:)) ?? 10),
            maxQueueDepthPerConversation: max(
                1,
                Environment.get("IM_MESSAGE_WRITE_BATCH_MAX_QUEUE_DEPTH").flatMap(Int.init(_:)) ?? 1_024
            )
        )
    }
}

struct IMCachedConversationMembership: Sendable {
    let conversationKind: IMConversationKind
    let directMessagingState: IMDirectMessagingState
    let memberUserIDs: [UUID]
}
