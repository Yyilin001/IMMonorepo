import Foundation
import Testing
@testable import IMV2ServerInfrastructure

@Suite("Shared persistence mechanisms")
struct V2PersistenceMechanismTests {
    @Test("Receipt clocks reject unsupported dates with the business error",
          arguments: [Double.nan, .infinity, -.infinity, -1, 0, 1e14])
    func invalidReceiptClock(_ seconds: Double) {
        #expect(throws: Failure.invalid) {
            try v2PersistenceMilliseconds(Date(timeIntervalSince1970: seconds), invalid: Failure.invalid)
        }
    }

    @Test("Receipt clocks preserve positive submillisecond truncation")
    func receiptClockTruncation() throws {
        #expect(try v2PersistenceMilliseconds(Date(timeIntervalSince1970: 0.0005), invalid: Failure.invalid) == 0)
        #expect(try v2PersistenceMilliseconds(Date(timeIntervalSince1970: 1.2345), invalid: Failure.invalid) == 1_234)
        #expect(try v2PositiveMilliseconds(Date(timeIntervalSince1970: 1e14), invalid: Failure.invalid) == 100_000_000_000_000_000)
        #expect(throws: Failure.invalid) { try v2PersistenceUnsigned(-1, invalid: Failure.invalid) }
    }

    @Test("A failed claimed item cancels siblings and waits for their cleanup", .timeLimit(.minutes(1)))
    func claimedBatchFailureDrainsChildren() async throws {
        let gate = BatchBarrier()
        await #expect(throws: Failure.work) {
            let _: Int = try await v2ProcessClaimedWorkBatch([0, 1], initial: 0, process: { item in
                await gate.arrive()
                if item == 0 { throw Failure.work }
                do { try await Task.sleep(for: .seconds(120)) }
                catch {
                    await gate.cleanedUp()
                    throw error
                }
                return item
            }, accumulate: { $0 += $1 })
        }
        #expect(await gate.cleanupCount == 1)
    }
}

private enum Failure: Error, Equatable { case invalid, work }

private actor BatchBarrier {
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cleanupCount = 0
    func arrive() async {
        arrived += 1
        if arrived == 2 {
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
    func cleanedUp() { cleanupCount += 1 }
}
