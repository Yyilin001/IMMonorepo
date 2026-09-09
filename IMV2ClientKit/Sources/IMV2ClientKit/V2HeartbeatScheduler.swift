import Foundation

/// 按固定等待间隔发送心跳的调度器。
///
/// 应用拥有调用 run 的任务，可按前后台策略取消；停止心跳不应改变持久化同步的正确性。
/// 调度器不自动重连或重试发送失败。
public struct V2HeartbeatScheduler: Sendable {
    /// 实际发送并等待心跳响应的依赖。
    private let sender: any V2HeartbeatSender
    /// 一次发送完成后再等待的时间，不是严格的两次开始时间差。
    private let interval: Duration

    /// 创建心跳调度器，不启动后台任务。
    ///
    /// - Parameters:
    ///   - sender: 心跳发送实现。
    ///   - interval: 必须大于零的等待时长，否则触发前置条件失败。
    public init(sender: any V2HeartbeatSender, interval: Duration) {
        precondition(interval > .zero)
        self.sender = sender
        self.interval = interval
    }

    /// 立即发送一次心跳，之后每次发送完成再等待指定间隔。
    ///
    /// - Throws: 发送错误或睡眠取消错误会结束循环并向调用方传播。
    ///
    /// 每次发送读取 Date 当前时间。进入循环前若任务已经取消则正常返回；发送过程中是否响应取消由 sender 决定。
    /// 本方法不保证固定发送频率，网络耗时会叠加到间隔中。
    public func run() async throws {
        while !Task.isCancelled {
            try await sender.sendHeartbeat(clientTime: Date())
            try await Task.sleep(for: interval)
        }
    }
}
