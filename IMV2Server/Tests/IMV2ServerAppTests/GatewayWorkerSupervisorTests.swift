import Foundation
import Synchronization
import Testing
@testable import IMV2ServerApp

@Suite("网关后台任务生命周期")
struct GatewayWorkerSupervisorTests {
    @Test("所有已登记的任务在取消后均被等待")
    func cancellationDrainsEveryRegisteredTask() async {
        let supervisor = GatewayWorkerSupervisor()
        let completed = Mutex(0)
        for _ in 0..<3 {
            supervisor.start {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { /* 收到取消后结束。 */ }
                completed.withLock { $0 += 1 }
            }
        }

        supervisor.cancelAll()
        #expect(await supervisor.drain(timeout: .seconds(2)))
        #expect(completed.withLock { $0 } == 3)
    }

    @Test("未完成的任务会使排空失败，资源所有者不能提前关闭")
    func unfinishedTaskPreventsDrain() async {
        let supervisor = GatewayWorkerSupervisor()
        let gate = Gate()
        supervisor.start { await gate.wait() }

        supervisor.cancelAll()
        #expect(!(await supervisor.drain(timeout: .milliseconds(200))))
        await gate.release()
        #expect(await supervisor.drain(timeout: .seconds(2)))
    }
}

private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
