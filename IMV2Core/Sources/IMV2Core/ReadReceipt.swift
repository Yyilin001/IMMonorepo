import Foundation

/// 账户级已读披露偏好，独立于设备。
///
/// 阅读事实的采集与对其他参与者披露分开；私聊双方都允许时才相互可见，实际判断由服务端完成。
public struct V2ReadReceiptPreferences: Equatable, Sendable {
    /// 是否允许私聊已读披露。
    public let allowsDirectReadReceipts: Bool
    /// 是否允许群聊已读披露。
    public let allowsGroupReadReceipts: Bool
    /// 偏好更新时间，构造器不校验日期。
    public let updatedAt: Date

    /// 保存两个披露开关及更新时间，不执行远端偏好更新。
    public init(allowsDirectReadReceipts: Bool, allowsGroupReadReceipts: Bool, updatedAt: Date) {
        self.allowsDirectReadReceipts = allowsDirectReadReceipts
        self.allowsGroupReadReceipts = allowsGroupReadReceipts
        self.updatedAt = updatedAt
    }
}

/// 修改已读披露偏好的幂等命令，不直接改变已记录的阅读事实。
public struct V2SetReadReceiptPreferencesCommand: Equatable, Sendable {
    /// 发起偏好修改的用户。
    public let actorUserID: UserID
    /// 本次修改的稳定操作身份。
    public let operationID: ReadReceiptPreferenceOperationID
    /// 期望的私聊披露开关。
    public let allowsDirectReadReceipts: Bool
    /// 期望的群聊披露开关。
    public let allowsGroupReadReceipts: Bool

    /// 保存偏好修改字段，不校验权限或写入存储。
    public init(actorUserID: UserID, operationID: ReadReceiptPreferenceOperationID, allowsDirectReadReceipts: Bool, allowsGroupReadReceipts: Bool) {
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.allowsDirectReadReceipts = allowsDirectReadReceipts
        self.allowsGroupReadReceipts = allowsGroupReadReceipts
    }
}

/// 通过对方可靠同步流投递的私聊已读投影。
///
/// isVisible 为 false 表示隐私墓碑，消费者应立即移除本地缓存的已读信息，不能继续展示旧值。
public struct V2DirectReadReceiptProjection: Equatable, Sendable {
    /// 投影所属私聊房间。
    public let roomID: RoomID
    /// 阅读者身份。
    public let readerUserID: UserID
    /// 读到的房间序号，此投影允许零值。
    public let readThroughRoomSequence: UInt64
    /// 服务端记录时间。
    public let recordedAt: Date
    /// 是否允许展示；false 表示应清除已缓存披露。
    public let isVisible: Bool

    /// 校验读取序号不超过 Int64.max，越界抛出 outOfRange；允许零值，不校验日期或可见性与序号的组合。
    public init(roomID: RoomID, readerUserID: UserID, readThroughRoomSequence: UInt64, recordedAt: Date, isVisible: Bool) throws {
        guard readThroughRoomSequence <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID
        self.readerUserID = readerUserID
        self.readThroughRoomSequence = readThroughRoomSequence
        self.recordedAt = recordedAt
        self.isVisible = isVisible
    }
}

/// 已读列表中的公开阅读者身份，由服务端按消息受众及分页绑定的成员版本筛选。
public struct V2ReadReceiptReader: Equatable, Sendable {
    /// 分页及去重使用的不透明用户标识，不直接用作展示名。
    public let userID: UserID
    /// 用于展示的公开身份，必须属于同一用户。
    public let publicIdentity: V2PublicIdentity

    /// 要求 publicIdentity.userID 与 userID 一致，不满足时触发 precondition；调用方必须先校验外部数据，不能把它当可恢复的抛错入口。
    public init(userID: UserID, publicIdentity: V2PublicIdentity) {
        precondition(publicIdentity.userID == userID)
        self.userID = userID
        self.publicIdentity = publicIdentity
    }
}

/// 单条消息已读用户分页结果，带可选后续游标。
public struct V2ReadReceiptReadersPage: Equatable, Sendable {
    /// 查询房间。
    public let roomID: RoomID
    /// 查询消息。
    public let messageID: MessageID
    /// 本页阅读者列表，要求用户身份唯一。
    public let readers: [V2ReadReceiptReader]
    /// 不透明后续游标，nil 表示没有提供下一页。
    public let nextCursor: String?

    /// 校验本页 userID 无重复，否则抛出 invalidReaderPage；不检查跨页重复、页面大小或游标格式。
    public init(roomID: RoomID, messageID: MessageID, readers: [V2ReadReceiptReader], nextCursor: String?) throws {
        guard Set(readers.map(\.userID)).count == readers.count else {
            throw V2ReadReceiptValidationError.invalidReaderPage
        }
        self.roomID = roomID
        self.messageID = messageID
        self.readers = readers; self.nextCursor = nextCursor
    }
}

/// 用户明确阅读行为的幂等声明，与设备传输确认及同步 ACK 分开。
///
/// 已读位置只允许向前推进，由服务端事务与现有值比较；构造器只校验单个输入范围。
public struct V2RecordReadReceiptCommand: Equatable, Sendable {
    /// 已读房间。
    public let roomID: RoomID
    /// 声明已读的用户。
    public let actorUserID: UserID
    /// 本次阅读声明稳定操作身份。
    public let operationID: ReadReceiptOperationID
    /// 用户已读到的正房间序号。
    public let readThroughRoomSequence: UInt64

    /// 要求已读序号在 1 到 Int64.max，越界抛出 invalidRoomSequence；不检查消息存在性或用户访问权限。
    public init(roomID: RoomID, actorUserID: UserID, operationID: ReadReceiptOperationID, readThroughRoomSequence: UInt64) throws {
        guard readThroughRoomSequence > 0, readThroughRoomSequence <= UInt64(Int64.max) else {
            throw V2ReadReceiptValidationError.invalidRoomSequence
        }
        self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID
        self.readThroughRoomSequence = readThroughRoomSequence
    }
}

/// 服务端记录的用户房间已读位置及记录时间。
public struct V2ReadReceipt: Equatable, Sendable {
    /// 已读位置所属房间。
    public let roomID: RoomID
    /// 阅读用户。
    public let userID: UserID
    /// 已持久化的正房间序号。
    public let readThroughRoomSequence: UInt64
    /// 服务端记录时间，模型不校验日期范围。
    public let recordedAt: Date

    /// 校验已读序号在 1 到 Int64.max，越界抛出 outOfRange；不校验与旧位置的单调关系或日期。
    public init(roomID: RoomID, userID: UserID, readThroughRoomSequence: UInt64, recordedAt: Date) throws {
        guard readThroughRoomSequence > 0, readThroughRoomSequence <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID; self.userID = userID
        self.readThroughRoomSequence = readThroughRoomSequence; self.recordedAt = recordedAt
    }
}

/// 已读业务校验错误；invalidRoomSequence 表示命令序号无效，invalidReaderPage 表示同页存在重复阅读者。
public enum V2ReadReceiptValidationError: Error, Equatable, Sendable { case invalidRoomSequence, invalidReaderPage }
