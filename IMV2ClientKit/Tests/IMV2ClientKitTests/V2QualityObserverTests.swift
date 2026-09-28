import Testing
@testable import IMV2ClientKit

struct V2QualityObserverTests {
    @Test func staleSamplesCannotCreateConsecutiveBadWindows() async {
        let observer = V2QualityObserver()
        for index in 0..<20 { await observer.record(.timeout, service: "api", now: Double(index) / 10) }
        for time in [100.0, 110, 120, 130] { await observer.record(.success, service: "api", now: time) }
        #expect(await observer.quality(for: "api") == .normal)
    }

    @Test func sparseWindowsCannotReuseOldSamplesToDowngrade() async {
        let observer = V2QualityObserver()
        for index in 0..<5 { await observer.record(.timeout, service: "api", now: Double(index)) }
        for time in [10.0, 20, 30, 40] { await observer.record(.timeout, service: "api", now: time) }
        #expect(await observer.quality(for: "api") == .normal)
    }

    @Test func onlyFreshHealthyWindowsRecoverTheAffectedService() async {
        let observer = V2QualityObserver()
        for window in 0..<2 {
            for index in 0..<20 {
                await observer.record(.timeout, service: "api", now: Double(window * 10) + Double(index) / 10)
            }
        }
        await observer.record(.timeout, service: "api", now: 20)
        #expect(await observer.quality(for: "api") == .degraded)
        #expect(await observer.quality(for: "media") == .normal)
        for time in 21..<61 {
            await observer.record(.transportFailure, service: "api", now: Double(time))
            await observer.record(.serviceCooldown, service: "api", now: Double(time))
            await observer.record(.localProcessing, service: "api", now: Double(time))
        }
        #expect(await observer.quality(for: "api") == .degraded)
        for window in 0..<3 {
            for index in 0..<20 {
                await observer.record(.success, service: "api", now: 100 + Double(window * 10) + Double(index) / 10)
            }
            #expect(await observer.quality(for: "api") == .degraded)
        }
        await observer.record(.success, service: "api", now: 130)
        #expect(await observer.quality(for: "api") == .normal)
    }

    @Test func invalidAndBackwardClocksDoNotPoisonObservation() async {
        let observer = V2QualityObserver()
        for clock in [Double.nan, .infinity, -.infinity, -1] {
            await observer.record(.timeout, service: "api", now: clock)
        }
        for window in 0..<2 {
            for index in 0..<5 {
                await observer.record(.timeout, service: "api", now: 100 + Double(window * 10 + index))
                await observer.record(.success, service: "api", now: 1)
            }
        }
        await observer.record(.timeout, service: "api", now: 120)
        #expect(await observer.quality(for: "api") == .degraded)
    }
}
