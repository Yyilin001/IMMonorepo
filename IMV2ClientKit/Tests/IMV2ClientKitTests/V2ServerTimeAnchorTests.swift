import Foundation
import Testing
@testable import IMV2ClientKit

@Suite("Server time anchored command deadlines")
struct V2ServerTimeAnchorTests {
    @Test(arguments: [-120.0, -30.0, 30.0, 120.0])
    func deviceClockDoesNotChangeServerWindow(skew: Double) throws {
        let serverMilliseconds: Int64 = 1_800_000_000_000
        let local = Date(timeIntervalSince1970: Double(serverMilliseconds) / 1000 + skew)
        let anchor = V2ServerTimeAnchor()
        try anchor.observe(milliseconds: serverMilliseconds)
        let localDeadline = UInt64((local.timeIntervalSince1970 + 86_395) * 1000)
        let deadline = try anchor.submissionDeadline(localDeadline: localDeadline, localNow: local,
            maximumRemainingSeconds: 86_395)
        #expect(deadline > UInt64(serverMilliseconds))
        #expect(deadline - UInt64(serverMilliseconds) <= 86_400_000)
    }

    @Test func resetAndStaleSamplesCannotIssueCommands() throws {
        let anchor = V2ServerTimeAnchor()
        let instant = ContinuousClock.now
        try anchor.observe(milliseconds: 1_800_000_000_000, receivedAt: instant)
        #expect(throws: V2ServerTimeAnchor.Failure.self) { try anchor.now(at: instant + .seconds(3601)) }
        anchor.reset()
        #expect(throws: V2ServerTimeAnchor.Failure.self) { try anchor.now() }
    }
}
