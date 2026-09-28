import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 群房间创建意图的状态。
public enum V2GroupRoomCreationIntentState: String, Equatable, Sendable {
    /// 已准备，尚未提交归属事务。
    case prepared
    /// 归属事务已提交，路由已确定。
    case committed
}

/// 一次建群操作不可变的控制面身份。
///
/// 生成的标识与归属会在跨库工作开始之前固定；此后只有状态可以从已准备推进到已提交。
public struct V2GroupRoomCreationIntent: Equatable, Sendable {
    /// 发起建群的用户。
    public let actorUserID: UserID
    /// 建群操作标识。
    public let operationID: GroupRoomOperationID
    /// 预分配的房间标识。
    public let roomID: RoomID
    /// 建群事件标识。
    public let eventID: EventID
    /// 逻辑房间分片标识，已去除首尾空白。
    public let roomShardID: String
    /// 路由代次。
    public let routeEpoch: Int64
    /// 请求指纹，需为 32 字节。
    public let requestFingerprint: Data
    /// 受众成员数量，含群主。
    public let audienceMemberCount: Int
    /// 当前状态。
    public let state: V2GroupRoomCreationIntentState

    /// 校验并保存建群意图。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起建群的用户。
    ///   - operationID: 建群操作标识。
    ///   - roomID: 预分配的房间标识。
    ///   - eventID: 建群事件标识。
    ///   - roomShardID: 逻辑分片标识，去除首尾空白后需非空。
    ///   - routeEpoch: 非负的路由代次。
    ///   - requestFingerprint: 请求指纹，需为 32 字节。
    ///   - audienceMemberCount: 受众成员数量，需落在 `1...100000`。
    ///   - state: 初始状态，默认已准备。
    /// - Throws: 任一约束不满足时抛出
    ///   ``V2GroupRoomCreationIntentStoreError/invalidIntent``。
    public init(
        actorUserID: UserID,
        operationID: GroupRoomOperationID,
        roomID: RoomID,
        eventID: EventID,

        roomShardID: String,
        routeEpoch: Int64,
        requestFingerprint: Data,
        audienceMemberCount: Int,
        state: V2GroupRoomCreationIntentState = .prepared
    ) throws {
        let shard = roomShardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shard.isEmpty, routeEpoch >= 0, requestFingerprint.count == 32,
              (1 ... 100_000).contains(audienceMemberCount)
        else {
            throw V2GroupRoomCreationIntentStoreError.invalidIntent
        }
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.roomID = roomID
        self.eventID = eventID
        self.roomShardID = shard
        self.routeEpoch = routeEpoch
        self.requestFingerprint = requestFingerprint
        self.audienceMemberCount = audienceMemberCount
        self.state = state
    }

    /// 以同一身份派生指定状态的新意图。
    ///
    /// - Parameter state: 目标状态。
    /// - Returns: 除状态外字段完全一致的意图。
    /// - Throws: 字段校验失败时抛出
    ///   ``V2GroupRoomCreationIntentStoreError/invalidIntent``。
    fileprivate func withState(
        _ state: V2GroupRoomCreationIntentState
    ) throws -> Self {
        try .init(
            actorUserID: actorUserID,
            operationID: operationID,
            roomID: roomID,
            eventID: eventID,

            roomShardID: roomShardID,
            routeEpoch: routeEpoch,
            requestFingerprint: requestFingerprint,
            audienceMemberCount: audienceMemberCount,
            state: state
        )
    }
}

/// Invalid fixed placement or corrupt persisted bootstrap state.
public enum V2GroupRoomCreationIntentStoreError: Error, Equatable, Sendable {
    case invalidIntent, routeConflict, corruptPersistenceState
}
