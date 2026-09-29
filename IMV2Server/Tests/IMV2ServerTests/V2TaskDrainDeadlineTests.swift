@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

struct V2TaskDrainDeadlineTests {
    @Test("task drain reports completion before its deadline")
    func reportsCompletion() async {
        let task = Task<Void, Never> {
            try? await Task.sleep(for: .milliseconds(1))
        }

        #expect(await v2WaitForTaskDrain([task], timeout: .seconds(1)))
    }

    @Test("task drain returns at its deadline for a non-cooperative task")
    func reportsTimeout() async {
        let task = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(5))
        }
        let startedAt = ContinuousClock.now

        #expect(!(await v2WaitForTaskDrain([task], timeout: .milliseconds(10))))
        #expect(startedAt.duration(to: .now) < .seconds(1))
        task.cancel()
    }
}
