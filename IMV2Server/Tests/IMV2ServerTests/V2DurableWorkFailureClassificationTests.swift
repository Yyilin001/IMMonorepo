@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

struct V2DurableWorkFailureClassificationTests {
    private let policy = V2DurableRetryPolicy.standard
    private let claimToken = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("Transient failures retry without ever pausing and cap their backoff")
    func transientFailuresNeverPause() {
        for attempt in [1, 3, 10, 50, 10_000, Int(Int32.max), Int.max - 1, Int.max] {
            let disposition = policy.disposition(
                attempt: attempt, claimToken: claimToken, now: base, kind: .transient
            )
            #expect(disposition != .pause)
            guard case .retry(let retryAt) = disposition else { return }
            #expect(retryAt > base)
            #expect(retryAt.timeIntervalSince(base) <= policy.maximumDelay)
        }
    }

    @Test("Deterministic failures pause on the first attempt instead of spending the budget")
    func deterministicFailuresPauseImmediately() {
        #expect(
            policy.disposition(attempt: 1, claimToken: claimToken, now: base, kind: .deterministic)
                == .pause
        )
    }

    @Test("The budgeted disposition keeps its attempt limit for unclassified callers")
    func budgetedDispositionIsUnchanged() {
        #expect(policy.disposition(attempt: 1, claimToken: claimToken, now: base) != .pause)
        #expect(
            policy.disposition(attempt: policy.maximumAttempts, claimToken: claimToken, now: base)
                == .pause
        )
    }

    @Test("Only proven invariant violations are classified as deterministic")
    func classifierStaysConservative() {
        #expect(
            v2DurableWorkFailureKind(for: V2RoomWriteStoreError.corruptPersistenceState)
                == .deterministic
        )
        #expect(
            v2DurableWorkFailureKind(for: V2MessageEditStoreError.corruptPersistenceState)
                == .deterministic
        )
        // 时钟、延迟或容量无法编码时，其余存储走的是优雅降级路径而不是数据损坏；
        // 把它们判为确定性会破坏既有降级行为。
        #expect(
            v2DurableWorkFailureKind(for: V2ForwardExportError.corruptPersistenceState)
                == .transient
        )
        #expect(
            v2DurableWorkFailureKind(
                for: V2ReadReceiptPreferencePropagationError.corruptPersistenceState
            ) == .transient
        )
        // 依赖缺失是可恢复的：同一行在依赖恢复后仍能完成。
        #expect(
            v2DurableWorkFailureKind(
                for: V2ReadReceiptPreferencePropagationError.missingControlProjection
            ) == .transient
        )
        struct TransientDependencyError: Error {}
        #expect(v2DurableWorkFailureKind(for: TransientDependencyError()) == .transient)
    }
}
