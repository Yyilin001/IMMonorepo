import Foundation

/// 控制已接受或已编辑的消息内容是否进入持久审核流水线。
///
/// 关闭该通道不会改动既有任务，
/// 且刻意不会回填在关闭期间产生的消息。
public enum V2ContentReviewMode: String, Equatable, Sendable {
    case enabled
    case disabled

    package var enqueuesJobs: Bool { self == .enabled }
}
