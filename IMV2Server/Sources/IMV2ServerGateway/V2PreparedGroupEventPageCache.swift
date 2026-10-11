import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Compression
import IMV2Core
import Synchronization

/// 已完成序列化的群事件分页载荷的有界进程内缓存。
///
/// 授权与游标可见性仍由 `V2GroupEventLogStore` 负责，并对每次请求都执行。
/// 只有在存储返回了已授权的不可变分页之后才会命中该缓存，且缓存不保存任何身份或成员事实。
/// 当前协议把请求关联绑定到 TLS 帧头，使同一份 protobuf 载荷可以被共享，
/// 又不会削弱请求匹配的严格性。
public final class V2PreparedGroupEventPageCache: Sendable {
    /// 缓存配置。
    public struct Configuration: Equatable, Sendable {
        /// 最大条目数。
        public let maximumEntries: Int
        /// 最大字节数。
        public let maximumBytes: Int
        /// 分片数量。
        public let shardCount: Int

        /// 校验并保存配置。
        ///
        /// - Parameters:
        ///   - maximumEntries: 条目上限，需大于零。
        ///   - maximumBytes: 字节上限，需大于零。
        ///   - shardCount: 分片数量，需大于零且不超过条目与字节上限。
        ///
        /// 参数不满足上述关系时直接失败，避免出现无法容纳任何条目的分片。
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

    private struct Representation: Sendable {
        let flags: V2FrameFlags
        let payload: Data
    }

    private final class Node: @unchecked Sendable {
        var plain: Representation?
        var compressed: Representation?
        var previous: V2PreparedGroupEventPageKey?
        var next: V2PreparedGroupEventPageKey?

        init(
            plain: Representation?,
            compressed: Representation?,
            previous: V2PreparedGroupEventPageKey?,
            next: V2PreparedGroupEventPageKey?
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
        var nodes: [V2PreparedGroupEventPageKey: Node] = [:]
        var leastRecentlyUsed: V2PreparedGroupEventPageKey?
        var mostRecentlyUsed: V2PreparedGroupEventPageKey?
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

    /// 以配置创建缓存。
    ///
    /// - Parameter configuration: 缓存容量配置。
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

    /// 为非群分页信封返回 `nil`，使调用方保留普通编解码路径。
    ///
    /// 冷表示在分片内只有一个生产者；同一不可变分页的其他请求会等待这次短时有界编码，
    /// 随后直接命中缓存。
    ///
    /// - Parameters:
    ///   - envelope: 待编码信封。
    ///   - frameVersion: 协商的帧版本，必须为当前版本。
    ///   - compression: 协商的压缩方式。
    ///   - maximumUncompressedPayloadBytes: 未压缩载荷上限。
    ///   - compressionThresholdBytes: 启用压缩的阈值。
    ///   - maximumExpansionRatio: 解压膨胀比上限。
    /// - Returns: 已编码帧；非群分页信封返回 `nil`。
    /// - Throws: 编码失败或超出协商上限时抛出。
    func frame(
        for envelope: IMV2Envelope,
        frameVersion: UInt8,
        compression: V2NegotiatedFrameCompression?,
        maximumUncompressedPayloadBytes: Int,
        compressionThresholdBytes: Int,
        maximumExpansionRatio: Int
    ) throws -> V2Frame? {
        guard frameVersion == UInt8(IMV2ProtocolVersion.current),
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

    /// 在持久化成员栅栏通过之后、把缓存事件切片复制为领域与 protobuf 数组之前使用的提前查询。
    ///
    /// 键由房间缓存分片内不可变的事件元数据派生；只有未命中时才会调用 `envelope`，
    /// 因此热路径命中除极小的请求专属帧头之外不产生额外分配。
    ///
    /// - Parameters:
    ///   - key: 分页键，协议版本必须为当前版本。
    ///   - requestID: 本次请求标识。
    ///   - compression: 协商的压缩方式。
    ///   - maximumUncompressedPayloadBytes: 未压缩载荷上限。
    ///   - compressionThresholdBytes: 启用压缩的阈值。
    ///   - maximumExpansionRatio: 解压膨胀比上限。
    ///   - envelope: 未命中时构造信封的闭包。
    /// - Returns: 已编码帧。
    /// - Throws: 编码失败或超出协商上限时抛出。
    func frame(
        for key: V2PreparedGroupEventPageKey,
        requestID: UInt64,
        compression: V2NegotiatedFrameCompression?,
        maximumUncompressedPayloadBytes: Int,
        compressionThresholdBytes: Int,
        maximumExpansionRatio: Int,
        envelope: () throws -> IMV2Envelope
    ) throws -> V2Frame {
        precondition(key.protocolVersion == UInt8(IMV2ProtocolVersion.current))
        let wantsCompressed = compression == .zlib
        let shard = shards[Self.shardIndex(for: key, count: shards.count)]
        // 有意在分片内部编码未预热的表示：首位调用方成为单飞生产者，
        // 同一不可变页面的后续调用方等待后命中缓存。
        // 独立分片继续并行，既避免重复序列化，
        // 也避免热群组独占进程级互斥锁。
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

    /// 读取当前缓存快照。
    ///
    /// - Returns: 条目数、字节数与各项累计计数。
    public func snapshot() -> V2PreparedGroupEventPageCacheSnapshot {
        shards.reduce(into: V2PreparedGroupEventPageCacheSnapshot(entries: 0, bytes: 0, hits: 0, misses: 0, evictions: 0)) {
            aggregate, shard in
            let value = shard.state.withLock {
                V2PreparedGroupEventPageCacheSnapshot(
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

    private static func shardIndex(for key: V2PreparedGroupEventPageKey, count: Int) -> Int {
        var hasher = Hasher()
        key.hash(into: &hasher)
        return Int(UInt(bitPattern: hasher.finalize()) % UInt(count))
    }

    private static func key(
        page: IMV2GroupEventPage,
        protocolVersion: UInt8
    ) -> V2PreparedGroupEventPageKey {
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

    private static func touch(_ key: V2PreparedGroupEventPageKey, node: Node, state: inout State) {
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

    private static func unlink(_ key: V2PreparedGroupEventPageKey, node: Node, state: inout State) {
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
