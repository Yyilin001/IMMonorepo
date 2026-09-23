import Foundation
import Synchronization

/// 等待已取消的服务任务收敛，同时不让单个不配合取消的 I/O 操作无限期拖住进程退出。
///
/// 这里刻意使用非结构化的竞速：结构化任务组在离开作用域前会等待全部子任务，
/// 一旦数据库驱动尚未感知取消，截止时间就形同虚设。调用方仍需在进入等待前取消全部来源任务，
/// 超时不代表任务已经结束；调用方应升级终止策略，不得在仍运行的任务下方释放连接池。
///
/// - Parameters:
///   - tasks: 已取消、等待收敛的任务列表。
///   - timeout: 最长等待时长，需大于零。
/// - Returns: 全部任务在截止时间内收敛时返回 `true`；超时返回 `false`。
public func v2WaitForTaskDrain(
    _ tasks: [Task<Void, Never>],
    timeout: Duration
) async -> Bool {
    precondition(timeout > .zero)
    guard !tasks.isEmpty else { return true }

    return await withCheckedContinuation { continuation in
        let race = V2TaskDrainRace(continuation: continuation)
        let drainTask = Task {
            for task in tasks { await task.value }
            race.resolve(true)
        }
        let timeoutTask = Task {
            do {
                try await v2Sleep(for: timeout)
                race.resolve(false)
            } catch {
                // The drain won and cancelled this timer.
            }
        }
        race.install(tasks: [drainTask, timeoutTask])
    }
}

/// 收敛等待与超时之间的单次竞速状态。
///
/// 首个解决者生效，另一方以及后续调用都会被取消或忽略，保证 continuation 只恢复一次。
private final class V2TaskDrainRace: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Bool, Never>?
        var tasks: [Task<Void, Never>] = []
        var resolved = false
    }

    private let state: Mutex<State>

    /// 保存等待方 continuation 与竞速任务。
    ///
    /// - Parameter continuation: 本次等待的 continuation。
    init(continuation: CheckedContinuation<Bool, Never>) {
        state = Mutex(.init(continuation: continuation))
    }

    /// 登记竞速任务；若竞速已结束则立即取消这些任务。
    ///
    /// - Parameter tasks: 本次竞速的两个任务。
    func install(tasks: [Task<Void, Never>]) {
        let cancel = state.withLock { state -> Bool in
            guard !state.resolved else { return true }
            state.tasks = tasks
            return false
        }
        if cancel { tasks.forEach { $0.cancel() } }
    }

    /// 以首个结果结束竞速并恢复等待方。
    ///
    /// 重复调用只生效一次，且总会取消另一方的任务。
    ///
    /// - Parameter drained: 任务是否已在截止时间前收敛。
    func resolve(_ drained: Bool) {
        let completion = state.withLock { state -> (
            CheckedContinuation<Bool, Never>?,
            [Task<Void, Never>]
        ) in
            guard !state.resolved else { return (nil, []) }
            state.resolved = true
            let continuation = state.continuation
            state.continuation = nil
            let tasks = state.tasks
            state.tasks = []
            return (continuation, tasks)
        }
        completion.1.forEach { $0.cancel() }
        completion.0?.resume(returning: drained)
    }
}
