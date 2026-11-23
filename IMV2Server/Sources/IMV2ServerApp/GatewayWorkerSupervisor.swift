import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Server
import IMV2ServerInfrastructure
import Synchronization

/// 统一登记网关后台任务，使启动集合与关停排空集合保持一致。
/// 此对象仅由服务生命周期任务访问；工作任务不会修改登记表。
final class GatewayWorkerSupervisor {
    private final class Completion: Sendable {
        let finished = Mutex(false)
    }

    private var workers: [(source: String, task: Task<Void, Never>, completion: Completion)] = []

    @discardableResult
    func start(file: StaticString = #fileID, line: UInt = #line,
               _ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let completion = Completion()
        let task = Task {
            await operation()
            completion.finished.withLock { $0 = true }
        }
        workers.append((source: "\(file):\(line)", task: task, completion: completion))
        return task
    }

    func cancelAll() {
        for worker in workers { worker.task.cancel() }
    }

    func drain(timeout: Duration) async -> Bool {
        await v2WaitForTaskDrain(workers.map(\.task), timeout: timeout)
    }

    var unfinishedSources: [String] {
        workers.compactMap { worker in
            worker.completion.finished.withLock { $0 ? nil : worker.source }
        }
    }
}
