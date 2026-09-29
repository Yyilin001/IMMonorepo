@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import Synchronization
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

/// The claim sees a normal clock; subsequent failure handling sees the boundary.
final class V2WorkerRetryClockFixture: Sendable {
    private let calls = Mutex(0)
    let failureTime: Date
    let policy: V2DurableRetryPolicy
    init(_ boundary: Int) {
        let seconds: [Double] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
                                 9_224_318_016_000 - 0.5, 9_224_318_016_000 - 10,
                                 946_684_800 + 0.00000025, 1_750_000_000]
        let delay = boundary == 6 ? 0.0001 : boundary == 7 ? 0.00000025 : boundary == 8 ? Double.leastNonzeroMagnitude : 1
        failureTime = Date(timeIntervalSince1970: seconds[boundary])
        policy = .init(initialDelay: delay, maximumDelay: delay, maximumAttempts: 3, jitterFraction: 0)
    }
    func now() -> Date {
        calls.withLock { count in
            defer { count += 1 }
            return count == 0 ? Date(timeIntervalSince1970: 1_750_000_000) : failureTime
        }
    }
}
