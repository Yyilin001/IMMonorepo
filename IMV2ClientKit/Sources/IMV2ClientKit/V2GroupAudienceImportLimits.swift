import Foundation

/// 持久化发件箱与 protobuf 适配器共用的受众分页上限，同时保证帧安全。
///
/// 一页追加恰好是一个公平调度时间片：UUID 载荷因此远低于 64 KiB 实时帧上限，
/// 又不会让单个大群在重连刷新时独占配额。
public enum V2GroupAudienceImportLimits {
    /// 单次追加允许携带的最大成员数。
    public static let maximumMembersPerAppend = 512
}
