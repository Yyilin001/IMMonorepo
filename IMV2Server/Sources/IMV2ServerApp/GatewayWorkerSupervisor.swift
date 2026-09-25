import Foundation
import IMV2Server

/// 统一登记网关后台任务，使启动集合与关停排空集合保持一致。
/// 此对象仅由服务生命周期任务访问；工作任务不会修改登记表。
final class GatewayWorkerSupervisor {
    private var tasks: [Task<Void, Never>] = []

    @discardableResult
    func start(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let task = Task(operation: operation)
        tasks.append(task)
        return task
    }

    func cancelAll() {
        for task in tasks { task.cancel() }
    }

    func drain(timeout: Duration) async -> Bool {
        await v2WaitForTaskDrain(tasks, timeout: timeout)
    }
}
