import Foundation

/// 提供命令重试的持久化时间查询与变更通知。
///
/// 数据库记录是调度依据；通知只要求重新查询，不携带必须逐条处理的业务事件，因此可以合并通知。
public struct V2CommandRetrySchedule: Sendable {
    /// 查询当前最早的重试时间；没有待调度命令时返回 `nil`。
    let nextAttemptAt: @Sendable () async throws -> Date?
    /// 订阅可能影响最早重试时间的变更。流结束会使等待中的调度循环退出。
    let updates: @Sendable () async -> AsyncThrowingStream<Void, any Error>

    /// 创建重试时间来源。
    ///
    /// - Parameters:
    ///   - nextAttemptAt: 每次唤醒后读取持久化状态的查询；返回有限的日期值或 `nil`。
    ///   - updates: 建立变更订阅的闭包；通知可以合并，查询必须能够读取完整的当前状态。
    public init(
        nextAttemptAt: @escaping @Sendable () async throws -> Date?,
        updates: @escaping @Sendable () async -> AsyncThrowingStream<Void, any Error>
    ) {
        self.nextAttemptAt = nextAttemptAt
        self.updates = updates
    }
}

/// 重试调度自身发现的数据错误。查询、通知流和刷新错误会直接向上传播。
enum V2CommandRetrySchedulerError: Error, Equatable, Sendable {
    /// 重试日期或当前日期的 Unix 时间不是有限数值。
    case invalidDate
}

/// 根据持久化重试时间驱动命令刷新。
///
/// 先订阅变更再查询，避免查询与注册等待之间遗漏唤醒。未来的重试时间以最长 60 秒的单调时钟等待分段检查，
/// 每次醒来重新读取墙上时钟和持久化时间，以响应客户端运行期间的系统时钟调整。
struct V2CommandRetryScheduler: Sendable {
    /// 重试时间及数据库变更通知来源。
    let schedule: V2CommandRetrySchedule
    /// 处理当前到期命令的操作；必须推进命令状态或重试时间，避免持续读取同一到期记录造成忙循环。
    let flush: @Sendable () async throws -> Void
    /// 可注入的当前墙上时钟，用于比较持久化日期及验证时间边界。
    var now: @Sendable () -> Date = Date.init

    /// 持续处理已到期工作，并在变更通知或分段计时结束后重新查询。
    ///
    /// 没有重试日期时等待通知。一次刷新后立即重新查询，即使最早时间没有变化，也能继续处理有批量上限的剩余工作。
    /// 通知最多缓冲一次；刷新操作应自行控制单批工作量。
    ///
    /// - Throws: 无效日期错误，以及查询、通知流或刷新操作的错误。循环检测到取消时抛出 `CancellationError`；
    ///   等待中的流若正常结束，则直接返回。
    ///
    /// 退出时取消观察任务和计时任务，但不等待它们完全退出。
    func run() async throws {
        let signal = AsyncThrowingStream<Void, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Subscribe before querying. A change racing with the query or sleep
        // registration remains buffered, closing the lost-wakeup window.
        let changes = await schedule.updates()
        let observer = Task {
            do {
                for try await _ in changes { signal.continuation.yield(()) }
                signal.continuation.finish()
            } catch { signal.continuation.finish(throwing: error) }
        }
        var timer: Task<Void, Never>?
        defer {
            timer?.cancel()
            observer.cancel()
            signal.continuation.finish()
        }
        var iterator = signal.stream.makeAsyncIterator()
        while !Task.isCancelled {
            if let due = try await schedule.nextAttemptAt() {
                let current = now()
                guard due.timeIntervalSince1970.isFinite, current.timeIntervalSince1970.isFinite else {
                    throw V2CommandRetrySchedulerError.invalidDate
                }
                let delay = due.timeIntervalSince(current)
                if delay <= 0 {
                    try await flush()
                    // A bounded flush may leave ready work without changing
                    // the earliest timestamp. Re-read and continue ourselves.
                    continue
                }
                timer = Task {
                    do {
                        // Date is durable; Task.sleep uses a monotonic clock.
                        // Re-evaluate wall-clock changes at least every minute.
                        try await Task.sleep(for: .seconds(min(delay, 60)))
                        signal.continuation.yield(())
                    } catch { }
                }
            }
            guard try await iterator.next() != nil else { return }
            timer?.cancel()
            timer = nil
        }
        throw CancellationError()
    }
}
