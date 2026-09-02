import Foundation
import IMV2Compression
import IMV2Core
import Synchronization

/// Bounded process-local cache of fully serialized group-event page payloads.
///
/// Authorization and cursor visibility stay in `V2GroupEventLogStore` and run
/// for every request. This cache is reached only after that store has returned
/// an authorized immutable page. It stores no identity or membership fact.
/// Protocol v21 binds request correlation to the TLS frame header, allowing
/// the same protobuf payload to be shared without weakening request matching.
public final class V2PreparedGroupEventPageCache: Sendable {
    public struct Configuration: Equatable, Sendable {
        public let maximumEntries: Int
        public let maximumBytes: Int
        public let shardCount: Int

        public init(maximumEntries: Int, maximumBytes: Int, shardCount: Int) {
            precondition(maximumEntries > 0)
            precondition(maximumBytes > 0)
            precondition(shardCount > 0)
            precondition(shardCount <= maximumEntries)
            precondition(shardCount <= maximumBytes)
            self.maximumEntries = maximumEntries
            self.maximumBytes = maximumBytes
            self.shardCount = shardCount
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let entries: Int
        public let bytes: Int
        public let hits: UInt64
        public let misses: UInt64
        public let evictions: UInt64
    }

    struct PageKey: Hashable, Sendable {
        let protocolVersion: UInt8
        let roomID: String
        let firstEventID: String
        let lastEventID: String
        let firstRoomSequence: UInt64
        let lastRoomSequence: UInt64
        let eventCount: Int
        let nextRoomSequence: UInt64
        let hasMore: Bool

        init(
            protocolVersion: UInt8,
            roomID: String,
            firstEventID: String,
            lastEventID: String,
            firstRoomSequence: UInt64,
            lastRoomSequence: UInt64,
            eventCount: Int,
            nextRoomSequence: UInt64,
            hasMore: Bool
        ) {
            self.protocolVersion = protocolVersion
            self.roomID = roomID
            self.firstEventID = firstEventID
            self.lastEventID = lastEventID
            self.firstRoomSequence = firstRoomSequence
            self.lastRoomSequence = lastRoomSequence
            self.eventCount = eventCount
            self.nextRoomSequence = nextRoomSequence
            self.hasMore = hasMore
        }
    }

    private struct Representation: Sendable {
        let flags: V2FrameFlags
        let payload: Data
    }

    private final class Node: @unchecked Sendable {
        var plain: Representation?
        var compressed: Representation?
        var previous: PageKey?
        var next: PageKey?

        init(
            plain: Representation?,
            compressed: Representation?,
            previous: PageKey?,
            next: PageKey?
        ) {
            self.plain = plain
            self.compressed = compressed
            self.previous = previous
            self.next = next
        }

        var byteCost: Int {
            (plain?.payload.count ?? 0) + (compressed?.payload.count ?? 0)
        }
    }

    private struct State: Sendable {
        var nodes: [PageKey: Node] = [:]
        var leastRecentlyUsed: PageKey?
        var mostRecentlyUsed: PageKey?
        var bytes = 0
        var hits: UInt64 = 0
        var misses: UInt64 = 0
        var evictions: UInt64 = 0
    }

    private final class Shard: Sendable {
        let maximumEntries: Int
        let maximumBytes: Int
        let state = Mutex(State())

        init(maximumEntries: Int, maximumBytes: Int) {
            self.maximumEntries = maximumEntries
            self.maximumBytes = maximumBytes
        }
    }

    private let shards: [Shard]

    public init(configuration: Configuration) {
        shards = (0 ..< configuration.shardCount).map { index in
            Shard(
                maximumEntries: Self.partitionedLimit(
                    total: configuration.maximumEntries,
                    partitions: configuration.shardCount,
                    index: index
                ),
                maximumBytes: Self.partitionedLimit(
                    total: configuration.maximumBytes,
                    partitions: configuration.shardCount,
                    index: index
                )
            )
        }
    }

    /// Returns nil for non-group-page envelopes so callers can preserve the
    /// ordinary codec path. A cold representation has one producer inside its
    /// shard; followers reuse the result after the short bounded encode.
    func frame(
        for envelope: IMV2Envelope,
        frameVersion: UInt8,
        compression: V2NegotiatedFrameCompression?,
        maximumUncompressedPayloadBytes: Int,
        compressionThresholdBytes: Int,
        maximumExpansionRatio: Int
    ) throws -> V2Frame? {
        guard frameVersion >= 21,
              case .groupEventPage(let page)? = envelope.body
        else { return nil }
        let key = Self.key(page: page, protocolVersion: frameVersion)
        return try frame(
            for: key,
            requestID: envelope.requestID,
            compression: compression,
            maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
            compressionThresholdBytes: compressionThresholdBytes,
            maximumExpansionRatio: maximumExpansionRatio,
            envelope: { envelope }
        )
    }

    /// Early lookup used after the durable membership fence but before a
    /// cached event slice is copied into domain and protobuf arrays. The key
    /// is derived from immutable event metadata inside the room-cache shard;
    /// only a miss invokes `envelope`, making the hot hit allocation-free
    /// apart from the tiny request-specific frame header.
    func frame(
        for key: PageKey,
        requestID: UInt64,
        compression: V2NegotiatedFrameCompression?,
        maximumUncompressedPayloadBytes: Int,
        compressionThresholdBytes: Int,
        maximumExpansionRatio: Int,
        envelope: () throws -> IMV2Envelope
    ) throws -> V2Frame {
        precondition(key.protocolVersion >= 21)
        let wantsCompressed = compression == .zlib
        let shard = shards[Self.shardIndex(for: key, count: shards.count)]
        // Encoding a cold representation inside its shard is intentional:
        // the first caller becomes the single-flight producer while followers
        // for the same immutable page wait and then hit. Independent shards
        // continue in parallel, avoiding both duplicate serialization and the
        // process-wide mutex that a hot group can otherwise monopolize.
        let representation = try shard.state.withLock { state -> Representation in
            if let node = state.nodes[key],
               let cached = wantsCompressed ? node.compressed : node.plain {
                state.hits &+= 1
                Self.touch(key, node: node, state: &state)
                return cached
            }
            state.misses &+= 1
            let encoded = try V2ServerProtobufFrameCodec.encode(
                envelope(),
                frameVersion: key.protocolVersion,
                compression: compression,
                maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
                compressionThresholdBytes: compressionThresholdBytes,
                maximumExpansionRatio: maximumExpansionRatio,
                bindRequestIDToHeader: true
            )
            let prepared = Representation(flags: encoded.flags, payload: encoded.payload)
            if let node = state.nodes[key] {
                if wantsCompressed { node.compressed = prepared }
                else { node.plain = prepared }
                state.bytes += prepared.payload.count
                Self.touch(key, node: node, state: &state)
            } else if prepared.payload.count <= shard.maximumBytes {
                let node = Node(
                    plain: wantsCompressed ? nil : prepared,
                    compressed: wantsCompressed ? prepared : nil,
                    previous: state.mostRecentlyUsed,
                    next: nil
                )
                if let tail = state.mostRecentlyUsed {
                    state.nodes[tail]?.next = key
                } else {
                    state.leastRecentlyUsed = key
                }
                state.mostRecentlyUsed = key
                state.nodes[key] = node
                state.bytes += prepared.payload.count
            }
            Self.evictIfNeeded(
                maximumEntries: shard.maximumEntries,
                maximumBytes: shard.maximumBytes,
                state: &state
            )
            return prepared
        }
        return Self.frame(
            representation: representation,
            requestID: requestID,
            version: key.protocolVersion
        )
    }

    public func snapshot() -> Snapshot {
        shards.reduce(into: Snapshot(entries: 0, bytes: 0, hits: 0, misses: 0, evictions: 0)) {
            aggregate, shard in
            let value = shard.state.withLock {
                Snapshot(
                    entries: $0.nodes.count,
                    bytes: $0.bytes,
                    hits: $0.hits,
                    misses: $0.misses,
                    evictions: $0.evictions
                )
            }
            aggregate = .init(
                entries: aggregate.entries + value.entries,
                bytes: aggregate.bytes + value.bytes,
                hits: aggregate.hits &+ value.hits,
                misses: aggregate.misses &+ value.misses,
                evictions: aggregate.evictions &+ value.evictions
            )
        }
    }

    private static func partitionedLimit(total: Int, partitions: Int, index: Int) -> Int {
        total / partitions + (index < total % partitions ? 1 : 0)
    }

    private static func shardIndex(for key: PageKey, count: Int) -> Int {
        var hasher = Hasher()
        key.hash(into: &hasher)
        return Int(UInt(bitPattern: hasher.finalize()) % UInt(count))
    }

    private static func key(
        page: IMV2GroupEventPage,
        protocolVersion: UInt8
    ) -> PageKey {
        .init(
            protocolVersion: protocolVersion,
            roomID: page.roomID,
            firstEventID: page.events.first?.sourceEventID ?? "",
            lastEventID: page.events.last?.sourceEventID ?? "",
            firstRoomSequence: page.events.first?.roomSequence ?? 0,
            lastRoomSequence: page.events.last?.roomSequence ?? 0,
            eventCount: page.events.count,
            nextRoomSequence: page.nextRoomSequence,
            hasMore: page.hasMore_p
        )
    }

    private static func frame(
        representation: Representation,
        requestID: UInt64,
        version: UInt8
    ) -> V2Frame {
        .init(
            version: version,
            flags: representation.flags,
            command: .groupEventPage,
            requestID: requestID,
            payload: representation.payload
        )
    }

    private static func touch(_ key: PageKey, node: Node, state: inout State) {
        guard state.mostRecentlyUsed != key else { return }
        unlink(key, node: node, state: &state)
        node.previous = state.mostRecentlyUsed
        node.next = nil
        if let tail = state.mostRecentlyUsed {
            state.nodes[tail]?.next = key
        } else {
            state.leastRecentlyUsed = key
        }
        state.mostRecentlyUsed = key
    }

    private static func unlink(_ key: PageKey, node: Node, state: inout State) {
        if let previous = node.previous {
            state.nodes[previous]?.next = node.next
        } else if state.leastRecentlyUsed == key {
            state.leastRecentlyUsed = node.next
        }
        if let next = node.next {
            state.nodes[next]?.previous = node.previous
        } else if state.mostRecentlyUsed == key {
            state.mostRecentlyUsed = node.previous
        }
    }

    private static func evictIfNeeded(
        maximumEntries: Int,
        maximumBytes: Int,
        state: inout State
    ) {
        while state.nodes.count > maximumEntries || state.bytes > maximumBytes {
            guard let key = state.leastRecentlyUsed,
                  let node = state.nodes.removeValue(forKey: key)
            else { return }
            unlink(key, node: node, state: &state)
            state.bytes -= node.byteCost
            state.evictions &+= 1
        }
    }
}
