import Foundation

/// 面向相互独立持久化命令通道的有界加权轮转调度器。
///
/// 每轮每个通道各获得一个时间片，因此处于重试或严重积压中的低优先级通道
/// 无法无限期推迟撤回、审核、成员变更或回执动作。
public actor V2FairDurableCommandScheduler: V2CommandFlushControlling {
    private let flight = V2CommandFlushFlight<Int>()

    /// 单条命令通道。
    public struct Lane: Sendable {
        /// 推进一条持久化命令的闭包。
        public let flushOne: @Sendable () async throws -> Bool

        /// 以推进闭包构造通道。
        ///
        /// - Parameter flushOne: 返回 `true` 表示有一条持久化条目取得进展
        ///   （包括已落库的重试或拒绝），返回 `false` 表示该通道当前空闲。
        public init(flushOne: @escaping @Sendable () async throws -> Bool) {
            self.flushOne = flushOne
        }
    }

    private let lanes: [Lane]
    private var nextLaneIndex = 0

    /// 以通道列表构造调度器。
    ///
    /// - Parameter lanes: 待调度的通道，需非空。
    ///
    /// 通道为空时直接失败，避免出现无意义的空转。
    public init(lanes: [Lane]) {
        precondition(!lanes.isEmpty)
        self.lanes = lanes
    }

    /// 按轮转顺序推进至多指定数量的工作项。
    ///
    /// 有界批次可能在一轮中途结束，因此会保留下次起始位置，
    /// 使多次小批量调用之间仍然保持公平。
    ///
    /// - Parameter maximumWorkItems: 本轮最多推进的工作项数，需大于零。
    /// - Returns: 实际推进的工作项数。
    /// - Throws: 任务取消时抛出 `CancellationError`；其余错误来自通道闭包。
    @discardableResult
    public func flush(maximumWorkItems: Int) async throws -> Int {
        precondition(maximumWorkItems > 0)
        return try await flight.run { try await self.flushBatch(maximumWorkItems: maximumWorkItems) }
    }

    /// 暂停命令刷新。
    public func suspendCommandFlushing() async { await flight.suspend() }

    /// 恢复命令刷新。
    public func resumeCommandFlushing() async { await flight.resume() }

    /// 执行一轮实际的轮转推进。
    ///
    /// - Parameter maximumWorkItems: 本轮最多推进的工作项数。
    /// - Returns: 实际推进的工作项数。
    /// - Throws: 任务取消或通道闭包失败时抛出。
    private func flushBatch(maximumWorkItems: Int) async throws -> Int {
        var remaining = maximumWorkItems
        var completed = 0
        while remaining > 0 {
            var madeProgress = false
            for _ in lanes.indices {
                guard remaining > 0 else { break }
                try Task.checkCancellation()
                let lane = lanes[nextLaneIndex]
                // A bounded batch may end in the middle of a round. Keep
                // the next position so repeated small batches remain fair.
                nextLaneIndex = (nextLaneIndex + 1) % lanes.count
                guard try await lane.flushOne() else { continue }
                madeProgress = true
                completed += 1
                remaining -= 1
            }
            guard madeProgress else { break }
        }
        return completed
    }
}
