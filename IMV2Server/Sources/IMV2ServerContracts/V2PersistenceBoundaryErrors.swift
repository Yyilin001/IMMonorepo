import Foundation

/// 私聊存储错误。
public enum V2DirectMessagingStoreError: Error, Equatable, Sendable {
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}

public enum V2GroupMessagingStoreError: Error, Equatable, Sendable {
    case corruptPersistenceState
}

/// 社交关系存储错误。
public enum V2SocialRelationshipStoreError: Error, Equatable, Sendable {
    /// 发起者账号当前无效。
    case actorInactive
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}

public enum V2SyncStoreError: Error, Equatable, Sendable {
    case invalidRecordLimit
    case resetRequired
    case generationMismatch
    case acknowledgementBeyondWatermark
    case invalidOrExpiredSyncToken
    case invalidOrExpiredSyncReceipt
    case invalidSnapshot
    case resetAlreadyPending
    case snapshotBeyondWatermark
    case invalidSnapshotReceipt
    case noResetPending
    case snapshotFenceMismatch
    case snapshotExpiredOrInvalid
    case snapshotCheckpointUnavailable
    case syncLogSequenceGap
    case syncRecordTooLarge
    case deviceRevoked
}

/// 房间分片存储配置与查找错误。
public enum V2RoomShardStorageRegistryError: Error, Equatable, Sendable {
    /// 逻辑标识或 schema 格式无效。
    case invalidLocation
    /// 当前注册表中未配置请求的逻辑标识。
    case unknownShardID
}

/// 房间归属栅栏校验错误。
public enum V2RoomOwnerFenceError: Error, Equatable, Sendable { case ownerChanged }

/// 已读回执批处理错误。
public enum V2RoomReceiptAdmissionError: Error, Equatable, Sendable {
    case serverBusy
}

/// Invalid fixed placement or corrupt persisted bootstrap state.
public enum V2GroupRoomCreationIntentStoreError: Error, Equatable, Sendable {
    case invalidIntent, routeConflict, corruptPersistenceState
}
