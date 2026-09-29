import Crypto
import Foundation
import IMV2Core

/// 尚未获得持久化创建意图时使用的稳定候选分片选择器。
///
/// 意图存储会在归属工作开始之前先持久化选择结果，
/// 因此之后的配置变化只会影响新操作，不会改变已有创建过程。
public struct V2GroupRoomShardSelector: Equatable, Sendable {
    /// 参与选择的候选分片标识，已规范化并排序。
    public let shardIDs: [String]

    /// 以 `IM_V2_GROUP_ROOM_SHARD_ID` 使用的逗号分隔形式构造。
    ///
    /// 既有房间路由是持久化的，绝不会被重新哈希；该有序集合只会在新的创建意图
    /// 尚未固定归属之前参与选择。
    ///
    /// - Parameter rawValue: 逗号分隔的分片标识，元素会去除首尾空白。
    /// - Throws: 分片数量、空白元素或重复项不满足约束时抛出
    ///   ``V2GroupRoomCreationIntentStoreError/invalidIntent``。
    public init(rawValue: String) throws {
        try self.init(shardIDs: rawValue
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }

    /// 以分片标识列表构造选择器。
    ///
    /// 标识会去除首尾空白并排序，使同一集合的不同输入顺序得到相同结果。
    ///
    /// - Parameter shardIDs: 非空、无空白元素且无重复的标识列表，数量需落在 `1...64`。
    /// - Throws: 任一约束不满足时抛出
    ///   ``V2GroupRoomCreationIntentStoreError/invalidIntent``。
    public init(shardIDs: [String]) throws {
        let normalized = shardIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard (1 ... 64).contains(normalized.count),
              normalized.allSatisfy({ !$0.isEmpty }),
              Set(normalized).count == normalized.count
        else { throw V2GroupRoomCreationIntentStoreError.invalidIntent }
        self.shardIDs = normalized.sorted()
    }

    /// 为一次建群操作选择候选分片。
    ///
    /// 选择结果稳定：同一发起者与操作标识始终得到同一候选分片。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起建群的用户。
    ///   - operationID: 建群操作标识。
    /// - Returns: 选中的分片标识。
    public func shardID(
        actorUserID: UserID,
        operationID: GroupRoomOperationID
    ) -> String {
        guard shardIDs.count > 1 else { return shardIDs[0] }
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in (
            actorUserID.rawValue.lowercased()
                + "\u{0}"
                + operationID.rawValue.lowercased()
        ).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return shardIDs[Int(hash % UInt64(shardIDs.count))]
    }
}
