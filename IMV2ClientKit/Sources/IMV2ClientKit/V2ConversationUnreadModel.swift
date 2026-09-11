import Foundation
import IMV2Core

/// 会话列表展示未读所需的本设备已读水位读取能力。
///
/// 只回答"我已经读到哪个房间序号"，不回答未读本身：未读数的权威在服务端摘要，
/// 本地水位唯一的用途是在等待服务端确认期间把计数**变小**。
public protocol V2ClientRoomReadWatermarkReading: Sendable {
    /// 批量读取若干房间的有效已读水位。
    ///
    /// - Parameter roomIDs: 目标房间，调用方需传入有界集合。
    /// - Returns: 有水位记录的房间到水位的映射。
    /// - Throws: 本地读取失败。
    func roomReadWatermarks(roomIDs: [RoomID]) async throws -> [RoomID: UInt64]
}

extension GRDBV2LocalSyncStore: V2ClientRoomReadWatermarkReading {}

/// 未读展示的唯一换算规则。
///
/// 服务端未读是权威值：
///
/// ```
/// 服务端未读 = head − max(服务端已读线, 我最新消息序号)
/// ```
///
/// 本地能做的只有"我已经读到 head"这一件事，因此展示值取两者较小：
///
/// ```
/// 展示未读 = min(服务端未读, max(head − 本地已读水位, 0))
/// ```
///
/// - 本地水位领先服务端（刚进入房间、回执还在路上）：`head − 本地水位` 更小且正确，
///   这正是"进入房间即已读"无需等待往返的原因。
/// - 本地水位落后服务端（投影还没到）：服务端更小，取服务端，绝不虚报。
/// - 没有本地水位：退化为服务端值。
///
/// 规则只减不增：任何本地状态都不可能把未读显示得比服务端更大，因此一次乐观推进
/// 不会掩盖真实未读。
public enum V2ClientConversationUnread {
    /// 计算展示用未读数。
    ///
    /// - Parameters:
    ///   - serverUnread: 服务端摘要给出的未读数。
    ///   - head: 房间日志头。
    ///   - localWatermark: 本设备已读水位；未知时为 `nil`。
    /// - Returns: 展示用未读数。
    public static func displayedUnread(serverUnread: UInt64, head: UInt64, localWatermark: UInt64?) -> UInt64 {
        let watermark = localWatermark ?? 0
        let remaining = head > watermark ? head - watermark : 0
        return min(serverUnread, remaining)
    }
}

/// 会话列表中的一行未读展示数据：服务端值加上本设备已读水位。
public struct V2ClientConversationUnreadRow: Equatable, Sendable {
    /// 房间标识。
    public let roomID: RoomID
    /// 房间日志头。
    public let head: UInt64
    /// 服务端未读数，权威值。
    public let serverUnreadCount: UInt64
    /// 本设备有效已读水位；未同步到时为空。
    public let localReadWatermark: UInt64?
    /// 展示用未读数。
    public let displayedUnread: UInt64

    /// 保存一行未读展示数据。
    ///
    /// - Parameters:
    ///   - roomID: 房间标识。
    ///   - head: 房间日志头。
    ///   - serverUnreadCount: 服务端未读数。
    ///   - localReadWatermark: 本设备有效已读水位。
    ///   - displayedUnread: 展示用未读数。
    public init(roomID: RoomID, head: UInt64, serverUnreadCount: UInt64, localReadWatermark: UInt64?, displayedUnread: UInt64) {
        self.roomID = roomID
        self.head = head
        self.serverUnreadCount = serverUnreadCount
        self.localReadWatermark = localReadWatermark
        self.displayedUnread = displayedUnread
    }
}
